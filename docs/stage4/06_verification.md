# Stage 4 verification: evidence for the AWS F2 build

**Build file:** `stage4/riscv.sv` (generated; MMCM ÷16 → 15.625 MHz; UART 136 clocks/bit;
ROM 2,793 words, `I` CRC `0x56DE`). **Fallback:** `stage4/riscv_bufgce_div.sv` (BUFGCE_DIV ÷8,
31.25 MHz). **Partner file:** the organisers' `top.sv`, byte-for-byte (sha256 `0fd73910…`).
Everything here was run locally; no AWS credit or synthesis hour was used.

## 1. Pre-flight gate (`bash scripts/stage4/preflight.sh`)

PREFLIGHT_SUMMARY_PLACEHOLDER

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
| `tb_app` directed / random / fuzz / smoke / showcase | REGRESSION_PLACEHOLDER |
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
