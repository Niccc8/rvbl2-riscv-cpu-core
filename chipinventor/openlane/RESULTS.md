# RVBL-2 place-and-route results

Two independent OpenLane flows on the same pinned toolchain — OpenLane `3876562d`,
sky130A `bdc9412b`, `sky130_fd_sc_hd`, Yosys `0.38 (543faed9c8c)`, no macros.

| | What it is | Where |
|---|---|---|
| **`runs/platform_20260904/`** | **The submitted signoff.** Run on the ChipInventor platform from `config.json` in this directory. | primary deliverable |
| `runs/local_rvbl2_c/` | Local WSL/Docker reproduction. Reports only — this is where the configuration was tuned. | methodology record |

Every number below is read out of a run directory. Nothing is estimated.

## The deliverable — `runs/platform_20260904/`

| | |
|---|---|
| Clock constraint | 33 ns → **30.303 MHz** reported |
| Die | **630.15 × 640.87 µm = 0.404 mm²** |
| Core | 618.70 × 617.44 µm (382,010 µm²) |
| Standard cells | **17,708** (1,393 flip-flops) |
| Cell area | 191,649 µm² |
| Final utilisation | 52.28 % |
| Wirelength / vias | 869,840 µm (0.87 m) / 151,445 |
| Antenna diodes | 516 |
| Total placed instances | 51,267 (incl. 17,132 decap, 8,940 fill, 5,381 well-tap) |
| Setup slack — min / nom / **max corner** | +3.83 / +3.08 / **+2.25 ns** |
| Hold slack, worst | +0.11 ns |
| Detailed routing violations | **0** |
| Magic DRC / KLayout DRC | **0 / 0** |
| Magic↔KLayout XOR | no differences |
| LVS | **circuits match uniquely** (19,544 devices, 19,302 nets) |
| Residual antenna | 86 pins / 60 nets |
| Runtime | 54 m 53 s |

The design closes with **2.25 ns to spare at the slow corner**, so it is not marginal.
That margin also means the reported 30.303 MHz is an artefact of the constraint, not the
limit: OpenLane clamps positive slack to zero before computing
`suggested_clock_frequency`, so the figure only ever echoes `CLOCK_PERIOD`. The design
demonstrably meets timing at ≈30.75 ns, i.e. **≈32.5 MHz**.

### What was synthesised, and why it is not the full memory map

Both reductions are the organiser's instruction for the synthesis run, and both are
visible in the run's own logs rather than only in our source:

| Reduction | Evidence in `runs/platform_20260904/` |
|---|---|
| `DMEM_WORDS = 8` (32 B, not the 8 kB window) | `logs/synthesis/1-synthesis.log` → `Parameter \DMEM_WORDS = 8`; `reports/synthesis/1-synthesis_pre.stat` → `$_DFFE_PP_ 256` (8 words × 32 bits) |
| 3-instruction mock ROM, not the 742-word firmware | the top-level `control_unit` instantiation sits at line 1109 of the synthesised source; the mock-ROM netlist puts it at 1114 and the full-firmware netlist at 1849 |

`DMEM_WORDS` is the documented resize knob in `dmem`'s own header, and the guard
`impl_sel = (word_addr < DMEM_WORDS)` keeps every address inside the architectural 8 kB
window well-defined — beyond the instantiated array it reads 0 and writes nothing, rather
than aliasing into a real word. Simulating the reduced configuration confirms the
organiser's choice is exactly right:

| `DMEM_WORDS` | Official validation firmware |
|---:|---|
| 1, 2, 4 | **FAIL** — `x4 = ffffffff`, branches to `_error` at `pc = 004003f4` |
| **8 (as built)** | **PASS** — `x4 = 00000000` |

The full 8 kB window would be 65,536 flip-flops and is not placeable in this area.

### Submitted RTL matches the taped-out design

The platform generates its own `hdl.v` from the block canvas, so it is worth proving
rather than assuming that it is our design. All seventeen blocks plus the top-level
wiring were diffed comment-stripped and whitespace-normalised against
`openlane/src/top.v`:

