#!/usr/bin/env python3
"""gen_de10lite.py - build the DE10-Lite desk-lane project in stage4/de10lite/.

    python scripts/stage4/gen_de10lite.py            # (re)write the generated files
    python scripts/stage4/gen_de10lite.py --check    # fail if one is stale

One source of truth, as for the AWS build (docs/stage4/07_max10_prototype.md):

  lanex_chip.v   GENERATED: the RVBL-2 chip and the LaneX ROM, from rtl/ and
                 firmware.hex by the very code that writes the AWS riscv.sv
                 (gen_riscv_sv.chip_modules, target "de10lite": the pad tri-state
                 resolved in the fabric and Quartus-style RAM, nothing else)
  lanex_data.v   GENERATED: the board's tables, from lane_model.py - the frame
                 templates, the 12 AWS ./emu lines for tour mode with their
                 golden answers, the 7-segment font and words, the build ID
  lanex.qpf, lanex.qsf, lanex.sdc   GENERATED: the Quartus project: device,
                 every pin (Terasic DE10-Lite schematic rev B1), I/O standards,
                 pull-ups, internal-flash boot, clocks
  wiring_card.html   GENERATED: the printable wiring card (same pin table)
  lanex_de10lite.v, lanex_board.v   hand-written: the board top (PLL) and the
                 fabric around the chip (test equipment, like the organisers' emu)

Quartus rewrites lanex.qsf when it closes a project (it adds its own lines), so
--check only requires every generated line to still be there.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "application", "testbench"))
import gen_riscv_sv as G      # noqa: E402
import lane_model as L        # noqa: E402

OUT = os.path.join(ROOT, "stage4", "de10lite")
EMU_FILE = os.path.join(ROOT, "application", "emulator-preview", "emu_commands.txt")
CORE_HZ = {31250000: (5, 8), 25000000: (1, 2), 20000000: (2, 5)}   # 50 MHz x mul / div

# ---------------------------------------------------------------------------
# The lane the board plays (docs/stage4/07 section 4)
# ---------------------------------------------------------------------------
RSSI_FLOOR = 30
GANTRY, FAR_GANTRY, FAR_POS = 1, 2, 400          # gantry 2 is 40.0 km away
CLONE_AGO_MS = 30000                             # ... and saw the cloned tag 30 s ago


def epc(cls, name):
    """Readable demo tags: byte 0 carries the registered class (epc[0] & 7)."""
    e = bytes([0x30 | cls]) + name.encode()
    assert len(e) == 12
    return e


# preset (SW5:3) -> (display name, epc, rssi, stored-CRC corruption)
PRESETS = {
    0: ("nonE", None, 0, 0),
    1: ("CAr", epc(1, "LANEX-CAR01"), 80, 0),
    2: ("LorrY", epc(3, "LANEX-LRY02"), 80, 0),
    3: ("CAb", epc(4, "LANEX-CAB03"), 80, 0),
    4: ("StOLEn", epc(1, "LANEX-STL04"), 80, 0),
    5: ("CLOnE", epc(1, "LANEX-CLN05"), 80, 0),
    6: ("bAd", epc(1, "LANEX-BAD06"), 80, 0x0100),           # radio-damaged: bad Gen2 CRC
    7: ("FAr", epc(1, "LANEX-FAR07"), RSSI_FLOOR - 10, 0),    # the next lane: below the floor
}
STOLEN, CLONED = PRESETS[4][1], PRESETS[5][1]

# Frames sent at every boot, in order (template ids 0..5); the last one is 'I'.
BOOT = [
    ("P", L.f_params(rssi_min=RSSI_FLOOR, timeout=48)),
    ("C", L.f_config(GANTRY, 0, L.DEFAULT_FARES)),
    ("G", L.f_gantry(FAR_GANTRY, FAR_POS)),
    ("H", L.f_hot_add(STOLEN)),
    ("K", L.f_key(L.DEMO_KEY)),
    ("I", L.f_identify()),
]
TID_SIGHTING = 6                                  # 'S' for the clone, time = now - 30 s
TID_READ = 8                                      # 8 + preset: 'R' for presets 1..7

# 10-bit template ops
OP_LIT, OP_TIME, OP_CRC = 0x000, 0x100, 0x200     # OP_TIME | k (byte k) | 4 (minus 30 s)


def template_ops(fr, time_at=None, minus=False):
    """A frame as ops: literal bytes, the 4 live time bytes at frame offset
    time_at, then the CRC computed by the fabric."""
    ops = []
    for i, b in enumerate(fr[:-2]):
        if time_at is not None and time_at <= i < time_at + 4:
            ops.append(OP_TIME | (i - time_at) | (4 if minus else 0))
        else:
            ops.append(OP_LIT | b)
    return ops + [OP_CRC, OP_CRC | 1]


def play_template(ops, now):
    """What the fabric's framer sends for these ops at time `now` (ms)."""
    out, crc = [], 0xFFFF
    for i, op in enumerate(ops):
        if op & 0x300 == OP_CRC:
            b = (crc >> (8 * (op & 1))) & 0xFF
        elif op & 0x300 == OP_TIME:
            t = (now - (CLONE_AGO_MS if op & 4 else 0)) & 0xFFFFFFFF
            b = (t >> (8 * (op & 3))) & 0xFF
        else:
            b = op & 0xFF
        if i > 0 and op & 0x300 != OP_CRC:
            crc = L.crc16(bytes([b]), crc)
        out.append(b)
    return bytes(out)


