# The lane controller: application specification (protocol v3)

**RVBL-2 Stage 3 application · Equipe 13 · 2026-09-26**

> This is the specification of what the firmware (`firmware/lane/main.c`) does. Its
> executable form is `testbench/lane_model.py`: the firmware must produce, byte for byte, the model's output
> stream and pin states, and the harnesses in §9 check exactly that. If this page and the
> model ever disagree, the model is right and this page is stale.

## 1. The system

One lane of a barrier-free (multi-lane free-flow) toll gantry. Vehicles pass at highway
speed. The equipment around the chip:

- a **UHF RFID reader** (EPC Gen2 / ISO 18000-63) reports every tag read;
- a **vehicle classifier** (lidar, loops or treadles) reports presence and a class code;
- an **ANPR camera** photographs violators;
- the **toll back end** sends hotlists, fares, gantry positions, sightings, parameters and
  the record-authentication key.

**The chip is the lane controller.** It fuses these inputs, decides for each vehicle in
real time, fires the camera and alarm lines, and emits one record per vehicle, sealed with
a CRC and, once a key is loaded, authenticated with Chaskey-12 so the toll back end can prove
which gantry made it.

## 2. Pins (DATADIR = `0xF0`)

This is the same direction as the organisers' GPIO and UART test firmware: `./emu -d 0xF0`.

| Pin | Dir | Meaning |
|---|---|---|
| P0 | in | Vehicle present in the read zone (level) |
| P2:P1 | in | Class code from the classifier, latched while P0 = 1: `00` class 1, `01` class 2, `10` class 3, `11` class 0 (motorcycle) |
| P3 | in | Lane-closed switch (level) |
| P4 | out | **Charged**: the last vehicle was charged |
| P5 | out | **Camera**: the last vehicle triggered the ANPR camera |
| P6 | out | **Alarm**: the last vehicle is stolen/blocked, or a cloned tag |
| P7 | out | Lane closed, by the switch or by configuration (live) |

The classes are those of the Malaysian toll rules:
- class 1: 2 axles, 3–4 wheels;
- class 2: 2 axles, 5–6 wheels;
- class 3: 3 or more axles.

Classes 4 (taxi) and 5 (bus) are registration classes, carried by the tag.

The inputs are **levels, not pulses**. The organisers' `emu` changes pins with separate
register writes that can be a few hundred nanoseconds apart, too short for pulses to be
counted reliably by polling firmware.

## 3. Host → chip frames (UART, 115200 bps, 8-N-1)

```text
A5 | type | len | payload[len] | crc16 (little-endian)
crc16 = CRC-16/CCITT-FALSE over type, len and payload - computed on the chip by Xicrc
```

All multi-byte fields are little-endian, and `len` ≤ 32.

| Type | Name | Payload | Effect |
|---|---|---|---|
| `R` 0x52 | tag read | `t_ms` u32, `pc` u16, `epc`[12], `stored_crc` u16, `rssi` u8 (21 bytes) | Checked, then added to the vehicle in the zone, or remembered for the next one (the guard window) |
| `T` 0x54 | time | `t_ms` u32 | Advances the lane clock |
| `C` 0x43 | config | `gantry` u8, `lane_closed` u8, `fare[6]` u16 in sen (14 bytes) | Gantry ID, lane state, fares per class 0–5 |
| `G` 0x47 | gantry position | `gantry` u8, `pos` u16 in 0.1 km | Used by the clone check |
| `H` 0x48 | hotlist add | `epc`[12], `reason` u8 | Stolen or blocked tag |
| `h` 0x68 | hotlist delete | `epc`[12] | |
| `S` 0x53 | sighting | `epc`[12], `gantry` u8, `t_ms` u32 | The tag was seen at another gantry |
| `Q` 0x51 | query | — | The chip replies with a stats record |
| `P` 0x50 | parameters | `rssi_min` u8, `guard_ms` u16, `dedup_ms` u16, `vmax_kmh` u16, `hold` u8, `timeout` u16 (10 bytes) | Lane parameters (defaults 0, 500, 3000, 250, 64, 0); `hold` is the exit hold-off in main-loop iterations (0 counts as 1); `timeout` is the frame timeout in main-loop iterations, 0 = never (§7) |
| `K` 0x4B | record key | `key`[16], or nothing | 16 bytes: load a Chaskey-12 key, turn authentication on, reset the record counter to 0. Empty: authentication off |
| `I` 0x49 | identify | — | The chip measures its own ROM and replies with an identity record |

