# RVBL-2 on ChipInventor

Everything needed to build this RISC-V core on ChipInventor, in one self-contained
directory. Nothing here reads anything outside this folder, and nothing outside it was
modified — the original file-driven flow in the repository root still works exactly as
it did and can be picked up unchanged.

**Phase 2 status: complete through GDSII.** The official validation firmware passes on this core
(`x4 = 0`), the design is entered on the platform, and the platform's own OpenLane flow has
produced a clean signed-off layout — 630.2 x 640.9 um, 0 DRC, LVS match uniquely, setup
+2.25 ns at the slow corner. See [openlane/RESULTS.md](openlane/RESULTS.md). The Phase 2
run of the checks, as graded:

```
=== 1/12  Official validation firmware is intact        OK   259 words, sha256 pinned
=== 2/12  Supplementary firmware image is current       OK   position-independent
=== 3/12  Generated ROM matches both firmware images    OK   742 words
=== 4/12  Testbench constants match the firmware        OK   8 values + 4 anchors
=== 5/12  Mirror equivalence vs the verified original   OK   410400 passed, 0 failed
=== 6/12  Combined suite against the local mirror       OK   15281 passed, 0 failed
=== 7/12  OFFICIAL VALIDATION FIRMWARE VERDICT          OK   x4 = 00000000  PASS
=== 8/12  Mock IMEM drives the core                     OK   x5=10, x6=5, x7=15
=== 9/12  Blocks free of unresolvable constructs        OK
=== 10/12 Schematic layout is clean                     OK
=== 11/12 Exported netlist matches the verified design  OK   graph-identical to ci_top.v
=== 12/12 Combined suite against the EXPORTED netlist   OK   15281 passed, x4 = 0
```

Steps 11 and 12 only run once `top.v` has been exported into this directory; before
that they skip. They are what turns "I wired 72 connections by hand" into a checked
claim — step 11 compares the export to `ci_top.v` as a graph, and step 12 runs the
whole suite against the netlist the canvas actually produced.

Re-run all of it with `bash scripts/run_ci.sh`. It needs `iverilog` and `python`.

The competition's criterion is step 7: the official firmware settles into its `all_good`
self-loop after 991 cycles with **`x4 = 0x00000000`**. `VALIDATION.md` records the full
audit against that firmware, including the one bug it found.

## Stage 3: GPIO and UART

Stage 3 adds a GPIO controller (`0xF0000000`) and a UART (`0xF1000000`, 8-N-1, 115200 bps)
as two canvas projects. **`rvbl2_soc`** is a copy of the graded Phase 2 project with
`imem` moved out and `gpio` and `uart` added; it is reused as IP inside **`top`**, the
chip, which adds `imem`, `gpio_bits` and eight 1-bit Inout Pins. `ci_top.v` mirrors both.

| To do | Where |
|---|---|
| The whole guide, with both schematics and tickable wire lists | `build/wiring_map.html` (from `scripts/gen_wiring_map.py`) |
| The 33 wires to draw on the Phase 2 copy (the address decoder is a new block), then the 34 wires of `top` | `NETLIST.md` |
| Form fields for `gpio`, `uart`, `gpio_bits` and the changed `address_decoder` | `BLOCK_METADATA.md` |
| Schematics (amber = new in Stage 3) | `build/schematic*.svg`, `build/schematic_top*.svg` |

