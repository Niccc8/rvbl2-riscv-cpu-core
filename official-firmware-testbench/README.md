# Official Firmware Testbench

**Stage 3 brief §3.** The organisers' GPIO and UART test firmware, run on our chip, to show
that the GPIO and the UART work before the application is built on them.

## What is here

| File | What it is |
|---|---|
| `firmware/main.s`, `firmware/firmware.txt` | The organisers' test firmware and its instructions, **unchanged** (from their repository, `RVBL-GPIO-UART-Test-Firmware`) |
| `firmware/firmware.bin`, `firmware/firmware.dmp` | The same firmware as a binary and as an assembly listing, rebuilt by `run.sh` with the organisers' Makefile |
| `imem_official.v` | Our instruction memory with the lines of `firmware.txt` pasted into its `case` statement, as the organisers' README says. Same ports as the `imem` block on the ChipInventor canvas. Written by `gen_imem.py` |
| `tb_official_firmware.v` | **Our testbench.** Drives only the chip's pins, and checks what the organisers' README asks for |
| `tb_wave_official.v` | A short run for the waveform screenshot: only the brief's signals (clk, rst, the pins, rx, tx), about 11,800 cycles (0.39 ms) |
| `emu_commands.txt`, `tb_emu_preview.v` | Four `./emu` command lines for this firmware, and the testbench that plays them on the chip as the emulator does |
| `run.sh` | Does all of it, and writes the logs to `logs/` |
| `logs/` | The simulation logs, and the waveform `official_firmware.vcd` |

## What the firmware does

```text
        +--> read P3-P0, write it to P7-P4 --> wait for a byte on rx_i --> send it back on tx_o --+
        |                                                                                          |
        +------------------------------------------------------------------------------------------+
```

It sets P7–P4 as outputs (`DATADIR = 0xF0`), then loops. Note the order: a new value on
P3–P0 reaches P7–P4 only after the next UART echo.

## What the testbench checks

The chip runs at its real clock (30.303 MHz) and its UART at its real 115,200 bps (263
clock cycles per bit).

1. **The organisers' test.** `0xA` is on P3–P0 before reset ends; P7–P4 must show `0xA`
   (`DATAOUT = 0xA0`). Then `0x30` is sent into `rx_i`, and `0x30` must come back on `tx_o`.
2. **All 16 values of P3–P0**, each with a different byte: `0x00`, `0xFF`, alternating bits,
   single bits. For each: set P3–P0, echo the byte, then P7–P4 must follow.

Every wait has a timeout that prints a clear `[FAIL]` line. The log uses the organisers'
format:

```text
[PASS] GPIO: P3-P0 = 0xA, P7-P4 = 0xA   (cycle 40)
[PASS] UART: RX = 0x30, TX = 0x30   (cycle 5097)
...
==== tb_official_firmware: 34 passed, 0 failed, 85849 cycles ====
[PASS] GPIO and UART firmware test completed successfully
```

The waveform shows `clk`, `rst`, `gpio_in` (P3–P0), `gpio_out` (P7–P4), `uart_rx`,
`uart_tx`, and the last byte sent (`rx_byte`) and received (`tx_byte`).

## Where it runs

| Design | How |
|---|---|
| The ChipInventor canvas design (`chipinventor/ci_top.v` and its blocks) | `bash run.sh` |
| The netlist the ChipInventor platform exported (`chipinventor/export_stage3.v`) | `bash run.sh`, when the export is present |
| The ChipInventor platform itself | Paste `imem_official.v` into the `imem` block's Code field, and `tb_official_firmware.v` into SIMULATE → Testbench |
| The waveform on the platform | The same IMEM, and `tb_wave_official.v` into SIMULATE → Testbench; open the waveform viewer on the whole run |

## The emulator preview

`emu_commands.txt` holds the organisers' README example `./emu -d 0xF0 -i 0x02 -o 0x20
-t1 0x30 -r1 0x30`, and three more. The preview shows a detail of the firmware's order:
the firmware copies P3–P0 once, right after reset (before `-i` sets it), and then waits
for a byte. So an `-o` placed before the echo reads `0x00`, and emu stops there. The same
options with `-o` after the echo pass.
