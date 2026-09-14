# OpenLane physical implementation

`config.json` in this directory is the configuration the ChampionCHIP submission is built
with. It has been run twice on the same pinned toolchain, once on the ChipInventor platform
and once locally, and both flows completed to a clean, signed-off GDSII.

| | |
|---|---|
| **`runs/platform_20260904/`** | **The deliverable.** Produced on the ChipInventor platform from `config.json`. |
| `runs/local_rvbl2_c/` | Local WSL/Docker reproduction. Reports only — this is where the configuration was tuned. |

Full numbers and the reasoning behind every setting are in [RESULTS.md](RESULTS.md).

## The environment, pinned from the platform's own log

| | Version |
|---|---|
| OpenLane | v1.1.1, commit `3876562d27af3f6825a823941b1cab36f7eb6dc3` |
| PDK | sky130A via Volare, `bdc9412b3e468c102d01b7cf6337be06ec6e9c9a` |
| Standard cells | `sky130_fd_sc_hd` (also the optimisation library) |
| Yosys | 0.38, `543faed9c8c` |
| Macros | none — pure standard cell, no SRAM macro |

Both hashes are content-addressed, so matching them means byte-identical cell libraries and
timing models. A byte-identical GDSII is *not* guaranteed on top of that — see the
instance-order result below for a concrete reason why — but the flows are directly
comparable, which is what the local reproduction is for.

## Entering the configuration on the platform

The platform reads `config.json` when the fields are **typed in**; pasting the file
wholesale does not take. Confirm it was applied by checking the run's own
`config_in.tcl`, which records every key the flow actually received, and by the floorplan
line in the log:

```text
[INFO]: Floorplanned with width 618.7 and height 617.44.
```

A square core of that size can only come from `FP_SIZING: relative` with
`FP_ASPECT_RATIO 1`. If the config had been ignored, the bundled `spm` example's
`DIE_AREA "0 0 34.5 57.12"` would apply instead — a 1,971 µm² box, about 64× too small for
this core — and detailed placement fails with `DPL-0036`.

Two variables appear in `config_in.tcl` that are **not** ours:
`TEST_POTENTIALLY_MALICIOUS_VARIABLE` and `TEST_EXTERNAL_GLOB`. They are the platform's own
config-parser fixtures, injected server-side. OpenLane ignores unknown keys, so they are
harmless, but do not be surprised to find them.

## What the config sets, and why

Every value here was chosen from a measured result, not a default.

| Setting | Value | Reason |
|---|---|---|
| `CLOCK_PORT` | `clk_i` | With no clock declared, `scripts/tcl_commands/cts.tcl` silently sets `RUN_CTS 0` and STA is vacuous |
| `CLOCK_PERIOD` | `33` | Tightest round value that closes; see RESULTS.md |
| `RUN_CTS` | `1` | The real knob. `CLOCK_TREE_SYNTH` **does not exist in OpenLane 1** and is silently ignored |
| `FP_SIZING` / `FP_CORE_UTIL` | `relative` / `50` | `DIE_AREA` is only read when sizing is `absolute` |
| `PL_TARGET_DENSITY` | `0.60` | OpenLane's own default relationship `(FP_CORE_UTIL + 10)/100`, valid because `GPL_CELL_PADDING` is 0 for `sky130_fd_sc_hd` |
| `PL_RANDOM_GLB_PLACEMENT` | `0` | Random placement does not legalise at this size |
| `FP_PDN_AUTO_ADJUST` | `1` | A fixed 25 µm pitch was chosen for a 34 µm die |
| `GRT_REPAIR_ANTENNAS` | `1` | Targeted repair — fixes real violations only |
| `RUN_HEURISTIC_DIODE_INSERTION` | `0` | Pre-emptive insertion adds ~9,800 diodes and costs 19.5 % of the die for no antenna benefit |
| `DIODE_ON_PORTS` | `"none"` | Set explicitly rather than via the deprecated `DIODE_INSERTION_STRATEGY` |

