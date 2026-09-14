#!/usr/bin/env python3
"""
gen_firmware_test.py - generates tests/progs/tb_firmware_prog.s: a
straight-line (mostly branch-free) test program that exercises all 47
required instructions (§4.1/§4.2), each with a directed, independently
computed expected value.

Design: rather than branching on pass/fail inside the firmware (error-prone
to hand-verify at this scale), each test computes (actual XOR expected) [or
(actual - expected) where XOR isn't meaningful] into a scratch register and
stores that DIFF word into a dedicated "signature" region of DMEM, one word
per test, in program order. A stored value of 0 means that instruction
passed; a nonzero value is itself diagnostic (shows which bits differed).
tb_firmware.v then reads every signature word back via hierarchical
reference and requires all of them to be exactly 0.

This keeps the *generated* assembly simple and auditable (straight-line,
no per-test branches to get wrong) while still giving full, mechanically
checked, per-instruction coverage - each test case's expected value is
computed independently in Python, not copied from the RTL.
"""

SIG_BASE = 0x100  # byte offset from DMEM base for the signature array
tests = []        # list of (name, category, list_of_asm_lines, comment)

def emit(name, category, lines):
    idx = len(tests)
    off = idx * 4
    body = list(lines) + [f"sw x28, {off}(x31)   # sig[{idx}] = {name}"]
    tests.append((name, category, body))

def rtype_test(name, category, mnem, rs1_val, rs2_val, expected):
    emit(name, category, [
        load_imm("x1", rs1_val),
        load_imm("x2", rs2_val),
        f"{mnem} x30, x1, x2",
        load_imm("x29", expected),
        "xor x28, x30, x29",
    ])

def to_signed(v, bits=32):
    v &= (1<<bits)-1
    if v & (1<<(bits-1)): v -= (1<<bits)
    return v

def load_imm(reg_, val):
    """Load an arbitrary 32-bit constant using LUI+ADDI (ADDI's imm is
    sign-extended, so the low 12 bits must be corrected for the sign
    extension LUI's ADDI companion normally handles)."""
    val &= 0xFFFFFFFF
    lo = val & 0xFFF
    hi = (val >> 12) & 0xFFFFF
    if lo & 0x800:         # ADDI will sign-extend lo; compensate by bumping hi
        hi = (hi + 1) & 0xFFFFF
        lo_signed = lo - 0x1000
    else:
        lo_signed = lo
    if hi == 0:
        return f"addi {reg_}, x0, {lo_signed}"
    return f"lui {reg_}, {hi}\n    addi {reg_}, {reg_}, {lo_signed}"

def itype_test(name, category, mnem, rs1_val, imm, expected):
    emit(name, category, [
        load_imm("x1", rs1_val),
        f"{mnem} x30, x1, {imm}",
        load_imm("x29", expected),
        "xor x28, x30, x29",
    ])

def load_test(name, mnem, dmem_off, store_word, expected):
    emit(name, "Load", [
        load_imm("x2", store_word),
        f"sw x2, {dmem_off}(x20)",
        f"{mnem} x30, {dmem_off}(x20)",
        load_imm("x29", expected),
        "xor x28, x30, x29",
    ])

def store_test(name, mnem, dmem_off, value, load_back_mnem, expected_readback):
    emit(name, "Store", [
        load_imm("x2", 0xFFFFFFFF),
        f"sw x2, {dmem_off}(x20)",   # pre-fill so we can tell a narrow store actually happened
        load_imm("x2", value),
        f"{mnem} x2, {dmem_off}(x20)",
        f"{load_back_mnem} x30, {dmem_off}(x20)",
        load_imm("x29", expected_readback),
        "xor x28, x30, x29",
    ])

def load_lane_test(name, mnem, word_off, lane, store_word, expected):
    """Set a whole word up with an aligned sw, then read one lane of it back.
    The setup store stays word-aligned so it always lands; only the load under
    test carries the non-zero address[1:0]."""
    emit(name, "Load", [
        load_imm("x2", store_word),
        f"sw x2, {word_off}(x20)",
        f"{mnem} x30, {word_off + lane}(x20)",
        load_imm("x29", expected),
        "xor x28, x30, x29",
    ])