def read_frame(preset, t):
    name, e, rssi, bad = PRESETS[preset]
    return L.f_read(t, e, rssi, stored=L.gen2_crc(L.PC_96, e) ^ bad)


def templates():
    tpl = {}
    for i, (_, fr) in enumerate(BOOT):
        tpl[i] = template_ops(fr)
    tpl[TID_SIGHTING] = template_ops(L.f_sighting(CLONED, FAR_GANTRY, 0), time_at=3 + 13, minus=True)
    for p in range(1, 8):
        tpl[TID_READ + p] = template_ops(read_frame(p, 0), time_at=3)
    # self-check: the ops replay to the golden model's own frames
    for now in (0, 1, 29999, 30000, 123456, 0xFFFFFFFF, 0x80000000):
        for i, (_, fr) in enumerate(BOOT):
            assert play_template(tpl[i], now) == fr
        assert play_template(tpl[TID_SIGHTING], now) == L.f_sighting(
            CLONED, FAR_GANTRY, (now - CLONE_AGO_MS) & 0xFFFFFFFF)
        for p in range(1, 8):
            assert play_template(tpl[TID_READ + p], now) == read_frame(p, now)
    assert all(len(v) <= 64 for v in tpl.values())
    return tpl


# ---------------------------------------------------------------------------
# Tour mode: the 12 ./emu lines that passed on the AWS F2, with their answers
# ---------------------------------------------------------------------------
T_PINS, T_LINE_END, T_TOUR_END = 0x200, 0x300, 0x3FF   # bytes: 0x0bb, last of a frame 0x1bb


def split_frames(bs):
    frames, i = [], 0
    while i < len(bs):
        assert bs[i] == L.SOF, "emu line bytes are not whole frames"
        n = bs[i + 2] + 5
        frames.append(bytes(bs[i:i + n]))
        i += n
    assert i == len(bs)
    return frames


def emu_lines():
    """[(title, tokens)] from emu_commands.txt, which must equal lane_model's."""
    lines, title = [], None
    for raw in open(EMU_FILE, encoding="utf-8"):
        raw = raw.strip()
        if raw.startswith("# ") and not raw.startswith("# ./emu") and "GENERATED" not in raw:
            title = raw[2:]
        elif raw.startswith("./emu "):
            lines.append((title, raw.split()[1:]))
    model = L.emu_commands()
    if [t for _, t in lines] != [t for _, t in model]:
        sys.exit("gen_de10lite: %s is stale (run lane_model.py)" % os.path.relpath(EMU_FILE, ROOT))
    return lines


