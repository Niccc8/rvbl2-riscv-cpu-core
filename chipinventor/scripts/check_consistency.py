#!/usr/bin/env python3
"""Fail if the testbench's hard-coded constants have drifted from the firmware.

tb_chipinventor.v cannot `include firmware/ci_prog_expected.vh - the platform's
testbench field is a single body of text with no filesystem behind it - so the
generated expectations are mirrored into the testbench by hand. That is a real
staleness hazard: rebuild the firmware, forget to update the testbench, and the
suite keeps passing while checking the wrong addresses.

This compares the two and fails the run if any value disagrees.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VH = os.path.join(ROOT, "firmware", "ci_prog_expected.vh")
TB = os.path.join(ROOT, "tb_chipinventor.v")
FW_HEX = os.path.join(ROOT, "firmware", "validation_firmware.hex")

FW_BASE = 0x00400000

# Constants the testbench mirrors. IMEM_WORDS_NEEDED is not among them: the
# testbench derives nothing from it, since the ROM is now inside the imem block.
CHECKED = ["SUPP_BASE", "NUM_SIG_TESTS", "SIG_BASE_WORDS",
           "EXP_JALR_LINK", "EXP_AUIPC",
           "EXP_IMEM_LOAD", "EXP_DEP_SUM", "EXP_DEP_CTR"]

# SUITE 2A synchronises on the official firmware's two exit loops and reads its
# verdict out of x4. Those addresses were read off a disassembly by hand, so
# they are re-derived here against the vendored image: each named constant must
# still point at the instruction it is supposed to.
#
# This is what makes an amended upstream firmware a loud failure rather than a
# testbench that waits forever for a self-loop that moved.
FW_ANCHORS = [
    ("FW_PASS_LOOP", 0x0000006F, "jal x0, 0  (all_good self-loop)"),
    ("FW_ERROR_PC",  0xFFF00213, "addi x4, x0, -1  (_error entry)"),
    ("FW_FAIL_LOOP", 0x0000006F, "jal x0, 0  (_error self-loop)"),
]


def localparams(path):
    with open(path) as fh:
        text = fh.read()
    out = {}
    for name, value in re.findall(
            r"localparam\s+(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^;]+);", text):
        out[name] = value.strip()
    return out


def norm(v):
    """Compare values by meaning, not spelling: 32'd15 == 32'h0000000F."""
    v = v.strip()
    m = re.match(r"^(?:(\d+)'([hdb]))?([0-9a-fA-F_]+)$", v)
    if m:
        base = {"h": 16, "d": 10, "b": 2}.get(m.group(2), 10)
        try:
            return int(m.group(3).replace("_", ""), base)
        except ValueError:
            return v.lower()
    return v.lower().replace(" ", "")


def main():
    for path in (VH, TB):
        if not os.path.exists(path):
            sys.exit("FAIL: %s does not exist" % path)

    want = localparams(VH)
    got = localparams(TB)

    problems = []
    for name in CHECKED:
        if name not in want:
            problems.append("%s missing from ci_prog_expected.vh" % name)
            continue
        if name not in got:
            problems.append("%s missing from tb_chipinventor.v" % name)
            continue
        if norm(want[name]) != norm(got[name]):
            problems.append("%s: firmware says %s, testbench says %s"
                            % (name, want[name], got[name]))

    # ---- the official firmware's exit loops still point where we think -----
    if not os.path.exists(FW_HEX):
        problems.append("%s does not exist - run gen_validation_hex.py" % FW_HEX)
    else:
        with open(FW_HEX) as fh:
            image = [int(line, 16) for line in fh if line.strip()]
        for name, expect_word, what in FW_ANCHORS:
            if name not in got:
                problems.append("%s missing from tb_chipinventor.v" % name)
                continue
            addr = norm(got[name])
            if not isinstance(addr, int):
                problems.append("%s is not a literal address: %s" % (name, got[name]))
                continue
            idx = (addr - FW_BASE) // 4
            if addr < FW_BASE or idx >= len(image):
                problems.append("%s = 0x%08X is outside the official image" % (name, addr))
                continue
            if image[idx] != expect_word:
                problems.append(
                    "%s = 0x%08X holds %08x, expected %08x (%s) - the official "
                    "firmware moved" % (name, addr, image[idx], expect_word, what))

        # all_good sets x4 = 0 in the word before its self-loop; that pairing is
        # the whole PASS criterion, so check it rather than assume it.
        if "FW_PASS_LOOP" in got:
            addr = norm(got["FW_PASS_LOOP"])
            if isinstance(addr, int):
                idx = (addr - FW_BASE) // 4 - 1
                if 0 <= idx < len(image) and image[idx] != 0x00000213:
                    problems.append(
                        "the word before FW_PASS_LOOP holds %08x, expected "
                        "00000213 (addi x4, x0, 0)" % image[idx])

    if problems:
        for p in problems:
            print("FAIL: %s" % p, file=sys.stderr)
        sys.exit("testbench constants are stale - copy them from firmware/ci_prog_expected.vh")

    print("OK   testbench constants match firmware/ci_prog_expected.vh (%d values)" % len(CHECKED))
    print("OK   official firmware anchors still point at the right instructions (%d)"
          % (len(FW_ANCHORS) + 1))


if __name__ == "__main__":
    main()
