#!/usr/bin/env python3
"""Assemble the Stage 3 peripheral programs for the ChipInventor ROM.

    firmware/stage3/<name>.s  ->  firmware/stage3/<name>.hex  (+ .lst)

Each program gets its own fixed slot above the two Phase 2 images, so one ROM
can hold every program the testbench runs; SUITE 4 enters each one by pointing
the PC at its base while the core is held in reset, exactly as SUITE 2B enters
the supplementary program.

    0x00401000  gpio_listing     Block Guide GPIO example, verbatim
    0x00401100  gpio_fixed       the same, completed so P1 really follows P0
    0x00401200  echo_listing     Block Guide UART echo example, verbatim
    0x00401300  echo_fixed       the same, completed so it really echoes
    0x00401400  periph_regress   24 self-checking register-semantics checks

Relocating a program is only safe if it is position-independent, so every
program is assembled at IMEM_BASE and at its slot and the two images must be
word-for-word identical (the same proof gen_ci_firmware.py makes for the
supplementary program). The sources are copies of tests/progs/stage3/*.s; the
repository-root flow (scripts/run_all.sh) fails if the two sets ever differ.

Usage: python gen_ci_stage3.py [--check]
    --check  re-assemble and fail if any committed .hex is stale
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(ROOT, "firmware", "stage3")

sys.path.insert(0, HERE)
from asm import assemble  # noqa: E402
from gen_ci_firmware import IMEM_BASE  # noqa: E402

# (name, base address). Order is ROM order; each slot is 64 words except the
# last, which runs to the end of the image.
PROGRAMS = [
    ("gpio_listing",   0x00401000),
    ("gpio_fixed",     0x00401100),
    ("echo_listing",   0x00401200),
    ("echo_fixed",     0x00401300),
    ("periph_regress", 0x00401400),
]
SLOT_WORDS = 64


def build(name, base):
    """Return the program's words, proven position-independent."""
    with open(os.path.join(SRC_DIR, name + ".s")) as fh:
        lines = fh.readlines()
    at_base, labels = assemble(lines, base)
    at_zero, _ = assemble(lines, IMEM_BASE)
    if at_base != at_zero:
        first = next(i for i, (a, b) in enumerate(zip(at_base, at_zero)) if a != b)
        sys.exit("FAIL %s is position-dependent: word %d differs between 0x%08X and 0x%08X"
                 % (name, first, IMEM_BASE, base))
    return at_base, labels


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    stale = []
    for i, (name, base) in enumerate(PROGRAMS):
        words, labels = build(name, base)
        last = i == len(PROGRAMS) - 1
        if not last and len(words) > SLOT_WORDS:
            sys.exit("FAIL %s is %d words; its slot holds %d" % (name, len(words), SLOT_WORDS))
        hex_text = "".join("%08x\n" % w for w in words)
        hex_path = os.path.join(SRC_DIR, name + ".hex")
        if args.check:
            try:
                with open(hex_path) as fh:
                    if fh.read() != hex_text:
                        stale.append(name)
            except IOError:
                stale.append(name)
            continue
        with open(hex_path, "w", newline="\n") as fh:
            fh.write(hex_text)
        with open(os.path.join(SRC_DIR, name + ".lst"), "w", newline="\n") as fh:
            for j, w in enumerate(words):
                fh.write("%08x: %08x\n" % (base + 4 * j, w))
            fh.write("\nLabels:\n")
            for lbl, addr in labels.items():
                fh.write("  %s: %08x\n" % (lbl, addr))
        print("wrote %-15s @ 0x%08X  %3d words" % (name, base, len(words)))

    if args.check:
        if stale:
            sys.exit("FAIL stale Stage 3 image(s): %s - run gen_ci_stage3.py" % ", ".join(stale))
        print("OK   %d Stage 3 programs current and position-independent" % len(PROGRAMS))


if __name__ == "__main__":
    main()