def store_lane_test(name, mnem, word_off, lane, value, load_back_mnem, expected_readback):
    """Pre-fill a word with 0xFFFFFFFF (aligned), narrow-store into one lane of
    it, then read that same lane back. A store landing in the wrong lane shows
    up as a wrong read-back rather than passing by luck."""
    emit(name, "Store", [
        load_imm("x2", 0xFFFFFFFF),
        f"sw x2, {word_off}(x20)",
        load_imm("x2", value),
        f"{mnem} x2, {word_off + lane}(x20)",
        f"{load_back_mnem} x30, {word_off + lane}(x20)",
        load_imm("x29", expected_readback),
        "xor x28, x30, x29",
    ])

def branch_test(name, mnem, rs1_val, rs2_val, expect_taken):
    lbl = f"br_{name}"
    # x30 starts at 0; the increment below only executes if the branch is
    # NOT taken (it sits between the branch and its own target label), so
    # x30 ends up 0 when taken and 1 when not taken - inverted from a naive
    # reading, and worth stating explicitly.
    emit(name, "Branch", [
        load_imm("x1", rs1_val),
        load_imm("x2", rs2_val),
        "addi x30, x0, 0",
        f"{mnem} x1, x2, {lbl}",
        "addi x30, x0, 1",     # only reached if NOT taken
        f"{lbl}:",
        load_imm("x29", 0 if expect_taken else 1),
        "xor x28, x30, x29",
    ])

def upper_test(name, mnem, imm20, expected):
    emit(name, "Upper Immediate", [
        f"{mnem} x30, {imm20}",
        load_imm("x29", expected),
        "xor x28, x30, x29",
    ])

def mul_test(name, mnem, a, b, expected):
    rtype_test(name, "Multiplication", mnem, a, b, expected)

def crc_test(name, mnem, seed, data, expected):
    # rs1 = data, rs2 = running CRC. That is the operand order the official
    # validation firmware uses ("crcb s0, s1, s0" folds the byte in s1 into the
    # accumulator held in s0), and rtype_test puts its first operand in rs1.
    #
    # Worth knowing if this ever looks wrong: CRCH is symmetric in the two
    # operands, because 16 data bits entering a 16-bit register makes seed and
    # data play identical roles in the LFSR recurrence. So a swapped CRCH still
    # produces the right answer, and only CRCB and CRCW expose a swap.
    rtype_test(name, "CRC", mnem, data, seed, expected)

# ---------------- CRC golden values (independent model) ----------------
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tests', 'golden'))
from crc_golden import crcb, crch, crcw

# =========================== Arithmetic/Logic (Register) 10/10 ===========
rtype_test("ADD","Arith/Logic(Reg)","add", 5, 10, 15)
rtype_test("SUB","Arith/Logic(Reg)","sub", 10, 5, 5)
rtype_test("SLL","Arith/Logic(Reg)","sll", 1, 31, 0x80000000)
rtype_test("SLT","Arith/Logic(Reg)","slt", to_signed(0x80000000), to_signed(0x7FFFFFFF), 1)
rtype_test("SLTU","Arith/Logic(Reg)","sltu", 0x80000000, 0x7FFFFFFF, 0)
rtype_test("XOR","Arith/Logic(Reg)","xor", 0xAAAAAAAA, 0xFFFFFFFF, 0x55555555)
rtype_test("SRL","Arith/Logic(Reg)","srl", to_signed(0x80000000), 4, 0x08000000)
rtype_test("SRA","Arith/Logic(Reg)","sra", -1, 5, 0xFFFFFFFF)
rtype_test("OR","Arith/Logic(Reg)","or", 0xF0F0F0F0, 0x0F0F0F0F, 0xFFFFFFFF)
rtype_test("AND","Arith/Logic(Reg)","and", 0xFF00FF00, 0x0FF00FF0, 0x0F000F00)

