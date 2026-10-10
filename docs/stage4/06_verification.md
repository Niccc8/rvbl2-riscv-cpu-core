# Stage 4 verification: evidence for the AWS F2 build

**Build file:** `stage4/riscv.sv` (generated; MMCM ÷8 → 31.25 MHz; UART 271 clocks/bit; ROM 2,793
words, `I` CRC `0x56DE`). **Backups:** `stage4/riscv_15mhz.sv` (MMCM ÷16, 15.625 MHz) and
`stage4/riscv_bufgce_div.sv` (BUFGCE_DIV ÷8, 31.25 MHz). **Partner file:** the organisers' `top.sv`,
byte-for-byte (sha256 `0fd73910…`). Everything here ran locally; no AWS credit or synthesis hour
was used.

## 1. Pre-flight gate (`bash scripts/stage4/preflight.sh`)

```text
Stage 4 pre-flight, 2026-10-10 17:43, commit 30bc470

PASS  G1  riscv.sv, riscv_15mhz.sv and riscv_bufgce_div.sv are current (regenerated from rtl/ + firmware.hex)
PASS  G1  ROM bit-identical to firmware.hex; no $readmemh/`timescale/`define/initial; module names safe
PASS  G1  organisers' top.sv (0fd7391018a38aeeaef7...) and emu.c (31e4ca7c3d4c4f08dd89...) unchanged
PASS  G2  Verilator -sv -Wall, riscv.sv + real top.sv: 0 errors, only waived rtl/ warnings
PASS  G2  Verilator -sv -Wall, riscv_15mhz.sv + real top.sv: 0 errors, only waived rtl/ warnings
PASS  G2  Verilator -sv -Wall, riscv_bufgce_div.sv + real top.sv: 0 errors, only waived rtl/ warnings
PASS  G3  riscv.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at 0.1x emu waits: ==== emu_sys: 15 passed, 0 failed, 4.650 s simulated ====
PASS  G3  riscv_15mhz.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at 0.1x emu waits: ==== emu_sys: 15 passed, 0 failed, 4.650 s simulated ====
PASS  G3  riscv_bufgce_div.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at 0.1x emu waits: ==== emu_sys: 15 passed, 0 failed, 4.650 s simulated ====
PASS  G4  emu start-up window, undriven pin 0 reads 0, stale pins 7-1: ==== tb_emu_preview: 12 passed, 0 failed ====
PASS  G4  emu start-up window, undriven pin 0 reads 1, stale pins 7-1: ==== tb_emu_preview: 12 passed, 0 failed ====
PASS  G5  riscv.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 2 (DMEM), DSP48E2 10, LUT 6231, FF 1226
PASS  G6  riscv.sv @ 32 ns: longest path estimate: 17.20 ns, uses 54 % of the period (pessimistic; typical 11.07 ns): GO
PASS  G5  riscv_15mhz.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 2 (DMEM), DSP48E2 10, LUT 6249, FF 1224
PASS  G6  riscv_15mhz.sv @ 64 ns: longest path estimate: 17.80 ns, uses 28 % of the period (pessimistic; typical 11.31 ns): GO
PASS  G5  riscv_bufgce_div.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 2 (DMEM), DSP48E2 10, LUT 6452, FF 1226
PASS  G6  riscv_bufgce_div.sv @ 32 ns: longest path estimate: 18.10 ns, uses 57 % of the period (pessimistic; typical 11.43 ns): GO
PASS  G7  ==== mutants: 5 caught, 0 missed ==== (reset polarity, UART divider, o_Tx_Done, o_Rx_Done, pin direction)

PREFLIGHT: GO
```

### 1a. G3 at full fidelity (emu's real 50 ms waits)

`sim_emu --scale 1.0 --negative` on `stage4/riscv.sv` (log: `docs/stage4/evidence/emu_sys_full.log`):
bring-up (RST = 1, PC moving inside the ROM) **PASS**; lines 1–12 **PASS** (0.8–6.4 s of hardware time
each); the two corrupted lines are reported by emu with `[error]`, as they must be. **15/15, 46.5 s of
simulated hardware time.** All evidence logs: `docs/stage4/evidence/`.

## 1b. The AWS build (2026-10-10, ChipInventor AWS FPGA, Vivado 2024.1)

Log: `docs/stage4/evidence/aws_build_log.txt`. **AFI `afi-0732c3cb90c96019a`, AGFI `agfi-0c12a9e5d082dcac8`.**

