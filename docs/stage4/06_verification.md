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

## 1d. The DE10-Lite desk lane (2026-10-11, before the board)

Design: `07_max10_prototype.md`; files: `stage4/de10lite/`. The chip is generated from `rtl/` and
`firmware.hex` by the AWS generator's own code; the three AWS files still regenerate byte-identical
(`gen_riscv_sv.py --check`, all three variants).

| Check | Result |
| --- | --- |
| `python scripts/stage4/gen_de10lite.py --check` | generated files current; the frame templates replay to `lane_model.py`'s own frames (7 time values incl. the 32-bit wrap); the tour's 12 lines equal `emu_commands.txt` and `lane_model.emu_commands()` |
| `python stage4/de10lite/sim/check_board.py` (Verilator 5.020, whole board: chip + ROM + fabric + an HC-SR04 model + a laptop) | **BOARD PASS: 623 checks, 0 failed**. Full pass (time ×10): matrix 430 (56 vehicles: 8 presets × car / lorry / manual / van / motorcycle / lorry-as-motorcycle, then 8 with the lane closed; 114 records), host 50, tour 37 (12 `./emu` lines + 2 lane runs), edges 76. Stress pass (time ×312: frames outlast vehicles), model comparison only: all PASS |
| What V2 compares | every byte and pin change the chip received, replayed by `lane_model.py` run by run: **the model's output equals the chip's, byte for byte, in every run**; the laptop's copy equals the chip's output; every decision equals the one PROTOCOL.md §6 gives for that preset and height |
| `python stage4/de10lite/dashboard/test_live.py` (QuickJS) | **LIVE PASS: 29 checks**: back-office frames = the model's; the demo stream; the four simulated laptop streams (169 records, 78 signatures found and verified by the page itself, across chip resets and tour mode); a damaged byte costs one record; a forged tag is reported |
| Quartus Prime Lite 25.1std.0 on Nicholas's laptop (`quartus_sh --flow compile lanex`, copy in `build/`) | **0 errors**; 14,715 LEs (30 %), 2,276 registers, 66,048 memory bits (M9K), 11 multiplier elements, 1 PLL (clk[0] = 32.000 ns); **setup slack +4.491 ns** (Fmax 36.35 MHz) and hold +0.326 ns at Slow 1200 mV 85 °C; `.sof` and `.pof` written. Worst path: inside the chip core, register file → register file. Without the high-performance fitter effort: +0.468 ns |

