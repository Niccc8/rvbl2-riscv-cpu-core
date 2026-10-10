# LaneX desk lane: a physical prototype on the DE10-Lite (Tier 1 plan)

**Status:** plan for approval; nothing built yet. Board **confirmed from Nicholas's photos**: Terasic
**DE10-Lite** (box "DE10-Lite (OJ)", LOT#3023), Intel/Altera **MAX 10 10M50DAF484C7G**, on-board
USB-Blaster, six 7-segment digits, 10 LEDs, 10 switches, 2 buttons, one 2×20 GPIO header, Arduino
header, VGA. Install guide for the tools: `08_quartus_setup.md`.

## 1. The idea in one paragraph

A toy lane on a desk. A cardboard gantry with **two infrared beams**: the low beam sees any vehicle
(presence), the high beam only sees tall ones (the **classifier**, the way real gantries use LiDAR
height). Visitors pick the toy vehicle's **tag** with the board's switches (a car tag, a stolen
tag, a cloned tag…), push a **toy car or a toy lorry** through, and the lane decides on the spot:
a **green** light and "CHArGE 2.50", or a **white camera flash**, or a **red light and a buzzer**.
The decision is made by **the exact RVBL-2 chip and LaneX firmware that passed all 12 lines on the
AWS F2** (same RTL, same ROM, same fingerprint `0x56DE`), now on a second FPGA family. A laptop, if
a USB-UART link is available, shows a **live dashboard**: every record decoded, its CRC and its
Chaskey-12 signature verified in the browser, revenue and alarms counted, and "back-office" buttons
(report a tag stolen, close the lane) that change the lane's next decision live.

## 2. What is on the board (and what is not)

```text
                         DE10-Lite (MAX 10)
  ┌────────────────────────────────────────────────────────────────────────────┐
  │  rvbl2_top  = the AWS chip, unchanged (core, GPIO, UART, LaneX ROM, 8 KB RAM)│
  │      ▲ UART rx          │ UART tx                │ P7..P4 lamps  ▲ P3..P0  │
  │      │                  ▼                        ▼               │         │
  │  ┌──────────┐     ┌──────────────┐       ┌───────────┐   ┌─────────────┐   │
  │  │ frame    │◄────┤ host link    │       │ lamps,    │   │ lane sensor │   │
  │  │ sender   │     │ (GPIO UART)  │◄──────┤ flash,    │   │ conditioner │◄──┼── 2 IR beams,
  │  │ (CRC-16, │     └──────────────┘ tx    │ buzzer    │   │ + classifier│   │   SW, KEY1
  │  │ live t)  │◄── tag reader emulator ◄───┼───────────┼───┤             │   │
  │  │          │◄── boot config + identify  └───────────┘   └─────────────┘   │
  │  │          │◄── tour player (12 golden lines, self-check)                  │
  │  └──────────┘     record decoder (CRC-16) ──► 7-segment words, LEDR9 check │
  └────────────────────────────────────────────────────────────────────────────┘
```

**Everything around the chip is test equipment in fabric**, the on-board equivalent of the
organisers' `emu`: it feeds the chip frames and pins and reads its records. **LaneX itself runs only
on our CPU.** No change to `rtl/` or the firmware: the generator gains a `--target de10lite`.

## 3. The experience, step by step

| # | Visitor does | The lane does | Why it impresses |
| --- | --- | --- | --- |
| 0 | (power on, USB power bank) | 7-seg scrolls "LAnE  rISC-V  bEAt tHE toLL"; lamp test; then **"Id 56dE"**: the chip measured its own ROM — the same fingerprint as on AWS | Self-test you can see; same silicon story |
| 1 | Sets the tag switches to **CAr**, pushes the **toy car** through | Green light, short chirp, **"CHArGE" / "2.50"** | It works |
| 2 | Same car tag, pushes the **toy lorry** | High beam → lorry; **"CLASS" / "7.50"**, white flash | The classic fraud, caught physically |
| 3 | Tag **StOLEn** | **Red light + buzzer**, "StOLEn" | Alarm |
| 4 | Tag **CLOnE** | "CLOnE": "this tag was 40 km away 30 s ago" | The clever one |
| 5 | Pushes the same car again within 3 s | "no tAG" + flash: tailgating protection | Shows a real rule |
| 6 | (laptop) clicks **"Report CAB tag stolen"**, then pushes a car with the CAb tag | Next decision becomes **StOLEn** | Back office ↔ lane, live |
| 7 | (presenter) flips SW9 | **Tour mode**: the 12 golden scenarios run on the board and are checked against the reference model: **"PASS12"**, LEDR9 on | The verification culture, live |

## 4. Inputs, outputs, switches

| Control | Meaning |
| --- | --- |
| Low IR beam (GPIO, header pin 3) | **P0 vehicle present** (beam broken) |
| High IR beam (pin 4) | Tall vehicle seen while present → class 3 (lorry), latched until the vehicle leaves |
| SW0 | P3 lane closed |
| SW2:SW1 | Class override: 00 = sensors (car/lorry), 01 = van, 10 = lorry, 11 = motorcycle |
| SW5:SW3 | Tag preset: 0 none · 1 **CAr** · 2 **LorrY** · 3 **CAb** (taxi) · 4 **StOLEn** · 5 **CLOnE** · 6 **bAd** (damaged, bad Gen2 CRC) · 7 **FAr** (adjacent lane, weak read) |
| SW8 | Manual vehicle: KEY1 is the vehicle (press = in the zone, release = leaves) — the no-sensor fallback |
| SW9 | Tour mode (KEY1 = next scenario; hold = run all) |
| KEY0 | Reset |

| Output | Meaning |
| --- | --- |
| LEDR4–7 | P4 charged · P5 camera · P6 alarm · P7 lane closed (exactly the `-o` lamps on AWS) |
| LEDR0 / LEDR1 | Low beam / high beam (sensor check) |
| LEDR8 | The last vehicle record was **signed** (its `A` record arrived, CRC ok) |
| LEDR9 | Self-check: the chip's answer equals the expected one (boot identify, tour mode) |
| HEX5–HEX0 | Idle: tag preset name; after a car: decision word ↔ fare, alternating 1 s, for 5 s |
| External (GPIO) | Green LED (charged), white LED (camera flash, 150 ms), red LED (alarm), buzzer (alarm: 3 beeps; charged: 1 chirp), optional lane-closed LED |

Decision words (7-segment alphabet): `CHArGE`, `no tAG`, `CLASS`, `StOLEn`, `CLOnE`, `FrEE`, `CLOSEd`.

## 5. The host link and its fallbacks (no rebuild between them)

The design is the same in every case; the two GPIO UART pins are simply unused without a link.

| Plan | Hardware | Wiring | Notes |
| --- | --- | --- | --- |
| **A** | USB-UART module: CP2102, CH340 or FT232, **3.3 V logic** | adapter TXD → header pin 1, RXD → pin 2, GND → pin 12. **Do not connect its VCC** | CH340/FT232 boards often have a 5 V/3.3 V jumper: **set 3.3 V**. MAX 10 pins are not 5 V tolerant |
| **B1** | Raspberry Pi Pico + Raspberry Pi's official **Debugprobe** firmware (drag-and-drop `debugprobe_on_pico.uf2`, no coding) | Pico **GP4 (TX, pin 6) → header pin 1**, **GP5 (RX, pin 7) → pin 2**, GND → pin 12; 115,200 baud (Raspberry Pi's `board_pico_config.h`) | Driverless (USB CDC); a Pico is ~RM20–25 (ASSUMPTION) and common |
| **B2** | Any ESP32/ESP8266 dev board with a CP2102/CH340 on it | Tie **EN to GND** (holds the ESP in reset), board TX0 → pin 1, RX0 → pin 2, GND → GND | Reuses the board's own USB-UART chip; 3.3 V logic |
| **C** | Nothing | — | **Standalone box**: everything in §3 except steps 6 and the dashboard. The laptop shows the slides and the AWS recording. Still a complete demo |