# =========================== Arithmetic/Logic (Immediate) 9/9 ============
itype_test("ADDI","Arith/Logic(Imm)","addi", 100, -50, 50)
itype_test("SLTI","Arith/Logic(Imm)","slti", -5, 0, 1)
itype_test("SLTIU","Arith/Logic(Imm)","sltiu", 5, 10, 1)
itype_test("XORI","Arith/Logic(Imm)","xori", 0x0F0F0F0F, -1, 0xF0F0F0F0)
itype_test("ORI","Arith/Logic(Imm)","ori", 0x0000FF00, 0xF, 0x0000FF0F)
itype_test("ANDI","Arith/Logic(Imm)","andi", 0xFFFFFFFF, 0xF, 0xF)
itype_test("SLLI","Arith/Logic(Imm)","slli", 1, 10, 1024)
itype_test("SRLI","Arith/Logic(Imm)","srli", to_signed(0x80000000), 4, 0x08000000)
itype_test("SRAI","Arith/Logic(Imm)","srai", -8, 2, -2 & 0xFFFFFFFF)

# =========================== Load 5/5 =====================================
load_test("LW","lw", 0x00, 0xDEADBEEF, 0xDEADBEEF)
load_test("LH","lh", 0x04, 0xABCD9234, to_signed(0xFFFF9234))
load_test("LHU","lhu", 0x08, 0xABCD8000, 0x8000)
load_test("LB","lb", 0x0C, 0xAABBCCF1, to_signed(0xFFFFFFF1))
load_test("LBU","lbu", 0x10, 0xAABBCC7F, 0x7F)

# Byte-lane coverage. The lane-select and sign/zero-extend path is where
# alignment bugs actually live, and it is only reachable through a non-zero
# address[1:0] - so every lane gets its own directed test end-to-end through
# the LSU, address decoder and DMEM, not just in the LSU unit test.
load_lane_test("LB_lane1","lb",   0x20, 1, 0xAABB80CC, to_signed(0xFFFFFF80))
load_lane_test("LB_lane2","lb",   0x24, 2, 0xAA7FBBCC, 0x7F)
load_lane_test("LB_lane3","lb",   0x28, 3, 0x91AABBCC, to_signed(0xFFFFFF91))
load_lane_test("LBU_lane1","lbu", 0x2C, 1, 0xAABB80CC, 0x80)
load_lane_test("LBU_lane3","lbu", 0x30, 3, 0x91AABBCC, 0x91)
load_lane_test("LH_lane2","lh",   0x34, 2, 0x8765ABCD, to_signed(0xFFFF8765))
load_lane_test("LHU_lane2","lhu", 0x38, 2, 0x8765ABCD, 0x8765)

# =========================== Store 3/3 (verified via read-back) ==========
store_test("SW","sw", 0x14, 0xCAFEBABE, "lw", 0xCAFEBABE)
store_test("SH","sh", 0x18, 0x0000ABCD, "lhu", 0x0000ABCD)
store_test("SB","sb", 0x1C, 0x000000EF, "lbu", 0x000000EF)

# Byte-lane coverage for the store side, mirroring the load-side tests above.
# Each pre-fills the word with 0xFFFFFFFF first, so a store that lands in the
# wrong lane shows up as a wrong read-back rather than passing by luck.
store_lane_test("SB_lane1","sb", 0x40, 1, 0x0000005A, "lbu", 0x0000005A)
store_lane_test("SB_lane2","sb", 0x44, 2, 0x000000A5, "lbu", 0x000000A5)
store_lane_test("SB_lane3","sb", 0x48, 3, 0x0000003C, "lbu", 0x0000003C)
store_lane_test("SH_lane2","sh", 0x4C, 2, 0x00001234, "lhu", 0x00001234)

