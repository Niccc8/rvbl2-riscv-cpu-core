# LaneX desk lane: a physical prototype on the DE10-Lite (Tier 1)

**Status: built and verified in simulation and in Quartus; board bring-up is Nicholas's (§9).**
Board confirmed from Nicholas's photos: Terasic **DE10-Lite** (box "DE10-Lite (OJ)", LOT#3023),
Intel/Altera **MAX 10 10M50DAF484C7G**. Plan approved 2026-10-10 ("assume the USB-UART adapter").
**Rescoped 2026-10-11:** one ultrasonic sensor (HC-SR04) instead of two IR beams, because that is
the sensor Nicholas has. It is mounted over the lane looking down, and measures each vehicle's
height, so it gives presence **and** the car/lorry class the way overhead gantry profilers do.
Files: `stage4/de10lite/` (start with its `README.md`). Quartus: `08_quartus_setup.md`.

## 1. The idea in one paragraph

A toy lane on a desk. A cardboard gantry holds **one ultrasonic sensor looking down** at the lane.
It sees each toy vehicle pass and measures its **height**: low is a car, tall is a **lorry**, the
way real gantries classify by height. Visitors pick the toy vehicle's **tag** with the board's
switches (a car tag, a stolen tag, a cloned tag…), push a **toy car or a toy lorry** under the
sensor, and the lane decides on the spot: a **green** light and "CHArGE 2.50", or a **white camera
flash**, or a **red light and a buzzer**. The decision is made by **the exact RVBL-2 chip and LaneX
firmware that passed all 12 lines on the AWS F2** (same RTL, same ROM, same fingerprint `0x56DE`),
now on a second FPGA family. A laptop on a USB-UART shows a **live dashboard**: every record
decoded, its CRC and its Chaskey-12 signature verified in the browser, revenue and alarms counted,
and "back-office" buttons (report a tag stolen, close the lane) that change the lane's next
decision live.

## 2. What is on the board

```text
                         DE10-Lite (MAX 10)
  ┌────────────────────────────────────────────────────────────────────────────┐
  │  rvbl2_top = the AWS chip (core, GPIO, UART, LaneX ROM, 8 KB RAM)            │
  │      ▲ UART rx            │ UART tx             │ P7..P4 lamps   ▲ P3..P0    │
  │  ┌─────────┐   one ordered channel (lx_chipio)  ▼                │           │
  │  │ frames: │◄── boot config + identify     ┌──────────┐  ┌──────────────┐  │
  │  │ CRC-16, │◄── tag-reader emulator ◄──────┤ lane:    │◄─┤ lx_sonar     │◄─┼── HC-SR04
  │  │ live t  │◄── laptop frames (whole only) │ presence,│  │ (height, mm) │   │   (Trig, Echo)
  │  │         │◄── tour player (12 AWS lines) │ class    │  └──────────────┘   │
  │  └─────────┘                               └──────────┘   SW, KEY1          │
  │  record decoder (CRC-16) ──► 7-segment words, fare, LEDs, lamps, buzzer       │
  │  chip UART tx ──────────────► GPIO 1 to the laptop, unchanged                 │
  └────────────────────────────────────────────────────────────────────────────┘
```

**Everything around the chip is test equipment in fabric**, the board's own equivalent of the
organisers' `emu`: it feeds the chip frames and pins and reads its records. **LaneX itself runs
only on our CPU.** No change to `rtl/` or the firmware. `scripts/stage4/gen_de10lite.py` builds the
chip from `rtl/` with the AWS generator's own code (`gen_riscv_sv.chip_modules`, target
`de10lite`). Two value-for-value differences: the pad tri-state is resolved in fabric (a MAX 10
has no internal tri-state), and the data RAM is coded as Quartus infers M9K blocks.

## 3. The experience, step by step

