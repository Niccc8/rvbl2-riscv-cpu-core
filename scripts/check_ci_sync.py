#!/usr/bin/env python3
"""Fail if the ChipInventor copies have drifted from this repository's sources.

chipinventor/ must stay self-contained - it is what gets pasted into the
platform - so it carries its own copies of the blocks and of the Stage 3
programs. This is the one place that compares them with the originals:

  * every chipinventor/blocks/X.v that has an rtl/X.v must be code-identical
    to it: the same text once comments, attributes and whitespace are removed.
    The canvas copies differ only in comments (they drop pointers into this
    repository's documents). Two blocks are different by design and are
    exempt, each for a stated reason:
        dmem.v  the canvas copy has no `ifdef (the platform cannot resolve
                one) and no zero-fill initial block (it would reach synthesis)
        imem.v  the canvas ROM is a generated case statement; the platform
                has no filesystem for $readmemh
    One is rewritten and proven instead:
        crc_unit.v  the canvas copy is the same CRC written as byte updates
                (chipinventor/scripts/gen_crc_xor.py), which simulates about
                2.7 times faster - what fits the platform's time window. It
                must be that script's output and pass its equivalence proof
                against the frozen Phase 2 block (chipinventor/rtl_ref), and
                rtl/crc_unit.v must be code-identical to that frozen block.
  * chipinventor/firmware/stage3/*.s must be byte-identical to
    tests/progs/stage3/*.s, file for file.

Exit status is non-zero on any mismatch.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CI_BLOCKS = os.path.join(ROOT, "chipinventor", "blocks")
RTL = os.path.join(ROOT, "rtl")
CI_PROGS = os.path.join(ROOT, "chipinventor", "firmware", "stage3")
PROGS = os.path.join(ROOT, "tests", "progs", "stage3")
EXEMPT = {"dmem.v", "imem.v"}
PROVEN = {"crc_unit.v"}
CRC_GEN = os.path.join(ROOT, "chipinventor", "scripts", "gen_crc_xor.py")
RTL_REF = os.path.join(ROOT, "chipinventor", "rtl_ref")


def code(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"\(\*.*?\*\)", "", text)
    return re.sub(r"\s+", " ", text).strip()


def main():
    passed = failed = 0

    for fn in sorted(os.listdir(CI_BLOCKS)):
        rtl = os.path.join(RTL, fn)
        if not fn.endswith(".v") or fn in EXEMPT or not os.path.exists(rtl):
            continue
        if fn in PROVEN:
            ok = code(rtl) == code(os.path.join(RTL_REF, fn))
            if not ok:
                print("FAIL rtl/%s differs in code from the frozen chipinventor/rtl_ref/%s" % (fn, fn))
            for flag in ("--check", "--prove"):
                r = subprocess.run([sys.executable, CRC_GEN, flag], capture_output=True, text=True)
                if r.returncode or "FAIL" in r.stdout:
                    ok = False
                    print("FAIL chipinventor/blocks/%s: gen_crc_xor.py %s\n%s" % (fn, flag, (r.stdout + r.stderr).strip()))
            passed += ok
            failed += not ok
            continue
        if code(os.path.join(CI_BLOCKS, fn)) == code(rtl):
            passed += 1
        else:
            failed += 1
            print("FAIL chipinventor/blocks/%s differs in code from rtl/%s" % (fn, fn))

    ours = sorted(f for f in os.listdir(PROGS) if f.endswith(".s"))
    theirs = sorted(f for f in os.listdir(CI_PROGS) if f.endswith(".s"))
    if ours != theirs:
        failed += 1
        print("FAIL program sets differ: tests/progs/stage3 %s, chipinventor %s" % (ours, theirs))
    for fn in sorted(set(ours) & set(theirs)):
        with open(os.path.join(PROGS, fn), "rb") as a, open(os.path.join(CI_PROGS, fn), "rb") as b:
            if a.read() == b.read():
                passed += 1
            else:
                failed += 1
                print("FAIL chipinventor/firmware/stage3/%s differs from tests/progs/stage3/%s" % (fn, fn))

    print("==== check_ci_sync: %d passed, %d failed ====" % (passed, failed))
    print("CHECK_CI_SYNC: ALL TESTS PASSED" if failed == 0 else "CHECK_CI_SYNC: FAILURES PRESENT")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
