# A physical LaneX prototype on the DE10-Lite (MAX 10): scope and recommendation

**Status:** scoped, not built; to start after the AWS bring-up ladder passes (or now, if Nicholas
says so). Board assumed: **Terasic DE10-Lite** (the Intel/Altera University Program "MAX 10 student"
board) — confirm the exact board before any pin file is written.

## 1. Verdict

**Yes: realistic, worth it, and low-risk if kept to Tier 0 (+ Tier 1 if time).**

- **It fits easily.** Our exact chip (`rvbl2_top` from `stage4/riscv.sv`: core, GPIO, UART, the
  firmware ROM, 8 KB DMEM) synthesises for MAX 10 to ~14,540 logic cells + 1,222 flip-flops
  (Yosys `synth_intel`, `build/stage4/yosys_max10_stat.txt`) — **~30 % of the 10M50's 50K LEs**;
  DMEM takes 8 of 182 M9K blocks. Quartus will map the multiplier to the board's 18×18 multipliers
  and do better still.
- **It is the same verified design.** The board wraps `rvbl2_top` exactly as the AWS shell does:
  no change to `rtl/` or the firmware; one generator, one more target.
- **It wins rooms.** A recruitment fair is people walking past. A box they can touch — flip a switch
  to "be a lorry", press "drive through", watch the alarm fire — beats an SSH terminal, works with no
  network at KLCC, and does not depend on AWS being reachable on the day.
- **It also de-risks AWS.** Quartus's TimeQuest gives a *real* post-route timing report for the same
  core on a 55 nm MAX 10, a much slower fabric than the F2's 16 nm UltraScale+. If it meets
  31.25 MHz there, the AWS core clock has a large margin — hard evidence, not an estimate.
- **The pitch line:** "the same RTL runs on two FPGA families and is laid out for an ASIC".

## 2. What the box does (Tier 0: the board alone, no extra parts)

```text
   SW0  vehicle present (P0)          LEDR4 charged   LEDR5 camera   LEDR6 alarm   LEDR7 lane closed
   SW2:1 classifier class (P2:P1)     HEX5..HEX0: the decision, decoded from the chip's own record
   SW3  lane closed (P3)                          "CHArGE"  "2.50"   "LorrY"  "StOLEn"  "CLonE"
   KEY1 "a car drives through"                    "no tAG"  "FrEE"   "CLOSEd" "Auth  " (A record)
   KEY0 reset                         LEDR9: "the chip agrees with the golden model" (self-check)
```

| Block (new RTL, board-only) | What it does |
| --- | --- |
| `de10lite_top` | PLL 50 → 31.25 MHz (50 × 5 / 8) or 25 MHz; instantiates `rvbl2_top` unchanged; maps switches/LEDs |
| **Scenario player** | A small ROM of verified traffic: the bytes of our 12 `./emu` lines (frames + pin events), generated from `lane_model.py`. KEY1 plays the next vehicle into the chip's UART and pins — exactly what emu does on the F2, on-board |
| **Record decoder** | Listens to the chip's TX line (a 115,200-baud receiver in fabric), checks each 8-byte record's CRC, and shows status + fare on the 7-segment displays |
| **Self-check** | The player also holds the golden model's expected record for each vehicle; LEDR9 lights when the chip's record matches. The verification culture, visible |
| **Free-play mode** | SW9 = 1: the switches drive P0–P3 live and KEY1 sends one pre-made tag read (SW8 picks a normal or a stolen tag) — visitors "drive" themselves |

Nothing here runs on our CPU except LaneX itself; the player and decoder are test equipment in
fabric, like the organisers' `emu`.

## 3. Tiers

| Tier | Adds | Parts (ASSUMPTION: typical local prices) | Effort | Value |
| --- | --- | --- | --- | --- |
| **0** | §2: board-only demo, self-checking | none | Me ~1 day (RTL, pin file, simulation against the golden model, build script); you ~2–3 h (install Quartus, compile, program, test) | High |
| **1** | **Laptop dashboard**: USB-UART adapter on the GPIO header → a Python "back office + lane simulator" (reuses `lane_model.py`'s frame builders) streams live traffic and shows decoded, CRC- and MAC-verified records. **Physical lane**: a toy car breaking an IR beam (or an ultrasonic sensor) = P0; big green/red LEDs + a buzzer for the alarm | CP2102/CH340 3.3 V adapter ~RM10–15; IR break-beam or HC-SR04 ~RM5–10; LEDs, resistors, buzzer, jumpers ~RM10; a toy car | +1 day me, +2 h you (wiring) | High |
| 2 | **Real cards as tags**: an RC522 (13.56 MHz, MIFARE) on an Arduino turns a card's UID into an `R` frame (Gen2 CRC computed) — honestly labelled "a stand-in for the UHF reader". Or a **VGA lane dashboard** on the board's VGA port | RC522 + Arduino ~RM40 | +1–2 days | Medium (fun, but more failure points) |
| ✗ | A real UHF Gen2 reader; a soft processor (Nios) for the glue; SDRAM | — | — | Not worth it: cost, and it dilutes "our CPU does the work" |

## 4. Plan and who does what

1. **Me (no hardware needed):** `--target de10lite` in the generator (same `rtl/` + firmware); the
   board top, PLL, player, decoder, 7-segment driver; the `.qsf` pin file from Terasic's DE10-Lite
   pin table; a self-checking simulation of the *whole board top* against the golden model; a
   one-command Quartus build script (`quartus_sh --flow compile`) that also prints TimeQuest's Fmax.
2. **You:** install **Quartus Prime Lite** with MAX 10 support (free; user-space install works;
   ~6 GB), run the build (~5–10 min), program over the on-board USB-Blaster, and walk the bring-up:
   reset → switches/LEDs → KEY1 plays vehicle 1 → `CHArGE 2.50`, LEDR4 + LEDR9.
3. **Demo kit:** the board, a USB cable/power bank, a printed card with the switch legend.

## 5. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Wrong pin assignments | Pin file from the board manual's table, reviewed line by line; a "lamp test" on reset |
| The combinational ROM limits Fmax on MAX 10 | Quartus reports it; fall back to 25 MHz (UART divider 217) — the firmware budgets still hold |
| Quartus install or licence trouble | Lite edition needs no licence; MAX 10 is fully supported |
| Takes time from AWS before the event | Strict order: AWS ladder first; Tier 0 only after; Tier 1 only if Tier 0 is done |
| Live hardware fails on stage | Self-check LED shows it immediately; fall back to the AWS run recording and the replay page |

## 6. Demo with the box: "Beat the toll" (2 minutes, visitors play)

1. "Drive a car through" (KEY1, player): **CHArGE 2.50**, green.
2. "Now cheat: put your car tag on a lorry" (SW2:1 = lorry, free-play): **LorrY** + camera.
3. "Use a stolen car" (SW8): **StOLEn**, alarm (and the buzzer, Tier 1).
4. "Clone a tag" (player): **CLonE** — "your tag was 40 km away 30 seconds ago".
5. Point at LEDR9: "and every decision you saw was checked live against our independent model".
