#!/usr/bin/env python3
"""Prove check_export.py and gen_ci_aliases.py on a platform-format export.

There is no real Stage 3 export until the canvas is wired, so the checker
would otherwise meet its first input on the day it matters. This builds the
mock export (gen_mock_export.py), requires check_export.py to pass it, then
breaks it the ways a hand-wired canvas goes wrong and requires each one to
FAIL with the right message:

    C/D swapped on an Inout Pin       two pad inputs crossed
    a wire missing                    the read-back chain reordered
    dmem DMEM_WORDS wrong             uart CLK_FREQ_HZ wrong
    SoC project named differently     a duplicate pin name
    a block's code edited             a pin with the wrong width

Finally gen_ci_aliases.py must resolve all nine aliases on the mock export.

Exit status is non-zero on any failure.
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MOCK = os.path.join(ROOT, "build", "mock_export.v")


def run(*args):
    p = subprocess.run([sys.executable] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def tri_swap(t):
    return re.sub(r"assign pins_io_3 = (\w+) \? (\w+) :", r"assign pins_io_3 = \2 ? \1 :", t, 1)


def pad_cross(t):
    t = t.replace(".p4_i (pins_io_4)", ".p4_i (TMP)").replace(".p5_i (pins_io_5)", ".p5_i (pins_io_4)")
    return t.replace(".p4_i (TMP)", ".p4_i (pins_io_5)")


def drop_wire(t):
    return re.sub(r"\n\s*\.bus_we_i \(w_\d+\),?", "", t, 1)


def chain_swap(t):
    # gpio's chain input and output exchanged: a different graph, same blocks.
    ip = t.index("module rvbl2_soc (")
    body = t[ip:]
    g = re.search(r"gpio blk\d+_\d+ \((.*?)\);", body, re.S).group(0)
    rin = re.search(r"\.bus_rdata_i \((w_\d+)\)", g).group(1)
    rout = re.search(r"\.bus_rdata_o \((w_\d+)\)", g).group(1)
    g2 = g.replace("(%s)" % rin, "(TMP)").replace("(%s)" % rout, "(%s)" % rin).replace("(TMP)", "(%s)" % rout)
    return t[:ip] + body.replace(g, g2)


MUTANTS = [
    ("C/D swapped on pins_io_3",   tri_swap, "pins_io_3: C and D are SWAPPED"),
    ("pad inputs 4/5 crossed",     pad_cross, "net in"),
    ("gpio bus_we_i not wired",    drop_wire, "net in"),
    ("read-back chain reversed",   chain_swap, "net in"),
    ("dmem DMEM_WORDS = 1024",     lambda t: t.replace(".DMEM_WORDS(2048)", ".DMEM_WORDS(1024)"),
     "DMEM_WORDS resolves to 1024"),
    ("uart CLK_FREQ_HZ = 50 MHz",  lambda t: t.replace(".CLK_FREQ_HZ(30303030)", ".CLK_FREQ_HZ(50000000)"),
     "CLK_FREQ_HZ resolves to 50000000"),
    ("SoC project misnamed",       lambda t: t.replace("rvbl2_soc", "riscv_core_championchip"),
     "name the project rvbl2_soc"),
    ("duplicate pin name",         lambda t: t.replace("output wire tx_o,\n  input wire rx_i",
                                                       "output wire tx_o,\n  output wire tx_o,\n  input wire rx_i"),
     "duplicate pin name"),
    ("gpio code edited",           lambda t: t.replace("wire [N_PINS-1:0] datain = sync2 & ~datadir;",
                                                       "wire [N_PINS-1:0] datain = sync2;"),
     "block gpio differs"),
    ("gpio_o pin 4 bits wide",     lambda t: t.replace("output wire [7:0] gpio_o,", "output wire [3:0] gpio_o,"),
     "pin missing or different"),
]


def main():
    passed = failed = 0

    def result(ok, what, detail=""):
        nonlocal passed, failed
        if ok:
            passed += 1
        else:
            failed += 1
            print("FAIL %s%s" % (what, ("\n" + detail) if detail else ""))

    rc, out = run(os.path.join(HERE, "gen_mock_export.py"))
    result(rc == 0, "gen_mock_export.py", out)
    text = open(MOCK).read()

    rc, out = run(os.path.join(HERE, "check_export.py"), MOCK)
    result(rc == 0, "check_export passes the correct mock export", out)

    with tempfile.TemporaryDirectory() as td:
        for name, mutate, expect in MUTANTS:
            bad = mutate(text)
            if bad == text:
                result(False, "mutant '%s' did not apply" % name)
                continue
            path = os.path.join(td, "mutant.v")
            with open(path, "w", newline="\n") as fh:
                fh.write(bad)
            rc, out = run(os.path.join(HERE, "check_export.py"), path)
            result(rc != 0 and expect in out,
                   "check_export must fail '%s' with \"%s\"" % (name, expect), out[-600:])

    rc, out = run(os.path.join(HERE, "gen_ci_aliases.py"), MOCK)
    ok = rc == 0 and "`define SOC   `DUT.blkProj" in out and out.count("`SOC.blk") == 7
    result(ok, "gen_ci_aliases resolves all nine aliases on the mock export", out)

    print("==== test_check_export: %d passed, %d failed ====" % (passed, failed))
    print("TEST_CHECK_EXPORT: ALL TESTS PASSED" if failed == 0 else "TEST_CHECK_EXPORT: FAILURES PRESENT")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
