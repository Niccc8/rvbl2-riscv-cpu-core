# LaneX: the free-flow transaction engine

**Stage 3 brief §4–§6.** LaneX is a Multi-Lane Free Flow (MLFF) edge controller on the
RVBL-2 RISC-V core: the chip, with its GPIO and UART, turns every vehicle that passes a
barrier-free toll gantry into one verified transaction.

## Application definition (brief §4)

**System context.** Multi-Lane Free Flow (MLFF) tolling: vehicles pass under a gantry at
highway speed, with no barrier and no toll booth. Malaysia starts MLFF in Penang in 2026 and
nationwide in 2027. With no barrier, nobody stops the car, so each lane needs an edge
controller that decides, for every vehicle and within milliseconds, whether to charge it,
photograph it, or raise an alarm, and that leaves a record the toll back end can trust. The
toll back end is the operator's central system: customer accounts, fares, and the lists of
stolen and suspect tags. **LaneX, on the RVBL-2 chip, is that edge controller.**

**System input.**

| From | Through | What |
|---|---|---|
| The RFID reader | UART (rx_i) | Every tag read: time, tag ID (96-bit EPC), the tag's own CRC, signal strength (RSSI) |
| The toll back end | UART (rx_i) | Hotlist (stolen tags), sightings at other gantries, gantry positions, fares, lane parameters, the authentication key, requests (stats, identity) |
| The vehicle classifier | GPIO P0 | A vehicle is in the read zone |
| The vehicle classifier | GPIO P2:P1 | Its class, measured by axles and wheels |
| The lane switch | GPIO P3 | The lane is closed |

**System processing.** For every frame on the UART, the firmware checks its CRC-16 with the
chip's own CRC instructions (Xicrc). For every tag read, it recomputes the tag's CRC as the
RFID standard defines it, and drops reads from the next lane (too weak). When the vehicle
leaves, it decides, first match wins:

| Condition | Decision | Lamps |
|---|---|---|
| Lane closed | LANE CLOSED | P7 |
| No valid tag, motorcycle | FREE | – |
| No valid tag | NO TAG | camera |
| Tag on the hotlist | HOTLIST | camera, alarm |
| Tag seen at another gantry too recently to have driven here (speed > limit) | CLONE | camera, alarm |
| Tag's class ≠ measured class (e.g. a car tag on a lorry) | CLASS MISMATCH, charged at the lorry fare | charged, camera |
| Otherwise | CHARGED at the tag's fare | charged |

The clone test uses the multiplier (Zmmul): `distance × 360,000 > speed limit × time`, with
no division.

**System output.**

| To | Through | What |
|---|---|---|
| The toll system | GPIO P4 | Charged |
| The ANPR camera | GPIO P5 | Photograph this vehicle |
| The enforcement system | GPIO P6 | Alarm: stolen or cloned tag |
| The lane sign | GPIO P7 | Lane closed |
| The toll back end | UART (tx_o) | One 8-byte record per vehicle (decision, class, fare), sealed with a CRC-16. Once a key is loaded, each record is followed by an 8-byte authentication record (Chaskey-12, ISO/IEC 29192-6) |

**Emulator values (`./emu`).** The pins are those of the organisers' test firmware
(`-d 0xF0`: P3–P0 in, P7–P4 out). A command line is one vehicle: `-i 0x01` it arrives, the
frames go out with `-t4/-t2/-t1` (least-significant byte first), `-i 0x00` it leaves, then two
`-r4` read its 8-byte record and `-o` reads the lamps. For example, a car with a valid tag:

```text
./emu -d 0xF0 -i 0x01 -t4 0x301552A5 ... -t2 0xF592 -i 0x00 -r4 0x11000056 -r4 0x7B3C00FA -o 0x10
                 |      '---- one tag-read frame ----'   |       '-- V record: CHARGED, RM 2.50 --'  '-- P4 on
          car arrives                             car leaves
```

The full protocol - every frame, every record, the decision table, the timing - is in
[`PROTOCOL.md`](PROTOCOL.md).

## Where each part is

| Brief | Folder | What is there |
|---|---|---|
| §4 Application definition | this file, [`PROTOCOL.md`](PROTOCOL.md) | The system, its inputs, processing and outputs; the full protocol |
| §5 Firmware development | [`firmware/`](firmware/) | The C source, built to assembly and binary with the organisers' Firmware Builder |
| §6 Custom testbench | [`testbench/`](testbench/) | The golden model, and the testbenches that check the firmware against it |
| Emulator preview | [`emulator-preview/`](emulator-preview/) | `./emu` command lines for every outcome, played on the chip in simulation |
| Demonstration | [`replay/`](replay/) | A web page that replays the chip's simulation log and checks every CRC and tag itself, and plays each `./emu` line from the emulator through the FPGA registers to the chip's pins |
