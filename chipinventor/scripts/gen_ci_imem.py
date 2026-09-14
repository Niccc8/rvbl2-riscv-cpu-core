#!/usr/bin/env python3
"""Generate the ChipInventor imem block from the firmware images.

The platform has no filesystem, so $readmemh cannot load a ROM image there.
This emits the ROM as an explicit `case` on the word index, which the
platform's synthesiser resolves at elaboration with no external dependency.

TWO PROGRAMS, ONE ROM
---------------------
The ROM holds two images at fixed word offsets:

    word   0..258   official validation firmware  (0x00400000..0x00400408)
    word 259..511   gap, reads back 32'h0, never fetched
    word 512..      this project's supplementary coverage program (0x00400800)

The official firmware has to sit at exactly 0x00400000 because it is
position-dependent: it derives its .bss base from the PC (auipc s0, 0xfc10 at
0x0040011C yields 0x10010000), so relocating it would move every store off
DMEM_BASE. The supplementary program is position-independent, which
gen_ci_firmware.py proves by assembling it at both bases and requiring
byte-identical output, so it is the one that moves.

Keeping both in one ROM is what lets a single testbench run the official
validation firmware for its x4 verdict AND keep the coverage that firmware
does not reach - FENCE, ECALL, EBREAK, illegal instructions, misaligned
access, and the 58 DMEM signatures.

For the OpenLane / P&R run, do not synthesise this block at all: paste
blocks/imem_mock.v instead, which is what the firmware repository's own README
recommends ("you do not need to synthesize the complete firmware ... a large
case block can generate unnecessary cells").

Why case on the word index rather than the full byte address (which is what
the platform's own example project does): address_decoder already range-checks
the 4MB IMEM window, so matching the full 32-bit address here would duplicate
that check in a second place that could drift out of step with it. Indexing by
word also gives the synthesiser a 20-bit comparison instead of a 32-bit one.

The `default: 32'b0` leg is exactly the old impl_sel behaviour: an address
inside the architectural window but past the end of the image reads back zero
rather than aliasing into a real word. The gap between the two programs falls
to the same leg.

Usage:
    python gen_ci_imem.py [--out BLOCK.v] [--check]

--check re-reads the generated block and confirms every word matches the
images, so a corrupted generation cannot pass silently.
"""

import argparse
import os
import re
import sys

from gen_ci_firmware import IMEM_BASE, SUPP_BASE

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_OUT = os.path.join(ROOT, "blocks", "imem.v")

# A flat $readmemh image of the same ROM, gap included, for the equivalence
# check. rtl_ref/imem.v loads its ROM from a file, so the reference design can
# only be run against the same program as the mirror if that program exists as
# a file - this is it. Emitted into build/ because it is a derived artifact of
# the block above, not an input to it.
FLAT_IMAGE = os.path.join(ROOT, "build", "rom_image.hex")

