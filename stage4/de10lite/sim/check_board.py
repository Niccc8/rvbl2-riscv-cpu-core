#!/usr/bin/env python3
"""check_board.py - verify the DE10-Lite desk lane in simulation, end to end.

    python stage4/de10lite/sim/check_board.py                 # everything (Verilator, in WSL)
    python stage4/de10lite/sim/check_board.py --pass full --only modes faults
    python stage4/de10lite/sim/check_board.py --only smoke --sim icarus --pass full

The whole board runs (tb_board.v: lanex_board with the chip, its ROM and every
fabric block), driven like the real desk lane - switches, KEY1, KEY0, the
ultrasonic sensor over the lane, a laptop on the host link - and logs every pin
change and byte that reaches the chip, every byte it sends, and every change a
person could see on the displays, LEDs and lamps. Then:

  V2  the golden model (lane_model.py) replays exactly what the chip received,
      run by run (each chip reset starts a new run), and must produce exactly
      the bytes the chip sent - whatever the fabric did; the laptop receives
      exactly those bytes. (Runs during an injected fault are not compared.)
  V2  each vehicle's decision is the one the scenario means (PROTOCOL.md
      section 6, worked out here, independently of the model);
  V3  every snapshot of the displays, LEDs, lamps and buzzer is what
      07_max10_prototype.md section 4 says for the chip's last record;
  V3  no flicker: at real speed, nothing a person sees lasts 5-150 ms unless
      it is meant to (the sensor's own readings while a vehicle is under it);
  V4  tour mode replays the 12 AWS ./emu lines (each run checked by the model
      too), paced and steady, and shows PASS12;
  V5  frames from the laptop are merged whole; garbage, half, oversize frames,
      frames during the tour or the boot never reach the chip;
  V8  every mode change, reset, fault and random abuse ends in a working lane
      (each scenario ends with a vehicle that must be decided correctly).

Scenario families: matrix (every tag preset x vehicle x lane state), host
(the laptop), tour, edges (vehicle shapes), modes (every mode change and
mid-vehicle switch change), faults (sensor lost, parked vehicle, a silent chip
and the watchdog), chaos (seeded random sessions: switches, KEY0/KEY1, the
sensor, the laptop, the tour, all at random), glitch (real time).

Passes: "full" (a board ms = 3,125 clocks: time runs 10x fast, every check but flicker),
"stress" (100 clocks: frames outlast vehicles; model comparison only), "real"
(31,250 clocks and the sensor's real 62.5 ms: the flicker analysis).
"""
import argparse
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "stage4"))
sys.path.insert(0, os.path.join(ROOT, "application", "testbench"))
import gen_de10lite as D      # noqa: E402
import lane_model as L        # noqa: E402