**Tag integrity.** A Gen2 tag stores `StoredCRC = CRC-16/EPC-C1G2(PC word ‖ EPC)`, which is
our Xicrc CRC-16/CCITT-FALSE followed by `XOR 0xFFFF`. The chip recomputes it with 14
`crcb` instructions and one `xor` (0xFFFF is too wide for `xori`), and ignores a read that does not match. The standard's
check value `0xD64E` is verified on the RTL by the firmware self-test (`firmware/selftest`).

**Registered class** = `epc[0] & 7`. This is our tag profile, and an assumption: the
Touch 'n Go tag layout is not public.

**Adjacent-lane reads.** A read whose `rssi` is below `rssi_min` is dropped: in a
free-flow gantry the next lane's tags are read too, only weaker.

## 4. Chip → host records

Every record is 8 bytes, so it fits the organisers' 8-byte receive buffer exactly. The last
two bytes are CRC-16/CCITT-FALSE over bytes 0–5, little-endian.

| Kind | Bytes 1–5 |
|---|---|
| `V` 0x56 vehicle | `seq` u8, `status` u8, `(phys << 4) \| tag_class` u8 (tag class 7 = none), `fare` u16 in sen |
| `A` 0x41 authenticator | `seq` u8 (the `V` it follows), `tag`[4] |
| `E` 0x45 line error | `reason` u8, `type` u8, `bad_frame` u8, 0, 0 |
| `Q` 0x51 stats | `vehicles` u16, `bad_tag` u8, `bad_frame` u8, `hotlist` u8 |
| `I` 0x49 identity | `version` u8 (3), `rom_words` u16, `rom_crc` u16 |

**Line errors.** A frame is rejected, counted in `bad_frame`, and reported with an `E`
record, for one of five reasons:

| Reason | Meaning |
|---|---|
| 1 | Frame CRC wrong |
| 2 | Length over 32 |
| 3 | Unknown frame type |
| 4 | Wrong length for the frame's type |
| 5 | Frame cut off: the line went quiet mid-frame (only while the frame timeout is on, §7) |

**One `E` per burst:** after an `E`, further errors are only counted until a good frame
arrives. A noisy line therefore cannot flood the transmit queue.

**Identity.** `rom_crc` is the Xicrc CRC-16 (seed `FFFF`, each 32-bit word most-significant
bit first) of the firmware image, from IMEM word 0 to the end of `.data`'s initial values
(`__rom_end`, the exact image in `firmware.bin`). The chip reads its own ROM to compute
it, as a background job, so the answer takes about 65,500 cycles (2.2 ms) at 115,200 bps and 46,700 at 921,600; records made
meanwhile may leave first. The host tool (`rvbl2 attest`) and the replay page compare it
with the build.

## 5. Record authentication (Chaskey-12)

**Algorithm.** Chaskey-12 (Mouha, 2015) is one of the three MACs standardised in
**ISO/IEC 29192-6:2019**, *Lightweight cryptography, Part 6: Message authentication codes*.
It was designed for 32-bit microcontrollers:
- the permutation uses only 32-bit add, rotate and XOR, twelve rounds;
- the core has no rotate instruction, so each rotation costs three.

**When.** While a key is loaded, every `V` record is followed by an `A` record.

**Tag.** The `A` record's tag is the first 4 bytes of the Chaskey-12 tag of the 12-byte
message:

```text
V[0..5] | gantry | 0x03 | counter u32 (little-endian)
```

- **`V[0..5]`:** the vehicle record without its CRC.
- **`gantry`:** the gantry ID from the last `C` frame.
- **`counter`:** counts `A` records since the key was loaded, so a replayed or reordered
  record fails.

**Verification.** The implementation matches the reference implementation's test vectors
at three levels:
- in Python, all 64 vectors (`lane_model.py`);
- on the RVBL-2 RTL, six lengths through the padded (K2) and complete-block (K1) paths
  (the firmware self-test, `SELFTEST PASS 82`);
- in the replay page's own JavaScript (`replay/test_lane_core.py`).

**Cost.** One tag costs one padded block: twelve rounds, 4 per main-loop iteration. The
`V` and its `A` leave together when the tag is done, and anything else that emits a record
first completes a pending tag, so the output order is always the model's.

**What it protects and what it doesn't:**
- A 32-bit truncated tag gives a forger a 1 in 2³² chance per record, which is adequate for
  an evidence trail, not for key exchange.
- The key is loaded in the clear over the UART: key provisioning is the toll back end's job
  and outside this chip.
- `DEMO_KEY` ("RVBL-2 lane key!") is a demonstration key.

## 6. The decision, made when a vehicle leaves