| Item | Result |
| --- | --- |
| Synthesis | 0 errors; 16 critical warnings, all `[Synth 8-5799]` tri-state → logic on `io_Pins` (expected); the rest of the critical warnings are the AWS Shell's own DDR/PCIe constraint files |
| Our primitives | `MMCME4_BASE` → `MMCME4_ADV` (internal compensation), BUFG → BUFGCE: accepted (risk R2 closed) |
| PC readback | `riscvtop.e_PROCESSOR.w_PC_Output` resolved, no error (risk R3 closed) |
| Mapping | DMEM in block RAM (2K × 32), ROM in LUTs, multiplier in DSP48E2 cascades; no black boxes; DRC 0 errors |
| Final timing | **Hold met** (no negative hold path). **Setup WNS −0.112 ns, TNS −0.290 ns** (a few endpoints). Worst path: `input_en_reg[4]` (`top.sv`, 250 MHz) → `riscvtop/e_PROCESSOR/pins_s1_reg[4]/D` (our clock) — the host's direction register through the tri-state logic into the **first flip-flop of our pin synchroniser**. Checkpoint named `post_route.VIOLATED.dcp`; the AFI was created |

**Why the violation is harmless.** The failing paths cross from `top.sv`'s 250 MHz registers into
our 31.25 MHz clock and end at a 2-flip-flop synchroniser, which exists to absorb a late or
metastable first sample (the second stage has a full 32 ns core cycle to settle). Bit 4 is an output
pin of ours whose read-back the firmware never uses (it reads `& 0x0F`), and emu changes pins only
every ≥ 50 ms. No path inside our core clock or inside `top.sv`'s own 250 MHz logic is reported.
The design rule is runbook §2.5: a small negative slack on a crossing → load and test. A clean
report would need `set_clock_groups -asynchronous` between the two clocks, which only an XDC
constraint file (not available in this flow) can give.

## 1c. On the AWS F2 FPGA (2026-10-10)

Console log (account number redacted): `docs/stage4/evidence/aws_console_log.txt`.

| Step | Result |
| --- | --- |
| AFI state | `available`, `Name: top`, ShellVersion `0x10212415`, DeviceId `0xf010` |
| Load | `fpga-load-local-image … loaded … ok`; manual reset written |
| L0 reset register | `0x00000001` ✓ |
| L1 PC readback | `0x00401da4`, then `0x00401ecc`: different, both inside the ROM ✓ |
| L2 identify (line 12) | `0x0AE90449`, `0x19A356DE` ✓: the chip measured its own ROM, **2,793 words, CRC `0x56DE`** = this build |
| L3–L4 lines 1–11, then line 12 again | **all pass**: every `-r4` record and every `-o` lamp value equals the golden model's; 0 `[error]` in the whole session |

Checked mechanically (each run's reads against the command's expected values; each command
against `application/emulator-preview/emu_commands.txt`): **12 of 12 generated lines passed on the
hardware, on the first and only build.** The −0.112 ns setup slack on the pin-synchroniser crossing
(§1b) had no visible effect, as predicted.

## 2. What each check proves, and its limits

| # | Check | Proves | Does not prove |
| --- | --- | --- | --- |
| G1 | Regeneration + ROM compare + content scan | Each file is what the generator makes from `rtl/` and `firmware.hex`; no `$readmemh`, directive or `initial` in code; module names cannot collide (`RISCV`, `Transmitter`, `Receiver`, `rvbl2_*`) | — |
| G2 | Verilator `-sv -Wall`, our file + the **real** `top.sv` | Parses as SystemVerilog together with their file; ports and the hierarchical PC reference resolve; no SV keyword clash; every warning is from verified `rtl/` and explained (`stage4/sim/lint_waivers.txt`) | Vivado-specific acceptance (Vivado is more lenient than Verilator on these points) |
| G3 | **The organisers' `emu.c`, unmodified**, against a simulated `fpga_pci_peek/poke`, driving the **real `top.sv`** (AXI-Lite FSMs, FIFO, reset register) and our file; each command line a fresh `emu` (statics reset); FPGA state kept between lines; MMCM modelled cycle-accurately | The exact register sequence emu performs (start-up `-d 0x01`, reset pulse, read-modify-writes, TX polling, the RX window) works at the real dividers (2,170 and 271); the PC readback; corrupted lines are reported by emu | Real MMCM phase and jitter; Vivado's tri-state conversion (G4 covers it) |
| G4 | Emulator preview with emu's start-up window: reset released first, pin 0 undriven for ≥ 100 ms, pins 7–1 stale; an undriven pin read as **0 and as 1** | No phantom vehicle whatever Vivado makes of an undriven internal tri-state | — |
| G5 | Yosys `synth_xilinx -family xcup` | Synthesizable for UltraScale+; no latch; `check` clean; DMEM infers 2 × RAMB36E2 (not 65k flip-flops); the multiply uses DSP48E2; tiny next to a VU47P | Vivado's exact mapping (it will use LUTRAM for the register file and DSP cascades, both faster) |
| G6 | `sta_estimate.py` on the Yosys netlist: a pessimistic model (the verdict: slack ≥ 25 % of the period) and a typical one | The core's longest path (a ROM load) is ~17–18 ns pessimistic, ~11 ns typical, against 32 ns | Placed-and-routed timing: the build log's WNS is the final word (runbook §2.5) |
| G7 | Five one-line mutants of `riscv.sv`, each through G3 | The harness is sensitive: reset polarity, UART divider, `o_Tx_Done` (emu hangs), `o_Rx_Done` (FIFO garbage), pin direction are each caught | — |