# (label, hex image, word offset in the ROM)
SEGMENTS = [
    ("official validation firmware",
     os.path.join(ROOT, "firmware", "validation_firmware.hex"), 0),
    ("supplementary coverage program",
     os.path.join(ROOT, "firmware", "ci_prog.hex"),
     (SUPP_BASE - IMEM_BASE) // 4),
]

HEADER = '''// ============================================================================
// imem.v - Instruction/constant ROM. Combinational read: "Upon receiving the
// memory address to be accessed and a read signal (output enable), the 32-bit
// instruction that was in that position is received by the kernel" (Block
// Guide S4.2 - no cycle-latency language, unlike DMEM's S4.3).
//
// GENERATED FILE - do not hand-edit. Produced by
// chipinventor/scripts/gen_ci_imem.py from:
{maptable}//
// The official firmware MUST stay at word 0: it is position-dependent, and
// derives its .bss base from the PC (auipc s0, 0xfc10 at 0x0040011C gives
// 0x10010000, which is DMEM_BASE). The supplementary program is
// position-independent and is placed above it.
//
// The *architectural* window is the full 4MB at 0x00400000 (Table 13), which
// address_decoder range-checks against. The ROM below covers only the words
// the images actually occupy; any address inside the 4MB window but past or
// between them falls to the `default` leg and reads back 0 rather than
// aliasing into a real word. That is the same guarantee the file-driven
// version's impl_sel comparison gave.
//
// WHY A CASE AND NOT $readmemh
// ----------------------------
// The platform has no filesystem to read a hex image from, so the image is
// unrolled into the source here. Everything else about this block - the oe_i
// gating, the zero-on-deselect, the word indexing - is unchanged, so the
// address_decoder contract this sits behind is identical either way.
//
// FOR THE OPENLANE / P&R RUN, PASTE blocks/imem_mock.v INSTEAD.
// ============================================================================
module imem (
    input  wire [31:0] address_i,    // full byte address (already imem_sel-gated by decoder)
    input  wire        oe_i,
    output reg  [31:0] data_o
);
    // Word index within the 4MB architectural window (22-bit byte address ->
    // 20-bit word index), exactly as the file-driven version computed it.
    wire [19:0] word_addr = address_i[21:2];

    always @(*) begin
        if (!oe_i) data_o = 32'b0;
        else begin
            case (word_addr)
'''

FOOTER = '''                default: data_o = 32'b0;
            endcase
        end
    end
endmodule
'''


def read_hex(path):
    """Read a $readmemh-style image: one 32-bit word per line, // comments ok."""
    if not os.path.exists(path):
        sys.exit("%s does not exist - generate it first" % path)
    words = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("//")[0].strip()
            if not line:
                continue
            for tok in line.split():
                try:
                    words.append(int(tok, 16) & 0xFFFFFFFF)
                except ValueError:
                    sys.exit("%s:%d: not a hex word: %r" % (path, lineno, tok))
    return words


def load_segments():
    """Read every image and place it, refusing any overlap."""
    rom = {}
    owner = {}
    placed = []
    for label, path, offset in SEGMENTS:
        words = read_hex(path)
        if not words:
            sys.exit("%s contains no words - refusing to emit an empty segment" % path)
        for i, word in enumerate(words):
            idx = offset + i
            if idx in rom:
                sys.exit(
                    "FAIL segment overlap at word %d (0x%08X): '%s' collides with '%s'"
                    % (idx, IMEM_BASE + 4 * idx, label, owner[idx])
                )
            rom[idx] = word
            owner[idx] = label
        placed.append((label, os.path.basename(path), offset, len(words)))
    return rom, placed


def map_table(placed):
    rows = []
    for label, name, offset, count in placed:
        rows.append(
            "//   word %4d..%-4d  0x%08X..0x%08X  %s (%d words)\n"
            % (offset, offset + count - 1,
               IMEM_BASE + 4 * offset, IMEM_BASE + 4 * (offset + count - 1),
               name, count)
        )
        rows.append("//                                          %s\n" % label)
    return "".join(rows)


def render(rom, placed):
    out = [HEADER.format(maptable=map_table(placed))]
    prev = None
    for idx in sorted(rom):
        if prev is not None and idx != prev + 1:
            out.append(
                "                // ---- gap: words %d..%d read back 32'h0 ----\n"
                % (prev + 1, idx - 1)
            )
        out.append("                20'd%-6d: data_o = 32'h%08x;\n" % (idx, rom[idx]))
        prev = idx
    out.append(FOOTER)
    return "".join(out)


def flat_length(rom):
    return max(rom) + 1


def write_flat_image(rom):
    """Emit the same ROM as a dense $readmemh image, gap zero-filled."""
    d = os.path.dirname(FLAT_IMAGE)
    if not os.path.isdir(d):
        os.makedirs(d)
    with open(FLAT_IMAGE, "w", newline="\n") as fh:
        for idx in range(flat_length(rom)):
            fh.write("%08x\n" % rom.get(idx, 0))


def check(block_path, rom):
    """Re-read the emitted block and confirm it encodes exactly `rom`."""
    if not os.path.exists(block_path):
        return "%s does not exist" % block_path
    with open(block_path) as fh:
        text = fh.read()
    found = dict(
        (int(i), int(v, 16))
        for i, v in re.findall(r"20'd(\d+)\s*:\s*data_o = 32'h([0-9a-fA-F]{8});", text)
    )
    if len(found) != len(rom):
        return "block has %d ROM entries, images have %d words" % (len(found), len(rom))
    for idx in sorted(rom):
        if idx not in found:
            return "word %d (0x%08X) missing from block" % (idx, IMEM_BASE + 4 * idx)
        if found[idx] != rom[idx]:
            return "word %d (0x%08X): block has %08x, image has %08x" % (
                idx, IMEM_BASE + 4 * idx, found[idx], rom[idx])
    if "default: data_o = 32'b0;" not in text:
        return "block is missing the out-of-range default leg"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--check", action="store_true",
                    help="verify the existing block against the images instead of writing")
    args = ap.parse_args()

    rom, placed = load_segments()
    summary = ", ".join("%s @ word %d (%d)" % (n, o, c) for _, n, o, c in placed)

    if args.check:
        problem = check(args.out, rom)
        if problem:
            sys.exit("FAIL %s: %s" % (os.path.basename(args.out), problem))
        # The flat image feeds the equivalence check, so it has to be current
        # too - a stale one would run the reference on a different program and
        # the divergence would look like a design bug.
        write_flat_image(rom)
        print("OK   %s: %d words - %s"
              % (os.path.basename(args.out), len(rom), summary))
        return

    with open(args.out, "w", newline="\n") as fh:
        fh.write(render(rom, placed))

    problem = check(args.out, rom)
    if problem:
        sys.exit("FAIL: generated block does not round-trip: %s" % problem)
    print("wrote %s: %d words - %s" % (args.out, len(rom), summary))

    write_flat_image(rom)
    print("wrote %s: %d words (flat image for the equivalence check)"
          % (FLAT_IMAGE, flat_length(rom)))


if __name__ == "__main__":
    main()
