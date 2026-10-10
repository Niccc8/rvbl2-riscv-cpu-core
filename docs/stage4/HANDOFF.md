# Stage 4 state (read this first in a new session)

**Updated 2026-10-10.** Branch `stage4` (local, not pushed). Mission: harden LaneX, build the pitch
intelligence, ship a first-try-correct AWS F2 build. **GATE 1 and 2 passed; GATE 3 verdict GO (re-confirmed
after the 31.25 MHz change: pre-flight GO, full regression green).**
**AWS build done 2026-10-10: `afi-0732c3cb90c96019a` / `agfi-0c12a9e5d082dcac8`** (0 errors; setup WNS −0.112 ns on
the pin-synchroniser crossing only, hold met; `06` §1b). Next: runbook §3, load and the bring-up ladder.

## Where everything is

| What | Where |
| --- | --- |
| AWS ground truth (guide PDF, organisers' `top.sv`, `emu.c`) | `01_aws_reference.md` |
| Audit, its approved scope and outcome | `02_audit.md` (§J outcome) |
| Market, event, ROI | `03_market.md`, `research/A–D`, `roi_model.py` |
| FPGA design (as built) | `04_fpga_plan.md` |
| **Runbook for the AWS session** | **`05_RUNBOOK.md`** |
| Verification evidence | `06_verification.md` |
| MAX 10 (DE10-Lite) prototype scope | `07_max10_prototype.md` (not built; awaiting Nicholas) |
| Pitch kit | `pitch/01–05` |
| Build files | `stage4/riscv.sv` (31.25 MHz, the build), `riscv_15mhz.sv`, `riscv_bufgce_div.sv` (backups) |
| Generator, gate | `scripts/stage4/gen_riscv_sv.py`, `scripts/stage4/preflight.sh` |
| Organisers' files (not in git) | `stage4/vendor/` (fetch: `stage4/README.md`) |

## Decisions (and why)

- GATE 1: approved B1, B2, C1, C2, C3, C5(a) + all P0 (`02_audit.md`).
- GATE 2: MMCM divider inside `RISCV`, `top.sv` unchanged; build before 13 Oct; the organisers'
  echo test line need not pass on our firmware.
- Clock 31.25 MHz (÷8), Nicholas's preference and the ASIC's own clock; estimated path 11–18 ns of
  32 ns; 15.625 MHz kept as a pre-verified backup.
- Firmware: the vehicle detector arms once the lane is seen empty (emu's start-up window floats
  pin 0; without this a pin read as 1 made phantom vehicles).

## Working rules learned the hard way

- Sessions end without warning: keep tool calls < ~5 min; launch long jobs with `nohup … &` on the
  Windows side (they survive); WSL jobs started from a background Git Bash also survive.
- `wsl.exe -- bash -lc "…"` re-parses the command in a shell: pass absolute paths, no `$VARS` meant
  for the inner shell. Git Bash heredocs mangle backslashes: write patch scripts with the Write tool.
- Never edit a running bash script (bash reads it incrementally).
- Commits: author Nicholas only, no co-author line; explicit paths; never push without asking.
- Tools: Windows — iverilog 12, xPack RISC-V GCC 13.2 (`~/tools`, `python3` shim in `~/tools/bin`);
  WSL Ubuntu-24.04 — Verilator 5.020, Yosys 0.33, gcc. No Quartus or Vivado on this machine.

## Key facts not to re-derive

- `top.sv` gives `RISCV` `clk_main_a0` = 250 MHz; wrapper UARTs 2,170 clocks/bit; `riscv_nreset`
  resets to 1. emu: 50 ms before every AXI access; each run sets `-d 0x01`, pulses RST 1/0/1;
  `-d` uninverted (1 = chip output); `-t` polls `0x0C` bit 8 (sticky `o_Tx_Done`); `o_Rx_Done` a
  one-cycle pulse; `-r` reads the circular 8-byte window (the last 8 bytes); exit status inverted.
- Firmware 2,793 words; `I` record CRC `0x56DE`; PC range `0x00400000–0x00402BA4`.
- The ChipInventor platform export still holds the Stage 3 (v3) ROM (`chipinventor/app/imem_app_stage3.v`);
  `run_ci.sh` swaps the v4 ROM in for its tests.
