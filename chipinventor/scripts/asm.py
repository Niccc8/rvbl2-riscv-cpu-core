#!/usr/bin/env python3
"""
asm.py - a small, purpose-built assembler for RV32I + Zmmul + Xicrc test
programs used by tb_soc.v / tb_firmware.v.

This exists as test infrastructure (§17 stage 3's "golden reference model"
spirit), independent of the RTL's own decode tables, to reduce the risk of
hand-transcribing 32-bit instruction words by hand for larger programs.
It is deliberately NOT a general RISC-V assembler - only the mnemonics this
project's ISA subset needs are supported.

Usage: python3 asm.py program.s -o program.hex [--listing program.lst]
Output: one 32-bit hex word per line (a $readmemh-compatible IMEM image),
word-addressed starting at IMEM offset 0 (i.e. byte address 0x00400000+4*n).
"""
import sys, re, argparse

REGS = {f"x{i}": i for i in range(32)}
ABI = {
    "zero":0,"ra":1,"sp":2,"gp":3,"tp":4,"t0":5,"t1":6,"t2":7,"s0":8,"fp":8,
    "s1":9,"a0":10,"a1":11,"a2":12,"a3":13,"a4":14,"a5":15,"a6":16,"a7":17,
    "s2":18,"s3":19,"s4":20,"s5":21,"s6":22,"s7":23,"s8":24,"s9":25,"s10":26,
    "s11":27,"t3":28,"t4":29,"t5":30,"t6":31,
}
REGS.update(ABI)

def reg(tok):
    tok = tok.strip().rstrip(',')
    if tok not in REGS:
        raise ValueError(f"unknown register '{tok}'")
    return REGS[tok]

PCREL_RE = re.compile(r'^%pcrel\((\w+)\)$')

def imm_val(tok, labels=None, pc=None, pcrel_pc=None):
    """Resolve an immediate operand.

    `pc` makes a bare label resolve PC-relative (branches/jumps); without it a
    bare label resolves to its absolute offset. `pcrel_pc` enables the
    %pcrel(label) form, which resolves against the `auipc rd, 0` that must sit
    on the immediately preceding word - the standard RISC-V auipc/addi pairing.
    """
    tok = tok.strip().rstrip(',')
    m = PCREL_RE.match(tok)
    if m:
        if labels is None or pcrel_pc is None:
            raise ValueError(f"%pcrel used where no label context is available: '{tok}'")
        if m.group(1) not in labels:
            raise ValueError(f"%pcrel references unknown label '{m.group(1)}'")
        return labels[m.group(1)] - (pcrel_pc - 4)
    if labels is not None and tok in labels:
        return labels[tok] - (pc if pc is not None else 0)
    return int(tok, 0)

def s12(v):
    v &= 0xFFF
    return v

def sext_check(v, bits):
    lo = -(1 << (bits-1)); hi = (1 << (bits-1)) - 1
    if not (lo <= v <= hi):
        raise ValueError(f"immediate {v} out of range for {bits}-bit field")

def r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i_type(opcode, funct3, rd, rs1, imm):
    imm = s12(imm)
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0xFFF
    return (((imm>>5)&0x7F)<<25) | (rs2<<20) | (rs1<<15) | (funct3<<12) | ((imm&0x1F)<<7) | opcode

def b_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0x1FFF
    b12=(imm>>12)&1; b11=(imm>>11)&1; b10_5=(imm>>5)&0x3F; b4_1=(imm>>1)&0xF
    return (b12<<31)|(b10_5<<25)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(b4_1<<8)|(b11<<7)|opcode

def u_type(opcode, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd<<7) | opcode

def j_type(opcode, rd, imm):
    imm &= 0x1FFFFF
    b20=(imm>>20)&1; b19_12=(imm>>12)&0xFF; b11=(imm>>11)&1; b10_1=(imm>>1)&0x3FF
    return (b20<<31)|(b10_1<<21)|(b11<<20)|(b19_12<<12)|(rd<<7)|opcode

OPC = dict(RTYPE=0b0110011, ITYPE=0b0010011, LOAD=0b0000011, STORE=0b0100011,
           BRANCH=0b1100011, JAL=0b1101111, JALR=0b1100111, LUI=0b0110111,
           AUIPC=0b0010111, SYSTEM=0b1110011, FENCE=0b0001111)