def tour():
    ops, exp = [], []
    for title, tok in emu_lines():
        pend, rbytes, lamps = [], [], None

        def flush():
            for fr in split_frames(pend):
                ops.extend(list(fr[:-1]) + [0x100 | fr[-1]])
            del pend[:]
        it = iter(tok)
        for k in it:
            v = int(next(it), 16)
            if k == "-d":
                assert v == 0xF0
            elif k == "-i":
                flush()
                ops.append(T_PINS | v)
            elif k.startswith("-t"):
                pend.extend(v.to_bytes(int(k[2]), "little"))
            elif k.startswith("-r"):
                rbytes.extend(v.to_bytes(int(k[2]), "little"))
            elif k == "-o":
                lamps = v
        flush()
        ops.append(T_LINE_END)
        assert len(rbytes) == 8, title
        exp.append((title, bytes(rbytes), lamps))
    ops.append(T_TOUR_END)
    return ops, exp


# ---------------------------------------------------------------------------
# 7-segment text
# ---------------------------------------------------------------------------
# char codes: 0-15 are the hex digits; segments gfedcba, active high here
FONT = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F,      # 0-9
        0x77, 0x7C, 0x39, 0x5E, 0x79, 0x71,                              # A b C d E F
        0x3D, 0x76, 0x30, 0x38, 0x54, 0x5C, 0x73, 0x50, 0x78, 0x3E,      # G H I L n o P r t U
        0x6E, 0x40, 0x58, 0x74, 0x1E, 0x00]                              # Y - c h J space
CHARS = "0123456789AbCdEFGHILnoPrtUY-chJ "
ALIAS = {"O": "0", "S": "5", "V": "U", "a": "A", "B": "8", "D": "0", "e": "E", "g": "9",
         "i": "I", "l": "L", "N": "n", "R": "r", "T": "t", "u": "U", "y": "Y"}


def code(c):
    c = ALIAS.get(c, c)
    if c not in CHARS:
        raise ValueError("no 7-segment glyph for %r" % c)
    return CHARS.index(c)


STATUS_WORDS = ["CHArGE", "no tAG", "CLASS", "StOLEn", "CLOnE", "FrEE", "CLOSEd"]
MSGS = {i: w for i, w in enumerate(STATUS_WORDS)}          # 0..6: the decision (V status)
MSGS.update({8 + p: PRESETS[p][0] for p in range(8)})      # 8..15: the tag preset
MSGS.update({7: "", 16: "Err", 17: "Id", 18: "no Id", 19: "tESt", 20: "PASS", 21: "FAIL",
             22: "LAnE"})
BANNER = "      LAnE  rISC-V  bEAt tHE toLL      "