| Condition, first match wins | Status | Fare | P4 | P5 | P6 |
|---|---|---|---|---|---|
| Lane closed (P3, or configured) | 6 LANE_CLOSED | 0 | | | |
| No usable tag, class 0 | 5 FREE | 0 | | | |
| No usable tag | 1 NO_TAG | 0 | | ● | |
| Tag on the hotlist | 3 HOTLIST | 0 | | ● | ● |
| Tag last seen at another gantry, implied speed > `vmax_kmh` | 4 CLONE | 0 | | ● | ● |
| Registered class ≠ physical class (taxi needs class 1; bus needs 2 or 3) | 2 CLASS_MISMATCH | fare[physical] | ● | ● | |
| Otherwise | 0 CHARGED | fare[tag class] | ● | | |

**Which tag counts as "usable":**
- **Candidates:** the tags read while the vehicle was present, plus those read up to
  `guard_ms` before it arrived. Only reads that pass the Gen2 CRC and the RSSI floor count.
- **Tailgating:** a tag already charged at this gantry within `dedup_ms` is excluded. That
  rejects the previous car's tag being read again.
- **Choice:** of the rest, the tag with the most reads wins; a tie goes to the higher RSSI.
- **Afterwards:** the chosen tag's sighting is recorded at this gantry.

**The clone test uses no division:** `distance_0.1km × 360000 > vmax_kmh × Δt_ms`. With
`Δt ≤ 0`, any nonzero distance counts as a clone.

**Table sizes:**

| Table | Size |
|---|---|
| Reads remembered before a vehicle | 8 (the oldest is dropped) |
| Distinct tags per vehicle | 4 |
| Hotlist | 64 slots, 8-slot probe window |
| Sightings | 64 slots, 8-slot probe window; the oldest in the window is evicted |

## 7. Timing rules (measured on the RTL, `tb_app`)

| Rule | Value | Why |
|---|---|---|
| Boot | **1,758 cycles** from reset release to the main loop (58 µs at 30.3 MHz) | The big tables and the transmit queue are in `.noinit`, so start-up zeroes only 360 bytes |
| The longest a received byte waits | **147–199 cycles** across every scenario, against a budget of 2,630 (ASIC), 4,340 (FPGA, 50 MHz) and 330 at 921,600 bps | The main loop never blocks. The MAC runs 4 rounds and the ROM measurement 64 words per iteration, as background jobs. The UART holds a single byte, so every long loop (hash probes, MAC rounds, record pushes, the ROM measurement) moves it into a 64-byte receive ring as soon as it lands; the parser reads from the ring |
| Host inter-frame gap | ≥ 2 byte-times after a frame | Headroom for end-of-frame work |
| **Frame timeout** | Off by default. With `P`'s `timeout` = N, a half-received frame is dropped after N quiet main-loop iterations and reported as `E` reason 5 (the testbenches use 48, about 3 byte-times) | The organisers' emulator sends one byte per AXI access, about 0.1 s apart, so any timeout would cut its frames. A host that streams its bytes can turn it on, so line noise never leaves a frame hanging |
| **Exit hold-off** | A decision waits until the UART has been quiet for `hold` iterations (default 64) after P0 falls. Measured at most **18,823 cycles** from the car leaving to its record (0.62 ms at 30.3 MHz), including any cut-off frame | Reads still in flight when the car leaves are counted. That covers a late reader report, or `emu` queuing a frame before `-i 0x00`. The next car's arrival decides the previous one at once |
| Host settle after a pin change | ≥ 16,000 cycles after an arrival and ≥ 30,000 after a departure when frames may be cut off; 2,000 and 16,000 otherwise | Longer than the frame timeout and the hold-off |
| ROM measurement | 65,425–65,778 cycles from the `I` frame to the `I` record at 115,200 bps; 46,650 at 921,600 | 2,774 words, one `crcw` each, 64 per iteration, unrolled by 8 with the UART serviced between groups |

## 8. Demonstrations

**The organisers' emulator (`./emu`).** In Stage 4 the organisers' `./emu` drives the
chip on the AWS F2. Its values for this application:

| emu option | Meaning here |
|---|---|
| `-d 0xF0` | P3–P0 are the chip's inputs (the emulator drives them), P7–P4 its outputs (the emulator reads them) |
| `-i` | The vehicle sensors: bit 0 presence, bits 2:1 class code, bit 3 lane closed. `-i 0x01` a car arrives, `-i 0x00` it leaves |
| `-t1`, `-t2`, `-t4` | The frames of §3, byte by byte. `-t4 0x301552A5` sends A5 52 15 30: emu sends the least-significant byte first |
| `-r4` twice | One 8-byte record (§4), the first byte lowest: `-r4 0x11000056 -r4 0x7B3C00FA` is `56 00 00 11 FA 00 3C 7B`, a `V` record |
| `-o` | The lamps P7–P4, e.g. `0x10` charged, `0x60` camera + alarm |