BUILD = os.path.join(ROOT, "build", "de10lite")
CLK = 31250000
CPB = (CLK + 57600) // 115200      # clocks per UART bit
FARES = L.DEFAULT_FARES
CAR_MM, LORRY_MM = 40, 90         # toy heights above the floor (the board's lorry threshold: 60 mm)
SW_MUTE, SW_LOWBUZZ = 1 << 7, 1 << 6
DEC_MS, FARE_FROM = 4000, 2500    # lanex_board.v: a decision's word, then its fare
ALL = ["matrix", "host", "tour", "edges", "modes", "faults", "chaos1", "chaos2", "chaos3", "chaos4"]
# pass: (tick, sonar period in clocks, checks: "all" | "model", scenarios)
PASSES = {
    "full":   (3125, 50000, "snap", ALL),
    "stress": (100, 50000, "model", ALL),
    "real":   (31250, CLK // 16, "all", ["glitch"]),
}


def sw_word(preset=0, closed=0, override=0, manual=0, tour=0, mute=0, lowbuzz=0):
    return closed | override << 1 | preset << 3 | lowbuzz << 6 | mute << 7 | manual << 8 | tour << 9


# ---------------------------------------------------------------------------
# Scenarios (the tb_board.v stimulus language)
# ---------------------------------------------------------------------------
class Stim:
    def __init__(self, name, tail_intent=False):
        self.name, self.lines, self.intent = name, [], []
        self.tail_intent = tail_intent         # only the last len(intent) decisions are meant

    def add(self, *a):
        self.lines.append(" ".join(str(x) for x in a))

    def set_sw(self, **kw):
        self.add("S", "%03x" % sw_word(**kw))
        self.add("W", 20)

    def snap(self, tag):
        self.add("D", tag)

    def host(self, b):
        self.add("X", len(b), " ".join("%02x" % x for x in b))

    def drive(self, kind, hold=5):
        """A vehicle's shape under the sensor (heights in mm, hold in readings) or on KEY1."""
        a = self.add
        if kind == "car":
            a("U", CAR_MM); a("Y", hold); a("U", 0)
        elif kind == "lorry":                          # the cab, then the tall body
            a("U", 50); a("Y", 2); a("U", LORRY_MM); a("Y", hold); a("U", 0)
        elif kind == "lorry_body_first":               # reversed in: the tall part first
            a("U", LORRY_MM); a("Y", hold); a("U", 50); a("Y", 2); a("U", 0)
        elif kind == "gappy":                          # a dip (a window, a gap) of 2 readings
            a("U", CAR_MM); a("Y", 3); a("U", 8); a("Y", 2); a("U", CAR_MM); a("Y", 3); a("U", 0)
        elif kind == "manual":                         # SW8 up: KEY1 is the vehicle
            a("K", 1); a("W", 300); a("K", 0)
        elif kind == "tap":                            # KEY1 pressed for 40 ms
            a("K", 1); a("W", 40); a("K", 0)
        else:
            raise ValueError(kind)

    def vehicle(self, kind, intent, hold=5, gap=1600, snaps=True):
        """One vehicle, its decision awaited; `intent`: the (status, fare) the
        scenario means, or None where either order of events is legal."""
        self.drive(kind, hold)
        self.decided(intent, snaps)
        self.add("W", gap)

    def decided(self, intent, snaps=True):
        self.intent.append(intent)
        self.add("V")
        if snaps:
            self.snap("dec")                           # just after the record: its word
            self.add("W", 1600)
            self.snap("dec2")                          # then its fare

    def text(self):
        return "\n".join(self.lines + ["E"]) + "\n"


def intended(preset, phys, closed=0):
    """The decision PROTOCOL.md section 6 gives (worked out here, not by the model)."""
    if closed:
        return (6, 0)
    if preset in (0, 6, 7):                    # no usable tag: none, damaged, the next lane's
        return (5, 0) if phys == 0 else (1, 0)
    if preset == 4:
        return (3, 0)                          # on the hotlist
    if preset == 5:
        return (4, 0)                          # seen 40 km away 30 s ago
    tagc = {1: 1, 2: 3, 3: 4}[preset]
    ok = (phys == 1) if tagc == 4 else (tagc == phys)
    return (0, FARES[tagc]) if ok else (2, FARES[phys])


def boot(s):
    s.add("W", 5)
    s.snap("boot")                             # the lamp test
    s.add("N")
    s.snap("id")                               # "Id.56dE" after the banner
    s.add("M")
    s.snap("idle")


def warm(s):
    """After the tour (SW9 down) or the watchdog: the chip restarts, then the lane."""
    s.add("I")
    s.snap("id")
    s.add("M")


def scenario_matrix():
    """Every tag preset x every vehicle shape; then every preset with the lane closed."""
    s = Stim("matrix")
    boot(s)
    shapes = [("car", 0, 1), ("lorry", 0, 3), ("manual", 0, 1), ("car", 1, 2), ("car", 3, 0),
              ("lorry", 3, 0)]                          # SW2:1 overrides the height
    n = 0
    for kind, override, phys in shapes:
        for preset in range(8):
            n += 1
            s.set_sw(preset=preset, override=override, manual=int(kind == "manual"),
                     mute=int(n % 5 == 0), lowbuzz=int(n % 7 == 0))
            s.vehicle(kind, intended(preset, phys))
    for preset in range(8):
        s.set_sw(preset=preset, closed=1)
        s.add("W", 3300)                       # the last decision's 4 s are over
        s.snap("idle")                         # CLOSEd
        s.vehicle("lorry" if preset % 2 else "car", intended(preset, 1, 1))
    s.set_sw(preset=1)
    s.add("W", 6000)
    s.snap("idle")
    return s


def scenario_host():
    """The laptop as the back office: its frames merged whole with the board's."""
    s = Stim("host")
    boot(s)
    cab = D.PRESETS[3][1]
    s.set_sw(preset=3)
    s.host(L.f_hot_add(cab))                   # report the taxi's tag stolen
    s.add("Q")
    s.vehicle("car", (3, 0))                   # -> StOLEn
    s.add("W", 2000)
    s.host(L.f_hot_del(cab))                   # cleared again
    s.vehicle("car", (0, FARES[4]))            # -> charged at the taxi fare
    s.host(L.f_config(1, 1, FARES))            # the back office closes the lane
    s.add("W", 3300)
    s.snap("idle")                             # CLOSEd (P7, from the chip)
    s.set_sw(preset=1)
    s.vehicle("car", (6, 0))
    s.host(L.f_config(1, 0, FARES))            # and opens it
    s.add("W", 3300)
    s.snap("idle")
    s.host(L.f_query())                        # stats
    s.add("W", 400)
    bad = bytearray(L.f_time(5))
    bad[5] ^= 0x04
    s.host(bytes(bad))                         # line noise -> 'E' reason 1
    s.add("W", 400)
    s.snap("err1")
    s.host(b"\x00\x11\x22\x5a")                # not a frame: ignored by the fabric
    s.host(L.f_identify()[:2])                 # half a frame, then silence: dropped
    s.add("W", 1500)
    s.host(bytes([0xA5, 0x52, 0x40]) + bytes(70))   # length 64: dropped by the fabric
    s.add("W", 1500)
    s.host(L.f_identify())                     # the chip measures its ROM again
    s.add("I")
    s.snap("id")
    s.add("W", 2500)
    s.set_sw(preset=2)
    s.add("U", LORRY_MM); s.add("Y", 2)              # a laptop frame while a vehicle passes
    s.host(L.f_hot_add(D.PRESETS[2][1]))
    s.add("Y", 2); s.add("U", 0)
    s.decided(None, snaps=False)               # before or after its read: both legal
    s.add("W", 3500)
    s.set_sw(preset=1)
    s.vehicle("car", (0, FARES[1]))
    return s


def scenario_tour():
    """SW9: the 12 AWS ./emu lines, each from reset; then the lane again."""
    s = Stim("tour")
    boot(s)
    s.set_sw(preset=1, tour=1)
    s.add("T")
    s.snap("pass")
    s.set_sw(preset=1)
    warm(s)
    s.vehicle("car", (0, FARES[1]))
    return s


def scenario_edges():
    """Shapes the toy lane will produce, and the controls in between."""
    s = Stim("edges")
    boot(s)
    s.set_sw(preset=1)
    s.vehicle("gappy", (0, FARES[1]), gap=400)
    s.vehicle("car", (1, 0), gap=3500)         # the same tag again within 3 s: tailgating
    s.set_sw(preset=2)
    s.vehicle("lorry_body_first", (0, FARES[3]))
    s.set_sw(preset=1)
    s.add("U", 10); s.add("Y", 6); s.add("U", 0); s.add("Y", 4)   # 10 mm: a hand, not a vehicle
    s.set_sw(preset=1, manual=1)
    s.add("Z", 0)                              # the sensor unplugged: manual mode still works
    s.vehicle("manual", (0, FARES[1]), gap=400)
    s.add("Z", 1); s.add("Y", 3)
    s.vehicle("tap", (1, 0), gap=3500)         # a quick press, the same tag within 3 s: tailgating
    s.set_sw(preset=5)
    s.vehicle("car", (4, 0), gap=200)          # a clone ...
    s.set_sw(preset=4)
    s.vehicle("car", (3, 0), gap=200)          # ... and a stolen car right behind it
    s.set_sw(preset=0)
    s.add("W", 3000)
    s.add("K", 1); s.add("I"); s.add("K", 0)   # KEY1 (not manual): identify, answered at once
    s.snap("id")
    s.add("W", 2500)
    s.set_sw(preset=1, closed=1)
    s.add("W", 300)
    s.snap("idle")
    s.set_sw(preset=1)
    s.add("W", 300)
    s.snap("idle")
    s.set_sw(preset=3, override=1)             # a taxi tag on a van
    s.vehicle("car", (2, FARES[2]))
    return s


def scenario_modes():
    """Every way to change mode, and every switch changed in the middle of things."""
    s = Stim("modes")
    s.add("W", 5)
    s.snap("boot")
    s.add("W", 2500)                           # in the banner ...
    s.set_sw(preset=1, tour=1)                 # ... SW9 up: the tour starts at once
    s.add("T"); s.snap("pass")
    s.set_sw(preset=1); warm(s); s.snap("idle")
    s.vehicle("car", (0, FARES[1]))
    for cut in (3000, 700, 100):               # tours cut short, mid-line and at once
        s.set_sw(preset=1, tour=1); s.add("W", cut); s.set_sw(preset=1); warm(s)
    s.set_sw(preset=1, tour=1); s.add("T"); s.snap("pass")      # two whole tours in a row
    s.set_sw(preset=1); warm(s)
    s.set_sw(preset=1, tour=1); s.add("T"); s.snap("pass")
    s.set_sw(preset=1); warm(s)
    s.add("S", "%03x" % sw_word(preset=1, tour=1)); s.add("W", 4)   # SW9 flicked under 10 ms:
    s.add("S", "%03x" % sw_word(preset=1)); s.add("W", 60)          # the debounce ignores it
    s.snap("idle")
    s.add("W", 3500)
    # mid-vehicle changes
    s.add("U", CAR_MM); s.add("Y", 3); s.set_sw(preset=1, closed=1); s.add("Y", 2); s.add("U", 0)
    s.decided((6, 0))                          # closed when it leaves: LANE CLOSED
    s.set_sw(preset=1); s.add("W", 1500)
    s.add("U", CAR_MM); s.add("Y", 3); s.set_sw(preset=1, override=3); s.add("Y", 2); s.add("U", 0)
    s.decided(intended(1, 0))                  # the class it had while there: a motorcycle
    s.set_sw(preset=1); s.add("W", 3500)
    s.add("U", CAR_MM); s.add("Y", 3); s.set_sw(preset=4); s.add("Y", 2); s.add("U", 0)
    s.decided((0, FARES[1]))                   # the tag was read on arrival: CAr, not StOLEn
    s.set_sw(preset=3); s.add("W", 1500)
    s.add("U", CAR_MM); s.add("Y", 3); s.set_sw(preset=3, manual=1)
    s.decided((0, FARES[4]))                   # SW8 up mid-vehicle: it leaves (KEY1 is up)
    s.add("U", 0); s.set_sw(preset=2); s.add("Y", 4)
    s.add("U", LORRY_MM); s.add("Y", 3); s.add("K", 1); s.add("I"); s.add("K", 0); s.add("Y", 2); s.add("U", 0)
    s.decided((0, FARES[3]))                   # KEY1 identify while a lorry is there
    s.add("W", 2500)
    s.host(L.f_key(b"another key 0123"))       # the laptop tries a new key: refused, 'E' 7
    s.add("W", 400); s.snap("err7")
    s.add("W", 2500)
    s.set_sw(preset=3, tour=1)                 # laptop frames during the tour are dropped
    s.host(L.f_hot_add(D.PRESETS[3][1])); s.host(L.f_query()); s.host(L.f_identify())
    s.add("T"); s.snap("pass")
    s.set_sw(preset=3); warm(s)
    s.vehicle("car", (0, FARES[4]))            # ... so the taxi is not stolen
    # KEY0 (reset) in the middle of things
    s.add("U", CAR_MM); s.add("Y", 3); s.add("R")                  # a vehicle under the sensor
    s.add("W", 1500); s.add("U", 0)            # it is taken away during the boot: the floor is relearnt
    s.host(L.f_identify())                     # (and a laptop frame in the boot: dropped)
    s.add("N"); s.snap("id"); s.add("M")
    s.set_sw(preset=3, tour=1); s.add("W", 2000); s.add("R")       # reset mid-tour, SW9 still up:
    s.add("T"); s.snap("pass")                 # the tour starts again from the cold boot
    s.set_sw(preset=1); warm(s)
    s.add("W", 3500)
    s.vehicle("car", (0, FARES[1]))            # and the lane works
    return s


def scenario_faults():
    """Things that break: the sensor, a parked vehicle, a chip that stops answering."""
    s = Stim("faults")
    boot(s)
    s.set_sw(preset=1)
    s.add("U", CAR_MM); s.add("Y", 4); s.add("Z", 0)   # the sensor unplugged under a car:
    s.decided((0, FARES[1]))                   # 1 s of no readings and the car has left
    s.add("U", 0); s.add("Z", 1); s.add("Y", 4); s.add("W", 3500)
    s.add("Z", 0); s.set_sw(preset=1, manual=1)         # unplugged, idle: manual mode
    s.vehicle("manual", (0, FARES[1]))
    s.set_sw(preset=2); s.add("Z", 1); s.add("Y", 4)
    s.add("U", LORRY_MM); s.add("Y", 150); s.add("U", 0)    # a lorry parked under the sensor
    s.decided((0, FARES[3]))
    s.add("W", 3500)
    s.set_sw(preset=1)
    s.add("F", 1)                              # the chip falls silent (fault injection)
    s.drive("car")
    s.add("W", 3200)                           # watchdog (1.5 s): warm boot; no 'I' -> "no Id"
    s.snap("noid")
    s.add("F", 0)
    s.add("M"); s.add("W", 3500)
    s.add("K", 1); s.add("I"); s.add("K", 0)   # KEY1: the chip measures its ROM again: LEDR9 back
    s.snap("id"); s.add("W", 2500)
    s.vehicle("car", (0, FARES[1]))            # the restarted chip decides again
    return s


CHAOS_FRAMES = [L.f_query(), L.f_identify(), L.f_config(1, 1, FARES), L.f_config(1, 0, FARES),
                L.f_hot_add(D.PRESETS[3][1]), L.f_hot_del(D.PRESETS[3][1]),
                b"\x00\xff\xa5", bytes([0xA5, 0x51]), bytes([0xA5, 0x52, 0x40]) + bytes(40),
                bytes(L.f_time(7)[:-1]) + b"\x00"]


def scenario_chaos(seed):
    """A random session: anything a visitor (or a nervous presenter) can do, in
    any order, then two vehicles that must come out right: one without a
    reset, one after KEY0."""
    rng = random.Random(seed)
    s = Stim("chaos%d" % seed, tail_intent=True)
    boot(s)
    sw, plugged = sw_word(preset=1), True
    s.add("S", "%03x" % sw); s.add("W", 20)
    for _ in range(140):
        r = rng.random()
        if r < 0.30:                                          # an object under the sensor
            h = rng.choice([8, 20, CAR_MM, 55, 65, LORRY_MM, 120])
            s.add("U", h)
            s.add("Y" if plugged else "W", rng.randint(1, 8) if plugged else rng.randint(20, 400))
            if rng.random() < 0.2:
                s.add("U", rng.choice([0, 10, h])); s.add("Y" if plugged else "W", 2 if plugged else 50)
            s.add("U", 0)
            s.add("Y" if plugged else "W", rng.randint(0, 5) if plugged else rng.randint(10, 300))
        elif r < 0.45:                                        # a switch
            bit = rng.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9])
            sw ^= 1 << bit
            s.add("S", "%03x" % sw); s.add("W", rng.choice([3, 15, 60, 300, 2000]))
        elif r < 0.55:                                        # KEY1
            s.add("K", 1); s.add("W", rng.choice([3, 12, 40, 300, 900])); s.add("K", 0)
            s.add("W", rng.randint(0, 400))
        elif r < 0.68:                                        # the laptop
            s.host(rng.choice(CHAOS_FRAMES)); s.add("W", rng.randint(0, 300))
        elif r < 0.73:                                        # the sensor unplugged / back
            plugged = not plugged
            s.add("Z", int(plugged)); s.add("W", rng.randint(50, 1500))
        elif r < 0.76:                                        # KEY0
            s.add("R"); s.add("W", rng.randint(0, 3000))
        else:
            s.add("W", rng.choice([10, 100, 600, 2500, 6000]))
    # recovery 1, no reset: every switch down, the lane opened by the back office
    if not plugged:
        s.add("Z", 1)
    s.add("U", 0)
    s.set_sw(preset=2)
    s.add("W", 6000)                                          # out of a tour, its warm boot
    s.add("M")
    s.host(L.f_config(1, 0, FARES)); s.host(L.f_hot_del(D.PRESETS[3][1]))
    s.add("W", 4000)
    s.vehicle("lorry", (0, FARES[3]))
    # recovery 2: KEY0, then a car
    s.add("R"); s.add("N"); s.snap("id"); s.add("M"); s.snap("idle")
    s.set_sw(preset=1)
    s.vehicle("car", (0, FARES[1]))
    return s