```
SAME  address_decoder   SAME  ir_fields        SAME  pc_incrementer
SAME  alu               SAME  ir_reg           SAME  pc_reg
SAME  branch_comparator SAME  lsu              SAME  register_file
SAME  control_unit      SAME  multiplier       SAME  wb_mux_32
SAME  crc_unit          SAME  mux2_32          SAME  dmem, imem
```

Top module: 41 wires, identical names, widths and order. The resolved `config.tcl`
differs from the local run's only in paths and timestamps.

## Local run series — how the configuration was chosen

Seven local runs established the settings in `config.json`. Their absolute cell counts are
smaller than the platform's (15,524 vs 17,708) for the reason explained below — instance
order, not a design difference — and their GDSII has been removed rather than kept as a
second, divergent physical result. The *relative* comparisons below are what they were for,
and those stand.

| Run | Period | Util | Heur. diodes | Die (µm) | Diodes | Setup min / nom / max | DRC | LVS |
|---|---:|---:|:--:|---|---:|---|:--:|:--:|
| `rvbl2_first` | 20 | 40 | on | 666 × 676 | 9,994 | −6.75 / −7.55 / **−8.35** | 0 | OK |
| `rvbl2_signoff` | 30 | 40 | on | 666 × 676 | 9,966 | −2.69 / −3.49 / **−4.29** | 0 | OK |
| `rvbl2_util50_FAILED` | 30 | 50 | on | 596 × 607 | 8,958 | flow failed, `GRT-0119` | — | — |
| `rvbl2_opt` | 30 | 50 | **off** | 596 × 607 | 325 | −0.87 / −1.61 / **−2.36** | 0 | OK |
| `rvbl2_b` | 32 | 50 | off | 596 × 607 | 325 | +1.13 / +0.39 / **−0.36** | 0 | OK |
| `rvbl2_c` | 33 | 50 | off | 596 × 607 | 325 | +2.13 / +1.39 / **+0.64** | 0 | OK |
| `rvbl2_a` | 38 | 50 | off | 596 × 607 | 325 | +7.13 / +6.39 / **+5.64** | 0 | OK |

Only `rvbl2_c`'s reports survive in `runs/local_rvbl2_c/`; the rest were deleted after
their numbers were recorded here.

### Why the local cell count is 12 % lower

The two flows differ in exactly one thing, and it is not logic. In the platform's generated
`hdl.v` the `imem` block is the **last** of the 20 top-level instances (`blk3661_26`); in
`src/top.v` it is the **5th** (`blk3661_6`). Everything else — all 17 module bodies, the
41-wire top-level net list, the resolved OpenLane environment, the Yosys build — is
identical.

Moving that single instantiation to the end of `src/top.v`, changing no logic whatsoever,
reproduces the platform's synthesis exactly:

| | `src/top.v` as-is | `imem` moved last | platform |
|---|---:|---:|---:|
| Pre-ABC cells | 17,073 | **19,080** | **19,080** |
| `$_XNOR_` / `$_XOR_` | 941 / 2,644 | **1,386 / 3,064** | **1,386 / 3,064** |
| Cell area (µm²) | 171,331.8 | **191,648.8** | **191,648.8** |

Yosys derives modules in instantiation order, which changes internal ID allocation, which
changes the visit order of order-sensitive passes (`opt_merge`, `share`, `fsm`,
`opt_muxtree`). The netlists are functionally equivalent; the optimiser simply lands
somewhere different.

Two consequences worth carrying forward:

- **Canvas block order is an area knob.** Moving the ROM block earlier is worth roughly
  11 % of cell area for free, at no functional cost.
- **A cell-count difference between two runs is not by itself evidence that the RTL
  changed.** It was nearly read as one here.

## The two findings that produced the configuration

### 1. Heuristic diode insertion was the dominant problem