Found and fixed by these checks before any hardware: (1) a vehicle could clear before the chip had
seen it arrive, when the channel into the chip was busy with a laptop frame; (2) a lorry's class
could be lost the same way. Both now wait until the chip has seen the vehicle's current pins.
(3) The testbench had a race of its own (it waited for KEY1's identify record after it had come);
a watchdog now ends any run that waits for an event that never comes.

Not covered until the board: the HC-SR04 on real toys (its readings, the threshold), the USB-UART
on Windows, Web Serial in the browser, the internal-flash boot. (All but the flash boot have since
been confirmed on the board: round 3.)

### 1d, round 2: after the first board test (2026-10-11)

Nicholas programmed the board: `Id.56dE` and `PASS12` worked; he saw the tour **flicker between
tests**, and found the manual car's word/fare/word/fare/word cycle confusing. Causes and fixes:

| Seen | Cause | Fix |
| --- | --- | --- |
| Tour flicker | Each line restarts the chip; for ~15 ms the chip's lamps were 0 and the display fell back to `tESt nn` until the line's record arrived | Tour shows latched, paced phases: `tESt nn` 0.5 s, then the line's result and lamps 0.9 s |
| Word/fare repeated | 5 s alternating display | Word 1.5 s, then the fare 2.5 s, then idle (alarms: the word blinking, lit first) |
| (review) a ~10 ms `no Id` / LEDR9 blink after the tour | A warm boot waits for the chip's `I` record | Displays, LEDs and lamps hold the last picture until it comes (at most 1 s) |
| (review) a ~1 ms idle flash between a vehicle's height and its decision | The `V` record takes ~1.4 ms to arrive | The height stays until the decision |
| (review) sensor lost under a vehicle: the vehicle stayed for ever | No reading counts as "clear" | 16 readings with no echo (1 s): the vehicle has left |
| (review) a silent chip would hang the lane | — | Watchdog: no `V` 1.5 s after a departure → warm boot |
| (review) a glitch on KEY0 reset the board | Unfiltered | KEY0 must be held 20 ms |
| (stress pass) two identify requests within 2 ms, or a frame right after one: the chip answers in another order or merges them | The fabric did not keep the host's rule "after `I`, wait for the answer" | After any `I` frame the fabric holds frames and pin changes until the `I` record (at most 6.4 ms) |

New checks (`check_board.py`): scenario families **modes** (SW9 during the banner, tours cut at
3 s / 0.7 s / 0.1 s, two tours in a row, SW9 flicked under the debounce, SW0 / override / tag /
SW8 changed under a vehicle, KEY1 identify under a vehicle, a refused key `E` 7, laptop frames
during the tour and the boot, KEY0 under a vehicle and mid-tour), **faults** (sensor unplugged under
a car and at idle, a lorry parked 150 readings, the chip silenced by fault injection: watchdog,
`no Id`, recovery with KEY1), **chaos 1–4** (seeded random sessions of 140 actions each: objects of
every height, every switch, KEY0, KEY1, the sensor, the laptop's valid, damaged, half and oversize
frames; each ends with two vehicles that must be decided right, one without and one after a reset),
**glitch** at real speed with the flicker analysis (per light: no state of 5–150 ms; tour states
≥ 300 ms), and `tb_top.v` for the top level's reset path.

| Run | Result |
| --- | --- |
| Full pass (×10), final RTL | **1,035 checks, 0 failed**: matrix 430, host 50, tour 38, edges 76, modes 188 (78 chip runs), faults 43, chaos 57 + 53 + 50 + 50 (90 chip runs) |
| Stress pass (×312), model comparison | **203 checks, 0 failed** (run on the RTL before the alarm-blink change, which touches only the display) |
| Real-speed pass, flicker analysis, final RTL | **52 checks, 0 failed**, no short state on any light |
| `tb_top.v` (KEY0 filter, power-up) | **TOP PASS** |
| Control: the real-speed pass on the previous design (`87e4a5a`) | **40 short states**, among them `tESt01` … for 5 ms: the flicker Nicholas saw, reproduced by the test |
| `test_live.py` | **29 checks, 0 failed** |
| Quartus 25.1std.0, final RTL | **0 errors**; 14,936 LEs (30 %), 2,368 registers; setup slack **+4.388 ns** (Fmax 36.22 MHz), hold +0.328 ns at Slow 1200 mV 85 °C |

### 1d, round 3: phantom vehicles on the bench (2026-10-15)

Nicholas, at lab brief E5: with nothing under the sensor the board sometimes showed a height of
about 1.6 cm, LEDR0 stayed on, LEDR0/LEDR2 flashed, and `no tAG` was decided again and again.

| Cause | Fix (`lanex_board.v`, the lane block's rules 1–4) |
| --- | --- |
| The floor was the farthest reading seen (a ratchet). An HC-SR04 now and then misses the floor and hears a farther echo (a footing, the table's edge): one such echo set the floor ~16 mm too far, and the empty lane then stood 16 mm "tall", over the 15 mm threshold | The floor is learnt by **agreement** (8 filtered readings within ±6 mm), re-learnt farther only when 16 agree |
| A single stray reading could start or end a vehicle | Each reading is the **median of three**; a vehicle arrives after **4** filtered readings over the threshold and leaves after **8** readings of the floor itself; its height (and lorry class) is the lowest of the last three |
| A floor learnt too far is the dangerous kind (a too-near floor only hides a vehicle for a second) | The lane is **armed** only after it has seen the floor 4 times since learning it; until then no vehicle can arrive, and a steady nearer distance (16 readings) is the floor |
| A lost echo (farther than the floor) in a vehicle's middle reset its arrival | A farther reading neither counts nor breaks an arrival or a departure |
| Echo spikes and drop-outs on the wire | Echo deglitched (1 µs), echoes shorter than the minimum range ignored |
| Something low left standing | Rule 4: a "vehicle" never taller than 25 mm that stays 30 s is the floor |

New checks: `tb_board.v` has a **noisy HC-SR04** (`G 1 seed`): ±3 mm jitter, 7 % lost floor echoes
heard 12–30 mm farther in bursts of 1–3, 3 % near strays, 2 % no echo, 2 % the 38 ms time-out,
spikes and drop-outs on Echo. Scenario **noise**: 94 s of an empty lane, seven toys at a hand's
pace, KEY0 with a toy underneath, a 2 cm block left standing; **chaos 5–6** are random sessions
on the noisy sensor. The stress pass found two more faults, both fixed: a floor learnt from a
long-echo streak right after KEY0 (18 mm too far: a vehicle that never left — the arming rule),
and a fast lorry lost to a lost-echo burst over its cab (the farther-reading rule).

The limit, stated plainly: a vehicle is promised at a hand's pace (15+ readings, ~1 s under the
sensor). A 0.6 s flick that coincides with a 9-reading streak of lost echoes (the stress pass met
one) leaves only 3 good readings and is missed; accepting 3 would let three stray echoes make a
vehicle again. The noisy chaos sessions therefore end with hand-paced vehicles; the clean ones keep
the 8-reading push. After KEY0 the lane needs ~12 readings (0.75 s) to learn and arm its floor;
the real boot takes ~3 s, and the stress pass (where the boot is only 6 readings) waits 24.

Also new: **GPIO9 (header pin 10) plays a 2.4 kHz tone** whenever the buzzer sounds, for a passive
(bare-coil) buzzer; pin 8 stays the level for an active one. `tb_board.v` checks every half period
of the tone (exactly `CLK_HZ/4800` clocks while it sounds, never a tone in silence).

| Run | Result |
| --- | --- |
| Control: the previous design (`f6a601c`) on the noisy sensor, 94 s of an empty lane | **23 phantom vehicles** |
| Full pass (×10), final RTL | **1,261 checks, 0 failed**: matrix 431, host 51, tour 39, edges 77, modes 189, faults 44, noise 86, chaos 58 + 54 + 51 + 51 + 64 + 65 (every scenario also checks the buzzer tone) |
| Stress pass (×312) | **286 checks, 0 failed** (model comparison; noise, faults and chaos 5–6 included) |
| Real-speed pass, flicker analysis | **54 checks, 0 failed**, no short state on any light |
| `test_live.py` | **29 checks, 0 failed** |
| **On the board** (Nicholas, after round 3) | **the whole desk lane works**: vehicle detection, the four lamps, the buzzer, and the USB-UART link to LaneX Live |
| Quartus 25.1std.0, final RTL | **0 errors**; 15,372 LEs (31 %), 2,484 registers; setup slack **+4.436 ns** (Fmax 36.28 MHz), hold +0.332 ns at Slow 1200 mV 85 °C |

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