def scenario_glitch():
    """At real speed: what a person sees, for the flicker analysis - the boot, a
    charge, an alarm, a manual vehicle, the whole tour and its warm boot. A
    person's own actions come at least 0.6 s apart, as a person's do."""
    s = Stim("glitch")

    def sw(**kw):
        s.add("S", "%03x" % sw_word(**kw)); s.add("W", 600)
    boot(s)
    s.add("W", 600)
    for preset in (1, 4):                                    # a charge, an alarm
        sw(preset=preset)
        s.vehicle("car", intended(preset, 1), gap=2000)
    sw(preset=3, manual=1)
    s.vehicle("manual", (0, FARES[4]), gap=3000)
    sw(preset=3, tour=1)
    s.add("T"); s.snap("pass"); s.add("W", 1000)
    s.add("S", "%03x" % sw_word(preset=3)); warm(s)       # (wait for the warm boot's 'I' at once)
    s.add("W", 600)
    sw(preset=1, closed=1); s.add("W", 1000); sw(preset=1)
    return s


def scenario_smoke():
    s = Stim("smoke")
    boot(s)
    s.set_sw(preset=1)
    s.vehicle("car", (0, FARES[1]))
    return s


SCENARIOS = {"matrix": scenario_matrix, "host": scenario_host, "tour": scenario_tour,
             "edges": scenario_edges, "modes": scenario_modes, "faults": scenario_faults,
             "glitch": scenario_glitch, "smoke": scenario_smoke}
