# RVBL-2 — Architecture Specification

**Equipe 13 · ChampionCHIP eXperience, Phase 2**

This document describes the processor **as built**. Every statement below was read back
from the RTL in [`../rtl/`](../rtl/), not from a design plan. Where the implementation
differs from what the Block Guide leaves open, the choice made is stated with its reason.

For the instruction encodings see [`ISA_COVERAGE.md`](ISA_COVERAGE.md); for what was tested
see [`VERIFICATION_REPORT.md`](VERIFICATION_REPORT.md); for physical results see
[`../chipinventor/openlane/RESULTS.md`](../chipinventor/openlane/RESULTS.md).

---

## 1. Overview

RVBL-2 is a 32-bit RISC-V core implementing **RV32I + Zmmul + Xicrc = 47 instructions**.

It is **multicycle**: each instruction takes three to five clock cycles and the hardware is
reused in each cycle. One ALU, one memory port and one register write port serve every
instruction. Nothing is duplicated.

Two consequences follow, and both are deliberate:

- **Area.** A shared ALU and a single memory port is what the Block Guide's §2.1 structure
  asks for, and it is why the design fits 0.404 mm² at 52 % density.
- **Verifiability.** Instructions never overlap, so no hazard can exist. There is no
  forwarding path, no stall logic and no flush logic — and therefore none to get wrong.

The core has exactly **two external pins**, `clk_i` and `rst_i`, as Block Guide Table 5
mandates. §9 explains how a design with no data outputs is kept observable.

## 2. Module hierarchy

Sixteen files in `rtl/`: fourteen leaf modules, plus `riscv_core` (11 instances) and `top`
(2 instances) as hierarchy wrappers.

| Module | Role |
|---|---|
| `control_unit` | 6-state FSM; decodes instruction class; drives every control signal |
| `pc_reg` | Program counter; resets to `0x00400000`; forces word alignment |
| `pc_incrementer` | `pc + 4`, its own adder so it never borrows an ALU cycle |
| `ir_reg` | Instruction register; loaded in FETCH, steady for the whole instruction |
| `immediate_generator` | I/S/B/U/J immediate extraction and sign extension |
| `register_file` | 32 × 32-bit; `x0` hardwired to zero; 2 read ports, 1 write port |
| `alu` | 11 operations, combinational |
| `branch_comparator` | All six branch conditions, signed and unsigned |
| `multiplier` | 64-bit combinational product with per-operand signedness |
| `crc_unit` | CRC-16/CCITT-FALSE over 8, 16 or 32 bits, zero latency |
| `lsu` | Byte lane positioning, write masks, sign/zero extension |
| `imem` | Instruction ROM, **combinational** read |
| `dmem` | Data memory, **synchronous**, byte-writable |
| `address_decoder` | Routes one memory port to IMEM or DMEM; muxes read data back |
| `riscv_core` | The core: everything except the two memories |
| `top` | `riscv_core` + `imem` + `dmem`; the two-pin chip boundary |

On the ChipInventor canvas the same design is 17 blocks, because `ir_fields`, `mux2_32` and
`wb_mux_32` are split out as their own blocks rather than being inline in `riscv_core`. The
two forms are proven equivalent cycle by cycle — see the repository README.

## 3. Datapath

### 3.1 Multiplexers

Five multiplexers, with the exact select expressions from `control_unit.v`:

| Mux | Select | 0 | 1 |
|---|---|---|---|
| ALU operand A | `alu_src_a_sel = is_auipc \| is_branch \| is_jal` | `rs1_data` | `pc` |
| ALU operand B | `alu_src_b_sel = ~(is_alu_reg \| is_mul \| is_crc)` | `rs2_data` | `imm` |
| Memory address | `addr_src_sel` (see below) | `pc` | `alu_result` |
| PC source | `pc_src_sel = (is_branch & branch_taken) \| is_jal \| is_jalr` | `pc+4` | `alu_result` |
| Writeback | `wb_src_sel` (3 bits) | — | see below |

