# Application firmware testbench

**Stage 3 brief §6.** How the firmware is proven correct before it goes into the chip's
instruction memory.

## The method: a golden model

`lane_model.py` is the application written again, in Python: the same protocol, the same
decisions, the same records, byte for byte. It is the specification. For each test scenario
it writes the stimulus (frames and pin changes) and the exact output the chip must produce.
The testbench then runs the real firmware on the chip and compares every byte the chip sends,
and its pins after every vehicle, with the model.

```text
             +--> golden model (Python) -------- expected records and pins --+
  scenario --+                                                                +--> compare --> PASS / FAIL
             +--> chip + firmware (Verilog, UART at 115,200 bps) -- tx_o ----+
```

## Files

| File | What it is |
|---|---|
| `lane_model.py` | The golden model; writes the scenarios to `build/lane/` (`.stim`, `.exp`), the coverage report, and the `./emu` command lines of `../emulator-preview/` |
| `tb_app.v` | The testbench: the firmware on the RTL SoC (`rtl/top.v`), stimulus in, every record and pin compared |
| `tb_selftest.v` | Runs the firmware self-test (`../firmware/selftest/`): drivers, CRC, multiply, division, Chaskey-12 reference vectors |
| `tb_wave_app.v` | One car, one tag read, one CHARGED record: a short run (about 110,000 cycles) with only the signals that tell the story, for the waveform screenshot. Runs on the platform with `chipinventor/app/imem_app.v` |
| `gen_platform_tb.py` | Writes the testbenches that run the application on the ChipInventor simulator (`chipinventor/app/`) |

## The scenarios

| Scenario | What it covers | Result |
|---|---|---|
| `directed` | Every rule at its limit: each decision; dedup and guard windows at and past their limits; clone speed exactly at the limit and 1 ms over; the signal floor; table overflows; all 5 error kinds and their suppression; the key loaded, cleared and replaced; the ROM check | 78/78 |
| `showcase` | Every outcome once, authenticated; the demonstration run. Also at 921,600 bps | 30/30, 30/30 |
| `fuzz` | Random bytes, start-byte storms, flipped bits, unknown types, wrong lengths, cut-off frames, among 60 vehicles | 262/262 |
| `random` | 127 mixed vehicles, authenticated, with a signal floor | 396/396 |
| coverage | Every outcome, every error and its suppression, every table limit, every parameter boundary, key on and off, identity | 34/34 bins |

`tb_app.v` also measures the timing the firmware must meet: the longest time a received byte
waits before the firmware reads it (it must be less than one byte-time, or a byte is lost),
the boot time, and the ROM check's duration. It fails the run on any overrun.

## Run

```sh
make -C application/firmware                       # the firmware
python application/testbench/lane_model.py         # the scenarios
iverilog -g2005 -o build/tb_app.vvp rtl/*.v application/testbench/tb_app.v
vvp build/tb_app.vvp +STIM=build/lane/directed.stim +EXP=build/lane/directed.exp
```

`scripts/run_all.sh` does all of it (`RUN_LONG=1` adds fuzz and random).
