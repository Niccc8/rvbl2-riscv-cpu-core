#!/usr/bin/env python3
"""Unit tests for the Stage 3 assembler extensions (.equ, block comments,
full-range li, la) in both copies of the assembler: scripts/asm.py (root flow)
and chipinventor/scripts/asm.py (platform flow).

Expected encodings are anchored, wherever possible, to words of the OFFICIAL
validation firmware, which a different toolchain produced: they are not
derived from the code under test.

    firmware word   0: 0x123452B7  lui  t0, 0x12345
    firmware word   1: 0x12345337  lui  t1, 0x12345
    firmware word   5: 0x00A00293  addi t0, zero, 10
    firmware word  74: 0x67830313  addi t1, t1, 0x678
    firmware word 134: 0xDEADC2B7  lui  t0, 0xDEADC   (rounded up: bit 11 of
    firmware word 135: 0xEEF28293  addi t0, t0, -273    0xDEADBEEF is set)
    firmware word 252: 0xFFF00213  addi tp, zero, -1

Also checks that both assemblers produce identical images for every Stage 3
program. Exit status is non-zero on any failure.
"""

import glob
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FW_HEX = os.path.join(ROOT, "chipinventor", "firmware", "validation_firmware.hex")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def words(asm, src):
    mem, _ = asm.assemble([l + "\n" for l in src.strip().splitlines()])
    return mem


def main():
    root_asm = load(os.path.join(ROOT, "scripts", "asm.py"), "asm_root")
    ci_asm = load(os.path.join(ROOT, "chipinventor", "scripts", "asm.py"), "asm_ci")
    with open(FW_HEX) as fh:
        fw = [int(l, 16) for l in fh if l.strip()]

    cases = [
        ("li: fits 12 bits -> one addi",       "li t0, 10",                   [fw[5]]),
        ("li: -1 -> one addi",                 "li tp, -1",                   [fw[252]]),
        ("li: 32-bit -> lui + addi",           "li t1, 0x12345678",           [fw[1], fw[74]]),
        ("li: bit 11 set -> lui rounded up",   "li t0, 0xDEADBEEF",           [fw[134], fw[135]]),
        ("la: low 12 bits zero -> lui only",   "la s0, 0xF0000000",           [0xF0000437]),
        ("la: .equ symbol",                    ".equ B, 0x12345000\nla t0, B", [fw[0]]),
        ("equ: memory offset",                 ".equ OFF, 8\nlw t0, OFF(s0)",  [0x00842283]),
        ("equ: I-type immediate",              ".equ M, 0x2\nandi t0, t0, M",  [0x0022F293]),
        ("comments: /* */ over lines, // , #", "/* a\n b */ li t0, 10 // c\n# d", [fw[5]]),
    ]

    passed = failed = 0
    for asm_name, asm in (("scripts/asm.py", root_asm), ("chipinventor/scripts/asm.py", ci_asm)):
        for name, src, exp in cases:
            try:
                got = words(asm, src)
            except Exception as e:  # pragma: no cover - reported, not raised
                got = "error: %s" % e
            if got == exp:
                passed += 1
            else:
                failed += 1
                print("FAIL [%s] %s: got %s expected %s" % (asm_name, name, got,
                      [hex(w) for w in exp]))

    # Both assemblers must agree on every Stage 3 program.
    for src_path in sorted(glob.glob(os.path.join(ROOT, "tests", "progs", "stage3", "*.s"))):
        with open(src_path) as fh:
            lines = fh.readlines()
        a, _ = root_asm.assemble(lines)
        b, _ = ci_asm.assemble(lines)
        if a == b:
            passed += 1
        else:
            failed += 1
            print("FAIL assemblers disagree on %s" % os.path.basename(src_path))

    print("==== test_asm: %d passed, %d failed ====" % (passed, failed))
    print("TEST_ASM: ALL TESTS PASSED" if failed == 0 else "TEST_ASM: FAILURES PRESENT")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