# =========================== Branch 6/6 ===================================
# Each condition is exercised in both directions: the taken path proves the
# comparator and the branch target, the not-taken path proves the fall-through
# (and that the comparator is not simply always asserting).
branch_test("BEQ","beq", 7, 7, True)
branch_test("BEQ_NT","beq", 7, 8, False)
branch_test("BNE","bne", 7, 8, True)
branch_test("BNE_NT","bne", 7, 7, False)
branch_test("BLT","blt", to_signed(0x80000000), to_signed(0x7FFFFFFF), True)
branch_test("BLT_NT","blt", to_signed(0x7FFFFFFF), to_signed(0x80000000), False)
branch_test("BGE","bge", to_signed(0x7FFFFFFF), to_signed(0x80000000), True)
branch_test("BGE_NT","bge", to_signed(0x80000000), to_signed(0x7FFFFFFF), False)
branch_test("BLTU","bltu", 0x7FFFFFFF, 0x80000000, True)
branch_test("BLTU_NT","bltu", 0x80000000, 0x7FFFFFFF, False)
branch_test("BGEU","bgeu", 0x80000000, 0x7FFFFFFF, True)
branch_test("BGEU_NT","bgeu", 0x7FFFFFFF, 0x80000000, False)

# =========================== Jump 2/2 (handled specially, see .s tail) ===
# JAL/JALR are verified structurally in the hand-written tail (landing +
# link value), same pattern already proven in tb_core/tb_soc.

# =========================== Upper Immediate 2/2 ==========================
upper_test("LUI","lui", 0x12345, 0x12345000)
# AUIPC's expected value depends on its own address, so it's verified in
# the hand-written tail where the address is known at generation time.

# =========================== System/Synchronization 3/3 ===================
# ECALL/EBREAK/FENCE are verified via sys_event_o / no-corruption checks at
# the testbench level (same approach as tb_soc's FENCE/illegal test) -
# not amenable to the diff-into-signature pattern since they produce no
# register result by design.

# =========================== Multiplication (Zmmul) 4/4 ===================
mul_test("MUL","mul", 123456, 6789, (123456*6789) & 0xFFFFFFFF)
mul_test("MULH","mulh", to_signed(0x80000000), to_signed(0x80000000), ((to_signed(0x80000000)*to_signed(0x80000000)) >> 32) & 0xFFFFFFFF)
mul_test("MULHSU","mulhsu", -2, 0xFFFFFFFF, ((-2 * 0xFFFFFFFF) >> 32) & 0xFFFFFFFF)
mul_test("MULHU","mulhu", 0xFFFFFFFF, 0xFFFFFFFF, ((0xFFFFFFFF*0xFFFFFFFF) >> 32) & 0xFFFFFFFF)

# =========================== CRC (Xicrc) 3/3 ===============================
crc_test("CRCB","crcb", 0xFFFF, 0x61, crcb(0xFFFF, 0x61))
crc_test("CRCH","crch", 0xFFFF, 0x6162, crch(0xFFFF, 0x6162))
crc_test("CRCW","crcw", 0xFFFF, 0x61626364, crcw(0xFFFF, 0x61626364))

# ============================================================================
# Emit the full program
# ============================================================================
lines = []
lines.append("# Auto-generated by scripts/gen_firmware_test.py - do not hand-edit.")
lines.append("# Comprehensive 47-instruction firmware test. Each test computes a")
lines.append("# diff (0=pass) into a dedicated DMEM signature slot; tb_firmware.v")
lines.append("# checks every slot is exactly 0 after the final ECALL.")
lines.append(f"    lui   x20, 0x10010        # x20 = DMEM base 0x10010000")
lines.append(f"    lui   x31, 0x10010        # x31 = DMEM base too")
lines.append(f"    addi  x31, x31, {SIG_BASE}   # x31 = signature array base")

for name, category, body in tests:
    lines.append(f"    # ---- {category}: {name} ----")
    for ln in body:
        for sub in ln.split("\n"):
            lines.append(f"    {sub.strip()}")

