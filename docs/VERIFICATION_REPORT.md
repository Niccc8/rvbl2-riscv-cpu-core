# Verification Report

Every number below comes from an actual `vvp` (Icarus Verilog) simulation run
against the RTL in `../rtl/`, executed via `../scripts/run_all.sh`. Nothing is
asserted without the corresponding testbench in `../tb/` having been run and
its output showing that result.

The summary table is **generated**, not maintained by hand: `run_all.sh` sums
each testbench's own `==== <name>: N passed, M failed ====` line and writes
`build/test_summary.md`, which is reproduced verbatim below. Regenerate both
with one command:

```bash
bash scripts/run_all.sh
```

## Summary

**16/16 testbenches pass. 8,285 individual checks pass, 0 fail.**

Without Yosys installed, `tb_gatelevel` skips and the run reports
**15/15 testbenches, 7,384 checks** - the figure quoted in the report.

The suite is run twice, against both DMEM realizations, because the SRAM macro
is optional and the design has to be correct either way:

| DMEM realization | Command | Result |
|---|---|---|
| Behavioral register array (default) | `bash scripts/run_all.sh` | 16/16, 8,285 checks |
| 4 x OpenRAM SRAM macro | `DMEM_MACRO=1 bash scripts/run_all.sh` | 16/16, 8,281 checks |

The four-check difference is three `tb_dmem` cases that only apply to the
behavioral array (out-of-implemented-range aliasing, and read-of-never-written
returning 0 rather than the undefined value real SRAM powers up with), plus one
fewer sub-check in the same file. See `../macros/README.md`.

The table below is the default run.

| Testbench | Level | Checks | Result |
|---|---|---:|---|
| `tb_alu` | Unit | 1128 | PASS |
| `tb_branch_comparator` | Unit | 24 | PASS |
| `tb_immediate_generator` | Unit | 34 | PASS |
| `tb_register_file` | Unit | 36 | PASS |
| `tb_multiplier` | Unit | 2202 | PASS |
| `tb_crc_unit` | Unit | 322 | PASS |
| `tb_lsu` | Unit | 26 | PASS |
| `tb_imem` | Unit | 7 | PASS |
| `tb_dmem` | Unit | 17 | PASS |
| `tb_address_decoder` | Unit | 12 | PASS |
| `tb_control_unit` | Unit | 1461 | PASS |
| `tb_core` | Integration | 29 | PASS |
| `tb_soc` | Integration | 14 | PASS |
| `tb_reset` | Integration | 2002 | PASS |
| `tb_firmware` | Integration | 70 | PASS |
| `tb_gatelevel` | Gate-level | 901 | PASS |
| **Total** | | **8285** | **16/16 PASS** |

`run_all.sh` also writes this table to `build/test_summary.md` on every run.
`build/` is a generated directory and is not committed; run the suite to
create it.

## Per-testbench detail

### `tb_alu`

Directed test per ALU operation (all 11 ops from Block Guide Table 9), plus
corner values (0, ±1, `INT_MIN`, `INT_MAX`, masked shift amounts ≥32, reserved
op-code default). Confirms shift amounts are masked to `b[4:0]` per RV32
semantics, and that `SLT`/`SLTU` diverge correctly at the signed/unsigned
boundary (`0x80000000` vs `0x7FFFFFFF`).

**How to read this count.** The directed vectors are the real oracle here. The
1,100 randomized checks that make up the rest of the total compute their
expected value with the same Verilog operator the DUT uses (`check(a + b)`
against `result = a + b`), so they verify operation decode and output muxing —
not operator semantics. They are kept deliberately, as a routing check, but
they should not be read as 1,128 independent functional checks. Operator
semantics are covered by the directed vectors and, end to end, by
`tb_firmware`.

### `tb_branch_comparator`

All 6 branch conditions in both directions, including the signed/unsigned
boundary case (`0x80000000` vs `0x7FFFFFFF` gives opposite answers for `BLT`
vs `BLTU`), equal-value cases (confirming `<` is strict and `>=` includes
equal), and confirmation that reserved `funct3` values (010/011) default to
not-taken.

### `tb_immediate_generator`

Checked against an **independent** Python bit-slicer
(`../tests/golden/imm_golden.py`), not the RTL's own logic transcribed a second
time — 33 generated vectors across all 5 formats (I/S/B/U/J) plus one
don't-care check for R-type encodings.

