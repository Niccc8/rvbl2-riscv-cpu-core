#!/usr/bin/env python3
"""Build the single firmware image the ChipInventor project runs.

The platform's IMEM is a fixed case-ROM, so unlike the file-driven flow it
cannot swap programs between tests. Everything the integration suite needs has
to live in one image, and that image is this one:

    firmware/tb_firmware_prog.s   (generated upstream, all 47 instructions)
  + an appended coverage block    (the cases tb_soc/tb_core covered separately)
  = firmware/ci_prog.s -> firmware/ci_prog.hex

WHAT THE APPENDED BLOCK ADDS, AND WHY

  * Load from IMEM. This is the timing case the datapath was specifically
    designed around (ARCH_SPEC 7.4): IMEM is combinational and has no output
    register, so a load whose address resolves into IMEM only works because
    oe_o and the address mux stay asserted through WRITEBACK. tb_soc covered
    it end to end; nothing in tb_firmware_prog does, so without this the
    migration would quietly lose the one test that exercises the reason that
    scoping exists.
  * A dependent-register loop. Back-to-back instructions where each reads what
    the previous one wrote, demonstrating the hazard-free-by-construction
    property (5.1) over many instructions rather than in isolation.

The block is spliced in BEFORE the final `ecall`, never appended after it, so
every address the upstream generator already computed - the signature base, the
JALR link address, the AUIPC expectation - is untouched and its expected-value
header stays valid. It uses only x21-x27, which the upstream program leaves
completely unused.

Usage: python gen_ci_firmware.py [--check]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FW = os.path.join(ROOT, "firmware")

SRC_S = os.path.join(FW, "tb_firmware_prog.s")

# Where this program sits in the ChipInventor ROM.
#
# Word 0 of that ROM is reserved for the official validation firmware, which is
# position-DEPENDENT (it derives its .bss base from the PC via auipc, so moving
# it would move that computed address off DMEM_BASE). This program is placed
# above it, clear of the official image's 259 words, on a round boundary.
#
# This program is position-INDEPENDENT - every control transfer is PC-relative
# and its DMEM addresses are absolute via lui/addi - so relocating it does not
# change a single instruction word. `--check` proves that rather than assuming
# it. What DOES move is the two absolute addresses the testbench expects, so
# they are relocated here in one place.
SUPP_BASE = 0x0040_0800
IMEM_BASE = 0x0040_0000
RELOC = SUPP_BASE - IMEM_BASE

# Expected-value constants carried over from the upstream header that hold an
# absolute IMEM address and therefore have to move with the program.
RELOCATABLE = ("EXP_JALR_LINK", "EXP_AUIPC")
OUT_S = os.path.join(FW, "ci_prog.s")
OUT_HEX = os.path.join(FW, "ci_prog.hex")
OUT_LST = os.path.join(FW, "ci_prog.lst")
OUT_VH = os.path.join(FW, "ci_prog_expected.vh")

# Registers used below are x21-x27, verified unused by the upstream program.
EXTRA = """
    # ========================================================================
    # Appended by chipinventor/scripts/gen_ci_firmware.py - the coverage that
    # lived in tb_soc/tb_core, which cannot be separate programs here because
    # the platform's IMEM is a fixed ROM. Uses only x21-x27.
    # ========================================================================

    # ---- Load from IMEM: the ARCH_SPEC 7.4 timing case ----
    # IMEM is combinational with no output register, so this load only returns
    # the real constant if oe_o and the address mux stay asserted through
    # WRITEBACK. If that scoping regresses, x22 reads back 0 instead.
imem_load_site:
    auipc x21, 0                  # x21 = address of this instruction
    lw    x22, 12(x21)            # the .word sits exactly 12 bytes ahead
    j     imem_const_skip
    .word 0xCAFEBABE              # the constant being loaded out of IMEM
imem_const_skip:
    addi  x23, x0, 1              # reached only if control flow survived it

    # ---- Dependent-register loop: hazard-free by construction (5.1) ----
    # Every add reads the register the immediately preceding add wrote.
    addi  x24, x0, 0              # accumulator
    addi  x25, x0, 1              # counter
    addi  x26, x0, 6              # bound (exclusive)
dep_loop:
    add   x24, x24, x25           # sum += counter
    addi  x25, x25, 1             # counter++
    blt   x25, x26, dep_loop      # loop while counter < 6  -> sum = 15
    addi  x27, x0, 1              # proves the loop exited normally

