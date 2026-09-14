#!/usr/bin/env python3
"""Turn the official validation firmware into a plain hex image.

Source of truth:
    https://github.com/championchip-experience-community/CCX_Malaysia_Edition_Firmware_Stage_2

The upstream file is a fragment of a Verilog `case` body, one line per word:

    32'h00400000: r_Instruction = 32'h123452B7;

It is vendored verbatim at firmware/validation_firmware.txt rather than fetched
at build time, so this flow stays offline and reproducible, and so a silent
upstream edit cannot change what we validated against. The SHA-256 below pins
the exact bytes that were audited.

WHY THE IMAGE MUST STAY AT 0x00400000
-------------------------------------
The firmware is position-dependent. It derives its .bss base from the PC:

    0040011c  auipc s0, 0xfc10   -> 0x1001011C
    00400120  addi  s0, s0, -284 -> 0x10010000

Relocating it would move that computed address off DMEM_BASE and every store
would land nowhere. The three structural assertions below (base, count,
contiguity) exist to make any drift from that a loud failure.

Usage:
    python gen_validation_hex.py [--check]

--check verifies the vendored source and the emitted hex without rewriting
anything, and is what run_ci.sh calls.
"""

import argparse
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FW = os.path.join(ROOT, "firmware")

SRC = os.path.join(FW, "validation_firmware.txt")
OUT = os.path.join(FW, "validation_firmware.hex")

# The exact upstream bytes this migration was audited against.
SRC_SHA256 = "18dd1ee8cc6925ac4ce5e0cbad635687ec129f5b4a75f861a9cb3a2f8df28890"

BASE = 0x00400000
EXPECT_WORDS = 259

LINE_RE = re.compile(
    r"32'h([0-9A-Fa-f]{8})\s*:\s*r_Instruction\s*=\s*32'h([0-9A-Fa-f]{8})\s*;"
)

# Subtest boundaries, read off firmware.s and confirmed against the
# disassembly. Every _error path is a branch to 0x004003F0, so the PC of the
# branch that took it there identifies the failing subtest exactly. Emitted
# into the generated header so the testbench can name a failure instead of
# leaving it to be bisected by hand.
SUBTESTS = [
    (0x00400000, 0x00400118, "_rv32i_alu_test"),
    (0x0040011C, 0x00400180, "_rv32i_lsu_test"),
    (0x00400184, 0x0040020C, "_rv32i_ctrl_test"),
    (0x00400210, 0x00400234, "_rv32i_reg_test"),
    (0x00400238, 0x00400294, "_rvbl2_mult_test"),
    (0x00400298, 0x00400348, "_rvbl2_crc_test"),
    (0x0040034C, 0x00400374, "_rvbl2_crc_mem_test"),
    (0x00400378, 0x00400390, "_rvbl2_arith_integ_test"),
    (0x00400394, 0x004003E4, "_rvbl2_mem_transfer_test"),
]

PASS_LOOP = 0x004003EC  # all_good:  li x4, 0        ; j .
FAIL_LOOP = 0x004003F4  # _error:    li x4, -1       ; j .
ERROR_ENTRY = 0x004003F0  # first instruction of _error


def read_source():
    """Parse the vendored file into a word list, asserting its structure."""
    with open(SRC, "rb") as fh:
        raw = fh.read()

    got = hashlib.sha256(raw).hexdigest()
    if got != SRC_SHA256:
        sys.exit(
            "FAIL validation_firmware.txt does not match the audited bytes\n"
            "       expected sha256 %s\n"
            "       got      sha256 %s\n"
            "  The upstream firmware may have been amended. Re-read the diff\n"
            "  and re-audit before updating SRC_SHA256 - do not just re-pin it."
            % (SRC_SHA256, got)
        )

    rows = LINE_RE.findall(raw.decode("utf-8"))
    if len(rows) != EXPECT_WORDS:
        sys.exit(
            "FAIL expected %d instruction lines, parsed %d"
            % (EXPECT_WORDS, len(rows))
        )

    addrs = [int(a, 16) for a, _ in rows]
    if addrs[0] != BASE:
        sys.exit("FAIL image starts at 0x%08X, expected 0x%08X" % (addrs[0], BASE))
    for i in range(1, len(addrs)):
        if addrs[i] != addrs[i - 1] + 4:
            sys.exit(
                "FAIL image is not contiguous: 0x%08X follows 0x%08X"
                % (addrs[i], addrs[i - 1])
            )

    return [int(w, 16) for _, w in rows]


def write_hex(words):
    with open(OUT, "w", newline="\n") as fh:
        for w in words:
            fh.write("%08x\n" % w)


def read_hex():
    if not os.path.exists(OUT):
        return None
    with open(OUT) as fh:
        return [int(line, 16) for line in fh if line.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="verify the vendored source and the emitted hex without writing",
    )
    args = ap.parse_args()

    words = read_source()

    if args.check:
        have = read_hex()
        if have is None:
            sys.exit("FAIL %s does not exist - run gen_validation_hex.py" % OUT)
        if have != words:
            for i, (a, b) in enumerate(zip(have, words)):
                if a != b:
                    sys.exit(
                        "FAIL %s is stale at word %d (0x%08X): has %08x, source says %08x"
                        % (OUT, i, BASE + 4 * i, a, b)
                    )
            sys.exit(
                "FAIL %s has %d words, source has %d" % (OUT, len(have), len(words))
            )
        print(
            "OK   official firmware: %d words, 0x%08X..0x%08X, contiguous, sha256 pinned"
            % (len(words), BASE, BASE + 4 * (len(words) - 1))
        )
        return

    write_hex(words)
    print(
        "Wrote %s: %d words, 0x%08X..0x%08X"
        % (OUT, len(words), BASE, BASE + 4 * (len(words) - 1))
    )


if __name__ == "__main__":
    main()