**OpenLane 1 does not validate its configuration.** An unrecognised key is silently
ignored, which is how `CLOCK_TREE_SYNTH` once sat in this file looking like it did
something. `run_openlane_local.sh` guards against a repeat: it parses `set ::env(...)` out
of OpenLane's own `configuration/*.tcl` and fails the run on any key not in that set.

## What to check when a run finishes

"Did it finish" is not the question, on two counts. This design has a **2-pin top**
(`clk_i`, `rst_i`, no outputs), so a synthesis sweep would leave an empty design that sails
through every later stage. And OpenLane does **not** fail a flow on a timing violation — it
will hand back a complete, DRC-clean, LVS-clean GDS that simply misses its clock.

| Stage | Check | Platform run |
|---|---|---|
| Synthesis | cell count | **17,708** — nothing was swept |
| Synthesis | flip-flop count | **1,393** — the real proof, see below |
| Synthesis | `Chip area for module '\top'` | 191,649 µm² |
| Floorplan | core from the log | **618.7 × 617.44 µm**, not 34.5 × 57.12 |
| Placement | no `DPL-0035` / `DPL-0036` | clean |
| CTS | clock tree on `clk_i` | built (step 15) |
| Routing | detailed routing violations | **0** |
| Signoff | Magic DRC / KLayout DRC | **0 / 0** |
| Signoff | Magic↔KLayout XOR | no differences |
| Signoff | LVS | **circuits match uniquely**, 19,544 devices |
| Signoff | residual antenna (`44-antenna_violators.rpt`) | 86 pins / 60 nets |
| STA | `report_worst_slack -max`, all 3 corners | **+2.25 ns** worst, at 33 ns |
| Final | `results/final/gds/top.gds` | 49 MB |

**The flop count is the check that actually matters** for the sweep risk. A raw cell count
can look healthy while the design has been gutted. 1,393 flops against an architectural
expectation of ~1,318 — register file 31×32 = 992, DMEM 8×32 = 256, PC 32, IR 32, plus FSM
state — accounts for every storage element.

**Never trust post-CTS slack.** It is single-corner with estimated parasitics, and on this
design it disagreed with signoff by more than 13 ns. Only the `*mcsta*` logs count.
`run_openlane_local.sh` reads them and fails the run on negative setup slack — a gate added
after an earlier run reported "all gates passed" at −4.29 ns.

## Instance order changes the result by 12 %

Worth knowing before comparing any two runs. The platform's generated `hdl.v` and this
directory's `src/top.v` are identical in every module body, in the top-level wire list, and
in the resolved OpenLane environment. They differ in exactly one thing: where the `imem`
block sits in the top module's instance list.

| | `src/top.v` | platform `hdl.v` |
|---|---|---|
| `imem` instance | `blk3661_6`, **5th** of 20 | `blk3661_26`, **20th** (last) |
| Pre-ABC cells | 17,073 | 19,080 |
| Mapped cells | 15,524 | 17,708 |
| Cell area | 171,332 µm² | 191,649 µm² |

Moving that one instantiation to the end of the file — changing no logic at all —
reproduces the platform's numbers exactly (19,080 pre-ABC, `$_XNOR_ 1386`, `$_XOR_ 3064`).
Yosys derives modules in instantiation order, which changes internal ID allocation, which
changes the visit order of order-sensitive passes (`opt_merge`, `share`, `fsm`,
`opt_muxtree`). The netlists are functionally equivalent; the optimiser simply lands
somewhere different.

Practical consequence: **the canvas block order is an area knob.** If the platform run needs
to be smaller, moving the ROM block earlier is worth roughly 11 % of cell area for free.
It also means a cell-count difference between two runs is not by itself evidence that the
RTL changed.

## If it does not close

- **Negative slack** — across the local series the required period was 32.36 ns whatever
  target was asked for, so raise `CLOCK_PERIOD` to just above the measured requirement;
  asking for more does not make it faster. The critical path is a deep XOR/XNOR chain in
  the CRC unrolls and the multiplier, preceded by repeater delay on high-fanout nets.
