#!/usr/bin/env python3
"""Assemble every Stage 3 test program into build/stage3/.

tests/progs/stage3/*.s -> build/stage3/<name>.hex (+ .lst)

The images are build products, regenerated on every run, so they can never go
stale. Each .hex is padded with zero words to the testbench ROM depth, so
$readmemh fills the whole array and the simulation log stays warning-free.
"""

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from asm import assemble  # noqa: E402

SRC = os.path.join(ROOT, "tests", "progs", "stage3")
OUT = os.path.join(ROOT, "build", "stage3")
ROM_WORDS = 512  # tb_periph_soc.v instantiates top with IMEM_WORDS = 512


def main():
    os.makedirs(OUT, exist_ok=True)
    sources = sorted(glob.glob(os.path.join(SRC, "*.s")))
    if not sources:
        sys.exit("no Stage 3 programs in %s" % SRC)
    for src in sources:
        name = os.path.splitext(os.path.basename(src))[0]
        with open(src) as fh:
            mem, labels = assemble(fh.readlines())
        if len(mem) > ROM_WORDS:
            sys.exit("%s: %d words exceed the %d-word test ROM" % (name, len(mem), ROM_WORDS))
        with open(os.path.join(OUT, name + ".hex"), "w") as fh:
            for w in mem + [0] * (ROM_WORDS - len(mem)):
                fh.write("%08x\n" % w)
        with open(os.path.join(OUT, name + ".lst"), "w") as fh:
            for i, w in enumerate(mem):
                fh.write("%08x: %08x\n" % (0x00400000 + 4 * i, w))
            fh.write("\nLabels:\n")
            for lbl, a in labels.items():
                fh.write("  %s: %08x\n" % (lbl, 0x00400000 + a))
        print("assembled %-16s %4d words" % (name, len(mem)))


if __name__ == "__main__":
    main()