R_OPS = { # mnemonic: (funct3, funct7)
    "add":(0,0), "sub":(0,0x20), "sll":(1,0), "slt":(2,0), "sltu":(3,0),
    "xor":(4,0), "srl":(5,0), "sra":(5,0x20), "or":(6,0), "and":(7,0),
    "mul":(0,1), "mulh":(1,1), "mulhsu":(2,1), "mulhu":(3,1),
    "crcb":(0,0x40), "crch":(1,0x40), "crcw":(2,0x40),
}
I_ALU_OPS = {"addi":0,"slti":2,"sltiu":3,"xori":4,"ori":6,"andi":7}
SHIFT_I_OPS = {"slli":(1,0), "srli":(5,0), "srai":(5,0x20)}
LOAD_OPS = {"lb":0,"lh":1,"lw":2,"lbu":4,"lhu":5}
STORE_OPS = {"sb":0,"sh":1,"sw":2}
BRANCH_OPS = {"beq":0,"bne":1,"blt":4,"bge":5,"bltu":6,"bgeu":7}

def parse_mem_operand(tok):
    # forms: "imm(rs1)"
    m = re.match(r'^(-?\w+)\((\w+)\)$', tok.strip().rstrip(','))
    if not m:
        raise ValueError(f"bad memory operand '{tok}'")
    return m.group(1), m.group(2)

