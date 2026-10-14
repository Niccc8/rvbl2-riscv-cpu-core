# stage4/de10lite — the LaneX desk lane on the DE10-Lite

A toy toll lane. One ultrasonic sensor over the lane measures each toy vehicle's height (a car, or
a lorry). The board's switches choose the tag the vehicle carries. **The exact RVBL-2 chip and
LaneX firmware that passed all 12 tests on the AWS F2** decide: a charge, a camera flash, or an
alarm. A laptop can watch every record live and verify it. Plan and rationale:
`docs/stage4/07_max10_prototype.md`. Installing Quartus: `docs/stage4/08_quartus_setup.md`.
**The printed gantry** that holds the sensor over the lane (one A1 plate, files ready for the SD card):
`gantry/README.md`.

## What is here

| File | What | Edit? |
| --- | --- | --- |
| `lab_brief.html` | **The lab brief**: how the chip maps onto the board (diagrams), then the bench procedure E1–E10 with expected results and checkboxes | — |
| `lanex.qpf` | **Open this in Quartus** | — |
| `compile.bat`, `program_sram.bat`, `program_flash.bat` | Double-click helpers: compile; load the `.sof` (until power-off); write the `.pof` to the internal flash (boots by itself) | — |
| `wiring_card.html` / `.png` | **The wiring card**: header pins, the sensor and its divider, lamps, controls, bring-up. Print the HTML (A4 landscape) or open the PNG on a phone | generated |
| `lanex_live.html` | **LaneX Live**, the laptop dashboard (Chrome or Edge; `lanex_live.html#demo` plays a demo with no board) | generated |
| `lanex_de10lite.v` | Board top: pins, PLL (50 MHz → 31.25 MHz), reset | hand-written |
| `lanex_board.v` | The fabric around the chip: ultrasonic sensor, tag-reader emulator, frame builder, laptop link, tour player, record decoder, displays, lamps | hand-written |
| `lanex_chip.v` | The RVBL-2 chip + LaneX ROM, from `rtl/` and `firmware.hex` by the same code as the AWS `riscv.sv` | generated |
| `lanex_data.v` | Tables: frame templates, the 12 AWS `./emu` lines with their golden answers, 7-segment words | generated |
| `lanex.qsf`, `lanex.sdc` | Device, every pin, I/O standards, pull-ups, flash boot; clocks | generated |
| `sim/` | Whole-board testbench, checker, Verilator build script, PLL stand-in | — |
| `dashboard/` | The dashboard's sources and its test | — |

"Generated" files come from `python scripts/stage4/gen_de10lite.py` (`--check` verifies that they
are current). Do not edit them by hand.

## Your steps

The short version; the full bench procedure, with wiring diagrams and the expected result of every
step, is `lab_brief.html`.