`wb_src_sel`: `000` ALU · `001` multiplier · `010` CRC · `011` load data · `100` `pc+4`.
JALR takes operand A from `rs1_data`, not `pc`, which is what makes it an indirect jump.

`addr_src_sel` is asserted for:

```text
(EXECUTE and (load or store)) or MEMORY or (WRITEBACK and load)
```

The **`WRITEBACK and load`** term is not redundant. `imem` reads combinationally, so a load
whose address falls in the instruction ROM only returns data while the address is still
being driven. Dropping the address in WRITEBACK would return zero. The same reasoning
extends `oe_o` through WRITEBACK for loads.

### 3.2 Registers — and the two that are absent

Only four state elements hold architectural state: `pc_reg`, `ir_reg`, `register_file`, and
the FSM state register in `control_unit`.

A textbook multicycle design adds two more — an ALU-result register and a memory-data
register. **This design has neither, and does not need them.**

The instruction register does not change until the next FETCH. Every value derived from it
is therefore steady for the whole instruction: `rs1_data`, `rs2_data`, the immediate, and
the ALU result. A register that holds an already-steady value adds nothing.

Removing both saves **64 flip-flops** and changes no behaviour. One rule makes it safe: no
cycle may change the ALU operand multiplexers mid-instruction. That is why `pc+4` has its
own adder instead of borrowing an ALU cycle.

## 4. Control unit

### 4.1 States

Six states, encoded in three bits: `RESET=0, FETCH=1, DECODE=2, EXECUTE=3, MEMORY=4,
WRITEBACK=5`.

The Block Guide §3.2 names four phases. This design adds `RESET` and `MEMORY`. `MEMORY` is
not decoration: Block Guide §4.3 specifies the data memory as synchronous, so a load
physically cannot present an address and consume the result in the same cycle. Six states
still encode in three bits, so the addition costs nothing.

### 4.2 Transitions

Nine transitions in total:

| From | To | Condition |
|---|---|---|
| `RESET` | `FETCH` | unconditional |
| `FETCH` | `DECODE` | unconditional |
| `DECODE` | `EXECUTE` | unconditional |
| `EXECUTE` | `MEMORY` | load or store |
| `EXECUTE` | `FETCH` | branch |
| `EXECUTE` | `WRITEBACK` | everything else |
| `MEMORY` | `WRITEBACK` | load |
| `MEMORY` | `FETCH` | store |
| `WRITEBACK` | `FETCH` | unconditional |

### 4.3 Cycles per instruction

| Class | Cycles | Path |
|---|---|---|
| Branch | 3 | F → D → E |
| Store | 4 | F → D → E → M |
| ALU, immediate, LUI, AUIPC, MUL, CRC, JAL, JALR, FENCE, ECALL, EBREAK, illegal | 4 | F → D → E → W |
| Load | 5 | F → D → E → M → W |

### 4.4 Control signal equations

Every output is gated by `~rst_i` **directly**, not merely by the state register having
reached `RESET`. This aborts an in-flight memory write in the same cycle reset asserts
rather than one cycle later.

```text
ir_write     = ~rst_i & (state == FETCH)
pc_write     = ~rst_i & ( (EXECUTE & branch) | (MEMORY & store) | WRITEBACK )
reg_write    = ~rst_i & WRITEBACK & ~(fence | illegal | ecall_ebreak)
we_o         = ~rst_i & MEMORY & store
oe_o         = ~rst_i & ( FETCH | (MEMORY & load) | (WRITEBACK & load) )
sys_event_o  = ~rst_i & EXECUTE & ecall_ebreak
```

The PC is written in the **last** cycle of each instruction. This is why branch and jump
targets are computed relative to the instruction's own address and not to `pc+4`.

### 4.5 Decode is full-tuple, not opcode-only

An instruction is recognised only if the complete `{opcode, funct3, funct7}` tuple matches.
`is_illegal` is the negation of `is_recognized`, and an illegal instruction decodes as a
safe no-operation: it reaches WRITEBACK, writes no register, touches no memory, and the FSM
returns to FETCH. It never locks the machine.

Two specifics worth recording:

- **ECALL and EBREAK are matched as whole 32-bit words**, `32'h00000073` and
  `32'h00100073`, not by opcode field. No other SYSTEM-opcode word can therefore pulse
  `sys_event_o` and be mistaken for a firmware checkpoint.
- **Shift immediates check `funct7`.** `SLLI` requires `0000000`; `SRLI`/`SRAI` accept
  `0000000` or `0100000`. Any other value falls through to the illegal default.

`sys_event_o` is a **single-cycle pulse**, not a sticky halt. A sticky halt would make the
core unable to continue past a firmware checkpoint, which is the opposite of what the
validation firmware needs.

## 5. Memory system

### 5.1 Map

| Region | Base | Last | Size | Access |
|---|---|---|---|---|
| IMEM | `0x00400000` | `0x007FFFFF` | 4 MB window | read only, combinational |
| DMEM | `0x10010000` | `0x10011FFF` | 8 kB | read/write, synchronous, byte-writable |

Reset vector is `0x00400000`. Addresses outside both windows are safe: reads return zero and
writes are ignored. `pc_reg` forces `pc[1:0]` to `00` on every write, so the PC is always
word-aligned.

The 4 MB figure is an architectural *ceiling*, not an instantiation mandate. `imem` is
parameterised by `IMEM_WORDS` and instantiates only what a given build needs; the decoder
still treats the whole 4 MB window as IMEM.

### 5.2 The timing asymmetry the design pivots on

IMEM reads **combinationally** — `data_o = (oe_i && impl_sel) ? rom[addr] : 0`. DMEM reads
and writes **synchronously**, on `posedge clk_i`.

That asymmetry is the entire reason the `MEMORY` state exists, and the reason `oe_o` and
`addr_src_sel` extend through WRITEBACK for loads (§3.1).

### 5.3 Decoder

`address_decoder` is combinational and does two jobs: it gates the enables toward whichever
memory the address selects, and it muxes the read data back.

```text
imem_oe_o = oe_i & imem_sel
dmem_oe_o = oe_i & dmem_sel
dmem_we_o = we_i & dmem_sel
dmem_bw_o = bw_i & {4{dmem_sel}}
data_o    = dmem_sel ? dmem_rdata : (imem_sel ? imem_rdata : 32'b0)
```

There is no `address_o`: the address reaches both memories directly, and the decoder only
resolves selection and read-back.

## 6. Execution units

### 6.1 ALU

Eleven operations, combinational, selected by a 4-bit `alu_op`:

| Code | Op | Code | Op | Code | Op |
|---|---|---|---|---|---|
| `0` | pass B | `4` | OR | `8` | SRA |
| `1` | ADD | `5` | XOR | `9` | SLT (signed) |
| `2` | SUB | `6` | SLL | `A` | SLTU (unsigned) |
| `3` | AND | `7` | SRL | | |

Shifts mask the amount to `b[4:0]`. `default` returns zero, so no latch is inferred.
`pass B` exists for LUI; every non-ALU class that needs an address or a target uses `ADD`.

### 6.2 Multiplier

A single 64-bit combinational product with per-operand signedness, per Block Guide Table 10:

```text
a_signed  = ~(funct3[1] & funct3[0])   // unsigned only for MULHU
b_signed  = ~funct3[1]                 // signed only for MUL / MULH
sel_upper =   funct3[1] | funct3[0]    // low half only for MUL
```

| Instruction | `funct3` | Operands | Result half |
|---|---|---|---|
| `MUL` | `000` | signed × signed | low 32 |
| `MULH` | `001` | signed × signed | high 32 |
| `MULHSU` | `010` | signed × unsigned | high 32 |
| `MULHU` | `011` | unsigned × unsigned | high 32 |

The product is evaluated in a 128-bit context before the low 64 bits are taken, so the
multiply is not truncated at 64 bits by Verilog's context-width rules. Zmmul specifies no
divider and none is present.

### 6.3 CRC unit (Xicrc)