def assemble(lines, base=0):
    # pass 1: compute label addresses (word-indexed *4 = byte offset from base)
    #
    # `base` makes labels resolve to absolute byte addresses instead of offsets
    # from the start of the image, which matters once a program is placed
    # somewhere other than the IMEM base - the ChipInventor ROM holds the
    # official validation firmware at 0x00400000 and this project's own
    # supplementary program at 0x00400800.
    #
    # Every control transfer here resolves PC-relative (label - pc), so `base`
    # cancels out of the emitted words; it changes only the reported label
    # values, the listing, and any immediate that references a label
    # absolutely. That last case is exactly what would make a program
    # position-DEPENDENT, so gen_ci_firmware.py --check assembles at two
    # different bases and requires the hex to come out byte-identical rather
    # than assuming position-independence.
    labels = {}
    cleaned = []
    addr = base
    for raw in lines:
        line = raw.split('#')[0].strip()
        if not line:
            continue
        if line.endswith(':'):
            labels[line[:-1]] = addr
            continue
        m = re.match(r'^(\w+):\s*(.*)$', line)
        if m and m.group(1) not in R_OPS and m.group(1) not in I_ALU_OPS:
            # could be "label: instr" on one line
            lbl, rest = m.group(1), m.group(2)
            labels[lbl] = addr
            if rest:
                cleaned.append((addr, rest))
                addr += 4
            continue
        cleaned.append((addr, line))
        addr += 4

    words = []
    for addr, line in cleaned:
        parts = line.replace(',', ' ').split()
        mnem = parts[0].lower()
        args = parts[1:]

        if mnem == "nop":
            words.append((addr, i_type(OPC["ITYPE"],0,0,0,0)))
        elif mnem in R_OPS:
            f3, f7 = R_OPS[mnem]
            rd, rs1, rs2 = reg(args[0]), reg(args[1]), reg(args[2])
            words.append((addr, r_type(OPC["RTYPE"], f3, f7, rd, rs1, rs2)))
        elif mnem in I_ALU_OPS:
            f3 = I_ALU_OPS[mnem]
            rd, rs1 = reg(args[0]), reg(args[1])
            # Bare labels resolve to their raw (non-pc-relative) offset; the
            # %pcrel(label) form resolves against the preceding auipc instead.
            imm = imm_val(args[2], labels, None, addr)
            sext_check(imm, 12)
            words.append((addr, i_type(OPC["ITYPE"], f3, rd, rs1, imm)))
        elif mnem in SHIFT_I_OPS:
            f3, f7 = SHIFT_I_OPS[mnem]
            rd, rs1 = reg(args[0]), reg(args[1])
            shamt = imm_val(args[2]) & 0x1F
            words.append((addr, i_type(OPC["ITYPE"], f3, rd, rs1, (f7<<5)|shamt)))
        elif mnem in LOAD_OPS:
            f3 = LOAD_OPS[mnem]
            rd = reg(args[0])
            imm, rs1 = parse_mem_operand(args[1])
            imm = imm_val(imm); rs1 = reg(rs1)
            sext_check(imm, 12)
            words.append((addr, i_type(OPC["LOAD"], f3, rd, rs1, imm)))
        elif mnem in STORE_OPS:
            f3 = STORE_OPS[mnem]
            rs2 = reg(args[0])
            imm, rs1 = parse_mem_operand(args[1])
            imm = imm_val(imm); rs1 = reg(rs1)
            sext_check(imm, 12)
            words.append((addr, s_type(OPC["STORE"], f3, rs1, rs2, imm)))
        elif mnem in BRANCH_OPS:
            f3 = BRANCH_OPS[mnem]
            rs1, rs2 = reg(args[0]), reg(args[1])
            target = imm_val(args[2], labels, addr)
            sext_check(target, 13)
            words.append((addr, b_type(OPC["BRANCH"], f3, rs1, rs2, target)))
        elif mnem == "jal":
            if len(args) == 1:
                rd = 1
                target = imm_val(args[0], labels, addr)
            else:
                rd = reg(args[0]); target = imm_val(args[1], labels, addr)
            words.append((addr, j_type(OPC["JAL"], rd, target)))
        elif mnem == "j":
            target = imm_val(args[0], labels, addr)
            words.append((addr, j_type(OPC["JAL"], 0, target)))
        elif mnem == "jalr":
            if len(args) == 1: # jalr rs1 -> jalr x1, 0(rs1)
                rd, imm, rs1 = 1, 0, reg(args[0])
            else:
                rd = reg(args[0]); imm, rs1 = parse_mem_operand(args[1]); imm=imm_val(imm); rs1=reg(rs1)
            words.append((addr, i_type(OPC["JALR"], 0, rd, rs1, imm)))
        elif mnem == "lui":
            rd = reg(args[0]); imm = imm_val(args[1])
            words.append((addr, u_type(OPC["LUI"], rd, imm)))
        elif mnem == "auipc":
            rd = reg(args[0]); imm = imm_val(args[1])
            words.append((addr, u_type(OPC["AUIPC"], rd, imm)))
        elif mnem == "li": # pseudo: small-immediate load (fits in 12 bits, addi from x0)
            rd = reg(args[0]); imm = imm_val(args[1])
            if -2048 <= imm <= 2047:
                words.append((addr, i_type(OPC["ITYPE"], 0, rd, 0, imm)))
            else:
                # lui + addi sequence would need 2 words; caller should
                # avoid large li in single-word contexts. Support via caller
                # splitting manually for now.
                raise ValueError(f"li immediate {imm} needs lui+addi (use them explicitly)")
        elif mnem == "mv":
            rd = reg(args[0]); rs1 = reg(args[1])
            words.append((addr, i_type(OPC["ITYPE"], 0, rd, rs1, 0)))
        elif mnem == "ecall":
            words.append((addr, i_type(OPC["SYSTEM"], 0, 0, 0, 0)))
        elif mnem == "ebreak":
            words.append((addr, i_type(OPC["SYSTEM"], 0, 0, 0, 1)))
        elif mnem == "fence":
            words.append((addr, i_type(OPC["FENCE"], 0, 0, 0, 0)))
        elif mnem == ".word":
            words.append((addr, imm_val(args[0]) & 0xFFFFFFFF))
        else:
            raise ValueError(f"unknown mnemonic '{mnem}' at addr {addr}: '{line}'")

    words.sort(key=lambda t: t[0])
    maxaddr = words[-1][0] if words else base
    n = (maxaddr - base)//4 + 1
    mem = [0]*n
    for a, w in words:
        mem[(a - base)//4] = w & 0xFFFFFFFF
    return mem, labels

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--listing")
    ap.add_argument("--base", default="0",
                    help="absolute byte address of the first word (default 0, "
                         "i.e. labels are offsets). Affects labels and the "
                         "listing only - the emitted words are PC-relative.")
    args = ap.parse_args()
    base = int(args.base, 0)
    with open(args.src) as f:
        lines = f.readlines()
    mem, labels = assemble(lines, base)
    with open(args.out, "w") as f:
        for w in mem:
            f.write(f"{w:08x}\n")
    if args.listing:
        origin = base if base else 0x00400000
        with open(args.listing, "w") as f:
            for i, w in enumerate(mem):
                f.write(f"{i*4:08x} (0x{origin:08x}+{i*4:04x}): {w:08x}\n")
            f.write("\nLabels:\n")
            for lbl, a in labels.items():
                f.write(f"  {lbl}: {a:08x}\n")
    print(f"Assembled {len(mem)} words from {args.src} -> {args.out}")

if __name__ == "__main__":
    main()