for _k in (1, 2, 3, 4):
    SCENARIOS["chaos%d" % _k] = (lambda k: (lambda: scenario_chaos(k)))(_k)


# ---------------------------------------------------------------------------
# Running the simulation
# ---------------------------------------------------------------------------
def wsl_path(p):
    p = os.path.abspath(p).replace("\\", "/")
    return "/mnt/%s%s" % (p[0].lower(), p[2:]) if p[1] == ":" else p


def run(sim, names, pas, tick, sonar):
    os.makedirs(BUILD, exist_ok=True)
    files = {}
    for n in names:
        stim, log = (os.path.join(BUILD, "%s_%s.%s" % (n, pas, x)) for x in ("stim", "log"))
        with open(stim, "w", newline="\n") as f:
            f.write(SCENARIOS[n]().text())
        files[n] = (stim, log)
    if sim == "verilator":
        out = "/tmp/lanex_vtb_%d_%d" % (tick, sonar)
        build = "bash %s %s 115200 %d %d" % (wsl_path(os.path.join(HERE, "build_vtb.sh")), out, tick, sonar)
        runs = " & ".join("%s/obj/vtb +stim=%s +log=%s > /dev/null" % (out, wsl_path(st), wsl_path(lg))
                          for st, lg in files.values())
        r = subprocess.run(["wsl.exe", "--", "bash", "-lc", "%s && { %s & wait; }" % (build, runs)],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit("verilator run failed:\n" + r.stdout + r.stderr)
    else:
        src = [os.path.join(HERE, "tb_board.v")] + [os.path.join(HERE, "..", f) for f in
                                                       ("lanex_board.v", "lanex_data.v", "lanex_chip.v")]
        vvp = os.path.join(BUILD, "tb_board_%d.vvp" % tick)
        subprocess.run(["iverilog", "-g2005", "-o", vvp, "-s", "tb_board", "-Ptb_board.TICK_DIV=%d" % tick,
                        "-Ptb_board.SONAR_PERIOD=%d" % sonar] + src, check=True)
        for st, lg in files.values():
            subprocess.run(["vvp", "-n", vvp, "+stim=" + st, "+log=" + lg], check=True, capture_output=True)
    return files


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------
SEG = {v: i for i, v in enumerate(D.FONT)}


def render(chars6, dp=0):
    """6 characters, left to right -> the 48-bit hex_n the board drives (0 = lit)."""
    v = 0
    for i, ch in enumerate(chars6):
        seg = D.FONT[D.code(ch)] | (0x80 if dp >> (5 - i) & 1 else 0)
        v |= (~seg & 0xFF) << (8 * (5 - i))
    return v


def show(hex_n):
    """48-bit hex_n -> readable text ('.' after a lit decimal point)."""
    out = ""
    for i in range(6):
        b = ~(hex_n >> (8 * (5 - i))) & 0xFF
        out += D.CHARS[SEG[b & 0x7F]] if (b & 0x7F) in SEG else "?"
        out += "." if b & 0x80 else ""
    return out


def fare_text(fare):
    """sen -> "  7.50" (the decimal point is HEX2's)."""
    d = "%05d" % fare
    return " " + (d[0] if d[0] != "0" else " ") + (d[1] if d[:2] != "00" else " ") + d[2:]


class Checker:
    def __init__(self):
        self.fails, self.checks = [], 0

    def ok(self, cond, what):
        self.checks += 1
        if not cond:
            self.fails.append(what)


def is_lane_run(m):
    """The board's own runs start with its boot frames (RSSI floor 30, the demo
    key); the tour's runs are the ./emu lines, none of which sets both."""
    return m.rssi_min == D.RSSI_FLOOR and m.key == L.DEMO_KEY


def check(name, log, rom, level, tick):
    st = SCENARIOS[name]()
    ck = Checker()
    ev = [l.split() for l in open(log) if l.strip() and not l.startswith("#")]
    ck.ok(ev and ev[-1][0] == "END", "the simulation did not reach the end of its stimulus (%s)"
          % (" ".join(ev[-1]) if ev else "empty log"))
    full = level in ("all", "snap")         # "all": also the flicker analysis (real time)
    # the switches and the height under the sensor as the stimulus had them at each snapshot
    at, sw, obj, plugged = [], 0, 0, True
    for l in st.lines:
        p = l.split()
        if p[0] == "S":
            sw = int(p[1], 16)
        elif p[0] == "U":
            obj = int(p[1])
        elif p[0] == "Z":
            plugged = p[1] == "1"
        elif p[0] == "D":
            # LEDR0: something under a working sensor (not in manual mode, which ignores it)
            at.append((p[1], sw, int(obj >= 15 and plugged and not sw >> 8 & 1)))
    at = iter(at)

    runs, m, got, host_out, rec = [], None, [], [], bytearray()
    run_start, cut = 0, []
    fault, run_faulted = False, False
    seen = {"V": None, "signed": False, "E": None, "I": None}
    shows = []                                 # (cycle, hex, ledr, lamps, mode)
    for p in ev:
        k = p[0]
        if k == "R":                                   # the chip leaves reset: a new run
            if m is not None:
                runs.append((m, bytes(got), run_faulted))
            m, got, rec, run_faulted = L.LaneModel(rom, boot_pins=0), [], bytearray(), fault
            seen.update(V=None, signed=False)
            run_start, cut = int(p[1]), []
        elif k == "F":
            fault = p[2] == "1"
            run_faulted = run_faulted or fault
        elif k == "P":                                 # as Scenario.run plays a pin change
            v = int(p[2], 16)
            if m.gp & 1 and not v & 1:
                m.line_idle(); m.gpio(v)
            else:
                m.gpio(v); m.line_idle()
        elif k == "B":
            m.rx_byte(int(p[2], 16))
        elif k == "C":
            if int(p[1]) - run_start < 10 * CPB:       # the byte a reset cut in half: the old run's
                cut.append(int(p[2], 16))
                continue
            got.append(int(p[2], 16))
            rec.append(got[-1])
            if len(rec) == 8:
                r, rec = bytes(rec), bytearray()
                if r[0] == 0x56:
                    seen.update(V=r, signed=False)
                elif r[0] == 0x41:
                    seen["signed"] = seen["V"] is not None and r[1] == seen["V"][1]
                elif r[0] in (0x45, 0x49):
                    seen[chr(r[0])] = r
        elif k == "T":
            if int(p[1]) - run_start < 10 * CPB + 2:
                continue
            host_out.append(int(p[2], 16))
        elif k == "H":
            shows.append((int(p[1]), int(p[2], 16), int(p[3], 16), int(p[4], 16), int(p[5])))
        elif k == "D":
            tag, sw, obj = next(at)
            assert tag == p[2]
            if full:
                snapshot(ck, tag, int(p[3], 16), int(p[4], 16), int(p[5], 16), int(p[6]),
                         sw, obj, m, seen, rom)
    if m is not None:
        runs.append((m, bytes(got), run_faulted))

    # V2: every run, byte for byte (not the runs a fault was injected into). A run that a
    # reset ended (KEY0, SW9, the next tour line) may have been cut off mid-answer: its
    # output must then be the start of the model's
    for i, (mm, g, faulted) in enumerate(runs):
        if faulted:
            continue
        want = bytes(mm.out)
        if i + 1 < len(runs) and want != g:
            ck.ok(want[:len(g)] == g, "run %d (ended by a reset): the chip sent %s, the model %s"
                  % (i, g.hex(), want.hex()))
        else:
            ck.ok(want == g, "run %d: the chip sent %s, the model %s" % (i, g.hex(), want.hex()))
    ck.ok(bytes(host_out) == b"".join(g for _, g, _ in runs), "the laptop did not receive exactly the chip's bytes")
    # V2 / V8: the decisions the scenario means
    dec = []
    for mm, g, _ in runs:
        if is_lane_run(mm):
            dec += [(g[i + 2], g[i + 4] | g[i + 5] << 8) for i in range(0, len(g) - 7, 8) if g[i] == 0x56]
    if st.tail_intent:
        ck.ok(len(dec) >= len(st.intent), "%d vehicles decided, fewer than the %d meant" % (len(dec), len(st.intent)))
        dec = dec[len(dec) - len(st.intent):]
    else:
        ck.ok(len(dec) == len(st.intent), "%d vehicles decided, the scenario has %d" % (len(dec), len(st.intent)))
    if full:
        for i, (d, w) in enumerate(zip(dec, st.intent)):
            if w is not None:
                ck.ok(d == w, "vehicle %d: the chip says (status %d, fare %d), the scenario means %s"
                      % (i + 1, d[0], d[1], w))
    if name == "tour":
        n = sum(1 for mm, _, _ in runs if not is_lane_run(mm))
        ck.ok(n == len(D.tour()[1]), "tour mode ran %d lines, not %d" % (n, len(D.tour()[1])))
    if level == "all":
        flicker(ck, shows, tick)
    return ck, runs


def snapshot(ck, tag, hexn, ledr, lamps, dec_ms, sw, obj, m, seen, rom):
    """V3: what the displays, LEDs, lamps and buzzer must show (07 section 4).
    obj: 1 if LEDR0 (something under the working sensor) must be lit."""
    pins = m.pins if m is not None else 0
    mute, lowbuzz = bool(sw & SW_MUTE), bool(sw & SW_LOWBUZZ)
    where = "snapshot '%s'" % tag
    if tag == "boot":
        ck.ok(hexn == 0 and ledr == 0x3FF and lamps & 0xF == 0xF, "%s: the lamp test is not all lit" % where)
        return
    if tag == "id":
        crc = D.G.rom_crc(rom)
        want = render("Id" + "".join(D.CHARS[(crc >> s) & 15] for s in (12, 8, 4, 0)), dp=0b010000)
        ck.ok(hexn == want, "%s: shows %s, want %s" % (where, show(hexn), show(want)))
        ck.ok(seen["I"] is not None and seen["I"][4] | seen["I"][5] << 8 == crc, "%s: no matching 'I'" % where)
        ck.ok(ledr >> 9 & 1, "%s: LEDR9 (self-check) is off" % where)
        return
    if tag == "noid":
        ck.ok(hexn == render(D.six("no Id")), "%s: shows %s, want no Id" % (where, show(hexn)))
        ck.ok(not ledr >> 9 & 1, "%s: LEDR9 is on without an identity" % where)
        return
    if tag == "pass":
        ck.ok(hexn == render("PASS12"), "%s: shows %s, want PASS12" % (where, show(hexn)))
        ck.ok(ledr >> 9 & 1, "%s: LEDR9 is off after the tour" % where)
        ck.ok(ledr & 0x1F4 == 0 and lamps & 0xF == 0, "%s: lamps lit after the tour (LEDR %03x)" % (where, ledr))
        return
    if tag.startswith("err"):
        e, want_r = seen["E"], int(tag[3:])
        ck.ok(e is not None and e[1] == want_r, "%s: no 'E' reason %d record" % (where, want_r))
        want = render("Err  %d" % want_r)
        ck.ok(hexn == want, "%s: shows %s, want %s" % (where, show(hexn), show(want)))
        return
    # the lane: LEDs (LEDR3, the laptop's activity light, is not checked)
    signed = seen["signed"] if tag != "idle" else bool(ledr >> 8 & 1)
    want_led = 1 << 9 | int(signed) << 8 | (pins & 0xF0) | (m.gp & 1) << 2 | obj
    ck.ok(ledr & ~0x8 == want_led, "%s: LEDR %03x, want %03x" % (where, ledr & ~0x8, want_led))
    if tag == "idle":
        word = "CLOSEd" if pins & 0x80 else D.PRESETS[(sw >> 3) & 7][0]
        ck.ok(hexn == render(D.six(word)), "%s: shows %s, want %s" % (where, show(hexn), word))
        want_l = int(bool(pins & 0x80)) << 3 | int(lowbuzz) << 4
        ck.ok(lamps == want_l, "%s: lamps %02x, want %02x" % (where, lamps, want_l))
        return
    v = seen["V"]
    status, fare = v[2], v[4] | v[5] << 8
    if fare and dec_ms <= FARE_FROM:
        want = render(fare_text(fare), dp=0b000100)            # after 1.5 s: the fare
    elif status in (3, 4) and (DEC_MS - dec_ms) & 256:
        want = (1 << 48) - 1                                    # alarms blink (lit first)
    else:
        want = render(D.six(D.STATUS_WORDS[status]))
    ck.ok(hexn == want, "%s: shows %s, want %s (status %d, fare %d, %d ms left)"
          % (where, show(hexn), show(want), status, fare, dec_ms))
    p4, p5, p6, p7 = (pins >> 4) & 1, (pins >> 5) & 1, (pins >> 6) & 1, (pins >> 7) & 1
    first = tag == "dec"                    # the flash and the beeps are over by 'dec2'
    beep = first and bool(p6 or p4) and not mute
    want_l = p4 | (p5 & first) << 1 | p6 << 2 | p7 << 3 | (int(beep) ^ int(lowbuzz)) << 4
    ck.ok(lamps == want_l, "%s: lamps %02x, want %02x (chip pins %02x)" % (where, lamps, want_l, pins))


def flicker(ck, shows, tick):
    """V3: light by light - the six-digit display, LEDR2 and LEDR4-9, the four
    lamps - how long each state lasts, in board milliseconds. In tour mode no
    state may last under 300 ms; elsewhere none may last 5-150 ms (a flicker a
    person sees), except the display while a vehicle is under the sensor (its
    height is re-measured at every reading). Under 5 ms nobody can see it."""
    lights = [("display", lambda h, l, m: h)]
    lights += [("LEDR%d" % b, (lambda b: lambda h, l, m: l >> b & 1)(b)) for b in (2, 4, 5, 6, 7, 8, 9)]
    lights += [(n, (lambda b: lambda h, l, m: m >> b & 1)(b)) for b, n in enumerate(("green", "white", "red", "closed"))]
    bad = []
    for name, get in lights:
        runs = []                                  # (start, value, mode, vehicle there)
        for cyc, hexn, ledr, lamps, mode in shows:
            v = get(hexn, ledr, lamps)
            if not runs or runs[-1][1] != v:
                runs.append((cyc, v, mode, bool(ledr & 4)))
        runs = [r for i, r in enumerate(runs) if i + 1 == len(runs) or runs[i + 1][0] - r[0] > 4]   # clock skew
        for i in range(1, len(runs) - 1):
            c, v, mode, veh = runs[i]
            ms = (runs[i + 1][0] - c) / float(tick)
            if mode == 2 and runs[i - 1][2] == 2 and runs[i + 1][2] == 2:
                if ms < 300:
                    bad.append("tour %s: %s for %.0f ms" % (name, show(v) if name == "display" else v, ms))
            elif 5 <= ms < 150:
                if name == "display" and (veh or runs[i - 1][3] or runs[i + 1][3]):
                    continue
                bad.append("%s %s: %s for %.0f ms" % (("boot", "lane", "tour")[mode], name,
                                                      show(v) if name == "display" else v, ms))
    ck.ok(not bad, "flicker: %d short states, e.g. %s" % (len(bad), "; ".join(bad[:4])))


def run_top():
    """V9: the top level's reset path (tb_top.v: power-up, KEY0's 20 ms filter)."""
    here = wsl_path(os.path.join(HERE, ".."))
    cmd = ("cd %s && verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style --top-module tb_top "
           "-Mdir /tmp/lanex_vtop -o vtop sim/tb_top.v sim/altpll_stub.v lanex_de10lite.v lanex_board.v "
           "lanex_data.v lanex_chip.v > /tmp/lanex_vtop.log 2>&1 && /tmp/lanex_vtop/vtop" % here)
    r = subprocess.run(["wsl.exe", "--", "bash", "-lc", cmd], capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.startswith("TOP")]
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sim", choices=("verilator", "icarus"), default="verilator")
    ap.add_argument("--only", nargs="*", choices=sorted(SCENARIOS), default=None)
    ap.add_argument("--pass", dest="passes", nargs="*", choices=list(PASSES), default=None)
    ap.add_argument("--no-run", action="store_true", help="check the existing logs only")
    a = ap.parse_args()
    rom = L.load_rom()
    total, bad, t0 = 0, 0, time.time()
    for pas, (tick, sonar, level, scen) in PASSES.items():
        if a.passes and pas not in a.passes:
            continue
        names = [n for n in (a.only or scen) if n in scen or a.only]
        if pas == "real" and a.only and "glitch" not in a.only:
            continue
        files = {n: tuple(os.path.join(BUILD, "%s_%s.%s" % (n, pas, x)) for x in ("stim", "log"))
                 for n in names} if a.no_run else run(a.sim, names, pas, tick, sonar)
        for n in names:
            ck, runs = check(n, files[n][1], rom, level, tick)
            total += ck.checks
            bad += len(ck.fails)
            print("%-6s %-7s %4d checks, %3d chip runs, %4d records  %s" % (
                pas, n, ck.checks, len(runs), sum(len(g) for _, g, _ in runs) // 8,
                "PASS" if not ck.fails else "FAIL"))
            for f in ck.fails[:12]:
                print("    " + f)
            sys.stdout.flush()
    if a.sim == "verilator" and not a.only and not a.no_run:
        top = run_top()
        total += 1
        bad += int(top != ["TOP PASS"])
        print("top    reset    %s" % ("; ".join(top) or "no result"))
    print("BOARD %s: %d checks, %d failed (%s, %.0f s)"
          % ("PASS" if not bad else "FAIL", total, bad, a.sim, time.time() - t0))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
