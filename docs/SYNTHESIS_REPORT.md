# Synthesis Validation Report

This documents exactly what synthesis validation was run, against which tools,
with what results — nothing here is claimed without a log to back it up.

The cell reports quoted below are committed in `../synth/`. The **netlists**
(`top_generic_synth.v`, `top_sky130_synth.v`, `top_sky130_synth_sram.v`) are
build outputs and are deliberately not committed — they are megabytes of
generated Verilog. Regenerate them with the commands below; every number in
this report comes from a committed `.txt` or `.log` that you can read now.

## Environment

- **Yosys 0.68+136** (git sha1 c30457480), from the OSS CAD Suite
  2026-08-30 build.
- **Sky130 standard-cell timing library**:
  `sky130_fd_sc_hd__tt_025C_1v80.lib`, fetched from the
  OpenROAD-flow-scripts repository (a real, current Sky130 PDK file, not a
  stand-in). The 12.8 MB file is a public PDK resource and is not committed
  here; re-fetch it or point at your own PDK install to reproduce Stage 3.
This report covers **logic synthesis only** — the Yosys/ABC stage, run to
validate the RTL maps cleanly to standard cells. Physical implementation
(floorplan → PDN → placement → CTS → routing → DRC/LVS → STA signoff → GDSII)
was completed separately through OpenLane; its results are in
`../chipinventor/openlane/RESULTS.md` and are the numbers that answer
Submission Guide §5.

Reproduce Stages 1–2 with:

```bash
bash scripts/synth_yosys_generic.sh          # elaboration, latch + ROM gates, cell counts
python3 scripts/area_report.py               # whole-SoC area roll-up (after Stage 3)
```

## Configuration synthesized

| Parameter | Value | Source |
|---|---|---|
| `IMEM_WORDS` | 471 | Sized to the current firmware image (Block Guide Table 6: "up to 4 MB" is the addressable ceiling, not a mandated instantiation) |
| `IMEM_INIT_FILE` | `tests/progs/tb_firmware_prog.hex` | The image actually executed by `tb_firmware` |
| `DMEM_WORDS` | 2048 | Full architectural 8 kB (Block Guide Table 6 / Table 13) |

## Stage 1 — Elaboration & structural check

`read_verilog` (all 16 RTL files) → `hierarchy -check -top top` → `synth`
→ `check`.

**Result:** no missing modules, no unresolved references, no structural
issues. Log: `elaboration_check.log`.

## Stage 2 — Generic-cell synthesis (`synth -top top`)

**Latch check: clean.** Zero `$_DLATCH_`-family cells in the netlist, in both
the generic and Sky130-mapped runs. The `dlatch` strings that appear in the
Sky130 log are `dfflibmap` printing its liberty mapping rules, not inferred
latches — the Sky130-mapped netlist contains no `dlxtp`/`dlrtp`/`dlrtn` cell
instances at all.

**Cell counts (244,006 total):**

| Module | Cells | Note |
|---|---:|---|
| `dmem` | 225,677 | 2048×32 bits as flip-flops; no SRAM macro wired in |
| `multiplier` | 8,946 | Largest logic block |
| `register_file` | 3,833 | 992 flops — `x0` correctly optimized away |
| `imem` | 2,628 | 471-word ROM realised as logic |
| `alu` | 1,264 | |
| `lsu` | 263 | |
| `crc_unit` | 298 | |
| `branch_comparator` | 182 | |
| `control_unit` | 154 | |
| `address_decoder` | 124 | |
| `immediate_generator` | 92 | |
| `pc_incrementer` | 58 | |
| `ir_reg` | 32 | 32 flops |
| `pc_reg` | 30 | 30 flops — bits `[1:0]` correctly optimized away |
| `riscv_core` (glue) | 425 | |

Netlist: `top_generic_synth.v`. Cell report: `generic_synth_stat.txt`.

### Two synthesis-only failures found and fixed

Both were invisible in simulation and would only have surfaced in a physical
run, or not at all.

**1. The whole design was swept away as dead code.** `top`'s only external
pins are `clk_i`/`rst_i` (Block Guide §2.2 — mandatory, zero data I/O), so
Yosys's optimization passes correctly concluded that logic with no path to a
primary *output* is unobservable and removed all of it. This is a general risk
for any RTL-to-gate flow applied to a verification-only, zero-output design.
Fixed in the RTL (not only in the synthesis script, so it survives whichever
flow the design is eventually run through) with `(* keep *)` on the key
state-holding elements: `dmem`'s `mem` array, `register_file`'s `regs` array,
`pc_reg`'s `pc`, `ir_reg`'s `ir`, `control_unit`'s `state`/`next_state`, and
`sys_event_o` all the way up through `riscv_core` to `top`.