| # | Do | You should see |
| --- | --- | --- |
| 1 | Quartus: **File → Open Project → `lanex.qpf`**, then **Processing → Start Compilation** (or double-click `compile.bat`). About 7 minutes (the fitter works hard on timing) | 0 errors. Every timing slack positive (the core clock's Fmax ≥ 31.25 MHz; on this laptop: **36.24 MHz**) |
| 2 | **Tools → Programmer**: Hardware Setup = USB-Blaster; Add File `output_files\lanex.sof`; Start (or `program_sram.bat`) | Lamp test (everything lit for 1 s), the banner scrolls, then **`Id.56dE`** and LEDR9: the chip measured its own ROM |
| 3 | **SW9 up** (nothing wired yet) | Each AWS test: `tESt01` for 0.5 s, then its result and lamps for 0.9 s (about 17 s in all), then **`PASS12`** and LEDR9. **SW9 down** |
| 4 | **SW8 up**, SW3 up (tag `CAr`), press and release KEY1 | `CHArGE`, then `2.50`; LEDR4 |
| 5 | Unplug the board. Wire the sensor and its divider (wiring card). Power up **with the lane empty** (the board learns the floor). SW8 down | A toy under the sensor: LEDR0, and the display shows its height (`h  4.5` = 4.5 cm) |
| 6 | Push the car, then the lorry (tag `CAr`) | Car: `CHArGE / 2.50`. Lorry: `CLASS / 7.50`, LEDR1 (tall) |
| 7 | Lamps and buzzer (optional), USB-UART (Cytron UC00C: switch at 3.3 V; TXO → pin 1, RXI → pin 2, GND → pin 12), open `lanex_live.html` in Chrome or Edge → **Connect board** → choose the adapter's COM port | Every record appears, `CRC ✓`, `signed ✓`; the back-office buttons change the next decision |
| 8 | Programmer: `output_files\lanex.pof`, **Program/Configure** + **Verify**, Start (or `program_flash.bat`) | Unplug, plug in a power bank: the desk lane starts by itself |

**If the lorry reads as a car (or the car as a lorry):** look at the heights the display shows
for each toy, then set `TALL_MM` in `lanex.qsf` between them (in mm) and compile again.

## The booth demo (from 07 §3)

| Tag (SW5:SW3) | Vehicle | The lane |
| --- | --- | --- |
| `CAr` (001) | car | Green, chirp, **`CHArGE` / `2.50`** |
| `CAr` | lorry | White flash, **`CLASS` / `7.50`**: a car's tag on a lorry, caught by its height |
| `StOLEn` (100) | any | Red, three beeps, **`StOLEn`** (on the back office's hotlist) |
| `CLOnE` (101) | any | Red, **`CLOnE`**: "this tag was seen 40 km away 30 s ago" |
| `CAr` again within 3 s | car | **`no tAG`** + flash: tailgating protection |
| `CAb` (011) | car | Charged at the taxi fare, `1.30`. Then **laptop: "Report stolen" (Taxi)** and push again: `StOLEn` |
| SW9 | — | The 12 AWS tests on the board: **`PASS12`** |

## Timing

The slowest path is inside the chip core (register file → multiplier → register file, about
31 ns), the same design that ran at 31.25 MHz on the AWS F2. On this laptop, Quartus Prime Lite
25.1std.0 meets timing with **+4.41 ns setup slack** (Fmax 36.24 MHz) at the worst corner (Slow
1200 mV, 85 °C), with the fitter's "high performance effort" (`lanex.qsf`); without it, +0.47 ns.
If a later compile ever shows a negative slack, change `set_parameter -name CORE_HZ 31250000` in
`lanex.qsf` to `25000000` and compile again: the PLL and every UART divider follow. The firmware
does not care: its timing rules are in clock cycles.

## How it was verified (before it reaches the board)

| Check | Result |
| --- | --- |
| Quartus compile (this laptop, 25.1std.0) | 0 errors; 15,442 LEs (31 %), the 64 Kbit data RAM in M9K blocks, 1 PLL; setup slack +4.41 ns, hold +0.35 ns; `.sof` + `.pof` written |
| `sim/check_board.py`: the whole board in simulation (Verilator) | **1,601 checks, 0 failed** (`06_verification.md` §1d): every mode change, fault and four random 140-action sessions, each ending in a working lane; a real-speed flicker analysis of every light; and every tag preset × every vehicle height × lane open/closed; the laptop's frames; tour mode; edge cases. **The golden model replays every byte and pin change the chip received and must produce exactly what the chip sent**; every display, LED, lamp and buzzer state checked. Also a stress pass, with time squeezed 31× so that frames outlast vehicles |
| `dashboard/test_live.py` (QuickJS) | **29 checks, 0 failed**: the dashboard finds every record in the simulated laptop stream, verifies every signature, survives damaged bytes, rejects a forged signature |
| `scripts/stage4/gen_de10lite.py --check` | the generated files are current; the frame templates replay to the golden model's own frames |

Run them: `python stage4/de10lite/sim/check_board.py` (needs WSL with Verilator 5, about
10 minutes; `--sim icarus --only smoke` without WSL), then `python stage4/de10lite/dashboard/test_live.py`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Display stays `no Id` | The chip did not answer `I` | Hold KEY0. If it persists: the `.sof` is from another build; recompile |
| No vehicle is ever detected | The sensor reads nothing (Echo not wired, no 5 V, divider wrong) | LEDR0 must light with a toy under it. Check pin 11 (5 V) on VCC, Trig on pin 4, Echo through 1 kΩ to pin 3, and 2 kΩ from pin 3 to GND |
| Vehicles appear on their own | Before 15 Oct: stray echoes moved the learnt floor (fixed: median filter, floor learnt by agreement, 4-reading arrival, 8-reading departure). Still: a sloped or soft lane surface, or something inside the sensor's cone | Reload the build; use a flat card as the lane floor; keep 10 cm clear around the spot under the sensor; KEY0 with the lane empty |
| Lorry/car confused | Threshold | `TALL_MM` in `lanex.qsf` (see above) |
| The buzzer sounds all the time | A low-level-trigger buzzer module | SW6 up |
| The buzzer only clicks | A passive 2-leg buzzer (green board visible underneath) on pin 8 | Pin 10 (GPIO9, a 2.4 kHz tone) through 330 Ω; an active one (sealed, e.g. TMB12A05) stays on pin 8 |
| **Connect board** and **Demo** do nothing | `dashboard/lanex_live.src.html` opened: the template | Open `lanex_live.html` in this folder |
| Dashboard: Connect does nothing | Not Chrome/Edge, or another program holds the COM port | Close serial monitors; use Chrome or Edge |
| Dashboard shows nothing | TX/RX swapped, or no common GND | Adapter TXD → pin 1, RXD → pin 2, GND → pin 12 |
| `Err  1` on the display | A frame from the laptop arrived damaged: the chip refused it | Normal for line noise; check the GND wire |
