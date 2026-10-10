# Stage 4 hand-off (read this first in a new session)

**Updated 2026-10-10 13:50.** Branch `stage4` (local only, not pushed). The mission is Nicholas's
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

## In progress (uncommitted, in the working tree)

`application/firmware/lane/main.c`: protocol **v4** started.
- Done: `#define PROTO 4`; new `advance(t)` (RFC 1982 serial-number time: `if ((int32_t)(t - now) > 0) now = t;`) used by `R` and `T` frames; dedup test now `(int32_t)(now - seen[s].t) < (int32_t)dedup_ms`.
- **The golden model (`application/testbench/lane_model.py`) is NOT yet updated**, so the regression fails until it is.

## Next, in order

1. Finish the approved P1 items **in lockstep** (model → `PROTOCOL.md` → firmware → directed test), regression after each:
   - **B1** model: `now` advance and guard/dedup with 32-bit modular arithmetic; directed test across the wrap (T near `0xFFFFFF00`, then small times).
   - **B2** hotlist add that finds no slot → `error(6, 0x48)` (`E` reason 6 "table full"); update the coverage bin.
   - **C1** key lock: once a key is loaded, any `K` → `error(7, 0x4B)`; empty `K` with no key = no-op. Coverage: replace "key cleared" with "key change refused". Directed scenarios that clear/replace keys must change (`directed_v3`).
   - **C2** `K` payload 16 (counter 0) or **20** bytes (key + u32 counter start); `frame_len_ok` 0x4B: 16, 20, 0.
   - **C3** with a key loaded, the `I` record is followed by an `A` (same `auth_message`, byte 1 of `I` = version): in `att_step` do `mac_flush(); seal(...); if (auth_on) mac_start(r); else push8(r);`.
   - **C5(a)** one more emu line in `emu_commands()`: load a key (`K`, 20 bytes) + one car → `-r4 -r4` reads the `A` record.
   - Protocol v4 everywhere: `lane_core.js` `authMessage` takes the version (3 for the Stage 3 transcripts in `docs/demo`, 4 new); `WHY[]` gains reasons 6 and 7; `PROTOCOL.md` v4.
   - Rebuild firmware; regenerate generated files (`lane_model.py`, `gen_ci_imem.py`, `gen_platform_tb.py`, `gen_emu_preview.py`) via their normal scripts, never by hand; full regression.
2. Phase 2 market research (I do it directly with WebSearch/WebFetch, small steps): partial files in `docs/stage4/research/` (A tolling, B silicon, C event, D diligence+ROI) → `docs/stage4/03_market.md`; pitch kit in `docs/stage4/pitch/`.
3. Write `docs/stage4/04_fpga_plan.md` → **GATE 2**.
4. Phase 3 (after GATE 2): clean `stage4-aws/` into `archive/`; generator → `riscv.sv`; pre-flight gate (Verilator lint with real `top.sv`, system sim with the real `top.sv` + **the organisers' real `emu.c` compiled against a simulated `fpga_pci_peek/poke`**, Yosys check, timing estimate, mutation tests) → `06_verification.md`; runbook `05_RUNBOOK.md` → **GATE 3**.

## Key facts to not re-derive (details in `01_aws_reference.md`)

- `top.sv` gives `RISCV` `clk_main_a0` = **250 MHz** directly; wrapper UARTs at 2,170 clocks/bit; `riscv_nreset` resets to 1.
- `emu`: 50 ms before every AXI access; each run sets `-d 0x01` then pulses RST 1/0/1; `-d` written uninverted (1 = chip output); `-t` polls `0x0C` bit 8 until 1 (**`o_Tx_Done` must be a sticky level**); `o_Rx_Done` must be a one-cycle pulse; `-r` reads a fixed 8-byte window from byte 0; exit status inverted (1 = success).
- Our chip module is named `top` → rename (`rvbl2_` prefix). Name our hierarchy `riscvtop.e_PROCESSOR.w_PC_Output` so `top.sv` needs **zero** edits.
- Sources cloned to the session scratchpad: organisers' Stage 4 repo `b748304`, Stage 3 repo `560947c` (`RVBL-Emulator/src/emu.c`). Re-clone if the scratchpad is gone.