def six(s, align="center"):
    if align == "left":
        s = s.ljust(6)
    elif len(s) < 6:
        pad = 6 - len(s)
        s = " " * (pad // 2) + s + " " * (pad - pad // 2)
    assert len(s) == 6, s
    return s


def chars_word(s):
    """6 chars left to right -> 30 bits, HEX0 (the rightmost) in bits 4:0."""
    v = 0
    for i, c in enumerate(s):
        v |= code(c) << (5 * (5 - i))
    return v


# ---------------------------------------------------------------------------
# Verilog emitters
# ---------------------------------------------------------------------------
def case_rom(name, comment, ain, aw, dw, entries, default="0"):
    out = ["// %s" % c for c in comment] + [
        "module %s (" % name,
        "    input  wire [%d:0] %s," % (aw - 1, ain),
        "    output reg  [%d:0] q" % (dw - 1),
        ");",
        "    always @(*) begin",
        "        case (%s)" % ain,
    ]
    for a, d, note in entries:
        out.append("            %d'd%d: q = %d'h%x;%s" % (aw, a, dw, d, ("  // " + note) if note else ""))
    out += ["            default: q = %d'h%s;" % (dw, default), "        endcase", "    end", "endmodule", ""]
    return "\n".join(out)


def data_v(words, tpl, tops, texp):
    rw, rc = len(words), G.rom_crc(words)
    parts = [
        "// " + "=" * 76,
        "// lanex_data.v - the DE10-Lite board's tables. GENERATED by",
        "// scripts/stage4/gen_de10lite.py from application/testbench/lane_model.py",
        "// and application/emulator-preview/emu_commands.txt. Do not edit: regenerate.",
        "// " + "=" * 76,
        "",
        "// The build the 'I' record must report (firmware.hex: %d words, CRC 0x%04X)" % (rw, rc),
        "module lx_build_id (",
        "    output wire [15:0] rom_words,",
        "    output wire [15:0] rom_crc",
        ");",
        "    assign rom_words = 16'd%d;" % rw,
        "    assign rom_crc   = 16'h%04X;" % rc,
        "endmodule",
        "",
    ]
    names = {i: "%s frame (boot %d)" % (n, i) for i, (n, _) in enumerate(BOOT)}
    names[TID_SIGHTING] = "S sighting of the CLOnE tag at gantry 2, now - 30 s"
    for p in range(1, 8):
        names[TID_READ + p] = "R read, preset %d %s" % (p, PRESETS[p][0])
    ent = []
    for tid in sorted(tpl):
        for i, op in enumerate(tpl[tid]):
            ent.append(((tid << 6) | i, op, names[tid] if i == 0 else ""))
    parts.append(case_rom(
        "lx_templates",
        ["Frame templates {tid, index} -> op: 0x0bb literal byte; 0x10k live time byte k",
         "(| 4: now - %d ms); 0x200 / 0x201 CRC-16 low / high byte (the end)." % CLONE_AGO_MS],
        "a", 10, 10, ent, default="201"))
    ent = [(i, op, "") for i, op in enumerate(tops)]
    line = 0
    for i, op in enumerate(tops):
        if (i == 0 or tops[i - 1] == T_LINE_END) and op != T_TOUR_END:
            ent[i] = (i, op, "line %d: %s" % (line + 1, texp[line][0]))
            line += 1
    aw = 10
    assert len(tops) <= 1 << aw
    parts.append(case_rom(
        "lx_tour_rom",
        ["Tour mode: the %d ./emu lines that passed on the AWS F2, in order." % len(texp),
         "0x0bb a byte, 0x1bb a frame's last byte, 0x20v pins P3:P0 = v, 0x300 end of",
         "line (compare), 0x3FF end of the tour. %d ops." % len(tops)],
        "a", aw, 10, ent, default="3ff"))
    ent = []
    for i, (title, rb, lamps) in enumerate(texp):
        chk = lamps is not None
        v = (int(chk) << 68) | (((lamps or 0) >> 4) << 64) | int.from_bytes(rb, "little")
        ent.append((i, v, "%s; -o %s" % (rb.hex(), "0x%02X" % lamps if chk else "unchecked")))
    parts.append(case_rom(
        "lx_tour_exp",
        ["Golden answer per tour line: {check lamps, P7:P4, the last 8 bytes (byte 0",
         "in bits 7:0)}, the ./emu line's -r and -o values (lane_model.py)."],
        "a", 4, 69, ent))
    parts.append("// Number of tour lines\nmodule lx_tour_n (output wire [3:0] n);\n"
                 "    assign n = 4'd%d;\nendmodule\n" % len(texp))
    ent = []
    for i in sorted(MSGS):
        s = MSGS[i]
        s6 = six(s, "left") if i in (16, 17, 19, 20, 21) else six(s)
        ent.append((i, chars_word(s6), '"%s"' % s6))
    parts.append(case_rom(
        "lx_text",
        ["Words, 6 characters, HEX5 (left) in bits 29:25 ... HEX0 in bits 4:0.",
         "0-6 the decision of a 'V' record (its status); 8-15 the tag presets (SW5:3);",
         "16-22 the board's own words (digits are filled in by the fabric)."],
        "a", 5, 30, ent, default="%x" % chars_word("      ")))
    ent = []
    for off in range(len(BANNER) - 5):
        ent.append((off, chars_word(BANNER[off:off + 6]), '"%s"' % BANNER[off:off + 6]))
    parts.append(case_rom(
        "lx_banner", ["The power-on banner, 6 characters from offset a (%d offsets)." % (len(BANNER) - 5)],
        "a", 6, 30, ent, default="%x" % chars_word("      ")))
    parts.append("module lx_banner_n (output wire [5:0] n);\n    assign n = 6'd%d;\nendmodule\n"
                 % (len(BANNER) - 5))
    ent = [(i, f, repr(CHARS[i])) for i, f in enumerate(FONT)]
    parts.append(case_rom("lx_font", ["7-segment font: char code -> segments gfedcba (1 = lit)."],
                          "a", 5, 7, ent))
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Pins (Terasic DE10-Lite schematic rev B1; docs/stage4/07 section 6)
# ---------------------------------------------------------------------------
SW_PINS = ["C10", "C11", "D12", "C12", "A12", "B12", "A13", "A14", "B14", "F15"]
LEDR_PINS = ["A8", "A9", "A10", "B10", "D13", "C13", "E14", "D14", "A11", "B11"]
HEX_PINS = [
    ["C14", "E15", "C15", "C16", "E16", "D17", "C17", "D15"],
    ["C18", "D18", "E18", "B16", "A17", "A18", "B17", "A16"],
    ["B20", "A20", "B19", "A21", "B21", "C22", "B22", "A19"],
    ["F21", "E22", "E21", "C19", "C20", "D19", "E17", "D22"],
    ["F18", "E20", "E19", "J18", "H19", "F19", "F20", "F17"],
    ["J20", "K20", "L18", "N18", "M20", "N19", "N20", "L19"],
]
GPIO_PINS = ["V10", "W10", "V9", "W9", "V8", "W8", "V7", "W7", "W6", "V5", "W5", "AA15", "AA14",
             "W13", "W12", "AB13", "AB12", "Y11", "AB11", "W11", "AB10", "AA10", "AA9", "Y8",
             "AA8", "Y7", "AA7", "Y6", "AA6", "Y5", "AA5", "Y4", "AB3", "Y3", "AB2", "AA2"]


def header_pin(g):
    """GPIO_n -> pin number on the 2x20 header JP1."""
    return g + 1 if g < 10 else (g + 3 if g < 26 else g + 5)


# What we wire to the header: (GPIO index, direction, signal, connects to, colour)
WIRES = [
    (0, "in", "Host link: laptop -> board (FPGA receives)", "USB-UART TXD", "#2563eb"),
    (1, "out", "Host link: board -> laptop (the chip's records)", "USB-UART RXD", "#16a34a"),
    (2, "in", "Ultrasonic Echo (5 V, through the divider)", "HC-SR04 Echo via 1 kΩ; 2 kΩ to GND", "#ea580c"),
    (3, "out", "Ultrasonic Trig", "HC-SR04 Trig", "#d97706"),
    (4, "out", "Green lamp: charged", "green LED + 330 Ω", "#22c55e"),
    (5, "out", "White lamp: camera flash", "white LED + 100 Ω", "#a3a3a3"),
    (6, "out", "Red lamp: alarm", "red LED + 330 Ω", "#dc2626"),
    (7, "out", "Buzzer", "buzzer module IN/I/O", "#7c3aed"),
    (8, "out", "Lane-closed lamp (optional)", "yellow LED + 330 Ω", "#eab308"),
]
PULLUPS = [0, 2]           # inputs that read 'idle' when nothing is plugged in (Echo high = no reading)


def qsf(core_hz):
    L_ = [
        "# lanex.qsf - the LaneX desk lane on the Terasic DE10-Lite (MAX 10 10M50DAF484C7G).",
        "# GENERATED by scripts/stage4/gen_de10lite.py; pins from Terasic's DE10-Lite",
        "# schematic (rev B1). Open lanex.qpf in Quartus Prime Lite and compile.",
        "",
        "set_global_assignment -name FAMILY \"MAX 10\"",
        "set_global_assignment -name DEVICE 10M50DAF484C7G",
        "set_global_assignment -name TOP_LEVEL_ENTITY lanex_de10lite",
        "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files",
        "set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0",
        "set_global_assignment -name MAX_CORE_JUNCTION_TEMP 85",
        "set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL",
        "# Fitter effort for timing: +4.5 ns of setup slack at 31.25 MHz instead of +0.5 ns",
        "# (Quartus 25.1std.0 on Nicholas's laptop); the compile takes about 7 minutes, not 2",
        "set_global_assignment -name OPTIMIZATION_MODE \"HIGH PERFORMANCE EFFORT\"",
        "# Boot from the internal configuration flash at power-up (as Terasic's own projects)",
        "set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE \"SINGLE IMAGE WITH ERAM\"",
        "set_global_assignment -name STRATIX_DEVICE_IO_STANDARD \"3.3-V LVTTL\"",
        "",
        "set_global_assignment -name VERILOG_FILE lanex_de10lite.v",
        "set_global_assignment -name VERILOG_FILE lanex_board.v",
        "set_global_assignment -name VERILOG_FILE lanex_data.v",
        "set_global_assignment -name VERILOG_FILE lanex_chip.v",
        "set_global_assignment -name SDC_FILE lanex.sdc",
        "",
        "# The core clock (Hz). 31,250,000 is the AWS F2 build's clock. If the Timing Analyzer",
        "# reports the core clock's Fmax below it, change this line to 25000000 (or 20000000)",
        "# and compile again: the PLL and every UART divider follow.",
        "set_parameter -name CORE_HZ %d" % core_hz,
        "# The ultrasonic sensor: an object at least PRESENT_MM above the floor under it is a",
        "# vehicle; one reaching TALL_MM is a lorry (class 3). Put your toys under the sensor:",
        "# the display shows the height it measures (\"h  4.5\" = 4.5 cm). Set TALL_MM between",
        "# your car's height and your lorry's, in mm, then compile again.",
        "set_parameter -name PRESENT_MM 15",
        "set_parameter -name TALL_MM 60",
        "",
        "set_location_assignment PIN_P11 -to MAX10_CLK1_50",
        "set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to MAX10_CLK1_50",
    ]
    for i, p in enumerate(["B8", "A7"]):
        L_ += ["set_location_assignment PIN_%s -to KEY[%d]" % (p, i),
               "set_instance_assignment -name IO_STANDARD \"3.3 V SCHMITT TRIGGER\" -to KEY[%d]" % i]
    for i, p in enumerate(SW_PINS):
        L_ += ["set_location_assignment PIN_%s -to SW[%d]" % (p, i),
               "set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to SW[%d]" % i]
    for i, p in enumerate(LEDR_PINS):
        L_ += ["set_location_assignment PIN_%s -to LEDR[%d]" % (p, i),
               "set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to LEDR[%d]" % i]
    for h, pins in enumerate(HEX_PINS):
        for i, p in enumerate(pins):
            L_ += ["set_location_assignment PIN_%s -to HEX%d[%d]" % (p, h, i),
                   "set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to HEX%d[%d]" % (h, i)]
    for i, p in enumerate(GPIO_PINS):
        L_ += ["set_location_assignment PIN_%s -to GPIO[%d]" % (p, i),
               "set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to GPIO[%d]" % i]
    L_.append("# inputs that read 'idle' with nothing plugged in")
    for g in PULLUPS:
        L_.append("set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to GPIO[%d]" % g)
    L_ += ["", "# (Quartus adds this line itself when it saves the project)",
           "set_global_assignment -name LAST_QUARTUS_VERSION \"25.1std.0 Lite Edition\""]
    return "\n".join(L_) + "\n"


QPF = """\
# lanex.qpf - Quartus project file (GENERATED by scripts/stage4/gen_de10lite.py)
QUARTUS_VERSION = "25.1"
PROJECT_REVISION = "lanex"
"""

SDC = """\
# lanex.sdc - timing constraints (GENERATED by scripts/stage4/gen_de10lite.py)
# The 50 MHz board oscillator feeds the PLL; everything inside runs on the PLL's
# output (the core clock, CORE_HZ). Quartus derives that clock from the PLL.
create_clock -name MAX10_CLK1_50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_pll_clocks
derive_clock_uncertainty
# Switches, buttons, sensors and the laptop's UART line are asynchronous: the
# fabric synchronises each through two flip-flops. Lamps and displays are slow.
set_false_path -from [get_ports {KEY[*] SW[*] GPIO[*]}]
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] GPIO[*]}]
"""


def chip_v(words):
    body = G.chip_modules(words, "de10lite")
    hexsha = G.hashlib.sha256(open(G.HEX, "rb").read()).hexdigest()
    head = [
        "// " + "=" * 76,
        "// lanex_chip.v - the RVBL-2 chip + LaneX ROM for the DE10-Lite (MAX 10).",
        "// GENERATED by scripts/stage4/gen_de10lite.py with the AWS build's own code",
        "// (gen_riscv_sv.chip_modules): the same rtl/ and the same ROM as stage4/riscv.sv.",
        "// Differences from the AWS chip, both value-for-value: the pad tri-state is",
        "// resolved in the board fabric (pins_o/pins_oe/pins_i), and the data RAM is coded",
        "// as Quartus infers M9K blocks. Do not edit: regenerate.",
        "//",
        "//   firmware.hex sha256: %s" % hexsha,
        "//   ROM: %d words; the 'I' record must report rom_words %d, rom_crc 0x%04X" % (
            len(words), len(words), G.rom_crc(words)),
        "// " + "=" * 76,
        "",
    ]
    return "\n".join(head) + "\n".join(body)


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# LaneX Live, the laptop dashboard (one self-contained page)
# ---------------------------------------------------------------------------
DASH = os.path.join(OUT, "dashboard")


def board_config(words):
    return {
        "key": list(L.DEMO_KEY), "gantry": GANTRY, "proto": L.PROTO,
        "romWords": len(words), "romCrc": G.rom_crc(words), "fares": list(L.DEFAULT_FARES),
        "presets": [{"name": PRESETS[p][0], "epc": PRESETS[p][1].hex()} for p in range(1, 8)],
    }


def demo_stream(tpl, words):
    """The page's demo: what the board sends for the booth's story, made by the
    golden model from the board's own frames ([delay ms, record hex], looped)."""
    m = L.LaneModel(words)
    for i in range(len(BOOT)):
        for b in play_template(tpl[i], 0):
            m.rx_byte(b)
    # (tag preset, P2:P1): a car (0), the lorry (2), a motorcycle (3)
    story = [(1, 0), (1, 2), (4, 0), (5, 0), (3, 0), (7, 0), (0, 3), (2, 2), (6, 0)]
    now = 5000
    for preset, code in story:
        m.gpio(1 | code << 1)
        jobs = ([TID_SIGHTING] if preset == 5 else []) + ([TID_READ + preset] if preset else [])
        for tid in jobs:
            for b in play_template(tpl[tid], now):
                m.rx_byte(b)
        m.gpio(0)
        now += 3700
    recs = [bytes(m.out[i:i + 8]) for i in range(0, len(m.out), 8)]
    demo, first = [], True
    for r in recs:
        if r[0] == 0x41:
            demo.append([450, r.hex()])        # its signature follows the record
        else:
            demo.append([900 if first else 3200, r.hex()])
            first = False
    return demo


def dashboard(tpl, words):
    import json
    page = open(os.path.join(DASH, "lanex_live.src.html"), encoding="utf-8").read()
    core = open(os.path.join(ROOT, "application", "replay", "lane_core.js"), encoding="utf-8").read()
    live = open(os.path.join(DASH, "live_core.js"), encoding="utf-8").read()
    for k, v in (("/*__LANE_CORE__*/", core), ("/*__LIVE_CORE__*/", live),
                 ("/*__BOARD__*/", json.dumps(board_config(words))),
                 ("/*__DEMO__*/", json.dumps(demo_stream(tpl, words)))):
        assert page.count(k) == 1, k
        page = page.replace(k, v.strip())
    return page


def outputs(core_hz):
    words = G.load_rom()
    tpl = templates()
    tops, texp = tour()
    import wiring_card
    return {
        "lanex_chip.v": chip_v(words),
        "lanex_data.v": data_v(words, tpl, tops, texp),
        "lanex.qsf": qsf(core_hz),
        "lanex.qpf": QPF,
        "lanex.sdc": SDC,
        "wiring_card.html": wiring_card.render(WIRES, header_pin, GPIO_PINS, PRESETS),
        "lanex_live.html": dashboard(tpl, words),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="fail if a generated file is stale")
    ap.add_argument("--core-hz", type=int, default=31250000, choices=sorted(CORE_HZ))
    a = ap.parse_args()
    stale = []
    for name, text in outputs(a.core_hz).items():
        path = os.path.join(OUT, name)
        if a.check:
            old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if name == "lanex.qsf":
                have = set(old.splitlines())
                ok = all(l in have for l in text.splitlines() if l and not l.startswith("#")
                         and not l.startswith("set_parameter"))
            else:
                ok = old == text
            if not ok:
                stale.append(name)
            continue
        os.makedirs(OUT, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("wrote stage4/de10lite/%s (%d lines)" % (name, text.count("\n")))
    if a.check:
        if stale:
            sys.exit("stale in stage4/de10lite: %s (run scripts/stage4/gen_de10lite.py)" % ", ".join(stale))
        print("stage4/de10lite generated files are current")


if __name__ == "__main__":
    main()