That golden model now emits every artifact the testbench consumes — the two
`$readmemh` hex files *and* the vector count as an `include`-able header — so
re-running it can never leave the testbench checking stale vectors against a
changed model. Previously it wrote only a human-readable `.txt` while the
testbench read two hand-split hex files that nothing regenerated.

### `tb_register_file`

`x0` write-guard (write attempted, confirmed still reads 0), full 32-register
round-trip sweep, reset-clears-everything, and confirmation that
`reg_write=0` performs no write.

### `tb_multiplier`

- 2,198 functional checks: full corner-value cross product (7×7×4 ops) plus
  500 randomized operand pairs × 4 ops, each checked against an **independent**
  64-bit signed/unsigned reference computation — not the RTL's own
  `a_signed`/`b_signed`/`sel_upper` expressions.
- 4 brute-force truth-table checks of those three formulas against the intended
  Table-10 mapping, explicitly confirming that the historically error-prone
  shortcut (`sel_upper = funct3[0]` alone) fails specifically on `MULHSU` and
  that the actual RTL formula (`funct3[1] | funct3[0]`) does not.

### `tb_crc_unit`

Checked against an **independent** Python bit-serial CRC-16/CCITT-FALSE model
(`../tests/golden/crc_golden.py`), which itself self-checks against the
standard published check value (`0x29B1` for ASCII `"123456789"`) before being
trusted as an oracle. 318 directed and randomized vectors across all 3 input
widths, plus a chained-CRCB reproduction of the check value run directly in the
testbench — independent of the vector file, so a corrupted vector file cannot
mask a broken engine.

All 319 still pass unchanged after the unit was restructured into three
constant-width XOR networks plus an output multiplexer, matching Block Guide
§3.1.3's description of the block ("three blocks, each of which performs the
CRC with a part of the inputs… and a multiplexer"). See
`SYNTHESIS_REPORT.md`.

### `tb_lsu`

Reproduces the Block Guide's own worked examples exactly — the byte-store
example (§3.3.2: storing `0x12` to `0x10010002` must produce `bw_o=0100`,
`data_o=0x00120000`) and the full load worked-example table (§3.3.1, DMEM word
`0xF4F3F2F1`) — plus a full alignment/size sweep for byte, half and word loads
and stores, and confirmation that misaligned half/word accesses
deterministically return 0 / write nothing rather than being undefined.

### `tb_imem`

Confirms `oe_i=0` reads 0, and specifically that an address just past the
*instantiated* array size but still inside the 4 MB architectural window reads
back 0 rather than aliasing into a real word — the bug class the `impl_sel`
range check exists to prevent.

### `tb_dmem`

Full-word and single-byte-lane writes, write-survives-idle-cycles (true
storage, not combinational passthrough), the full 4-lane sweep, and
simultaneous `we_i`/`oe_i` (write-wins, deterministic).

Also covers the implemented-size boundary, mirroring `tb_imem`: an address
inside the architectural 8 kB window (Block Guide Table 13) but beyond the
instantiated array must read back 0 and write nothing, rather than aliasing
into a real word. The Block Guide explicitly allows a DMEM smaller than 8 kB
(§4.3: "a 256-byte memory contains 64 words of 4 bytes"), so this is a
supported configuration and not a hypothetical one — the test writes past the
array, then confirms word 0 is untouched.

**Note:** an earlier version of this testbench had a genuine Verilog race
(changing `we_i`/`oe_i` in the same simulation timestep as the clock edge the
DUT samples on) that caused an intermittently skipped write. Isolated,
confirmed and fixed by restructuring all accesses through `do_write`/`do_read`
helpers that always land a safe `#1` past any edge before changing control
signals — documented inline in `tb_dmem.v`.

### `tb_address_decoder`

Boundary sweep for both memory windows (base, last byte, one below, one above),
and — the check this section exists for — confirmation that a **store to an
out-of-range address asserts zero `dmem_we_o`/`dmem_bw_o`**, not just "produces
an unread result". A read-only sweep would not catch this; the aliasing risk
only manifests as an unwanted write.

### `tb_control_unit`

- **1,408 behavioural-sweep checks**: every {opcode ∈ 11 real opcodes} ×
  {funct3 ∈ 0..7} × {8 representative funct7 values, including clearly invalid
  ones} = 704 encodings driven through the actual FSM. Each is checked twice:
  which state `EXECUTE` hands off to, **and** whether `reg_write` is asserted
  where it would be. The `reg_write` half is what makes the sweep able to catch
  the "opcode matches a real class but funct3/funct7 doesn't" failure mode —
  previously only the state transition was checked, so an invalid encoding that
  wrote a register would have passed.

  Expectations come from a reference classifier written from the ISA table
  (§4.2), deliberately not copy-pasted from `control_unit.v`'s own expressions.
  The sweep drives `rd=1` rather than `rd=0` so a spurious `reg_write` is
  observable instead of being masked by the `x0` write-guard.