| # | Visitor does | The lane does | Why it impresses |
| --- | --- | --- | --- |
| 0 | (power on, USB power bank, lane empty) | Lamp test; the 7-seg scrolls "LAnE  rISC-V  bEAt tHE toLL"; then **`Id.56dE`**: the chip measured its own ROM, the same fingerprint as on AWS | Self-test you can see; same silicon story |
| 1 | Sets the tag switches to **CAr**, pushes the **toy car** under the sensor | While it passes, the display shows its height (`h  4.0`); then a green light, a chirp, **`CHArGE` / `2.50`** | It works, and you see it measure |
| 2 | Same car tag, pushes the **toy lorry** | Tall: `h  9.0`, LEDR1. **`CLASS` / `7.50`**, white flash | The classic fraud, caught physically |
| 3 | Tag **StOLEn** | **Red light + buzzer**, `StOLEn` | Alarm |
| 4 | Tag **CLOnE** | `CLOnE`: "this tag was 40 km away 30 s ago" | The clever one |
| 5 | Pushes the same car again within 3 s | `no tAG` + flash: tailgating protection | Shows a real rule |
| 6 | (laptop) clicks **"Report stolen" (Taxi)**, then pushes a car with the `CAb` tag | The next decision is **`StOLEn`** | Back office ↔ lane, live |
| 7 | (presenter) flips SW9 | **Tour mode**: the 12 AWS golden scenarios run on the board, each checked against its golden answer, paced and steady (`tESt01` 0.5 s, then its result and lamps 0.9 s) … **`PASS12`**, LEDR9 | The verification culture, live |

## 4. Inputs, outputs, switches

| Control | Meaning |
| --- | --- |
| Ultrasonic sensor | Each reading is the median of the last three. The floor is learnt when 8 filtered readings agree, and the lane is **armed** only once it has seen that floor (a floor learnt from a stray far echo can never make a vehicle). **P0 vehicle present** when something stands ≥ `PRESENT_MM` (15 mm) above the floor for 4 filtered readings in a row (0.25 s); gone after 8 readings of the floor itself (0.5 s); a lost echo (farther than the floor) counts for nothing. **Class 3 (lorry)** when the lowest of its last three heights reaches `TALL_MM` (60 mm), latched while it is there. Rules and their evidence: `06_verification.md` §1d round 3 |
| SW0 | P3 lane closed |
| SW2:SW1 | Class override: 00 = the sensor (car/lorry), 01 = van, 10 = lorry, 11 = motorcycle |
| SW5:SW3 | Tag preset: 0 nonE · 1 **CAr** · 2 **LorrY** · 3 **CAb** (taxi) · 4 **StOLEn** · 5 **CLOnE** · 6 **bAd** (damaged, bad Gen2 CRC) · 7 **FAr** (adjacent lane, weak read) |
| SW6 / SW7 | Buzzer module is low-level trigger (pin 8 only) / mute the buzzer |
| SW8 | Manual: KEY1 is the vehicle (press = in the zone) — the no-sensor fallback |
| SW9 | Tour mode: the 12 AWS `./emu` lines, then `PASS12` (or `FAIL` + the first failing line) |
| KEY0 | Reset, when held 20 ms (a glitch is ignored); the sensor relearns the floor |
| KEY1 | Manual vehicle when SW8 is up; otherwise "fingerprint the ROM now" (an `I` frame) |

| Output | Meaning |
| --- | --- |
| LEDR0 / LEDR1 | Something is under the sensor / that vehicle is tall |
| LEDR2 | The chip sees a vehicle (P0) |
| LEDR3 | The laptop is sending |
| LEDR4–7 | P4 charged · P5 camera · P6 alarm · P7 lane closed (exactly the `-o` lamps on AWS) |
| LEDR8 | The last vehicle record was **signed** (its `A` record arrived, CRC ok) |
| LEDR9 | Self-check: the chip's ROM fingerprint matches the build (tour mode: all 12 passed) |
| HEX5–HEX0 | Idle: the tag preset (or `CLOSEd`). A vehicle under the sensor: its height. After a decision: the word for 1.5 s, then the fare for 2.5 s (alarms: the word, blinking, 4 s). `Err  n` for a refused frame, `Id.56dE` for an identity |
| GPIO lamps | Green (charged, 4 s), white (camera flash, 200 ms), red (alarm, 4 s), buzzer (charged: a chirp; alarm: three beeps), lane-closed lamp |

Decision words: `CHArGE`, `no tAG`, `CLASS`, `StOLEn`, `CLOnE`, `FrEE`, `CLOSEd`.

## 5. The host link

| Plan | Hardware | Wiring |
| --- | --- | --- |
| **A (chosen)** | USB-UART module, **3.3 V logic** (CP2102, CH340 or FT232) | adapter TXD → header pin 1, RXD → pin 2, GND → pin 12. Its VCC stays unconnected; its jumper on 3.3 V |
| B1 (fallback) | Raspberry Pi Pico + Raspberry Pi's **Debugprobe** firmware | GP4 (TX) → pin 1, GP5 (RX) → pin 2, GND → pin 12; 115,200 baud |
| C (fallback) | Nothing | The standalone box: everything except the dashboard |