**CRC-16/CCITT-FALSE**: polynomial `0x1021`, seed `0xFFFF` supplied by software, MSB-first,
**no input reflection, no output reflection, no final XOR**. Zero latency — the block is
pure combinational logic with no clock, as Block Guide §3.1.3 requires.

**Operand roles** — this is the one detail that must be exactly right:

| Port | Carries |
|---|---|
| `rs1_data` | the **data** to fold in (low 8, 16 or 32 bits by `funct3`) |
| `rs2_data` | the **running CRC / seed** (low 16 bits used) |

An earlier revision of this specification had these reversed. The official validation
firmware uses `crcb s0, s1, s0` — encoding `0x80848433`, `rs1 = s1` holding the data byte,
`rs2 = s0` holding the accumulator — and the mismatch was a real bug, caught only when that
firmware ran. It is worth knowing why it survived a large test suite: `CRCB(seed=X, data=Y)`
and `CRCB(seed=Y, data=X)` are *both* valid CRC-16 computations, and **CRCH is symmetric in
its two operands** (sixteen data bits entering a sixteen-bit register make seed and data
play identical roles). Only a test written against the firmware's own expected value pins
the order down. See [`../chipinventor/VALIDATION.md`](../chipinventor/VALIDATION.md).

Output select is on `funct3[1:0]`: `00` CRCB, `01` CRCH, `10` CRCW; the unused encoding
passes the seed through. The 16-bit result is zero-extended to 32 bits.

### 6.4 Branch comparator

All six conditions, evaluated on `rs1_data` and `rs2_data` with `funct3`. Signed
comparisons use `$signed`, so `BLT`/`BGE` and `BLTU`/`BGEU` separate correctly at the
sign boundary. Its output `branch_taken` feeds `pc_src_sel` in the same cycle, which is
what lets a branch finish in three cycles.

### 6.5 LSU

`op_size` is simply `funct3`, republished by the control unit so that four blocks read the
width field from one source instead of four.

**Stores.** `byte_write_o` and `store_data_o` are produced together from the width and the
low two address bits — byte stores select one of four lanes, half stores one of two, word
stores all four. A **misaligned half or word store writes nothing**: the mask is forced to
`0000`. Stores are gated by `is_valid_store`, so an illegal store-shaped encoding cannot
reach memory.

**Loads.** The addressed lane is extracted from the returned word and then sign- or
zero-extended by `funct3[2]`: `LB`/`LH` sign-extend, `LBU`/`LHU` zero-extend, `LW` passes
through.

## 7. Register file

32 × 32 bits, two combinational read ports and one synchronous write port.

`x0` is handled on **both** sides: reads of address 0 return zero by mux, and writes to
address 0 are suppressed. Synchronous reset clears all 32 entries.

## 8. Clocking and reset

Single clock domain on `clk_i`; every sequential element uses `posedge clk_i`.

Reset is **synchronous and active-high**. No asynchronous reset tree exists anywhere, which
removes reset recovery/removal timing from signoff entirely. The cost is that `rst_i` must
be held for at least one full clock period — trivially satisfied by the testbench and by the
platform harness.

Combinational blocks assign to every output on every path (`default` arms present
throughout), so no latch is inferred anywhere in the design.

## 9. Two-pin top level and observability

Block Guide Table 5 permits exactly two pins and both are inputs. The chip therefore has no
data outputs at all, which creates a synthesis problem: with nothing observable, a sweep
pass can legally delete the entire design.

Three mitigations are in place:

- **`(* keep *)` on the storage arrays** — `pc`, `ir`, the register file and the DMEM array
  — so they survive synthesis. The measured result confirms it worked: 17,708 cells and
  1,393 flip-flops, against an architectural need of about 1,315 (992 register file, 256
  data memory in the P&R build, 32 PC, 32 IR, 3 state).
- **`sys_event_o` and `state_o`** are brought out of `control_unit` for the testbench even
  though the canvas leaves them unconnected; they are observed by hierarchical reference.