`RUN_HEURISTIC_DIODE_INSERTION` pre-emptively places a diode on nearly every net. It
inserted **9,838 diodes** — a 63 % cell-count increase applied *after* the floorplan had
already been sized. Turning it off and letting `GRT_REPAIR_ANTENNAS` repair only real
violations gives **325 diodes**, and leaves exactly the same residual violating nets at
signoff. The 9,838 extra diodes bought no antenna improvement at all, and cost:

- **Area** — the util-50 floorplan became routable: 666 × 676 → 596 × 607 µm, −19.5 %.
- **Timing** — ≈1.9 ns at the slow corner, from ~22,500 µm² less cell area and less wire.
- **Robustness** — it is what turned the `GRT-0119` congestion failure into a clean route.

This is why `config.json` sets `RUN_HEURISTIC_DIODE_INSERTION: 0` and `DIODE_ON_PORTS:
"none"` explicitly, rather than relying on `DIODE_INSERTION_STRATEGY`.

### 2. Required period was stable across the local series

Within the local run series the critical path did not move with the constraint:

| Run | Period set | Slack (slow) | Required |
|---|---:|---:|---:|
| `rvbl2_opt` | 30 | −2.36 | 32.36 |
| `rvbl2_b` | 32 | −0.36 | 32.36 |
| `rvbl2_c` | 33 | +0.64 | 32.36 |
| `rvbl2_a` | 38 | +5.64 | 32.36 |

That is what fixed 33 ns as the tightest round value that closes, and it is the constraint
carried into `config.json`. The stability did *not* hold at util 40 with heuristic diodes,
where the required period tracked the target (20 ns needed 28.35; 30 ns needed 34.29)
because the resizer works only as hard as the constraint demands.

Note the platform run then closed the same 33 ns with **+2.25 ns**, not +0.64 — 1.6 ns of
placement-seed variation on the same configuration. Treat single-run slack as a sample,
not a property.

## Negative results worth recording

- **Resizer setup margin does nothing here.** Raising `GLB_RESIZER_SETUP_SLACK_MARGIN` and
  `PL_RESIZER_SETUP_SLACK_MARGIN` from 0.025/0.05 ns to 3.0 ns changed the required period
  by exactly zero.
- **`FP_CORE_UTIL 50` with heuristic diodes on fails** with `GRT-0119`. The die shrinks and
  placement legalises, but global routing cannot absorb ~9,000 extra cells.
- **Post-CTS single-corner slack is not predictive.** It disagreed with post-route
  multi-corner signoff by more than 13 ns on this design. Only signoff STA counts.

## Known warnings, and what they mean

Both flows emit the same set. None affects DRC, LVS or manufacturability.

- **Max-slew and max-fanout violations at the typical corner.** `MAX_FANOUT_CONSTRAINT`
  defaults to 10; the offenders are high-fanout control and operand-broadcast nets. Real
  signoff warnings, but not what limits f_max.
- **`VSRC_LOC_FILES` not set** — IR-drop analysis is approximate. Expected for a design
  that is not a top-level chip integration.
- **`PNR_SDC_FILE` / `SIGNOFF_SDC_FILE` not set** — the flow falls back to `BASE_SDC_FILE`.
  Both the platform and the local flow do this.
- **Residual antenna violations** (86 pins / 60 nets on the platform run; worst ratio
  **8.69×** the 400 limit, on met3). The local reproduction is smaller on every count
  — 69 pins, 39 nets, worst 4.19× — so quote the platform figures for the submission. Enabling heuristic diode insertion does not reduce them, so they
  are recorded rather than papered over.

## Reproducing

The platform run is reproduced by pasting `config.json` into the ChipInventor synthesis
configuration. To reproduce locally instead:

```bash
bash ../scripts/setup_openlane_wsl.sh      # once - Docker, OpenLane, pinned PDK
bash ../scripts/run_openlane_local.sh      # uses config.json and src/top.v
```

`config.json` in this directory is the exact configuration the platform read; see
`runs/platform_20260904/config_in.tcl` for the platform's own record of it.