Not planned: a JTAG link through the board's own USB-Blaster (Virtual JTAG + Tcl) — possible with
no extra hardware, but a day of engineering and Quartus running at the booth; only if A and B fail
and there is time.

**The dashboard ("LaneX Live")**: one HTML page, reusing `application/replay/lane_core.js` (the
replay page's CRC-16, Chaskey-12 and record decoder, already tested against the golden model),
reading the serial port with the browser's **Web Serial** API (Chrome or Edge; no install). It shows
each record decoded, CRC ✓, signature ✓ (it finds the counter itself), totals (vehicles, RM
collected, alarms), and three back-office buttons: report a preset tag stolen (`H` frame), clear it
(`h`), close/open the lane (`C`). Frames from the laptop and from the board are merged **frame by
frame** in fabric (never interleaved mid-frame).

## 6. Parts (Tier 1)

| Part | Qty | Note | Price (ASSUMPTION, Malaysian online shops) |
| --- | --- | --- | --- |
| IR obstacle sensor module (FC-51 / "IR obstacle avoidance", LM393, digital out, active low) | 2 | **Power from 3.3 V (header pin 29)**, never 5 V: the output swings to its supply | RM2–4 each |
| LEDs 5 mm: green, white (or yellow), red, + 330 Ω resistors — or a 3-LED "traffic light" module | 1 set | Active high from the GPIO | RM3–6 |
| Active buzzer module (3.3–5 V, with transistor) | 1 | Power from 3.3 V | RM2–4 |
| Female–female Dupont jumpers | ~15 | | RM3–6 |
| Toy car + **toy lorry taller than the car** (≈1:43–1:64 scale) | 1 each | The height difference is the classifier | RM10–20 |
| Cardboard/foam gantry, tape | — | Two sensors at different heights | — |
| USB power bank + USB-A–B cable | 1 | Powers the board standalone | (own) |
| **Plan A** USB-UART 3.3 V **or Plan B1** Raspberry Pi Pico | 1 | | RM8–25 |

**Wiring (header JP1, from Terasic's schematic):**

| Header pin | FPGA ball | Signal | Connects to |
| --- | --- | --- | --- |
| 1 | V10 (GPIO_0) | host → FPGA (FPGA receives) | adapter TXD / Pico GP4 |
| 2 | W10 (GPIO_1) | FPGA → host | adapter RXD / Pico GP5 |
| 3 | V9 (GPIO_2) | low beam, input, weak pull-up | IR sensor 1 OUT |
| 4 | W9 (GPIO_3) | high beam, input, weak pull-up | IR sensor 2 OUT |
| 5 | V8 (GPIO_4) | green LED | LED anode via 330 Ω |
| 6 | W8 (GPIO_5) | white LED (flash) | LED anode via 330 Ω |
| 7 | V7 (GPIO_6) | red LED | LED anode via 330 Ω |
| 8 | W7 (GPIO_7) | buzzer | buzzer module IN |
| 9 | W6 (GPIO_8) | lane-closed LED (optional) | LED anode via 330 Ω |
| 12 | — | GND | adapter/Pico GND |
| 29 | — | **3.3 V** | sensors VCC, buzzer VCC |
| 30 | — | GND | sensors, LEDs, buzzer GND |
| 11 | — | 5 V | **leave unconnected** |

Unconnected sensor pins read "clear" (weak pull-up, active-low sensors), so the board behaves
safely with nothing plugged in.

## 7. Technical plan

| Item | Plan |
| --- | --- |
| Source of truth | `scripts/stage4/gen_riscv_sv.py --target de10lite` emits `stage4/de10lite/lanex_de10lite.v` (the chip from `rtl/` + the ROM from `firmware.hex`, as for AWS) + the board fabric; plus `lanex.qpf`, `lanex.qsf` (device, every pin, I/O standard 3.3-V LVTTL, weak pull-ups, `INTERNAL_FLASH_UPDATE_MODE` as Terasic's own file), `lanex.sdc` |
| Clock | MAX 10 PLL (ALTPLL, instantiated directly, no IP wizard): 50 MHz × 5 / 8 = **31.25 MHz**, the same as AWS; UART divider 271. If Quartus's timing report says the core misses 31.25 MHz on this slower 55 nm chip, regenerate at 25 MHz (one switch; the firmware's budgets are in cycles and still hold). **Compiles are free and local**, so iterating costs nothing |
| One clock domain | Chip, sender, decoder and lane logic all run on the PLL clock; only the 50 MHz input and the asynchronous pins/UART lines cross (2-flip-flop synchronisers) |
| Reset | KEY0, PLL lock, and the tour player's per-scenario reset (each golden line starts from reset, as in emu) |
| Frame sender | Builds frames from small templates with **live fields** (the read's millisecond time, a sighting at "now − 30 s") and computes the frame CRC-16 on the fly; Gen2 tag CRCs are precomputed by the generator from `lane_model.py`. Arbitrates whole frames between: boot config, the tag reader emulator, the tour player, the host link |
| Boot sequence | `P` (RSSI floor 30), `G` (gantry 2 at 40.0 km), `H` (the stolen preset), `K` (the demo key) — then `I`: the identify record is decoded and compared with `0x56DE` → LEDR9 |
| Tag reader emulator | On a vehicle's arrival, sends one `R` frame for the selected preset (for CLOnE, first an `S` sighting at gantry 2, now − 30 s). Time = a millisecond counter, so the chip's guard/dedup rules behave as in a real lane |
| Record decoder | A UART receiver on the chip's TX, 8-byte records, CRC-16 check, `V`/`A`/`I`/`E`/`Q` handled; drives the 7-segment words, fare digits, LEDR8 |
| Tour player | A ROM of the 12 golden `./emu` lines (generated from `lane_model.emu_commands()`): reset, pins, frames, then compare the last 8 bytes and the lamps with the golden values → "PASS12" |
| Resources | The chip alone synthesises to ~14.5k LEs + 1.2k FFs of 50k (Yosys estimate); the fabric adds roughly 1–2k LEs (ASSUMPTION). DMEM in 8 of 182 M9K blocks |
| Persistence | Program the `.pof` into the MAX 10's internal configuration flash: the box **boots the demo on power-up, no laptop** |

## 8. Verification before you touch the board

| # | Check | Tool |
| --- | --- | --- |
| V1 | The generated top elaborates and lints | Icarus + Verilator |
| V2 | **Differential, whole board**: a testbench drives the sensors and switches through every preset × car/lorry/motorcycle × lane open/closed; it logs every byte the fabric sends the chip and every pin change, and **`lane_model.py` replays them and must produce the same records** (whatever the fabric does, the chip must agree with the golden model) | Icarus + Python |
| V3 | Display: each decision shows the right 7-segment word and fare; LEDs/buzzer patterns | Icarus |
| V4 | Tour mode: all 12 golden lines pass in simulation; boot identify shows `56dE` | Icarus |
| V5 | Host link: frames from the "laptop" merge with board frames without corruption; a back-office `H` changes the next decision | Icarus |
| V6 | Dashboard decoding/verification of a recorded stream | the existing `test_lane_core.py` + a stream test |
| V7 | Synthesis sanity (no latch, resource estimate); **Quartus's own timing report** is checked by you after the first compile (`08_quartus_setup.md` §6) | Yosys `synth_intel`; Quartus |

## 9. Bring-up on the board (your steps)

| Step | Do | Pass |
| --- | --- | --- |
| B0 | Install Quartus + driver (`08`) | Programmer shows USB-Blaster, Auto Detect finds 10M50DA |
| B1 | Compile, program the `.sof` | All segments/LEDs light for 1 s (lamp test), then the scrolling banner |
| B2 | Wait 2 s | **"Id 56dE"** and LEDR9 on: the chip is alive and runs the right ROM |
| B3 | SW9 up, hold KEY1 | **"PASS12"** |
| B4 | SW8 up (manual), tag = CAr, press/release KEY1 | "CHArGE" / "2.50", LEDR4 |
| B5 | Wire the sensors and lamps; SW8 down; push the car / the lorry | as §3 |
| B6 | Plan A/B link + dashboard | records stream, ✓ CRC ✓ signature |
| B7 | Program the `.pof` (internal flash), power from the power bank | the demo starts by itself |

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| Core misses 31.25 MHz on MAX 10 | Regenerate at 25 MHz (or 20 MHz); recompile locally, free |
| A 5 V signal on a MAX 10 pin (sensor powered from 5 V, adapter on 5 V) | Wiring table: sensors and buzzer on 3.3 V (pin 29); adapters set to 3.3 V; nothing on pin 11 |
| No admin rights for the USB-Blaster driver | Needs an administrator once (`08` §4); plan this first |
| No USB-UART available | Plan B1/B2, else plan C (standalone) — same bitstream |
| Sensors unreliable under venue lighting (IR) | Adjust each module's potentiometer on site; SW8 manual mode with KEY1 as the vehicle |
| Time (event 14–17 Oct) | Order: AWS done ✓ → this plan; Tier 1 only; VGA and real RFID stay out |

## 11. Effort and schedule

| When | Me | You |
| --- | --- | --- |
| Day 1 (11 Oct) | Generator target, fabric RTL, qsf/sdc, testbenches V1–V7, dashboard, wiring card | Install Quartus + driver (`08`); buy parts; ask for a USB-UART or a Pico |
| Day 2 (12 Oct) | Fix anything the first compile/timing shows | B0–B6; build the gantry |
| Day 3 (13 Oct) | Polish the display words/banner from your feedback | B7; rehearse "Beat the toll" |

## 12. Ideas considered and left out (on purpose)

| Idea | Why not now |
| --- | --- |
| VGA dashboard drawn by the FPGA | ~a day of RTL (fonts, text buffer) and the booth may have no VGA monitor |
| Real RFID cards (RC522 + Arduino) — Tier 2 | More parts and failure points; HF cards are not the UHF Gen2 tags of real tolling |
| Speed measurement with the two beams | Fun but off-message |
| Accelerometer "tamper" alarm | Needs a firmware change: not worth re-verifying the chip |
