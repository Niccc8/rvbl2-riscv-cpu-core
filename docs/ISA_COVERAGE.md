# ISA Coverage

Per Submission Guide §2. Every row below is backed by a passing directed test
in `tb/tb_firmware.v` — 58 signature-diff checks whose expected values are
computed independently in Python, plus structural checks for the instructions
that produce no register result by design (JAL/JALR/AUIPC/FENCE/ECALL/EBREAK).
See `../docs/VERIFICATION_REPORT.md` for the actual pass/fail run this table is
drawn from; it is not asserted independently of it.

The 58 tests exceed the 47 instructions because loads and stores are tested at
every byte lane (`address[1:0]` = 0/1/2/3), not only word-aligned, and every
branch condition is tested in both the taken and not-taken direction.

## Summary table

| Category | Expected Instructions | Implemented Instructions | Coverage |
|---|---:|---:|---:|
| Arithmetic and Logic (Register) | 10 | 10 | 100% |
| Arithmetic and Logic (Immediate) | 9 | 9 | 100% |
| Load | 5 | 5 | 100% |
| Store | 3 | 3 | 100% |
| Branch | 6 | 6 | 100% |
| Jump | 2 | 2 | 100% |
| Upper Immediate | 2 | 2 | 100% |
| System / Synchronization | 3 | 3 | 100% |
| Multiplication | 4 | 4 | 100% |
| CRC | 3 | 3 | 100% |
| **Total** | **47** | **47** | **100%** |

## Instructions implemented, by category

**Arithmetic and Logic (Register) (10/10)**
ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND

**Arithmetic and Logic (Immediate) (9/9)**
ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI

**Load (5/5)**
LB, LH, LW, LBU, LHU

**Store (3/3)**
SB, SH, SW

**Branch (6/6)**
BEQ, BNE, BLT, BGE, BLTU, BGEU

**Jump (2/2)**
JAL, JALR

**Upper Immediate (2/2)**
LUI, AUIPC

**System / Synchronization (3/3)**
ECALL, EBREAK, FENCE

**Multiplication — Zmmul (4/4)**
MUL, MULH, MULHSU, MULHU

**CRC — Xicrc (3/3)**
CRCB, CRCH, CRCW

## Full encoding table

All values taken directly from the Block Guide (R-type ALU/Zmmul/Xicrc)
or the public RV32I base spec (I/S/B/U/J instructions), and cross-checked
against `rtl/control_unit.v`'s actual decode `case` statements — this
table is what the RTL implements, not a separate restatement of intent.

| # | Instruction | Type | Opcode | funct3 | funct7 |
|---|---|---|---|---|---|
| 1 | ADD | R | 0110011 | 000 | 0000000 |
| 2 | SUB | R | 0110011 | 000 | 0100000 |
| 3 | SLL | R | 0110011 | 001 | 0000000 |
| 4 | SLT | R | 0110011 | 010 | 0000000 |
| 5 | SLTU | R | 0110011 | 011 | 0000000 |
| 6 | XOR | R | 0110011 | 100 | 0000000 |
| 7 | SRL | R | 0110011 | 101 | 0000000 |
| 8 | SRA | R | 0110011 | 101 | 0100000 |
| 9 | OR | R | 0110011 | 110 | 0000000 |
| 10 | AND | R | 0110011 | 111 | 0000000 |
| 11 | ADDI | I | 0010011 | 000 | — |
| 12 | SLTI | I | 0010011 | 010 | — |
| 13 | SLTIU | I | 0010011 | 011 | — |
| 14 | XORI | I | 0010011 | 100 | — |
| 15 | ORI | I | 0010011 | 110 | — |
| 16 | ANDI | I | 0010011 | 111 | — |
| 17 | SLLI | I | 0010011 | 001 | 0000000 (imm[11:5]) |
| 18 | SRLI | I | 0010011 | 101 | 0000000 (imm[11:5]) |
| 19 | SRAI | I | 0010011 | 101 | 0100000 (imm[11:5]) |
| 20 | LB | I | 0000011 | 000 | — |
| 21 | LH | I | 0000011 | 001 | — |
| 22 | LW | I | 0000011 | 010 | — |
| 23 | LBU | I | 0000011 | 100 | — |
| 24 | LHU | I | 0000011 | 101 | — |
| 25 | SB | S | 0100011 | 000 | — |
| 26 | SH | S | 0100011 | 001 | — |
| 27 | SW | S | 0100011 | 010 | — |
| 28 | BEQ | B | 1100011 | 000 | — |
| 29 | BNE | B | 1100011 | 001 | — |
| 30 | BLT | B | 1100011 | 100 | — |
| 31 | BGE | B | 1100011 | 101 | — |
| 32 | BLTU | B | 1100011 | 110 | — |
| 33 | BGEU | B | 1100011 | 111 | — |
| 34 | JAL | J | 1101111 | — | — |
| 35 | JALR | I | 1100111 | 000 | — |
| 36 | LUI | U | 0110111 | — | — |
| 37 | AUIPC | U | 0010111 | — | — |
| 38 | ECALL | I | 1110011 | 000 | imm=0x000 |
| 39 | EBREAK | I | 1110011 | 000 | imm=0x001 |
| 40 | FENCE | I | 0001111 | 000 | (treated as NOP) |
| 41 | MUL | R | 0110011 | 000 | 0000001 |
| 42 | MULH | R | 0110011 | 001 | 0000001 |
| 43 | MULHSU | R | 0110011 | 010 | 0000001 |
| 44 | MULHU | R | 0110011 | 011 | 0000001 |
| 45 | CRCB | R | 0110011 | 000 | 1000000 |
| 46 | CRCH | R | 0110011 | 001 | 1000000 |
| 47 | CRCW | R | 0110011 | 010 | 1000000 |
