# Stage 4 hand-off (read this first in a new session)

**Updated 2026-10-10 14:30.** Branch `stage4` (local only, not pushed). The mission is Nicholas's
Stage 4 prompt: harden LaneX, build the pitch intelligence, ship a first-try-correct AWS F2 build.
Gates: GATE 1 (audit scope) **passed**; GATE 2 (go for the FPGA build) and GATE 3 (go/no-go) pending.

## Working rules learned the hard way

- **Sessions die when a turn runs long.** Never use background jobs or subagents for long work:
  they are killed at session end. Keep each tool call under ~5 minutes; save to disk after every step.
- `scripts/run_all.sh` takes ~10 min: run its sections separately (see `build/stage4_baseline/`),
  the application suites in parallel in one foreground call (~5 min).
- Windows Git Bash mangles backslashes in heredocs: use the Edit tool, or a Python script file.
- Commits: author Nicholas only, never a co-author line; explicit paths; never push without asking.
- WSL Ubuntu-24.04 has Verilator 5.020, Yosys 0.33 and gcc (for compiling the organisers' `emu.c`
  against a simulated FPGA). Windows has iverilog 12 and xPack RISC-V GCC 13.2 (`~/tools`).

## Done

| Step | Result | Where |
|---|---|---|
| Phase 0: ground truth | AWS guide, organisers' Stage 4 repo (`top.sv`), `emu.c` read; discrepancy table (14 items) | `docs/stage4/01_aws_reference.md` (commit `566ad68`) |
| Baseline | Official 34/34 + emu 4/4; `run_all` 31/31; `run_ci` 15,517 checks; all green | `build/stage4_baseline/*.log` |
| Phase 1 audit | Findings A1–A8, B1–B6, C1–C6, D1–D4, lean, standards, ten sceptic questions | `docs/stage4/02_audit.md` (commit `b18a1db`) |
| GATE 1 | Approved: **B1, B2, C1, C2, C3, C5(a)** + all P0 | — |
| Clock decision (A1) | Nicholas asked to slow the clock "on the FPGA side, not inside the RISC-V". Agreed design: **a thin FPGA-only shell module `RISCV` in `riscv.sv`** holds the clock divider (MMCM or BUFGCE_DIV), reset sync, `Transmitter`/`Receiver`, and the **unchanged** core as `e_PROCESSOR`. `top.sv` stays byte-identical. Present line by line in `04_fpga_plan.md` at GATE 2 | — |

## Session 2 (2026-10-10 afternoon)

- **P1 items B1, B2, C1, C2, C3, C5(a) implemented in lockstep** (model -> PROTOCOL.md v4 -> firmware ->
  directed tests -> lane_core.js), firmware 2,799 words. Results: directed **103/103**, smoke 18/18,
  showcase 30/30, fast 30/30, fuzz **262/262**, platform tb 26/26, emu preview **12/12**, page logic
  182/182, official 34/34 + 4/4, coverage **40/40** bins; random (127 keyed vehicles, counter crossing
  2^32) was still running at the time of writing: check `build/app_random.log`.
- **Harness fix (justified):** `gen_emu_preview.py` kept the *first* 8 bytes; the organisers' `top.sv`
  FIFO is circular (6-bit walker += 8), so the window holds the *last* 8. Preview now models that and
  reads once the line is quiet (emu waits 50 ms). Found by the new authenticated emu line.
- **Research:** `research/A` (MLFF status, TNG Titan Flow = our architecture), `B` (SkyeChip IPO,
  Arm deal, RISC-V forecasts), `C` (MSRD 14-17 Oct 2026 KLCC, ASEM, inside SIBS; judging NOT public),
  `D` (ETC market, Kapsch comparable, ROI model `docs/stage4/roi_model.py`: break-even 3.8 sen per RM100).
- **`04_fpga_plan.md` written** (MMCM /8 -> 31.25 MHz inside `RISCV`, top.sv byte-identical, UART 271
  clocks/bit, generator rules, CDC table, pre-flight G1-G8, risks) -> **GATE 2 PASSED (14:35): approved as written (MMCM); build before 13 Oct, so Phase 3 before the pitch kit; the organisers' echo test line need NOT pass on our build.**
- Organisers' repos re-cloned to the session scratchpad `ext/s4`, `ext/s3` (unchanged: b748304, 560947c).
- Local `aws_fpga_example/` is the OLD Stage 3 example (top.sv sha 3e6b...), not Stage 4's.

## Next, in order

1. If random passed: commit the v4 work (explicit paths; no co-author line).
2. GATE 2 answer -> Phase 3 per `04_fpga_plan.md` §9.
3. `03_market.md` (synthesise research A-D) and the pitch kit in `docs/stage4/pitch/`.
4. Refresh `docs/demo/index.html` (still the Stage 3 v3 snapshot) only after `run_ci.sh` produces v4 transcripts.

## Key facts to not re-derive (details in `01_aws_reference.md`)

- `top.sv` gives `RISCV` `clk_main_a0` = **250 MHz** directly; wrapper UARTs at 2,170 clocks/bit; `riscv_nreset` resets to 1.
- `emu`: 50 ms before every AXI access; each run sets `-d 0x01` then pulses RST 1/0/1; `-d` written uninverted (1 = chip output); `-t` polls `0x0C` bit 8 until 1 (**`o_Tx_Done` must be a sticky level**); `o_Rx_Done` must be a one-cycle pulse; `-r` reads a fixed 8-byte window from byte 0; exit status inverted (1 = success).
- Our chip module is named `top` → rename (`rvbl2_` prefix). Name our hierarchy `riscvtop.e_PROCESSOR.w_PC_Output` so `top.sv` needs **zero** edits.
- Sources cloned to the session scratchpad: organisers' Stage 4 repo `b748304`, Stage 3 repo `560947c` (`RVBL-Emulator/src/emu.c`). Re-clone if the scratchpad is gone.