The design is the same in every case. **LaneX Live** (`stage4/de10lite/lanex_live.html`) is one
self-contained page: it reuses `application/replay/lane_core.js` (CRC-16, Chaskey-12, the record
decoder, already tested against the golden model) and reads the port with the browser's Web Serial
API (Chrome or Edge). It shows each record decoded, CRC ✓, signature ✓ (it finds the record
counter itself), the totals, the chip's identity, and the back-office buttons (`H`, `h`, `C`, `Q`,
`I` frames). The board forwards a laptop frame only when it is whole, between its own frames.
`lanex_live.html#demo` plays a recorded stream (made by the golden model from the board's own
frames) with no board.

## 6. Parts

| Part | Qty | Note |
| --- | --- | --- |
| Ultrasonic sensor **HC-SR04** (VCC, Trig, Echo, GND) | 1 | VCC from header pin 11 (5 V). **Echo is 5 V: through a 1 kΩ + 2 kΩ divider** to pin 3 |
| Resistors 1 kΩ and 2 kΩ (or 2 × 1 kΩ in series) | 1 each | The Echo divider |
| LEDs: green, red, yellow (330 Ω), white (100 Ω) | 1 each | Optional: the board's own LEDs show the same |
| Buzzer: active 2-leg (e.g. TMB12A05) on pin 8, passive 2-leg through 330 Ω on pin 10, or a 3-pin module on pin 8 | 1 | Optional. SW6 if a module is low-level trigger |
| USB-UART 3.3 V | 1 | Plan A |
| Mini breadboard + jumpers | 1 + ~20 | |
| Toy car, toy lorry clearly taller | 1 each | |

