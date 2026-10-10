# Stage 4 FPGA design: `riscv.sv` for the organisers' `top.sv`

**Status:** approved at GATE 2 (2026-10-10), built and verified (`06_verification.md`).
Ground truth: `01_aws_reference.md` (organisers' Stage 4 repo `b748304`, `top.sv` sha256
`0fd73910…`; `emu.c` `31e4ca7c…`). Goal: one AWS synthesis (~45 min of VM time), right the first time.

## 1. The design in one paragraph

We paste **two files**: the organisers' `top.sv` **byte-for-byte unchanged**, and `riscv.sv`,
**generated** from `rtl/` and the firmware by `scripts/stage4/gen_riscv_sv.py` (never edited by
hand). Inside `riscv.sv`, a thin FPGA-only shell module `RISCV` divides the 250 MHz `clk_main_a0`
by 8 with an **MMCM** to **31.25 MHz** (our ASIC's own operating point), synchronises reset and pins,
and runs our **unchanged, verified chip** as instance `e_PROCESSOR`. The firmware (LaneX protocol
v4) is a literal ROM equal to `firmware.hex` bit for bit. The shell also provides the
`Transmitter`/`Receiver` that `top.sv` instantiates.

| File | Clock | Use |
|---|---|---|
| `stage4/riscv.sv` | MMCM ÷8 → **31.25 MHz**, UART 271 clocks/bit | **The build** |
| `stage4/riscv_15mhz.sv` | MMCM ÷16 → 15.625 MHz, UART 136 | Timing backup (only if the build log shows negative slack on the core clock) |
| `stage4/riscv_bufgce_div.sv` | BUFGCE_DIV ÷8 → 31.25 MHz, UART 271 | Primitive backup (only if the MMCM is refused) |

All three pass the same pre-flight gate.

## 2. The clock

**Why not 250 MHz.** `top.sv` feeds `RISCV` with `clk_main_a0` = 250 MHz (4 ns). Our core is a
multicycle design signed off at 33 ns (Sky130); its longest one-cycle path is a load from the ROM
(register read → address add → combinational ROM → load alignment → write-back). Pipelining it to
250 MHz would rewrite verified RTL days before the event: rejected. Dividing the clock **inside our
own module** keeps `top.sv` untouched and the core exactly as verified.

**Why 31.25 MHz.** It is the ASIC's operating point (30.3 MHz), so every firmware budget validated
on the RTL holds (a UART byte = 2,713 cycles vs a measured worst receive wait of 199), and it is
the honest story: *the same clock as our signed-off silicon*. Timing evidence on the synthesized
netlist (`06` G6): longest path **18.1 ns pessimistic, 11.4 ns typical** against 32 ns → slack 13.9
ns (43 %) even in the pessimistic model; estimated maximum 55–87 MHz. The build log's own `WNS` on
the core clock is the final word (runbook §2.5); `riscv_15mhz.sv` exists for the unlikely case it
is negative.

**UART.** `round(31.25 MHz / 115,200) = 271` → 115,314 bps (+0.10 %); `top.sv`'s side: 2,170 at
250 MHz = 115,207 bps. Mismatch 0.09 % against a tolerance of ~2 %.

> **Q1 (ask the organisers before building):** their README *describes* the processor as using
> `clk_main_a0` directly and says the `riscv_clk` connection must be preserved (it is). It does not
> forbid dividing the clock inside our module.

## 3. `riscv.sv` architecture

```text
RISCV                      ports exactly as top.sv instantiates it: i_Rx_Serial, i_Clk, i_nRst,
│                          o_Tx_Serial, io_Pins[7:0]  (so top.sv needs ZERO edits)
├─ u_mmcm   MMCME4_BASE    CLKIN 250 MHz (4.0 ns), VCO = 250 × 4 = 1000 MHz (legal 800–1600),
│                          CLKOUT0 ÷32 = 31.25 MHz → BUFG → clk_core; RST tied 0; LOCKED used
├─ reset    ~i_nRst | ~LOCKED, 2-FF synchroniser in clk_core (async assert, sync release)
├─ e_PROCESSOR : rvbl2_top our chip (rtl/top.v, renamed), UART_CLK_FREQ_HZ = 31_250_000
│   ├─ wire w_PC_Output    ← the core's PC: top.sv's riscvtop.e_PROCESSOR.w_PC_Output resolves
│   ├─ pins: assign pins_io[n] = gpio_oe[n] ? gpio_o[n] : 1'bz  (the tri-state idiom top.sv uses)
│   ├─ pin inputs: 2-FF synchroniser (they come from top.sv's 250 MHz registers)
│   ├─ rvbl2_imem: literal `case` ROM, 2,793 words = firmware.hex (no $readmemh)
│   └─ rvbl2_dmem: 2,048 × 32 synchronous RAM with byte enables → 2 × RAMB36E2
├─ Transmitter #(p_CLKS_PER_BIT)  idle high, also in reset; one byte per 1-cycle i_Tx_Transmit;
│     o_Tx_Done a sticky LEVEL (1 from reset and after each byte) — emu polls it 50 ms later
└─ Receiver    #(p_CLKS_PER_BIT)  2-FF synchroniser on i_Rx_Serial; o_Rx_Done ONE cycle per
      byte, o_Rx_Byte valid in that cycle (top.sv advances its FIFO walker every cycle it is high)
```

### 3.1 The diff against the organisers' `top.sv`: none

| `top.sv` line | Allowed change | Ours | Why no edit is needed |
|---|---|---|---|
| `RISCV riscvtop (` | module name | `RISCV` | Our shell module is named `RISCV` |
| `.i_Rx_Serial (w_Rx),` … `.io_Pins (io_Pins)` | left names | same | Our ports carry exactly these names |
| `3'b111: … riscvtop.e_PROCESSOR.w_PC_Output;` | path or `32'b0` | same | Our instance is `e_PROCESSOR` and holds a wire `w_PC_Output` |

**Fallback, one line:** if Vivado rejects the hierarchical reference, replace that line with
`32'b0` (the README allows it); PC readback is then lost, the demo is not.

### 3.2 Generator rules (one source of truth)

1. Read `rtl/*.v` (never copies). Prefix every module with `rvbl2_` (`top` → `rvbl2_top`): no clash
   with `top`, `tick_gen`, `Transmitter`, `Receiver` or HDK names.
2. Resolve `` `ifdef `` as Vivado synthesis sees them (`SYNTHESIS` defined, no SRAM macro).
3. FPGA-only edits, each matched exactly once or the run fails: `riscv_core` exports its PC
   (`pc_o` → `w_PC_Output`); the chip top gets the pin synchroniser; `dmem` loses `(* keep *)`
   (an ASIC-flow workaround that could block block-RAM inference); `imem` becomes the case ROM.
   `rtl/` itself is not modified, so the ASIC sign-off stays valid.
4. No `` `timescale ``, `` `default_nettype ``, `` `define `` or `` `include `` (they would leak into
   `top.sv`), no `initial` blocks, no file I/O; no module named like a Xilinx primitive.
5. The header records the source commit, `firmware.hex` sha256, and the ROM size and CRC the `I`
   record must report, so the hardware's answer can be compared with the file.

## 4. Firmware: one bitstream carries everything

- LaneX protocol v4 (`application/firmware/out/lane/firmware.hex`, 2,793 words), the image every
  regression runs. Nothing FPGA-specific in C: the clock only changes the UART divider, in RTL.
- A firmware change is a new 45-min synthesis, so the image already answers all 12 demo lines.
- The **vehicle detector arms once the lane has been seen empty** (a vehicle present at reset is
  not decided; a departure without an arrival is ignored): emu releases pin 0 for ≥ 100 ms after
  every reset, and whichever way Vivado resolves an undriven pin, no phantom vehicle appears.
- The organisers' own echo test line is for *their* firmware and fails on ours by design
  (GATE 2: it need not pass).

### 4.1 Bring-up ladder (runbook §3)

| Step | Command | Proves |
|---|---|---|
| L0 | `./axil_rw read 0 0x00` → 1 | Core out of reset |
| L1 | `./axil_rw read 0 0x1C` twice → different values in `0x00400000–0x00402BA4` | MMCM locked, core running our ROM |
| L2 | `./emu` identify line → CRC `0x56DE` | UART both ways; this exact build |
| L3 | `./emu` charged line | Pins, tag CRC, decision, record |
| L4 | the other 10 lines | Every outcome, authentication |

## 5. Clock-domain crossings (all between related clocks; Vivado times them)

| Crossing | From → to | Handling |
|---|---|---|
| `i_Rx_Serial` | `top.sv` Transmitter FF (250) → our UART | 2-FF synchroniser in `uart.v` |
| `o_Tx_Serial` | our UART FF (31.25) → `Receiver` | 2-FF synchroniser in our `Receiver` |
| `io_Pins` in | `input_pins` (250) → our GPIO | 2-FF synchroniser in the FPGA chip top |
| `io_Pins` out | our GPIO FF (31.25) → `cl_ocl_rdata` (250) | short path; read 50 ms after a change |
| `i_nRst` | `riscv_nreset` (250) → reset synchroniser | async assert, sync release |
| `w_PC_Output` | PC (31.25) → `cl_ocl_rdata` (250) | multi-bit; bring-up only |

## 6. Pre-flight gate (`scripts/stage4/preflight.sh`; evidence in `06_verification.md`)

| # | Check | Pass criterion |
|---|---|---|
| G1 | The three files regenerate identically; ROM = `firmware.hex`; no directive, file I/O or `initial` in code; safe module names; vendor hashes | all |
| G2 | Verilator 5.020 `-sv -Wall` with the **real** `top.sv` | 0 errors; warnings only from `rtl/`, listed and explained in `stage4/sim/lint_waivers.txt` |
| G3 | **The organisers' `emu.c`, unmodified**, driving the real `top.sv` + our file (Verilator; `fpga_pci_peek/poke` → AXI-Lite; `usleep` → simulated time; a fresh emu per line) | all 12 lines, the bring-up, and 2 corrupted lines reported |
| G4 | emu's start-up window, an undriven pin read as 0 and as 1 | 12/12 both |
| G5 | Yosys `synth_xilinx -family xcup` | no latch, `check` clean, DMEM in 2 × RAMB36E2 |
| G6 | Timing estimate on the netlist (pessimistic and typical models) | pessimistic slack ≥ 25 % of the period |
| G7 | Five one-line mutants through G3 | each caught |

## 7. Risk register

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Organisers require the core itself at 250 MHz | L–M | H | Ask before building (Q1) |
| R2 | MMCM fed by `clk_main_a0` refused in the CL partition | L | H | AWS's own AWS_CLK_GEN puts MMCMs in the CL fed by a shell clock; LOCKED gates reset; L1 detects "no lock"; `riscv_bufgce_div.sv` |
| R3 | Hierarchical PC reference refused | L | H | Same depth as the organisers' working build; one-line `32'b0` fallback |
| R4 | Phantom vehicle in emu's start-up window | — | — | **Closed**: G4 passes for both resolutions |
| R5 | Web editor and a 196 kB paste | L | M | Runbook checks the header, line count and last line |
| R6 | Core path misses 31.25 MHz in Vivado | L | M | 43 % pessimistic slack; read WNS in the log; `riscv_15mhz.sv` |
| R7 | Paste error (missing line, wrong file) | M | H | Runbook §1 checks; the identify line proves the build on the board |

## 8. Options considered and not taken

| Option | Verdict |
|---|---|
| UART-loadable IMEM (a bootloader loads firmware into a RAM IMEM) | Not now: emu sends ~10 bytes/s (an 11 kB image ≈ 19 min, lost at every emu reset), and it changes the verified IMEM and boot path. Roadmap item ("field-updatable firmware") |
| Two images in one ROM (ours + an echo mode for the organisers' test line) | Not needed (GATE 2) |
| Core at 250 MHz with a clock enable on every register | Rewrites every always block; Vivado would report thousands of false violations with no XDC |
| Pipeline the core to 250 MHz | Rewrites verified RTL; rejected |
