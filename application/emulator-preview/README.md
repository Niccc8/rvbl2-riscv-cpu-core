# Emulator preview

**Stage 3 workflow, last step.** The organisers' emulator (`./emu`) drives the processor on
the AWS F2 in Stage 4. Here the same command lines are played on our chip in simulation, so
the application's emulator values are proven before the FPGA stage.

| File | What it is |
|---|---|
| `emu_commands.txt` | One `./emu` command line per application outcome (11), with the golden model's expected `-r` and `-o` values. Written by `../testbench/lane_model.py` |
| `gen_emu_preview.py` | Turns any file of `./emu` lines into a testbench |
| `tb_emu_preview.v` | The testbench for `emu_commands.txt` |

## What the testbench does

For each command line, as `emu.c` does:

1. reset the processor ("`[ok] RISC-V started!`");
2. perform the options in order, on the chip's pins:
   - `-d`: which pins the emulator drives (bit 0) and which it observes (bit 1);
   - `-i`: the level on the pins it drives;
   - `-t1/-t2/-t4`: 1, 2 or 4 bytes into `rx_i`, least-significant byte first, at 115,200
     bps, each followed by 20,000 clock cycles of silence (emu: about 0.1 s per byte);
   - `-r1/-r2/-r4`: the next bytes the chip sent on `tx_o` (the emulator keeps the first 8),
     compared with the value;
   - `-o`: the observed pins, compared with the value;
3. print emu's own lines (`[ok] Written 0x301552A5 to UART RX`, `[ok] Read 0x11000056 from
   UART TX`, `[error] ...`), and stop the run at the first failed comparison, as emu does.

## Run

```sh
python gen_emu_preview.py emu_commands.txt tb_emu_preview.v
iverilog -g2005 -s testbench -o emu.vvp ../../chipinventor/blocks/*.v ... (see scripts/run_all.sh, emu_preview)
```

`scripts/run_all.sh` runs it on the canvas design with the application ROM. Result: all 11
command lines pass. The same generator makes `official-firmware-testbench/tb_emu_preview.v`
for the organisers' test firmware.