- **53 explicit state-transition-table checks**: the full RESET→FETCH→DECODE→
  EXECUTE path, branch (3-cycle total), store (4-cycle), load (5-cycle,
  including confirming `oe_o` stays asserted through `WRITEBACK` per the §7.4
  timing requirement), `sys_event_o` pulse timing for `ECALL` and `EBREAK`, the
  illegal-instruction path, reset-mid-instruction abort (confirming `we_o`
  drops to 0 in the *same* cycle `rst_i` asserts), and confirmation that a
  SYSTEM-opcode word which is not exactly `ECALL`/`EBREAK` neither pulses
  `sys_event_o` nor asserts `reg_write`.

**Debugging note — three real bugs were found and fixed while writing this
testbench** (recorded rather than quietly fixed, since finding and fixing is
what this project is meant to demonstrate):

1. `clk` was never initialized. Verilog `reg`s default to `X` and `~X = X`, so
   the clock toggled between `X` and `X` forever and `@(posedge clk)` never
   fired — an apparent infinite hang with zero output. Fixed by adding
   `clk = 0;`.
2. A sweep loop counter meant to reach 128 was declared as a 7-bit `reg`, whose
   maximum value is 127 — `127 < 128` is still true, so the loop never
   terminated. Fixed by declaring loop counters as `integer`.
3. A hand-counted `@(posedge clk)` reset sequence had one wasted edge before
   asserting `rst` and one missing edge after deasserting it, leaving the FSM
   one state behind what the surrounding code assumed. Fixed by correcting the
   count, and more durably by rewriting the whole task set around a
   `wait_for_state(target, max_cycles, cycles_taken)` polling helper with a
   hard timeout, so no hand-counted edges remain in the file.

### `tb_core`

Core + address decoder + IMEM + DMEM (no outer `top` wrapper), running
`../tests/progs/tb_core_prog.s` — one representative instruction from every
major class in a single program, checked via hierarchical references into the
register file (`dut.u_core.u_rf.regs[i]`) and DMEM (`dut.u_dmem.mem[i]`) after
the program signals completion via `sys_event_o` (ECALL). Includes a CRC result
cross-checked against the same independent Python golden model used in the unit
test.

### `tb_soc`

Full `top` (2-pin interface only), running `tests/progs/tb_soc_prog.s`: a
dependent-register loop (sum 1..5 = 15, confirming the hazard-free-by-
construction property across many back-to-back instructions), `FENCE` and an
illegal encoding as pure no-ops (confirmed via a sentinel register unchanged
across both), a JALR indirect call and return, and — the case this testbench
exists for — **a load whose address resolves into IMEM rather than DMEM**,
confirming the §7.4 timing requirement (extending `oe_o`/`AddrSrc` through
`WriteBack` for loads) actually works: the test loads a `.word` constant placed
inline in the instruction stream via AUIPC-relative addressing and confirms the
exact value (`0xCAFEBABE`) comes back, not the `0` an IMEM without that scoping
would silently return.

