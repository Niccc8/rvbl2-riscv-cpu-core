#!/usr/bin/env python3
"""Cross-check scripts/asm.py against the GNU assembler, word for word.

asm.py is this repository's own purpose-built assembler; every hex image the
testbenches run comes from it. This assembles each program a second time with
GNU as (xPack riscv-none-elf-gcc 13.2.0, the same GCC release as the
organisers' riscv32-unknown-elf-gcc 13.2.0) and requires the two images to be
identical. For the official validation firmware it also requires both to equal
the organisers' own hex.

The source rewrites are mechanical, and each maps an asm.py notation onto the
GNU notation for the same encoding:
  * crcb/crch/crcw (Xicrc, not known to GNU as) become .insn r with the
    encoding the official firmware fixes: opcode 0x33, funct7 0x40,
    funct3 0/1/2.
  * la rd, CONST becomes li rd, CONST. In asm.py, la loads an absolute
    constant; GNU's la would emit an auipc-relative pair for the same value.
    la of a label is left alone: that is GNU's own auipc/addi form, which the
    official firmware uses and asm.py does not support.
  * "auipc rd, 0" + "addi rd, rd, %pcrel(L)" becomes GNU's
    %pcrel_hi(L)/%pcrel_lo pair. asm.py requires the auipc immediate to be 0,
    so the words agree whenever asm.py accepts the pair (|offset| < 2 KiB).
  * A bare label as an addi immediate (asm.py: its offset from IMEM base)
    becomes %lo(L): the same 12 bits, because IMEM_BASE has zero low bits.
  * A bare "fence" becomes the all-zero-field FENCE asm.py emits
    (0x0000000F). GNU writes "fence" as "fence iorw,iorw" (0x0FF0000F), and
    so does GCC. Both are FENCE: the core decodes it on the opcode alone
    (control_unit.v, "NOP regardless of fm/pred/succ fields"), so the choice
    only matters for this word-for-word comparison.
The link lays memory out as the official firmware does: .text then .rodata in
IMEM from IMEM_BASE, and .data/.bss in DMEM from DMEM_BASE.
'//' comments are removed first (GNU as for RISC-V treats only '#' as one).

Usage: python scripts/xcheck_gnu_as.py [--gcc-bin DIR]
Exit status is non-zero on any mismatch or if the toolchain is missing.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import asm  # noqa: E402

DEFAULT_BIN = os.path.join(os.path.expanduser("~"), "tools",
                           "xpack-riscv-none-elf-gcc-13.2.0-2", "bin")
PREFIX = "riscv-none-elf-"
IMEM_BASE = 0x00400000
DMEM_BASE = 0x10010000

# (source, reference hex or None). The reference is an independent image that
# GNU as must reproduce; None means compare the two assemblers only. The
# official firmware uses la on labels, which asm.py does not support, so it is
# checked against the organisers' hex only (asm.py never assembles it).
PROGRAMS = [
    ("chipinventor/firmware/validation_firmware.s", "chipinventor/firmware/validation_firmware.hex"),
    ("chipinventor/firmware/ci_prog.s", None),
    ("tests/progs/tb_core_prog.s", None),
    ("tests/progs/tb_soc_prog.s", None),
    ("tests/progs/tb_firmware_prog.s", None),
    ("tests/progs/stage3/gpio_listing.s", None),
    ("tests/progs/stage3/gpio_fixed.s", None),
    ("tests/progs/stage3/echo_listing.s", None),
    ("tests/progs/stage3/echo_fixed.s", None),
    ("tests/progs/stage3/periph_regress.s", None),
]

CRC_F3 = {"crcb": 0, "crch": 1, "crcw": 2}


def to_gnu(lines):
    out = [".option norvc", ".text", ".globl _start", "_start:"]
    src = asm._preprocess(lines)
    labels = set(re.findall(r"^\s*([A-Za-z_]\w*):", "\n".join(src), flags=re.M))
    src = [l for l in src if l.strip()]
    n_auipc = 0
    for i, line in enumerate(src):
        nxt = re.search(r"%pcrel\((\w+)\)", src[i + 1]) if i + 1 < len(src) else None
        m = re.match(r"^(\s*(?:\w+:\s*)?)auipc(\s+\w+\s*,\s*)0\s*$", line)
        if m and nxt:
            n_auipc += 1
            line = ".Lxa%d: %sauipc%s%%pcrel_hi(%s)" % (n_auipc, m.group(1), m.group(2), nxt.group(1))
        line = re.sub(r"%pcrel\(\w+\)", "%%pcrel_lo(.Lxa%d)" % n_auipc, line)
        m = re.match(r"^(\s*(?:\w+:\s*)?addi\s+\w+\s*,\s*\w+\s*,\s*)([A-Za-z_]\w*)\s*$", line)
        if m and m.group(2) in labels:
            line = "%s%%lo(%s)" % (m.group(1), m.group(2))
        m = re.match(r"^(\s*(?:\w+:\s*)?)(crc[bhw])\s+(\S+?)\s*,\s*(\S+?)\s*,\s*(\S+)\s*$", line)
        if m:
            lead, op, rd, rs1, rs2 = m.groups()
            line = "%s.insn r 0x33, %d, 0x40, %s, %s, %s" % (lead, CRC_F3[op], rd, rs1, rs2)
        m = re.match(r"^(\s*(?:\w+:\s*)?)la(\s+\w+\s*,\s*)(\S+)\s*$", line)
        if m and m.group(3) not in labels and not re.match(r"^\d+[bf]$", m.group(3)):
            line = "%sli%s%s" % m.groups()
        line = re.sub(r"^(\s*(?:\w+:\s*)?)fence\s*$", r"\1.insn i 0x0f, 0, x0, x0, 0", line)
        out.append(line)
    return "\n".join(out) + "\n"


def gnu_words(src_path, bindir, work):
    base = os.path.join(work, os.path.basename(src_path))
    with open(src_path, encoding="utf-8") as fh:
        text = to_gnu(fh.readlines())
    with open(base + ".S", "w", encoding="utf-8") as fh:
        fh.write(text)
    tool = lambda t: os.path.join(bindir, PREFIX + t)
    subprocess.run([tool("as"), "-march=rv32i_zmmul", "-mabi=ilp32", "-mno-relax",
                    "-o", base + ".o", base + ".S"], check=True, capture_output=True, text=True)
    subprocess.run([tool("ld"), "-m", "elf32lriscv", "-Ttext=0x%08x" % IMEM_BASE,
                    "-Tdata=0x%08x" % DMEM_BASE, "-Tbss=0x%08x" % DMEM_BASE, "-e", "_start",
                    "-o", base + ".elf", base + ".o"], check=True, capture_output=True, text=True)
    subprocess.run([tool("objcopy"), "-O", "binary", "-j", ".text", "-j", ".rodata",
                    base + ".elf", base + ".bin"],
                   check=True, capture_output=True, text=True)
    data = open(base + ".bin", "rb").read()
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


def ours_words(src_path):
    with open(src_path, encoding="utf-8") as fh:
        mem, _ = asm.assemble(fh.readlines())
    return mem


def read_hex(path):
    with open(path, encoding="utf-8") as fh:
        return [int(t, 16) for t in fh.read().split() if not t.startswith("//")]


def trim(words):
    # asm.py pads gaps (.org) with zeros up to the last word; GNU emits the
    # same zeros, so only trailing zero words can legitimately differ.
    w = list(words)
    while w and w[-1] == 0:
        w.pop()
    return w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gcc-bin", default=os.environ.get("RISCV_GCC_BIN", DEFAULT_BIN))
    args = ap.parse_args()
    if not os.path.exists(os.path.join(args.gcc_bin, PREFIX + "as" + (".exe" if os.name == "nt" else ""))):
        print("FAIL GNU toolchain not found in %s (set RISCV_GCC_BIN)" % args.gcc_bin)
        return 1

    passed = failed = 0
    work = tempfile.mkdtemp(prefix="xcheck_")
    try:
        for src, ref in PROGRAMS:
            path = os.path.join(ROOT, src)
            try:
                g = trim(gnu_words(path, args.gcc_bin, work))
            except subprocess.CalledProcessError as e:
                failed += 1
                print("FAIL %s: GNU as rejected it\n%s" % (src, e.stderr.strip()))
                continue
            pairs = []
            if ref:
                pairs.append(("official hex", trim(read_hex(os.path.join(ROOT, ref)))))
            else:
                pairs.append(("asm.py", trim(ours_words(path))))
            for name, words in pairs:
                if words == g:
                    passed += 1
                    print("OK   %-45s %-12s = GNU as  (%d words)" % (src, name, len(g)))
                else:
                    failed += 1
                    n = min(len(words), len(g))
                    first = next((i for i in range(n) if words[i] != g[i]), n)
                    print("FAIL %-45s %-12s != GNU as: lengths %d/%d, first difference at word %d"
                          % (src, name, len(words), len(g), first))
                    if first < n:
                        print("       word %d: %s %08x, GNU %08x" % (first, name, words[first], g[first]))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print("==== xcheck_gnu_as: %d passed, %d failed ====" % (passed, failed))
    print("XCHECK_GNU_AS: ALL TESTS PASSED" if failed == 0 else "XCHECK_GNU_AS: FAILURES PRESENT")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