emu resets the chip at the start of every command line and returns at most 8 bytes, so a
command line is one vehicle and its one record (no key: an `A` record would be a ninth
byte). `testbench/lane_model.py` writes one command line per outcome, with the model's
expected `-r` and `-o` values, to `emulator-preview/emu_commands.txt`:
charged, class mismatch, taxi, no tag, motorcycle (free), hotlist, clone, corrupted tag,
adjacent lane, lane closed, and identify. `emulator-preview/tb_emu_preview.v` plays them on
the chip in simulation, exactly as emu performs them.

**Showcase** (`showcase_scenario()`). The demonstration run for the video, the platform and
the F2:
- `I`, then the key, the RSSI floor, config, gantry position, a stolen tag and a clone
  sighting;
- seven vehicles, one per outcome (charged, class mismatch, hotlist, clone, taxi, the
  adjacent lane's weak read, a motorcycle), each `V` with its `A`;
- a corrupted frame and its `E`;
- the stats.

Seventeen records in all.

**Replay page.** `replay/lane_replay.html`, built by `replay/gen_lane_replay.py`, replays a
transcript (the platform's simulation log, or `rvbl2 --json` from the F2). It recomputes
every CRC and tag, compares the identity record with the build, lets the viewer corrupt any
byte, and generates **blind tests**: a fresh scenario and a testbench with no expected
answers, run on the platform, with the page's prediction sealed until the chip's log is
pasted back.

## 9. Verification

| Harness | What it proves | Result |
|---|---|---|
| `testbench/tb_app.v`, `directed` | Firmware on `rtl/top.v` at the ASIC's real UART rate: every record and every post-vehicle pin equals the model. Every boundary of §3–§7 | **78/78** |
| `testbench/tb_app.v`, `showcase` | The demo run, keyed | **30/30**; the same at 921,600 bps: **30/30**, no overrun |
| `testbench/tb_app.v`, `fuzz` | Random bytes, `SOF` storms, flipped bits, unknown types, wrong lengths, cut-off frames, among 60 keyed vehicles; differential against the model | **262/262** (196 records, 75 `E`) |
| `testbench/tb_app.v`, `random` | 127 mixed vehicles, keyed, with an RSSI floor | **396/396** (127 `V` + 127 `A`) |
| Functional coverage | Every outcome, every `E` reason and its suppression, every table limit, every parameter boundary (guard, dedup, clone speed), key on/off, identity | **34/34 bins** (`build/lane/coverage.txt`) |
| `chipinventor/app/tb_app_ci.v`, `tb_app_ci_fast.v` | The same on the canvas chip, touching only pins; run on the export by `run_ci.sh`. At 115,200 bps the showcase; at 921,600 bps the platform's three runs (`SCEN` 0-2), each sized to the platform's time window | **26/26**; **13/13, 8/8, 6/6** |
| `emulator-preview/tb_emu_preview.v` | The eleven `./emu` command lines of §8, played on the canvas chip as the emulator performs them, with 20,000 silent cycles after every byte | **11/11** |
| `replay/test_lane_core.py --sim` | The replay page's logic against the model (vectors, CRCs, 12 blind scenarios), the platform's three runs pasted together, and three page-generated blind testbenches run on the export (each also checks the page's cycle estimate) | **182/182** |

**Directed boundaries** (`directed_scenario()` and `directed_v3()`):
- de-duplication just inside and exactly at the window (3,000 ms, then 1,000 ms by
  parameter);
- the guard at exactly its limit and 1 ms beyond (500 ms, then 100 ms);
- clone speed at exactly `vmax` (not a clone) and 1 ms faster (a clone), at 250 and at
  120 km/h;
- RSSI floor at `rssi_min − 1` and `rssi_min`;
- class mismatch; hotlist add, then delete; RSSI tie-break;
- lane closed, then reopened;
- all five `E` reasons, burst suppression and re-arming;
- cut-off frames while a car is present and as it leaves;
- the key loaded (`A` counters 0, 1), cleared, and replaced;
- the ROM measurement;
- table limits: 10 reads before a car (8 kept), 6 tags in one car (4 tracked), hotlist
  overflow (70 adds into 64 slots).
