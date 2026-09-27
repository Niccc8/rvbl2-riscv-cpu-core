#!/usr/bin/env python3
"""Check a firmware image built by the organisers' Firmware Builder flow.

    python check_image.py out/lane --tc riscv64-unknown-elf [--imem-words 4096]

Reads what the builder wrote into out/<app>/ (the object files, firmware.elf
and firmware.bin) and enforces two gates; either failing is a non-zero exit:

  ISA   every instruction in the program is one the RVBL-2 core executes:
        RV32I, Zmmul (mul, mulh, mulhsu, mulhu) or Xicrc (opcode 0x33, funct7
        0x40, funct3 0-2). No compressed, CSR, divide or atomic instruction.
  SIZE  code + constants + .data's initial values fit in IMEM; the data leave
        at least --min-stack bytes of DMEM for the stack.

The ISA gate disassembles the object files' code sections: the image links
nothing else (-nostdlib), and the organisers' linker script puts constant
tables in the same output section as the code, where a disassembler would
misread them as instructions.

and writes out/<app>/firmware.hex: one 32-bit word per line, IMEM word 0
first, for the RTL testbenches ($readmemh).
"""
import argparse
import glob
import os
import re
import subprocess
import sys

RV32I = {"lui", "auipc", "jal", "jalr", "beq", "bne", "blt", "bge", "bltu", "bgeu",
         "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw", "addi", "slti", "sltiu",
         "xori", "ori", "andi", "slli", "srli", "srai", "add", "sub", "sll", "slt",
         "sltu", "xor", "srl", "sra", "or", "and", "fence", "ecall", "ebreak"}
ZMMUL = {"mul", "mulh", "mulhsu", "mulhu"}
DMEM_BASE, DMEM_BYTES = 0x10010000, 8192


def is_xicrc(word):
    return (word & 0x7F) == 0x33 and (word >> 25) == 0x40 and ((word >> 12) & 7) in (0, 1, 2)


def tool(tc, name, *args):
    r = subprocess.run(["%s-%s" % (tc, name)] + list(args), capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", help="the builder's output directory, e.g. out/lane")
    ap.add_argument("--tc", default="riscv64-unknown-elf", help="toolchain prefix, as the Makefile's TC")
    ap.add_argument("--imem-words", type=int, default=4096)
    ap.add_argument("--min-stack", type=int, default=1024)
    a = ap.parse_args()
    data = open(os.path.join(a.out, "firmware.bin"), "rb").read()

    n, bad = 0, []
    for obj in sorted(glob.glob(os.path.join(a.out, "*.o"))):
        for line in tool(a.tc, "objdump", "-d", "-M", "no-aliases", obj).splitlines():
            m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)", line)
            if not m:
                if re.match(r"^\s*[0-9a-f]+:\s+[0-9a-f]{4}\s", line):
                    bad.append(line.strip() + "   <- 16-bit (compressed) instruction")
                continue
            word, mnem = int(m.group(2), 16), m.group(3)
            n += 1
            if mnem in RV32I or mnem in ZMMUL or is_xicrc(word):
                continue
            bad.append("%s: %s" % (os.path.basename(obj), line.strip()))

    data += bytes(-len(data) % 4)
    words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    with open(os.path.join(a.out, "firmware.hex"), "w", encoding="ascii", newline=chr(10)) as fh:
        fh.write("".join("%08x" % w + chr(10) for w in words))

    # static DMEM use: the end of the last DMEM section below the stack
    top = DMEM_BASE
    for m in re.finditer(r"^\s*\d+\s+\.(data|bss|noinit)\s+([0-9a-f]+)\s+([0-9a-f]+)",
                         tool(a.tc, "objdump", "-h", os.path.join(a.out, "firmware.elf")), re.M):
        top = max(top, int(m.group(3), 16) + int(m.group(2), 16))

    ok = True
    if bad:
        ok = False
        print("FAIL ISA gate: %d instruction(s) the core does not execute:" % len(bad))
        for b in bad[:20]:
            print("   " + b)
    else:
        print("OK   ISA gate: all %d instructions are RV32I, Zmmul or Xicrc" % n)
    stack = DMEM_BASE + DMEM_BYTES - top
    if len(words) > a.imem_words:
        ok = False
        print("FAIL SIZE gate: image needs %d words, IMEM has %d" % (len(words), a.imem_words))
    elif stack < a.min_stack:
        ok = False
        print("FAIL SIZE gate: only %d bytes of DMEM left for the stack" % stack)
    else:
        print("OK   SIZE gate: %d of %d IMEM words; DMEM %d bytes static, %d left for the stack"
              % (len(words), a.imem_words, top - DMEM_BASE, stack))
    print("wrote %s" % os.path.join(a.out, "firmware.hex"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