## 3. Regression on the final firmware (2,793 words) and RTL

| Suite | Result |
| --- | --- |
| `run_all.sh` (RUN_LONG=1): every Stage 2 core and Stage 3 SoC/application testbench | **34/34 testbenches, 10,894 checks** + 1,238,859 lockstep comparisons (gate-level skipped, as at baseline: needs a generic synthesis netlist) |
| `tb_app` directed / random / fuzz / smoke / showcase (+ showcase at 921,600 bps) | 103/103 · 396/396 · 262/262 · 18/18 · 30/30 (+ 30/30) |
| Golden-model functional coverage | 40/40 bins |
| Emulator preview, undriven pin = 0 / = 1 | 12/12 / 12/12 |
| Official firmware testbench + its emu lines | 34/34 + 4/4 |
| Replay page logic + blind tests on the export | 182/182 |
| `run_ci.sh`: the ChipInventor design and the platform's exported netlist | all checks pass: the 15,517-check suite on the export; the v4 application ROM on the export 13/13, 8/8, 6/6 (921,600 bps) and 26/26 (115,200 bps); 1,238,859 lockstep comparisons |
| Firmware rebuild | byte-identical |

## 4. What this verification found and fixed

1. **A phantom vehicle at emu's start-up** (G4): emu releases pin 0 for ≥ 100 ms after every reset;
   with an undriven pin read as 1, 5 of 12 lines failed. Fixed in model, spec and firmware together
   (the detector arms once the lane is seen empty); now 12/12 for both resolutions.
2. **Harness corrections** (no product change): the emulator preview kept the first 8 bytes
   (`top.sv` keeps the last 8), released reset after `-d` (emu releases it before) and had no wait
   after `-d` (emu waits ≥ 100 ms). Each made the preview kinder than the hardware; all now match
   `emu.c`, which G3 runs itself.
3. **Clock:** the first build file ran at 15.625 MHz for a 2× margin in the pessimistic model; with a
   second, typical model and a 25 % pessimistic-slack rule, the build file runs at 31.25 MHz (the
   ASIC's clock), and the 15.625 MHz file stays as a pre-verified backup.
4. **Bookkeeping:** the ChipInventor export check failed because the platform still holds the Stage 3
   (v3) ROM; that image is now a named known ROM (`chipinventor/app/imem_app_stage3.v`).

## 5. Residual risks (only the hardware can answer)

| Risk | Likelihood | Mitigation in place |
| --- | --- | --- |
| MMCM fed by `clk_main_a0` refused in the CL partition | Low (AWS's own AWS_CLK_GEN puts MMCMs in the CL fed by a shell clock) | Pre-verified `riscv_bufgce_div.sv`; runbook §5/§6 |
| Hierarchical PC reference refused | Low (the organisers' reference build uses it) | One-line `32'b0` fallback, allowed by the README |
| Core clock misses 31.25 MHz in Vivado | Low (46 % slack in the pessimistic model) | WNS check in the log; pre-verified `riscv_15mhz.sv` |
| Organisers require the core itself at 250 MHz | Low–medium (README describes, does not forbid) | Ask before building |
| Web editor and a 196 kB paste | Low | Header, line count and last-line checks in the runbook; the identify line proves the build |
