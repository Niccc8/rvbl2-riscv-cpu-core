# Stage 4 verification: evidence for the AWS F2 build

**Build file:** `stage4/riscv.sv` (generated; MMCM ÷16 → 15.625 MHz; UART 136 clocks/bit;
ROM 2,793 words, `I` CRC `0x56DE`). **Fallback:** `stage4/riscv_bufgce_div.sv` (BUFGCE_DIV ÷8,
31.25 MHz). **Partner file:** the organisers' `top.sv`, byte-for-byte (sha256 `0fd73910…`).
Everything here was run locally; no AWS credit or synthesis hour was used.

## 1. Pre-flight gate (`bash scripts/stage4/preflight.sh`)

```text
Stage 4 pre-flight, 2026-10-10 16:26, commit afa9698

PASS  G1  riscv.sv and riscv_bufgce_div.sv are current (regenerated from rtl/ + firmware.hex)
PASS  G1  ROM bit-identical to firmware.hex; no $readmemh/`timescale/`define/initial; module names safe
PASS  G1  organisers' top.sv (0fd7391018a38aeeaef7...) and emu.c (31e4ca7c3d4c4f08dd89...) unchanged
PASS  G2  Verilator -sv -Wall, riscv.sv + real top.sv: 0 errors, only waived rtl/ warnings
PASS  G2  Verilator -sv -Wall, riscv_bufgce_div.sv + real top.sv: 0 errors, only waived rtl/ warnings
PASS  G3  riscv.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at 0.1x emu waits: ==== emu_sys: 15 passed, 0 failed, 4.650 s simulated ====
PASS  G3  riscv_bufgce_div.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at 0.1x emu waits: ==== emu_sys: 15 passed, 0 failed, 4.650 s simulated ====
PASS  G4  emu start-up window, undriven pin 0 reads 0, stale pins 7-1: ==== tb_emu_preview: 12 passed, 0 failed ====
PASS  G4  emu start-up window, undriven pin 0 reads 1, stale pins 7-1: ==== tb_emu_preview: 12 passed, 0 failed ====
PASS  G5  riscv.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 2 (DMEM), DSP48E2 10, LUT 6249, FF 1224
PASS  G6  riscv.sv @ 64 ns: longest path estimate: 17.80 ns, uses 28 % of the period (pessimistic model): GO
PASS  G5  riscv_bufgce_div.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 2 (DMEM), DSP48E2 10, LUT 6452, FF 1226
NOTE  G6  riscv_bufgce_div.sv @ 32 ns: longest path estimate: 18.10 ns, uses 57 %: positive slack, below the 2x bar (fallback only)
PASS  G7  ==== mutants: 5 caught, 0 missed ==== (reset polarity, UART divider, o_Tx_Done, o_Rx_Done, pin direction)

PREFLIGHT: GO
```

### 1a. G3 at full fidelity (emu's real 50 ms waits)

`sim_emu --scale 1.0 --negative` on `stage4/riscv.sv` (log: `build/stage4/emu_sys_full.log`):
bring-up (RST = 1, PC moving inside the ROM) **PASS**; lines 1–12 **PASS** (0.8–6.4 s of hardware
time each); the two corrupted lines are reported by emu with `[error]`, as they must be.
**15/15, 46.5 s of simulated hardware time.**

## 2. What each check proves, and its limits

