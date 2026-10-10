#!/usr/bin/env python3
"""check_board.py - verify the DE10-Lite desk lane in simulation, end to end.

    python stage4/de10lite/sim/check_board.py                # everything (Verilator, in WSL)
    python stage4/de10lite/sim/check_board.py --only smoke --sim icarus

The whole board runs (tb_board.v: lanex_board with the chip, its ROM and every
fabric block), driven like the real desk lane - switches, KEY1, the ultrasonic
sensor over the lane, a laptop on the host link - and logs every pin change and every byte
that reaches the chip, and every byte it sends. Then:

  V2  the golden model (lane_model.py) replays exactly what the chip received,
      run by run (each chip reset starts a new run), and must produce exactly
      the bytes the chip sent - whatever the fabric did, the chip agrees with
      the model; the laptop must receive exactly those bytes;
  V2  each vehicle's decision is the one the scenario means (PROTOCOL.md
      section 6, worked out here independently of the model), so the matrix
      really covers every tag preset x vehicle height x lane state;
  V3  every display / LED / lamp / buzzer snapshot is what 07_max10_prototype.md
      section 4 says for the chip's last record;
  V4  tour mode replays the 12 AWS ./emu lines (each run checked by the model
      too) and shows PASS12;
  V5  frames from the laptop are merged whole ('H' changes the next decision);
      garbage, half frames and oversize frames never reach the chip.

Two passes. "full": a board millisecond is 3,125 core clocks (time runs 10x
fast), every check. "stress": 100 core clocks (31x faster again), so frames
outlast vehicles and every pin change collides with one (vehicles still
last whole ultrasonic readings); only the model
comparison and the laptop copy are checked (the scenario's timing intent and
the display timers do not survive that squeeze).
"""
import argparse
import os
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
PASSES = [("full", 3125, True), ("stress", 100, False)]
FARES = L.DEFAULT_FARES
CAR_MM, LORRY_MM = 40, 90         # toy heights above the floor (the board's lorry threshold: 60 mm)
SW_MUTE, SW_LOWBUZZ = 1 << 7, 1 << 6


def sw_word(preset=0, closed=0, override=0, manual=0, tour=0, mute=0, lowbuzz=0):
    return closed | override << 1 | preset << 3 | lowbuzz << 6 | mute << 7 | manual << 8 | tour << 9


# ---------------------------------------------------------------------------
# Scenarios (the tb_board.v stimulus language)
# ---------------------------------------------------------------------------
class Stim:
    def __init__(self, name):
        self.name, self.lines, self.intent = name, [], []

    def add(self, *a):
        self.lines.append(" ".join(str(x) for x in a))

    def set_sw(self, **kw):
        self.add("S", "%03x" % sw_word(**kw))
        self.add("W", 20)

    def snap(self, tag):
        self.add("D", tag)

    def host(self, b):
        self.add("X", len(b), " ".join("%02x" % x for x in b))

    def vehicle(self, kind, intent, hold=5, gap=1600, snaps=True):
        """One vehicle under the sensor (heights in mm above the floor, `hold`
        in ultrasonic readings). `intent`: the (status, fare) the scenario
        means, or None where either order of events is legal."""
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
        self.intent.append(intent)
        a("V")
        if snaps:
            self.snap("dec")                           # just after the record
            a("W", 1100)
            self.snap("dec2")                          # the fare's second
        a("W", gap)

    def text(self):
        return "\n".join(self.lines + ["E"]) + "\n"


def intended(preset, phys, closed):
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
    s.snap("boot")                             # the lamp test
    s.add("N")
    s.snap("id")                               # "Id.56dE" after the banner
    s.add("M")
    s.snap("idle")


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
            s.vehicle(kind, intended(preset, phys, 0))
    for preset in range(8):
        s.set_sw(preset=preset, closed=1)
        s.add("W", 3300)                       # the last decision's 5 s are over
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
    s.snap("err")
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
    s.intent.append(None)                      # before or after its read: both legal
    s.add("V"); s.add("W", 3500)
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
    s.add("I")                                 # the warm boot's 'I' record
    s.snap("id")
    s.add("M")
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
    s.add("Z", 0)                                   # the sensor unplugged: manual mode still works
    s.vehicle("manual", (0, FARES[1]), gap=400)
    s.add("Z", 1); s.add("Y", 3)
    s.vehicle("tap", (1, 0), gap=3500)         # a quick press, the same tag within 3 s: tailgating
    s.set_sw(preset=5)
    s.vehicle("car", (4, 0), gap=200)          # a clone ...
    s.set_sw(preset=4)
    s.vehicle("car", (3, 0), gap=200)          # ... and a stolen car right behind it
    s.set_sw(preset=0)
    s.add("W", 3000)
    s.add("K", 1); s.add("I"); s.add("K", 0)       # KEY1 (not manual): identify, answered at once
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