`sys_event_o` needs the same treatment as the state registers for a specific
reason: it is the firmware-completion event every integration testbench keys
on (§8.6/§15.4), it has no fanout at `top`, and nothing else anchors it — so a
flattening flow would delete it and make post-synthesis firmware verification
impossible.

**2. The instruction ROM was constant-folded to zero.** With an empty
`IMEM_INIT_FILE`, `imem`'s array elaborates as all zeros and synthesis folds
the entire ROM away: the synthesized module was literally
`assign data_o = 32'd0;`, reported 0 cells, and was excluded from every area
figure. A design built from that netlist fetches `0x00000000` forever — which
decodes as an illegal instruction and executes as a no-op — so it would have
run nothing at all, silently.

Two things were needed:

- **A real image, everywhere.** `imem.v`/`top.v` now default
  `IMEM_INIT_FILE` to the firmware image rather than `""`, and
  `chipinventor/openlane/config.json` sets it explicitly.
- **An initial block the tool can actually resolve.** Even with the right
  filename, a `$readmemh` wrapped in `if (INIT_FILE != "")` and preceded by a
  variable-index zero-fill loop is not statically resolvable at elaboration,
  so the array still ended up empty. `imem.v` now uses a bare, unconditional
  `initial $readmemh(INIT_FILE, rom);` under `` `ifdef SYNTHESIS ``, keeping
  the zero-fill and empty-file tolerance for simulation only.

`scripts/check_synth_stats.py` now fails the synthesis run if either memory
reports zero cells, so neither failure can silently reach a physical flow
again.

### A latch risk found and fixed earlier in development

`crc_unit.v`'s combinational block used two module-level scratch registers
(`bit_in`, `fb`) inside a conditional with no default assignment before the
loop — the "signal retains its previous value on some path" pattern that
defines an inferred latch, confirmed by `proc_dlatch` flagging both by name.
It caused no functional bug (the unit test passed 319/319 either way), but it
violated the project's own latch-avoidance discipline. That module has since
been restructured entirely (see below), and the current version has no
scratch state at all.

### CRC unit restructured to match Block Guide §3.1.3

The earlier implementation was a single 32-iteration loop with a *variable*
bit count, so each stage carried a 16-bit bypass mux and a variable bit-select
(579 of its 951 generic cells were muxes). Block Guide §3.1.3 describes the
unit as "three blocks, each of which performs the CRC with a part of the
inputs (8, 16 or 32 bits) and a multiplexer, which selects the final value" —
so it is now exactly that: three constant-bound unrolled XOR networks feeding
one output mux selected per Table 11.

Generic cell count dropped from 951 to **298** (−69%), and the structure now
matches the Block Guide's description directly. Mapped Sky130 area is
essentially unchanged (1,990.66 µm² vs 1,985.65 µm² before) — ABC had been
optimizing most of the bypass logic away already, so the win here is
structural clarity and shallower logic, not area. Verified functionally
identical: 319/319 vectors against the independent Python golden model, plus
the standard `0x29B1` check-value gate.

## Stage 3 — Sky130-liberty-mapped synthesis

`synth` → `dfflibmap -liberty sky130_fd_sc_hd__tt_025C_1v80.lib` →
`abc -liberty …` → `stat -liberty …`, mapping every cell to a real Sky130
standard cell.

**Total SoC cell area: 2,557,336.44 µm² (2.557 mm²).**

| Module | Area (µm²) | Share |
|---|---:|---:|
| `dmem` | 2,433,350.03 | 95.15% |
| `register_file` | 51,030.19 | 2.00% |
| `multiplier` | 49,258.49 | 1.93% |
| `imem` | 7,960.13 | 0.31% |
| `alu` | 5,676.69 | 0.22% |
| `riscv_core` (glue) | 2,285.94 | 0.09% |
| `crc_unit` | 1,990.66 | 0.08% |
| `ir_reg` | 1,084.79 | 0.04% |
| `pc_reg` | 1,014.72 | 0.04% |
| `lsu` | 927.14 | 0.04% |
| `branch_comparator` | 709.43 | 0.03% |
| `address_decoder` | 635.61 | 0.02% |
| `control_unit` | 628.10 | 0.02% |
| `pc_incrementer` | 412.90 | 0.02% |
| `immediate_generator` | 371.61 | 0.01% |
| **Total** | **2,557,336.44** | **100%** |

Note on reading this table: Yosys reports each module's *local* area,
excluding submodules, so the `top` line is 0.00 (it is pure structure) and the
design total is the sum of the rows. `scripts/area_report.py` does that
roll-up; it is also what produced the numbers above.

The flop count confirms where the area goes: 66,560 `edfxtp_1` (enabled D
flip-flop) instances — 65,536 for DMEM's 2048×32 bits, 992 for the register
file's 31 live registers, and 32 for `ir_reg`.

Warnings in this run are benign: 32 ABC liberty-parsing notices ("merged SCL
conversion failed, using liberty format", a known ABC fallback on Sky130's
scan-pin function expressions) and one Yosys note. None indicate a functional
or structural problem. Full list: `sky130_synth_report.log`. Netlist:
`top_sky130_synth.v`.

### DMEM as an SRAM macro — implemented, optional

DMEM is 95% of the behavioral design, so it is by a wide margin the highest-value
change available. `rtl/dmem.v` now carries **two realizations behind one
interface**:

- **Default** — the behavioral register array. Plain portable Verilog with no
  external dependencies; the file does not reference the macro at all unless
  the define is set. This is what builds on any flow or platform, including one
  that exposes no macro library.
- **`DMEM_USE_SRAM_MACRO`** — four `sky130_sram_2kbyte_1rw1r_32x512_8` OpenRAM
  macros banked on `address[12:11]` to cover the same 2048 × 32 window, with
  `bw_i[3:0]` driving each macro's `wmask0`. See `../macros/README.md`.

Measured, same configuration and same non-flattened synthesis both ways:

| | Behavioral array | 4 × SRAM macro | Change |
|---|---:|---:|---:|
| `dmem` | 2,433,350 µm² | 1,139,191 µm² | −53.2% |
| Rest of SoC | 123,986 µm² | 124,354 µm² | +0.3% |
| **Total** | **2,557,336 µm²** | **1,263,545 µm²** | **−50.6%** |
| Flip-flops | 66,560 | ~1,050 | −98% |

The flip-flop count matters more than the area for physical implementation:
65,536 of them existed only to hold DMEM. Removing them is what turns place and
route from a congested, slow run into a routine one. The die-area gain is also
larger than the cell-area gain implies, since a macro is a hard footprint while
standard cells are placed at some utilisation — 2.43 mm² of cells at 35%
utilisation needs roughly 6.9 mm² of core.

**Both realizations are verified.** The full suite passes either way
(`bash scripts/run_all.sh`, and again with `DMEM_MACRO=1`), and 20 randomized
programs match an independent instruction-set simulator in both modes.

Two deliberate behavioural differences, neither affecting the core:

1. **Power-up contents.** The behavioral array zero-fills for simulation
   determinism; a real SRAM powers up undefined, and the macro model reflects
   that. Firmware that reads `.bss` before initialising it would see zeros in
   one and garbage in the other — worth re-checking against the official
   validation firmware when it is released.
2. **Read-data arrival within the cycle.** The behavioral array presents read
   data at the capturing edge; the macro presents it part way through the
   following cycle. Both are valid before the next edge, which is where the
   register file samples load data.

Two integration details the banked design has to get right, both verified:
the output mux is selected by the **registered** bank (read data returns a
cycle after the address, so selecting on the current bank would return the
wrong macro's word), and it is a real select rather than an OR, because
deselected macros drive `x`.

Netlist: `top_sky130_synth_sram.v`. Cell report: `sky130_sram_stat.txt`.

## What this does and doesn't establish

**Established, with real tool output:**

- The RTL elaborates cleanly, with no missing or unresolved modules.
- The RTL is latch-free — checked in both the generic and Sky130-mapped
  netlists.
- The RTL is synthesizable end to end through ABC technology mapping against a
  real Sky130 library, with no synthesis errors.
- Both memories contain real cells in the netlist, gated automatically.
- A real (not estimated) pre-place-and-route cell area for the whole SoC.
- **The synthesized netlist is functionally equivalent to the RTL.**
  `tb_gatelevel` runs the RTL core and the synthesized core in lockstep
  against identical memory subsystems and compares the core's entire external
  interface every cycle: 900 cycles, bit-identical, zero mismatches. See
  `VERIFICATION_REPORT.md`.

**Not established here — established by the OpenLane flow instead:**

Everything below is outside the scope of logic synthesis. Each was answered by
the place-and-route flow; the figures are in
[`../chipinventor/openlane/RESULTS.md`](../chipinventor/openlane/RESULTS.md).

| Question | Where it is answered |
|---|---|
| Does the design close timing? | Setup **+2.25 ns** at the slow corner, 33 ns constraint |
| Placed-and-routed die area (Guide §5) | **630.2 × 640.9 µm = 0.404 mm²**, 52.3 % utilisation |
| DRC / LVS cleanliness | 0 Magic DRC, 0 KLayout DRC, LVS *circuits match uniquely* |
| Final GDSII and post-route GL netlist | `runs/platform_20260904/results/final/` |

Two caveats when comparing this report's numbers with those:

- The cell area here is **pre-placement** and for the full design; the P&R runs
  use the synthesis netlist the organiser specified (3-instruction mock ROM,
  `DMEM_WORDS = 8`).
- The critical-path guess above was close but not exact — signoff STA puts the
  path in the CRC unrolls and the multiplier together, preceded by repeater
  delay on high-fanout nets.