Export `top` with the BLOCKS button, save it here as **`export_stage3.v`**, and run
`bash scripts/run_ci.sh`: steps 14 and 15 audit it wire by wire (both projects, every
Inout Pin's C/D polarity, the parameters) and run the whole testbench on it. Until the
export exists, step 13 runs the same tools on a mock export in the platform's own format
and on ten deliberately broken copies of it. The Phase 2 export `top.v` is kept as it was.

```
=== 6/16  Mirror equivalence vs the frozen Phase 2 core  OK   470400 passed, 0 failed
=== 7/16  Combined suite against the local mirror        OK   15517 passed, 0 failed
=== 8/16  OFFICIAL VALIDATION FIRMWARE VERDICT           OK   x4 = 00000000  PASS
=== 13/16 Export tooling proven on a mock export         OK   13 passed; dry run 15517 passed
=== 16/16 Application ROM and its platform testbench     OK   3 runs, on the mirror and the export
```

**Running on the platform.** ChipInventor stops a simulation after a fixed wall-clock time,
so the long testbenches run in parts. Paste the file, set the parameter, run, repeat:

| ROM in `imem` | Testbench | Parameter |
|---|---|---|
| `blocks/imem.v` (validation) | `build/tb_platform.v` (the export's instance names; written by `run_ci.sh`) | `PART` = 1, 2, 3, 4 |
| `app/imem_app.v` (application) | `build/tb_app_platform.v` (written by `run_ci.sh`) | `SCEN` = 0, 1, 2 |
| `../official-firmware-testbench/imem_official.v` | `../official-firmware-testbench/tb_official_firmware.v` | — |

`blocks/crc_unit.v` is the Phase 2 CRC written as byte updates: the same function (proved
equal on every input by `scripts/gen_crc_xor.py --prove`, step 6), about 2.7 times faster
to simulate, which is what lets these runs fit.

The repository-root flow adds the two checks this directory cannot make on its own:
`blocks/` and `firmware/stage3/` still match `rtl/` and `tests/progs/stage3/`, and
`ci_top.v` runs cycle-identical to `rtl/` on all seven ROM programs (`tb/tb_ci_equiv.v`).

---

## What is here

| Path | What it is |
|---|---|
| `blocks/` | 21 files, each the exact text to paste into a block's Code field |
| `BLOCK_METADATA.md` | The rest of each block's form fields, generated from the source |
| `NETLIST.md` | Stage 3: the edits to the Phase 2 copy, then every wire of both projects |
| `VALIDATION.md` | What was checked against the official firmware, and what it proved |
| `ci_top.v` | Local mirror of the two projects the canvas will generate — **not pasted anywhere** |
| `tb_chipinventor.v` | The one combined testbench, pasted into the platform's testbench field |
| `firmware/` | The official validation firmware, our supplementary program, and their inputs |
| `app/` | The application on the canvas: its ROM (`imem_app.v`) and platform testbenches |
| `rtl_ref/` | Frozen copy of the verified original, used only by the equivalence check |
| `scripts/` | Generators and the local verification runner |

## What is in the ROM

Two programs, because a fixed case-ROM cannot be swapped between tests:

```
word   0..258   official validation firmware   0x00400000..0x00400408   VERDICT: x4
word 259..511   gap, reads back 32'h0, never fetched
word 512..994   supplementary coverage program 0x00400800..0x00400F88
```

The official firmware **cannot be relocated** — it derives its `.bss` base from the PC
(`auipc s0, 0xfc10` at `0x0040011C` gives `0x10010000`, which is `DMEM_BASE`) — so it owns
the reset vector. Our program is position-independent and was placed above it; it is what
covers FENCE, ECALL, EBREAK, illegal instructions, misaligned access and the 58 instruction
signatures, none of which the official firmware reaches.

## The order to do things in (Phase 2)

This is the Phase 2 procedure for the core alone, kept as it was graded; its counts (20
instances, 72 connections, 15,281 checks) are Phase 2's. For Stage 3, follow
[Stage 3: GPIO and UART](#stage-3-gpio-and-uart) above: two projects, and the suite runs as
`PART` 1–4 on the platform.

**1. Smoke-test the paste path first.** Create one block — `alu` — before anything else.
Fill in the fields from `BLOCK_METADATA.md`, paste `blocks/alu.v` into the Code field,
save. If the platform accepts it and renders the block, the remaining 16 are mechanical.
If it does not, you have found that out after five minutes rather than after an hour.

**2. Create the other 16 blocks.** `BLOCK_METADATA.md` has each one's fields. The Code
files need no editing, trimming or reformatting first. (`blocks/imem_mock.v` is the
eighteenth file but not an eighteenth block — it is an alternative Code field for `imem`,
used at step 8.)

**3. Place the 20 instances and add the two input pins.** Name the pins exactly `clk_i`
and `rst_i`. Set `dmem`'s `DMEM_WORDS` parameter to 2048 on its instance.

**4. Draw the 72 connections** from `NETLIST.md`, ticking as you go.

**5. Export the project** (the BLOCKS button) and save the generated `top.v` into this
directory, then run `bash scripts/run_ci.sh`. Steps 11 and 12 now activate: they audit the
export against `ci_top.v` and run the whole suite on it. **Do this before pasting anything**
— a mis-wire is found here in seconds rather than as a puzzling failure on the platform.

**6. Paste `build/tb_platform.v` (generated by `scripts/run_ci.sh`; `build/` is not committed)**, which step 12 just produced and ran. It is
`tb_chipinventor.v` with its alias block rewritten for this export's instance names:

```bash
# what step 12 does, if you want it separately
cp tb_chipinventor.v build/tb_platform.v
python scripts/gen_ci_aliases.py top.v --write build/tb_platform.v
```

Re-aliasing is necessary because the platform names instances automatically
(`blk3658_25` and similar) and those names change on **every** regeneration — the example
project's own exported netlist and its own testbench already disagree about them. Paste the
re-aliased copy, not `tb_chipinventor.v` itself, so the local checks keep working.

**7. Run it** on the platform. Expect `ALL TESTS PASSED` with 15,281 checks, and this in
the log:

```text
-- SUITE 2A: OFFICIAL VALIDATION FIRMWARE --------------------
  Firmware settled after 991 cycles at pc=004003ec (all_good)
  *  OFFICIAL VALIDATION FIRMWARE: x4 = 00000000  PASS  *
```

That line is the competition's own criterion. If it reads `x4 = FFFFFFFF`, the suite prints
the PC the run branched to `_error` from and names the failing subtest — read that before
anything else.

**8. Swap in the mock ROM for synthesis.** Open the `imem` block and paste
`blocks/imem_mock.v` over its Code field. The ports and the module name are identical, so
nothing on the canvas moves. This is the firmware repository's own advice: the full ROM is
742 words and "a large `case` block can generate unnecessary cells". Paste `blocks/imem.v`
back before running the testbench again.

**9. Synthesise, and check the cell count is not zero.** See "If the design disappears"
below.

---

## Things that will bite you

### The canvas cannot slice a bus

Every connection the platform generates is a whole bus of exactly matching width — there
is not a single `[` or `{` in any port connection of the exported example project. That
is why the example needed a whole block, `PC_TARGET_ALIGN`, just to force bit 0 to zero.

Two consequences here, both already handled:

- `ir_fields` exists solely to extract `rs1`/`rs2`/`rd` from the instruction, because
  `ir[19:15]` cannot be drawn as a wire.
- `funct3` is **not** extracted anywhere. `control_unit` already publishes it as
  `op_size`, so `branch_comparator`, `multiplier`, `crc_unit` and `lsu` all take that one
  output. One source, no chance of two copies disagreeing.

### `lsu`'s port names read backwards

`mem_data_o` is an **input**. `core_data_i` is an **output**. The names date from the
original design and were kept so the block stays byte-identical to the verified version,
but they are the easiest thing on the whole canvas to mis-wire.

### `` `define `` leaks between blocks

The platform concatenates every block's source into one file, so a `` `define `` in one
block is visible to all the others — the example project's ALU defines `c_ALU_OP_PASS_B`
at file scope for the whole design. Every block here uses `localparam` instead, which is
scoped to its own module. Keep it that way if you add blocks.

### The platform drops `(* keep *)` from port declarations

Confirmed on a real export: attributes on **port** declarations do not survive, because the
Add Block form rebuilds the module header from its own Inputs/Outputs fields. Attributes on
**internal** declarations do survive.

So `control_unit`'s `sys_event_o`, `ir_reg`'s `ir` and `pc_reg`'s `pc` lose theirs, while
`dmem.mem`, `register_file.regs` and `control_unit.state` keep theirs. That is the harmless
half: the kept storage arrays anchor the whole datapath, since everything feeding a kept
register survives with it. `sys_event_o` is an unconnected debug pulse and may be optimised
away in synthesis — it is still present in simulation, which is where the suite checks it.
`scripts/check_export.py` reports these as notes rather than failures for this reason.

### If the design disappears at synthesis

`top` has only `clk_i` and `rst_i`, because Block Guide Table 5 mandates exactly those two
pins. Nothing is reachable from a primary output, and a synthesis flow that removes logic
with no path to one will delete **the entire design** — confirmed directly with Yosys
during this project, which reported 0 cells. The example project's five debug output pins
may well exist for exactly this reason.

The defence already in place is `(* keep *)` on the storage arrays and state registers.
**After the first synthesis run, check the reported cell count.** If it is zero or
implausibly small, add exactly one 1-bit output pin, `o_Sys_Event`, wired to
`u_ctrl.sys_event_o` — which is independently justified as the Submission Guide §6
firmware-completion marker — and nothing more.

### The CRC operands are not in the order you would guess

`crc_unit`'s `rs1_data` is the **data** and `rs2_data` is the **running CRC** — that is the
order the official firmware uses (`crcb s0, s1, s0` folds the byte in `s1` into the
accumulator in `s0`). Wire them straight through in the usual rs1/rs2 positions and do not
"correct" them. `VALIDATION.md` has the full story; it was the one bug the official firmware
found, and it is invisible to a check-value test because both orders are valid CRC-16
computations.

### DMEM is the thing most likely to make P&R painful

At `DMEM_WORDS = 2048` (the full 8 kB) the array is 65,536 flip-flops, measured locally at
2.43 mm² in Sky130 — about 95% of total cell area. If place-and-route cannot absorb that,
change the parameter to 1024 or 512 on the `dmem` instance. Nothing else changes and no
rewiring is needed: the block reads back 0 and writes nothing above the instantiated
array, which Block Guide §4.3 explicitly permits ("a 256-byte memory contains 64 words").

The official validation firmware settles how far this can go: it touches **28 bytes**
(`0x10010000`–`0x1001001B`, DMEM words 0–6). So the functional floor for passing validation
is 8 words, not a guess. Keep 2048 for the Block Guide's sake and for the supplementary
program's 58 signatures at `0x10010100`; shrink only if P&R forces it, and re-run the suite
if you do.

Worth checking whether the platform's shared block library exposes an SRAM macro. Swapping
the flip-flop array for one halved total area locally.

### The platform's synthesis configuration must be typed in, not pasted

Pasting `config.json` into the platform's configuration field does not take: the run then
falls back to the bundled `spm` example's config, which hardcodes
`DIE_AREA: "0 0 34.5 57.12"` — a 1,971 µm² box for a core that needs ~190,000 µm². Detailed
placement fails with `DPL-0036` every time and no RTL change can help.

Entering the fields manually works. Confirm it took by reading the run's own
`config_in.tcl`, and by the floorplan line in the log — a square core of ~618 µm can only
come from `FP_SIZING: relative`.

`openlane/` also carries a local reproduction of the same flow — identical OpenLane commit
and PDK hash, pinned from the platform's log, run through WSL2. One-time setup with
`scripts/setup_openlane_wsl.sh`, then `scripts/run_openlane_local.sh` per run. See
[openlane/README.md](openlane/README.md) and [openlane/RESULTS.md](openlane/RESULTS.md).

Worth knowing from the early failed runs: they reached detailed placement with ~30k
instances, which proves synthesis did **not** sweep the design despite the two-pin top. The
`(* keep *)` attributes are doing their job and no escape pin is needed.

---

## What changed from the file-driven design, and why

The blocks are the verified RTL. Twelve of the seventeen are byte-identical copies. The
rest changed only where the platform forced it:

| Change | Why |
|---|---|
| `imem` is a generated `case` ROM, not `$readmemh` | No filesystem on the platform |
| `dmem` lost its `` `ifdef `` macro branch | No way to pass a define; an unresolved `` `ifdef `` leaves the block with no storage |
| `dmem` lost its zero-fill `initial` block | It would reach synthesis and attach init values to 65,536 flip-flops that deliberately have no reset network. The testbench zeroes the array instead |
| `riscv_core`'s inline logic became `mux2_32` ×4, `wb_mux_32`, `ir_fields` | A project canvas holds no logic of its own |
| The hierarchy is flat | The platform generates exactly one level below `top` |
| Sixteen testbenches became one | The platform runs testbenches only at project level |
| Golden vector files became inline reference functions | No filesystem; also sweeps wider than the fixed vector sets did |
| `tb_core`/`tb_soc` programs merged into the one image | A fixed ROM cannot be swapped between tests |
| The ROM holds two programs, ours relocated to `0x00400800` | The official firmware is position-dependent and owns the reset vector |
| Completion is detected by the PC settling into a self-loop | The official firmware ends with `j .`, not `ecall`/`ebreak` |
| `crc_unit`'s operands swapped | The official firmware puts data in rs1 and the accumulator in rs2 — see `VALIDATION.md` |

`scripts/gen_ci_firmware.py` appends two things to the upstream program that would
otherwise have been lost with `tb_soc`: a **load from IMEM**, which is the timing case the
datapath was specifically designed around (IMEM is combinational with no output register,
so the load only works because `oe_o` and the address mux stay asserted through
WRITEBACK), and a **dependent-register loop**. Both are spliced in before the final
`ecall`, so every address the upstream generator computed is untouched.

## Verification coverage

15,517 checks in one file in Stage 3 (15,281 in Phase 2, against a baseline of 8,285 across
sixteen files). On the platform it runs as `PART` 1–4; the parts total 15,523, because parts
2–4 each end with the same 3 pin and line monitor checks.

| Suite | Covers | Checks |
|---|---|---:|
| 0 | Every block standalone: ALU, branch comparator, immediate generator, multiplier, CRC, LSU, address decoder, register file, IMEM, DMEM, and the three new glue blocks | ~9,900 |
| 1 | Control FSM: 704 `{opcode, funct3, funct7}` encodings, transitions, cycle counts, `sys_event_o`, mid-instruction reset abort, every mux select | ~1,500 |
| **2A** | **The official validation firmware, from reset. Verdict `x4 == 0`, both exit loops, and its six DMEM words checked independently of the branches it used to check them** | ~10 |
| 2B | Our supplementary program: 58 instruction signatures, JAL/JALR/AUIPC/FENCE/EBREAK, load-from-IMEM, dependent loop | ~80 |
| 3 | Reset injected at 40 points, then **both** programs re-run to completion — the official one back to `x4 == 0` | ~3,700 |
| **4** | **Stage 3 peripherals**: `gpio`, `uart` and `gpio_bits` alone, then on the chip: the Block Guide's Figure 1 tri-state on all 8 pins, its GPIO and echo listings, the echo with the far end 2 % slow and 2 % fast, a 24-check register program, and pin and line monitors over the whole run | 219 |

The one thing not carried over is gate-level equivalence (901 checks). It co-simulated the
RTL against a locally synthesised netlist; the platform runs its own synthesis and exposes
no netlist to the testbench field. It still runs in the root flow, and passed after the CRC
fix.

`scripts/tb_mirror_equiv.v` now compares the two designs over **both** programs — 470,400
cycle-by-cycle comparisons in Stage 3 (410,400 in Phase 2), zero mismatches. Phase 1 (the official firmware) covers every
RV32I instruction, all four multiplies and all three CRC widths; phase 2 covers FENCE,
ECALL, EBREAK, illegal instructions and misaligned access, which the official firmware
never reaches.

**`ci_top.v` is what makes any of this trustworthy.** It is a hand-written copy of the
structure the canvas will generate — same 20 instances, same 45 nets, no hierarchy — and
the mirror check runs it against the frozen original in lockstep, comparing PC, IR, FSM
state, all 32 GPRs and the full memory interface every cycle. The flattening, the three new
glue blocks, the `op_size` rewiring and the generated ROM are therefore proven faithful
before anything reaches the platform.

## Regenerating

```bash
python scripts/gen_validation_hex.py # firmware/validation_firmware.hex (checksum-pinned)
python scripts/gen_ci_firmware.py    # firmware/ci_prog.{s,hex,lst} + expected values
python scripts/gen_ci_imem.py        # blocks/imem.v + build/rom_image.hex from both images
python scripts/gen_docs.py           # NETLIST.md and BLOCK_METADATA.md
bash   scripts/run_ci.sh             # verify everything
```

If you change the supplementary firmware, run the middle two and then copy the constants
from `firmware/ci_prog_expected.vh` into the `localparam` block near the top of
`tb_chipinventor.v`. Step 4 of `run_ci.sh` fails the run if you forget.

If the organisers publish an amended `firmware.txt`, step 1 fails on the checksum. Diff the
new file against `firmware/validation_firmware.txt` and re-read `VALIDATION.md` before
updating `SRC_SHA256` — the point of the pin is to force that reading, not to be bumped.