def scenario_smoke():
    s = Stim("smoke")
    boot(s)
    s.set_sw(preset=1)
    s.vehicle("car", (0, FARES[1]))
    return s


SCENARIOS = {"matrix": scenario_matrix, "host": scenario_host, "tour": scenario_tour,
             "edges": scenario_edges, "smoke": scenario_smoke}


# ---------------------------------------------------------------------------
# Running the simulation
# ---------------------------------------------------------------------------
def wsl_path(p):
    p = os.path.abspath(p).replace("\\", "/")
    return "/mnt/%s%s" % (p[0].lower(), p[2:]) if p[1] == ":" else p


def run(sim, names, pas, tick):
    os.makedirs(BUILD, exist_ok=True)
    files = {}
    for n in names:
        stim, log = (os.path.join(BUILD, "%s_%s.%s" % (n, pas, x)) for x in ("stim", "log"))
        with open(stim, "w", newline="\n") as f:
            f.write(SCENARIOS[n]().text())
        files[n] = (stim, log)
    if sim == "verilator":
        out = "/tmp/lanex_vtb_%d" % tick
        cmd = "bash %s %s 115200 %d" % (wsl_path(os.path.join(HERE, "build_vtb.sh")), out, tick)
        for n, (stim, log) in files.items():
            cmd += " && %s/obj/vtb +stim=%s +log=%s > /dev/null" % (out, wsl_path(stim), wsl_path(log))
        r = subprocess.run(["wsl.exe", "--", "bash", "-lc", cmd], capture_output=True, text=True)
        if r.returncode:
            sys.exit("verilator run failed:\n" + r.stdout + r.stderr)
    else:
        src = [os.path.join(HERE, "tb_board.v")] + [os.path.join(HERE, "..", f) for f in
                                                       ("lanex_board.v", "lanex_data.v", "lanex_chip.v")]
        vvp = os.path.join(BUILD, "tb_board_%d.vvp" % tick)
        subprocess.run(["iverilog", "-g2005", "-o", vvp, "-s", "tb_board",
                        "-Ptb_board.TICK_DIV=%d" % tick] + src, check=True)
        for n, (stim, log) in files.items():
            subprocess.run(["vvp", "-n", vvp, "+stim=" + stim, "+log=" + log], check=True,
                           capture_output=True)
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


def check(name, log, rom, full):
    st = SCENARIOS[name]()
    ck = Checker()
    ev = [l.split() for l in open(log) if l.strip() and not l.startswith("#")]
    ck.ok(ev and ev[-1][0] == "END", "the simulation did not reach the end of its stimulus")
    # the switches and the height under the sensor as the stimulus had them at each snapshot
    at, sw, obj = [], 0, 0
    for l in st.lines:
        p = l.split()
        if p[0] == "S":
            sw = int(p[1], 16)
        elif p[0] == "U":
            obj = int(p[1])
        elif p[0] == "D":
            at.append((p[1], sw, obj))
    at = iter(at)

    runs, m, got, host_out, rec = [], None, [], [], bytearray()
    seen = {"V": None, "signed": False, "E": None, "I": None}
    for p in ev:
        k = p[0]
        if k == "R":                                   # the chip leaves reset: a new run
            if m is not None:
                runs.append((m, bytes(got)))
            m, got, rec = L.LaneModel(rom, boot_pins=0), [], bytearray()
            seen.update(V=None, signed=False)
        elif k == "P":                                 # as Scenario.run plays a pin change
            v = int(p[2], 16)
            if m.gp & 1 and not v & 1:
                m.line_idle(); m.gpio(v)
            else:
                m.gpio(v); m.line_idle()
        elif k == "B":
            m.rx_byte(int(p[2], 16))
        elif k == "C":
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
            host_out.append(int(p[2], 16))
        elif k == "D":
            tag, sw, obj = next(at)
            assert tag == p[2]
            if full:
                snapshot(ck, tag, int(p[3], 16), int(p[4], 16), int(p[5], 16), int(p[6]),
                         sw, obj, m, seen, rom)
    if m is not None:
        runs.append((m, bytes(got)))

    # V2: every run, byte for byte; the laptop sees the same bytes
    for i, (mm, g) in enumerate(runs):
        ck.ok(bytes(mm.out) == g, "run %d: the chip sent %s, the model %s" % (i, g.hex(), bytes(mm.out).hex()))
    ck.ok(bytes(host_out) == b"".join(g for _, g in runs), "the laptop did not receive exactly the chip's bytes")
    # V2: the decisions the scenario means
    dec = []
    for mm, g in runs:
        if is_lane_run(mm):
            dec += [(g[i + 2], g[i + 4] | g[i + 5] << 8) for i in range(0, len(g) - 7, 8) if g[i] == 0x56]
    ck.ok(len(dec) == len(st.intent), "%d vehicles decided, the scenario has %d" % (len(dec), len(st.intent)))
    if full:
        for i, (d, w) in enumerate(zip(dec, st.intent)):
            if w is not None:
                ck.ok(d == w, "vehicle %d: the chip says (status %d, fare %d), the scenario means %s"
                      % (i + 1, d[0], d[1], w))
    if name == "tour":
        n = sum(1 for mm, _ in runs if not is_lane_run(mm))
        ck.ok(n == len(D.tour()[1]), "tour mode ran %d lines, not %d" % (n, len(D.tour()[1])))
    return ck, runs