| # | Check | Proves | Does not prove |
|---|---|---|---|
| G1 | Regeneration + ROM compare + content scan | The file is what the generator makes from `rtl/` and `firmware.hex`; no `$readmemh`, directive or `initial` that the cloud editor or Vivado could trip on; module names cannot collide (`RISCV`, `Transmitter`, `Receiver`, `rvbl2_*`) | — |
| G2 | Verilator `-sv -Wall`, our file + the **real** `top.sv` | Parses as SystemVerilog with their file in the same compile; ports and the hierarchical PC reference resolve; no SV keyword clash | Vivado-specific acceptance (Vivado is more lenient than Verilator, not less, on these points) |
| G3 | System simulation: **the organisers' `emu.c`, unmodified**, compiled against a simulated `fpga_pci_peek/poke`, driving the **real `top.sv`** (AXI-Lite FSMs, FIFO, reset register) and our `riscv.sv`; each command line a fresh `emu` (statics reset), FPGA state kept between lines; MMCM modelled cycle-accurately | The exact register sequence emu performs (start-up `-d 0x01`, reset pulse, read-modify-writes, TX polling, RX window) works at the real dividers (2,170 and 136); the PC readback; negative lines are reported by emu | Real MMCM phase/jitter; Vivado's tri-state conversion (see G4) |
| G4 | Emulator preview with emu's start-up window: reset released, pin 0 undriven for ≥ 100 ms, pins 7–1 stale, an undriven pin resolved as **0 and as 1** | No phantom vehicle whatever Vivado makes of an undriven internal tri-state | — |
| G5 | Yosys `synth_xilinx -family xcup` | Synthesizable for UltraScale+; no latch; `check` clean; DMEM infers 2 × RAMB36E2 (not 65k flip-flops); multiply → DSP48E2; resource use tiny for a VU47P | Vivado's exact mapping (it will use LUTRAM for the register file) |
| G6 | `sta_estimate.py` on the Yosys netlist, pessimistic per-cell delays incl. routing | The core's longest path (a ROM load) ≈ 17–20 ns vs a 64 ns clock: > 3× margin | Placed-and-routed timing (Vivado reports it in the build log) |
| G7 | Five one-line mutants of `riscv.sv`, each run through G3 | The G3 harness is sensitive: reset polarity, UART divider, `o_Tx_Done` semantics (emu hang), `o_Rx_Done` semantics (FIFO garbage), pin direction are each caught | — |

## 3. Application regression on the final firmware (2,793 words)

| Suite | Result |
|---|---|
| Golden-model coverage | 40/40 bins |
| `tb_app` directed / random / fuzz / smoke / showcase | 103/103 · 396/396 · 262/262 · 18/18 · 30/30 |
| `tb_app` showcase at 921,600 bps | 30/30 |
| ChipInventor netlist (`tb_app_ci`, showcase) | 26/26 |
| Emulator preview, undriven pin = 0 / = 1 | 12/12 / 12/12 |
| Official firmware testbench + its emu lines | 34/34 + 4/4 |
| Replay page logic + blind tests on the export | 182/182 |
| Firmware rebuild | byte-identical |

The core RTL (`rtl/`) is unchanged in Stage 4, so the Stage 2/3 core and SoC suites
(`run_all.sh` 31/31, `run_ci.sh` 15,517 checks; baseline `build/stage4_baseline/`) still apply.

## 4. Deviations found by this verification (and fixed)

1. **Clock ÷16 instead of ÷8** (G6): pessimistic 17–20 ns path vs 32 ns did not give the 2×
   margin the plan promised. Functionally free (see `04_fpga_plan.md`, "As built").
2. **Vehicle detector arms once the lane is seen empty** (G4): with emu's start-up window and an
   undriven pin read as 1, 5 of 12 lines produced a phantom vehicle. Fixed in model, spec and
   firmware together; now 12/12 for both resolutions.
3. **Harness corrections** (no product change): the preview kept the first 8 bytes (top.sv keeps
   the last 8), released reset after `-d` (emu releases it before), and had no wait after `-d`
   (emu waits ≥ 100 ms). Each made the preview kinder than the hardware; all three now match emu.c.

## 5. Residual risks (what only the hardware can answer)

| Risk | Likelihood | Mitigation in place |
|---|---|---|
| MMCM fed by `clk_main_a0` refused in the CL partition | Low (AWS's own AWS_CLK_GEN puts MMCMs in the CL fed by a shell clock) | Pre-verified BUFGCE_DIV fallback file; runbook §5/§6 |
| Hierarchical PC reference refused | Low (the organisers' reference build uses it) | One-line `32'b0` fallback, allowed by the README |
| Organisers require the core itself at 250 MHz | Low–medium (README describes, does not forbid) | Ask before building |
| Web editor and a 196 kB paste | Low | Header + line count checks in the runbook |