- **`GRT-0119` routing congestion** — check `RUN_HEURISTIC_DIODE_INSERTION` first. It adds
  ~9,800 diodes *after* the floorplan is sized and is the single biggest congestion driver
  here. Only then consider dropping `FP_CORE_UTIL`, keeping `PL_TARGET_DENSITY` at
  `(FP_CORE_UTIL + 10)/100`.
- **OOM** — set `ROUTING_CORES` in the environment, not the config
  (`ROUTING_CORES=8 bash scripts/run_openlane_local.sh`).
- **Antenna violations** — targeted repair leaves 60 residual violating nets on the
  submitted platform run (86 pins, worst ratio **8.69×** the 400 limit); the local
  reproduction leaves 39 nets at 4.19×. Enabling heuristic insertion does not reduce that and costs 19.5 %
  of the die. Try `DIODE_ON_PORTS: "in"` and re-measure before reaching for it.
- **Resizer slack margins do not help.** Raising `GLB_RESIZER_SETUP_SLACK_MARGIN` and
  `PL_RESIZER_SETUP_SLACK_MARGIN` to 3.0 ns changed the required period by exactly zero.
- **Never hand-edit `src/top.v`** — regenerate it, so the audit chain from the exported
  netlist through to P&R stays intact.

## Running it locally

OpenLane 1 runs inside Docker. On Windows that means WSL2 with systemd, so **Docker Engine
installs natively in the distro and Docker Desktop is not needed.**

```bash
bash ../scripts/setup_openlane_wsl.sh    # once; asks for sudo password
bash ../scripts/run_openlane_local.sh    # uses config.json and src/
```

Setup installs Docker Engine, clones OpenLane to `~/OpenLane` at the pinned commit, pulls
the matching image and PDK, **verifies the installed PDK hash is the platform's**, and
finishes with the bundled `spm` smoke test so any later failure is unambiguously ours. It
is idempotent. After Docker is first installed it stops and asks for `wsl --shutdown` from
PowerShell, because group membership is only read at login; that shutdown also picks up
`.wslconfig`, raising the WSL memory cap to 12 GB.

OpenLane lives under `$HOME`, deliberately **not** on `/mnt/c` — the 9p mount is roughly an
order of magnitude slower and a full flow writes tens of thousands of small files.

Useful options: `--tag NAME`, `--dry-run` to stage without running, and
`-- <flow.tcl args>` to pass anything else through. There are deliberately **no tuning
flags** — `config.json` is the deliverable, so it is the single place settings live.

## Regenerating `src/top.v`

It is generated, not hand-maintained:

```bash
python ../scripts/gen_pnr_netlist.py --dmem-words 8
```

That takes the exported `../top.v` and applies the two synthesis substitutions the
organiser specified: the 742-word firmware ROM becomes the 3-instruction mock, and
`DMEM_WORDS` drops to 8. The functional netlist is otherwise untouched, so the file the
testbench verifies and the file that gets taped out cannot drift apart.
`run_openlane_local.sh` refuses to run if `src/top.v` is older than `../top.v`.

## Viewing the layout

OpenROAD's GUI is the most informative view — placed and routed design with congestion,
placement-density and power-density heat maps:

```bash
cd ~/OpenLane
docker run --rm -v $HOME:$HOME -v $PWD:/openlane -v $HOME/.volare:$HOME/.volare \
  -e PDK_ROOT=$HOME/.volare -e PDK=sky130A -u $(id -u):$(id -g) \
  -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix --network host \
  efabless/openlane:3876562d27af3f6825a823941b1cab36f7eb6dc3-amd64 \
  sh -c "openroad -gui"
```

Then `File > Open DB` on a run's `results/routing/top.odb`. WSLg supplies the X display on
Windows 11 with no extra setup. If `~/.Xauthority` does not exist, create it first
(`touch ~/.Xauthority`) — Docker bind-mounts that path and will otherwise create a
*directory* there, which breaks the mount.

For a plain layout view, open `runs/platform_20260904/results/final/gds/top.gds` in KLayout.