def snapshot(ck, tag, hexn, ledr, lamps, dec_ms, sw, obj, m, seen, rom):
    """V3: what the displays, LEDs, lamps and buzzer must show (07 section 4)."""
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
    if tag == "pass":
        ck.ok(hexn == render("PASS12"), "%s: shows %s, want PASS12" % (where, show(hexn)))
        ck.ok(ledr >> 9 & 1, "%s: LEDR9 is off after the tour" % where)
        return
    if tag == "err":
        e = seen["E"]
        ck.ok(e is not None and e[1] == 1, "%s: no 'E' reason 1 record" % where)
        want = render("Err  1")
        ck.ok(hexn == want, "%s: shows %s, want %s" % (where, show(hexn), show(want)))
        return
    # the lane: LEDs (LEDR3, the laptop's activity light, is not checked)
    signed = seen["signed"] if tag != "idle" else bool(ledr >> 8 & 1)
    # LEDR1:0: the lorry latch (cleared once the vehicle has gone) and "something under the sensor"
    want_led = 1 << 9 | int(signed) << 8 | (pins & 0xF0) | (m.gp & 1) << 2 | int(obj >= 15)
    ck.ok(ledr & ~0x8 == want_led, "%s: LEDR %03x, want %03x" % (where, ledr & ~0x8, want_led))
    if tag == "idle":
        word = "CLOSEd" if pins & 0x80 else D.PRESETS[(sw >> 3) & 7][0]
        ck.ok(hexn == render(D.six(word)), "%s: shows %s, want %s" % (where, show(hexn), word))
        want_l = int(bool(pins & 0x80)) << 3 | int(lowbuzz) << 4
        ck.ok(lamps == want_l, "%s: lamps %02x, want %02x" % (where, lamps, want_l))
        return
    v = seen["V"]
    status, fare = v[2], v[4] | v[5] << 8
    if fare and (3000 < dec_ms <= 4000 or 1000 < dec_ms <= 2000):
        want = render(fare_text(fare), dp=0b000100)            # seconds 2 and 4: the fare
    elif status in (3, 4) and dec_ms & 256:
        want = (1 << 48) - 1                                    # alarms blink
    else:
        want = render(D.six(D.STATUS_WORDS[status]))
    ck.ok(hexn == want, "%s: shows %s, want %s (status %d, fare %d, %d ms left)"
          % (where, show(hexn), show(want), status, fare, dec_ms))
    p4, p5, p6, p7 = (pins >> 4) & 1, (pins >> 5) & 1, (pins >> 6) & 1, (pins >> 7) & 1
    first = tag == "dec"                    # the flash and the beeps are over by 'dec2'
    beep = first and bool(p6 or p4) and not mute
    want_l = p4 | (p5 & first) << 1 | p6 << 2 | p7 << 3 | (int(beep) ^ int(lowbuzz)) << 4
    ck.ok(lamps == want_l, "%s: lamps %02x, want %02x (chip pins %02x)" % (where, lamps, want_l, pins))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sim", choices=("verilator", "icarus"), default="verilator")
    ap.add_argument("--only", nargs="*", choices=sorted(SCENARIOS), default=None)
    ap.add_argument("--pass", dest="passes", nargs="*", choices=[p[0] for p in PASSES], default=None)
    ap.add_argument("--no-run", action="store_true", help="check the existing logs only")
    a = ap.parse_args()
    names = a.only or ["matrix", "host", "tour", "edges"]
    rom = L.load_rom()
    total, bad, t0 = 0, 0, time.time()
    for pas, tick, full in PASSES:
        if a.passes and pas not in a.passes:
            continue
        files = {n: tuple(os.path.join(BUILD, "%s_%s.%s" % (n, pas, x)) for x in ("stim", "log"))
                 for n in names} if a.no_run else run(a.sim, names, pas, tick)
        for n in names:
            ck, runs = check(n, files[n][1], rom, full)
            total += ck.checks
            bad += len(ck.fails)
            print("%-6s %-7s %4d checks, %3d chip runs, %4d records  %s" % (
                pas, n, ck.checks, len(runs), sum(len(g) for _, g in runs) // 8,
                "PASS" if not ck.fails else "FAIL"))
            for f in ck.fails[:12]:
                print("    " + f)
    print("BOARD %s: %d checks, %d failed (%s, %.0f s)"
          % ("PASS" if not bad else "FAIL", total, bad, a.sim, time.time() - t0))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