**Wiring (header JP1, Terasic's schematic):** `stage4/de10lite/wiring_card.html` (printable) and
`wiring_card.png`.

| Header pin | FPGA ball | Signal | Connects to |
| --- | --- | --- | --- |
| 1 | V10 (GPIO_0) | laptop → board | adapter TXD |
| 2 | W10 (GPIO_1) | board → laptop | adapter RXD |
| 3 | V9 (GPIO_2) | ultrasonic Echo, in, weak pull-up | HC-SR04 Echo **through 1 kΩ**; and 2 kΩ from here to GND |
| 4 | W9 (GPIO_3) | ultrasonic Trig, out | HC-SR04 Trig |
| 5–9 | V8, W8, V7, W7, W6 | green, white, red, buzzer (a level), lane closed | LEDs via resistors; an active buzzer's + or a module's IN |
| 10 | V5 | buzzer, a 2.4 kHz tone | a passive buzzer through 330 Ω |
| 11 | — | 5 V | **HC-SR04 VCC only** |
| 12, 30 | — | GND | HC-SR04 GND, adapter GND, the rail |
| 29 | — | 3.3 V | buzzer module VCC (a module only) |

## 7. Technical design (as built)

| Item | Design |
| --- | --- |
| Source of truth | `scripts/stage4/gen_de10lite.py` writes `lanex_chip.v` (the chip + ROM, as for AWS), `lanex_data.v` (frame templates, the tour's 12 lines with golden answers, 7-segment words), `lanex.qpf/qsf/sdc`, the wiring card and the dashboard. `--check` fails if any is stale |
| Clock | MAX 10 PLL (`altpll`, instantiated directly): 50 MHz × 5 / 8 = **31.25 MHz**, the AWS clock. Quartus (high-performance fitter effort): **+4.39 ns setup slack** at Slow 1200 mV 85 °C (Fmax 36.22 MHz); fallback `CORE_HZ` 25 MHz, one line in `lanex.qsf` |
| One clock domain | Only the 50 MHz input (into the PLL) and the asynchronous pins (switches, KEY1, Echo, the laptop's line) cross, through 2-flip-flop synchronisers |
| One channel into the chip (`lx_chipio`) | Pin changes and whole frames, one at a time; a pin change only between frames, then a 40,000-cycle settle (PROTOCOL.md §7). So the order the chip sees is exactly the order a testbench logs, and the golden model can replay it |
| The lane | `lx_sonar` triggers the HC-SR04 every 62.5 ms and times the echo (mm = cycles × 171.5 m/s). A vehicle never "leaves" before the chip has seen it arrive with its current class |
| Frames | Built from templates with live fields (the read's millisecond time; the clone's sighting at now − 30 s) and the CRC-16 computed in fabric. Boot: `P` (RSSI floor 30, frame timeout 48), `C`, `G` (gantry 2 at 40.0 km), `H` (the stolen preset), `K` (the demo key), then `I` |
| Records | 8-byte records (CRC-16 checked, re-synchronised byte by byte if needed) drive the display, LEDs, lamps and buzzer; the chip's UART output also goes to the laptop unchanged |
| Tour | Each of the 12 `./emu` lines from a chip reset, its pins and frames in order; then its last 8 bytes and lamps compared with the golden answer, as `emu -r`/`-o` do |
| Resources (Quartus) | 14,936 LEs (30 %), 2,368 registers, 66,048 memory bits (the 8 KB data RAM and the 64-byte laptop buffer in M9K), 11 multiplier elements, 1 PLL |
| Persistence | The `.pof` in the MAX 10's internal flash: the box boots the demo on power-up, no laptop |

## 8. Verification (before the board)

| # | Check | Tool | Result |
| --- | --- | --- | --- |
| V1 | The design elaborates and lints | Icarus, Verilator | clean (width notes only) |
| V2 | **Differential, whole board**: every tag preset × car / lorry / manual / van / motorcycle, the lane open and closed. Every byte and pin change the chip receives is logged and **`lane_model.py` replays them and must produce exactly the chip's bytes**. Also each decision is the one the scenario means (from PROTOCOL.md §6, worked out independently), and a stress pass with time squeezed 31× | `sim/check_board.py` (Verilator) | **PASS** (1,291 checks in all, V2–V5 and every mode change, fault, random session and a real-speed flicker analysis; `06` §1d) |
| V3 | Display, LEDs, lamps, buzzer for every decision | same | same |
| V4 | Tour mode: the 12 lines, each also replayed by the model; `PASS12` | same | same |
| V5 | Laptop frames merged whole; `H` changes the next decision; garbage, half and oversize frames never reach the chip | same | same |
| V6 | The dashboard's logic on the simulated laptop stream; damage; forgery | `dashboard/test_live.py` (QuickJS) | **PASS**, 29 checks |
| V7 | **Quartus** synthesis, fit, timing, programming files | Quartus Prime Lite 25.1std.0 on Nicholas's laptop | 0 errors; timing met, +4.39 ns |

Two real fabric bugs were found and fixed by V2 before any hardware: a vehicle could "leave" before
the chip had seen it arrive (if the channel was busy with a laptop frame), and a lorry's class could
be lost the same way. Both now wait until the chip has seen the vehicle's current pins.

## 9. Bring-up on the board (your steps)

`stage4/de10lite/README.md` §"Your steps" (compile, program, `Id.56dE`, `PASS12`, manual car, the
sensor, the dashboard, the flash), and the wiring card's bring-up list.

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| **5 V on a MAX 10 pin** (the HC-SR04's Echo) | The 1 kΩ/2 kΩ divider; the wiring card's first rule; measure pin 29 → 30 = 3.3 V first |
| Ultrasonic misses a sloped toy surface | A missed echo changes nothing (not counted as "clear"); presence needs 2 readings, departure 3; KEY1 manual mode as a fallback |
| Car/lorry threshold wrong for the toys | The display shows each toy's measured height; `TALL_MM` in `lanex.qsf` |
| Something under the sensor at power-up | Once it is taken away, 16 readings agreeing on the farther floor re-learn it (about 1 s); KEY0 relearns everything |
| The sensor stops answering under a vehicle | After 16 readings with no echo (1 s) the vehicle counts as gone and is decided |
| The chip stops answering | Watchdog: no decision 1.5 s after a vehicle leaves → the board restarts the chip (warm boot) |
| Flicker between states | Tour results latched and paced; warm boots hold the picture until the chip's identity arrives; a leaving vehicle's height stays until its decision. Checked at real speed in simulation: nothing visible lasts 5–150 ms unless meant to |
| Timing margin | Met with +4.39 ns (16 %); `CORE_HZ` 25 MHz fallback, one line |
| No admin rights for the driver | Done: Quartus and the USB-Blaster work (Nicholas's school project ran) |
| Time (event 14–17 Oct) | Tier 1 only; VGA and real RFID stay out |

## 11. Ideas considered and left out (on purpose)

| Idea | Why not now |
| --- | --- |
| VGA dashboard drawn by the FPGA | ~a day of RTL; the laptop dashboard covers it |
| Real RFID cards (RC522) | More parts and failure points; HF cards are not the UHF Gen2 tags of real tolling |
| Speed from the ultrasonic | Off-message |
| Accelerometer "tamper" alarm | Needs a firmware change: not worth re-verifying the chip |