- **No `initial` blocks, no `` `ifdef ``, no `` `include ``, no `$readmemh``** in any canvas
  block. Each of these fails *quietly* on a platform with no file system, so the ROM image
  is inlined as constants instead and a gate checks for all four automatically.

## 10. Verification summary

| Route | Scale | Result |
|---|---|---|
| Reference regression, `rtl/` + `tb/` | 15 testbenches, **7,384** checks | 0 failures |
| Platform suite, on the exported netlist | **15,281** checks | 0 failures |
| Lockstep equivalence, canvas vs reference | **410,400** cycle comparisons | 0 mismatches |
| Official validation firmware | 9 stages | **PASS**, `x4 = 0`, 991 cycles |

Detail in [`VERIFICATION_REPORT.md`](VERIFICATION_REPORT.md).

## 11. Where the Block Guide left a choice

| Question | Choice made | Why |
|---|---|---|
| IMEM read timing | Combinational | Guide states no latency for IMEM while explicitly requiring a cycle for DMEM |
| "Up to 4 MB" IMEM | Architectural ceiling; instantiate what is needed | 4 MB of flip-flop ROM is not placeable; the decoder still maps the full window |
| Illegal instructions | Safe no-operation | Never locks the FSM; the Guide specifies no trap mechanism |
| Firmware completion signal | Non-sticky `sys_event_o` pulse | The firmware ends in `j .`, not `ecall`; a sticky halt would prevent continuing |
| Reset polarity | Synchronous, active-high | Matches the Guide's convention table; avoids async reset timing at signoff |
| `ALUOut` / MDR registers | Omitted | IR is steady for the instruction, so both would hold already-steady values; saves 64 flops |
| CRC operand roles | `rs1` = data, `rs2` = accumulator | Fixed by the official firmware's own encoding (§6.3) |

---

## Appendix — where the old section numbers went

This specification was rewritten against the finished RTL and renumbered from 25
sections to 11. Comments in `rtl/*.v` and passages in
[`VERIFICATION_REPORT.md`](VERIFICATION_REPORT.md) still cite the old numbers.
Use this map.

| Old | Subject | Now |
|---|---|---|
| 4.1 / 4.2 | ISA categories, full encoding table | [`ISA_COVERAGE.md`](ISA_COVERAGE.md) |
| 6.1 | Module hierarchy | §2 |
| 7.2 | Datapath multiplexers | §3.1 |
| 7.3 / 7.4 | Datapath registers; why no `ALUOut`/MDR | §3.2 |
| 7.5 | PC update rule | §4.4 |
| 8.1 | State list | §4.1 |
| 8.2 | State transition table | §4.2 |
| 8.3 | Cycle counts per class | §4.3 |
| 8.5 | Illegal-instruction behaviour | §4.5 |
| 8.6 | `sys_event_o` | §4.5 |
| 9.1 | `control_unit` | §4 |
| 9.2 – 9.4 | `pc_reg`, `ir_reg`, `pc_incrementer` | §2, §5.1 |
| 9.5 | `alu` | §6.1 |
| 9.6 | `branch_comparator` | §6.4 |
| 9.7 | `immediate_generator` | §2 |
| 9.8 | `register_file` | §7 |
| 9.9 | `multiplier` | §6.2 |
| 9.10 | `crc_unit` | §6.3 |
| 9.11 | `lsu` | §6.5 |
| 9.12 / 9.13 | `imem`, `dmem` | §5 |
| 9.14 | `address_decoder` | §5.3 |
| 9.15 | `top`, observability | §9 |
| 10.x | Memory system, map, timing | §5 |
| 11.x | LSU store/load paths | §6.5 |
| 12.x | Multiplier | §6.2 |
| 13.x | CRC unit | §6.3 |
| 15.4 | Firmware completion detection | [`../chipinventor/VALIDATION.md`](../chipinventor/VALIDATION.md) |
| 18.x | Clocking and reset | §8 |

Sections that were purely pre-implementation planning — external research, the
architecture trade-off study, the verification roadmap, the risk register, the
competition-strategy checklist and the list of decisions awaiting confirmation —
are gone. The decisions they were weighing are now settled and recorded in §11.

**References of the form "Block Guide §3.1.3" are unaffected** — those point at
the competition's own Block Guide, not at this document.