"""

# What the appended block must produce, checked by the testbench.
EXTRA_EXPECT = """
// ---- Expectations for the block gen_ci_firmware.py appends ----
localparam [31:0] EXP_IMEM_LOAD = 32'hCAFEBABE; // x22: load resolved into IMEM
localparam [31:0] EXP_DEP_SUM   = 32'd15;       // x24: 1+2+3+4+5
localparam [31:0] EXP_DEP_CTR   = 32'd6;        // x25: loop counter on exit
"""


def relocate_header(text):
    """Shift the absolute-address expectations to match SUPP_BASE.

    Rewritten by name and value rather than by literal string, so this keeps
    working if the upstream generator ever re-emits different addresses.
    """
    seen = []

    def sub(m):
        name, val = m.group(1), int(m.group(2), 16)
        seen.append(name)
        return "%s32'h%08X;" % (m.group(0)[: m.group(0).index("32'h")],
                                (val + RELOC) & 0xFFFFFFFF)

    pattern = re.compile(
        r"localparam\s*\[31:0\]\s*(%s)\s*=\s*32'h([0-9A-Fa-f]{8})\s*;"
        % "|".join(RELOCATABLE)
    )
    out = pattern.sub(sub, text)
    missing = [n for n in RELOCATABLE if n not in seen]
    if missing:
        sys.exit(
            "FAIL upstream header no longer defines %s - it cannot be relocated,\n"
            "     and leaving it un-relocated would silently mis-check the run."
            % ", ".join(missing)
        )
    return out


def assemble_to(src_path, hex_path, base, listing=None, quiet=False):
    cmd = [sys.executable, os.path.join(HERE, "asm.py"), src_path,
           "-o", hex_path, "--base", "0x%08X" % base]
    if listing:
        cmd += ["--listing", listing]
    out = subprocess.DEVNULL if quiet else None
    if subprocess.call(cmd, stdout=out) != 0:
        sys.exit("assembly failed")


def assert_position_independent(src_path):
    """The whole two-program ROM layout rests on this being true."""
    with tempfile.TemporaryDirectory() as td:
        a = os.path.join(td, "at_imem_base.hex")
        b = os.path.join(td, "at_supp_base.hex")
        assemble_to(src_path, a, IMEM_BASE, quiet=True)
        assemble_to(src_path, b, SUPP_BASE, quiet=True)
        with open(a) as fa, open(b) as fb:
            wa, wb = fa.read().split(), fb.read().split()
    if wa != wb:
        for i, (x, y) in enumerate(zip(wa, wb)):
            if x != y:
                sys.exit(
                    "FAIL ci_prog.s is position-DEPENDENT: word %d is %s at "
                    "0x%08X but %s at 0x%08X.\n"
                    "     Something in it references a label absolutely. The "
                    "two-program ROM layout is not safe until that is fixed."
                    % (i, x, IMEM_BASE, y, SUPP_BASE)
                )
        sys.exit("FAIL ci_prog.s assembles to different lengths at the two bases")
    return len(wa)


def splice(lines):
    """Insert EXTRA immediately before the final `ecall` line."""
    idx = None
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].split("#")[0].strip()
        if stripped == "ecall":
            idx = i
            break
    if idx is None:
        sys.exit("could not find the final `ecall` in %s - refusing to guess" % SRC_S)
    return lines[:idx] + [EXTRA] + lines[idx:]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the existing image instead of rebuilding it")
    args = ap.parse_args()

    with open(SRC_S) as fh:
        lines = fh.readlines()

    merged = splice(lines)
    text = ("# GENERATED by chipinventor/scripts/gen_ci_firmware.py - do not hand-edit.\n"
            "# Source: firmware/tb_firmware_prog.s plus an appended coverage block.\n"
            + "".join(merged))

    if args.check:
        if not os.path.exists(OUT_S):
            sys.exit("FAIL: %s does not exist - run without --check first" % OUT_S)
        with open(OUT_S) as fh:
            if fh.read() != text:
                sys.exit("FAIL: %s is stale - re-run gen_ci_firmware.py" % OUT_S)
        nwords = assert_position_independent(OUT_S)
        print("OK   ci_prog.s matches tb_firmware_prog.s + the coverage block")
        print("OK   position-independent: %d words identical at 0x%08X and 0x%08X"
              % (nwords, IMEM_BASE, SUPP_BASE))
        return

    with open(OUT_S, "w") as fh:
        fh.write(text)

    assert_position_independent(OUT_S)
    assemble_to(OUT_S, OUT_HEX, SUPP_BASE, OUT_LST)

    with open(OUT_HEX) as fh:
        nwords = sum(1 for line in fh if line.strip())

    # Carry the upstream expected-value header through, relocating the two
    # constants that hold an absolute IMEM address. Everything else in it is a
    # register value or a DMEM offset and is unaffected by where the program
    # sits.
    with open(os.path.join(FW, "tb_firmware_expected.vh")) as fh:
        head = fh.read()
    head = head.replace("localparam IMEM_WORDS_NEEDED = 471;",
                        "localparam IMEM_WORDS_NEEDED = %d;" % nwords)
    head = relocate_header(head)
    with open(OUT_VH, "w") as fh:
        fh.write("// GENERATED by chipinventor/scripts/gen_ci_firmware.py - do not hand-edit.\n")
        fh.write("// This program is placed at 0x%08X in the ChipInventor ROM; word 0\n"
                 "// belongs to the official validation firmware. EXP_JALR_LINK and\n"
                 "// EXP_AUIPC below are relocated by +0x%X accordingly.\n"
                 % (SUPP_BASE, RELOC))
        fh.write("localparam [31:0] SUPP_BASE = 32'h%08X;\n" % SUPP_BASE)
        fh.write(head)
        fh.write(EXTRA_EXPECT)

    print("wrote %s (%d words @ 0x%08X) and %s"
          % (OUT_HEX, nwords, SUPP_BASE, OUT_VH))


if __name__ == "__main__":
    main()