This is the case Block Guide §4.2 calls out directly ("the IMEM can maintain
constant values that can be read by the CPU while running a program"), with a
worked `LW T0, 0(T1)` example.

### `tb_reset`

SoC-level reset-during-execution stress (§15.3). `rst_i` is asserted at 40
different cycle offsets across a running program — so reset lands in every FSM
state, including inside a store's `MEMORY` cycle — and after each injection the
testbench confirms that **no DMEM word changed across the reset edge** (the
in-flight write was genuinely aborted), `PC` is back at the reset vector
`0x00400000`, the FSM is in `RESET`, and every GPR is cleared. It then releases
reset once more and confirms the program re-runs to the same result.

The unit-level check in `tb_control_unit` confirms the combinational enables
drop in the same cycle `rst_i` asserts; it cannot see whether the write
actually committed. This one can, and that is the property the design's
reset discipline (§9.1) exists to provide.

### `tb_firmware`

Full `top`, running `tests/progs/tb_firmware_prog.s`, an auto-generated (via
`../scripts/gen_firmware_test.py`) program covering **all 47 required
instructions** (§4.1/§4.2) — see `../docs/ISA_COVERAGE.md`. 58 instruction
tests use a diff-into-signature pattern (compute `actual XOR expected` into a
dedicated DMEM word per test, every expected value computed independently in
Python, not by the RTL); JAL/JALR/AUIPC/FENCE/EBREAK/ECALL are checked
structurally via direct register values. Confirms exactly 2 `sys_event_o`
pulses occur (EBREAK then ECALL), each logged with cycle number and PC — the
firmware-completion logging Submission Guide §6 asks for.

**Byte-lane and branch-direction coverage.** The load and store tests sweep
every `address[1:0]` lane, not just word-aligned offsets: `SB` into lanes
1/2/3, `SH` into lane 2, and `LB`/`LBU`/`LH`/`LHU` from every non-zero lane.
That path — LSU positioning, `bw_o` routing through the decoder, DMEM's
per-byte write enables, and writeback extension — is where alignment bugs
actually live, and it is only reachable through a non-zero `address[1:0]`. Each
lane test sets the word up with an aligned `sw` first, so only the access under
test carries the offset. Every branch condition is likewise tested in both
directions, so a comparator that simply always asserted would fail.

**Generated expectations.** The signature count, the signature base address and
the two address-dependent structural expectations (the JALR link value and the
AUIPC result) are emitted by the generator into
`tests/progs/tb_firmware_expected.vh` and `include`d by the testbench, because
all four move when the test program grows. They were previously hand-copied
constants.

**Two bugs found and fixed while building this test, both in the generated test
program, not the RTL:**

1. The branch-outcome flag's polarity was inverted: the scratch register used
   to detect "was the branch taken" stays at its initial value when the branch
   *is* taken (the increment that would change it sits between the branch and
   its target label, and gets skipped). The generator's expected-value logic had
   this backwards.
2. The JALR test's "must be skipped" register was checked against the wrong
   expected value: the link register computed by `jalr` points at the very next
   instruction, which is exactly the register the test called "skipped" — and
   the test's own `jalr x0, 0(link)` return jump lands there, executing it once
   after all. The register does get set, correctly, once; the test's
   expectation was wrong, not the control flow.

### `tb_gatelevel`

Gate-level equivalence (§17 stage 16). Runs the RTL `riscv_core` and the
Yosys-synthesized `riscv_core` in the same simulation, each against its own
identical behavioral memory subsystem, and compares the core's entire external
interface — `address_o`, `we_o`, `oe_o`, `bw_o`, `store_data_o`,
`sys_event_o` — on every one of 900 cycles, then compares both DMEM arrays word
for word.

**Result: bit-identical, zero mismatches.** That interface is the whole of what
the core presents to the rest of the SoC, so identical behaviour on it across a
full program is a strong functional-equivalence result — and unlike a
register-file comparison it works even though synthesis has flattened the
netlist's internal names away.

`scripts/gen_gl_netlist.py` prepares the netlist by prefixing its module names
with `gl_` so both copies of the design can coexist in one simulation;
`scripts/run_gl_equiv.sh` does both steps and is invoked automatically by
`run_all.sh` whenever a synthesized netlist is present (and skipped, not
failed, when one is not).

## What is deliberately *not* covered

- **The official ChampionCHIP validation firmware** is not run *in this tree*.
  It was released after this report's suite was built, and is exercised by the
  ChipInventor flow instead: `bash chipinventor/scripts/run_ci.sh` runs it
  against both the mirror and the exported netlist and reports the verdict
  (**`x4 = 0x00000000`, settled after 991 cycles**). See
  [`../chipinventor/VALIDATION.md`](../chipinventor/VALIDATION.md).
  `tb_firmware`'s program remains this project's own coverage vehicle, built
  for full ISA reach with an independently verifiable pass/fail signature.
- **Post-layout (SDF-annotated) gate-level simulation.** `tb_gatelevel`
  compares against the post-synthesis netlist, which catches
  synthesis-introduced functional regressions. It cannot catch timing-related
  failures, which need a post-route netlist simulated with real delays. The
  physical flow *has* been run — the post-route gate-level netlist is in
  `chipinventor/openlane/runs/platform_20260904/results/final/verilog/gl/` and
  signoff STA reports **+2.25 ns setup margin at the slow corner** — but the
  SDF was not retained (88 MB) and SDF-annotated simulation was not attempted.
- **Constrained-random instruction-sequence fuzzing** beyond the operand-level
  randomization in `tb_multiplier`/`tb_crc_unit`. The directed plus
  full-behavioural-sweep approach above was judged to give better, more
  debuggable coverage per unit of effort for a design this size.