# ---- Hand-written tail: JAL/JALR, AUIPC, ECALL/EBREAK/FENCE, final ECALL ----
tail = r"""
    # ---- Jump: JAL ----
    jal   x6, jal_target
    addi  x7, x0, 1              # must be SKIPPED by JAL
jal_target:
    addi  x8, x0, 1              # proves JAL landed

    # ---- Jump: JALR ----
    auipc x10, 0
    addi  x10, x10, %pcrel(jalr_target)   # target address, PC-relative so it
                                          # stays in range however large the
                                          # generated test program grows
    jalr  x9, 0(x10)
jalr_link:
    addi  x11, x0, 1              # NOT skipped overall: jalr_target's own
                                   # return jump lands exactly here, since
                                   # x9 (the link) points at this address
    j     after_jalr
jalr_target:
    addi  x12, x0, 1             # proves JALR landed
    jalr  x0, 0(x9)               # returns to x9 = address of the addi above
after_jalr:
    addi  x13, x0, 1             # proves control flow rejoined correctly

    # ---- Upper Immediate: AUIPC ----
auipc_site:
    auipc x14, 5                 # x14 = this_pc + (5<<12)

    # ---- System/Synchronization: FENCE must be a pure no-op ----
    addi  x15, x0, 0x77
    fence
    addi  x16, x15, 0             # must still read 0x77

    # ---- System/Synchronization: EBREAK must be a pure no-op (control-flow-wise) ----
    addi  x17, x0, 0x88
    ebreak
    addi  x18, x17, 0             # must still read 0x88

    ecall                         # final completion marker
"""
lines.append(tail)

with open(os.path.join(os.path.dirname(__file__), '..', 'tests', 'progs', 'tb_firmware_prog.s'), 'w') as f:
    f.write("\n".join(lines) + "\n")

print(f"Generated {len(tests)} directed instruction tests -> tests/progs/tb_firmware_prog.s")
print(f"Signature array: {len(tests)} words at DMEM offset 0x{SIG_BASE:x} (address 0x{0x10010000+SIG_BASE:08x})")

# Assemble immediately, so the address-dependent expectations below are always
# derived from the exact image the testbench will run.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import assemble

progs = os.path.join(os.path.dirname(__file__), '..', 'tests', 'progs')
with open(os.path.join(progs, 'tb_firmware_prog.s')) as f:
    mem, labels = assemble(f.readlines())

with open(os.path.join(progs, 'tb_firmware_prog.hex'), 'w') as f:
    for w in mem:
        f.write(f"{w:08x}" + chr(10))

with open(os.path.join(progs, 'tb_firmware_prog.lst'), 'w') as f:
    for i, w in enumerate(mem):
        f.write(f"{i*4:08x} (0x00400000+{i*4:04x}): {w:08x}" + chr(10))
    f.write(chr(10) + "Labels:" + chr(10))
    for lbl, a in labels.items():
        f.write(f"  {lbl}: {a:08x}" + chr(10))

IMEM_BASE = 0x00400000
jalr_link  = IMEM_BASE + labels['jalr_link']            # JALR's link value (x9)
auipc_val  = IMEM_BASE + labels['auipc_site'] + (5 << 12)  # AUIPC result (x14)

# Structural expectations that depend on where the tail landed. Generated
# rather than hand-copied so they cannot go stale as the test set grows.
with open(os.path.join(progs, 'tb_firmware_expected.vh'), 'w') as f:
    f.write("// Generated by scripts/gen_firmware_test.py - do not hand-edit." + chr(10))
    f.write(f"localparam NUM_SIG_TESTS  = {len(tests)};" + chr(10))
    f.write(f"localparam SIG_BASE_WORDS = 'h{SIG_BASE:x}/4;" + chr(10))
    f.write(f"localparam [31:0] EXP_JALR_LINK = 32'h{jalr_link:08X};" + chr(10))
    f.write(f"localparam [31:0] EXP_AUIPC     = 32'h{auipc_val:08X};" + chr(10))
    f.write(f"localparam IMEM_WORDS_NEEDED = {len(mem)};" + chr(10))

# Emit a small JSON manifest the testbench-generation / report step can use
import json
manifest = {"num_tests": len(tests), "sig_base_offset": SIG_BASE,
            "image_words": len(mem),
            "tests": [{"idx": i, "name": n, "category": c} for i,(n,c,_) in enumerate(tests)]}
with open(os.path.join(progs, 'tb_firmware_manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=2)

print(f"Assembled {len(mem)} words; JALR link = 0x{jalr_link:08X}, AUIPC = 0x{auipc_val:08X}")
