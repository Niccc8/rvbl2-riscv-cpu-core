# Application firmware

**Stage 3 brief §5.** The lane controller's firmware, in C, built into assembly and a
binary with the organisers' Firmware Builder.

## The delivered firmware (`out/lane/`)

| File | Format |
|---|---|
| `asm/crt0.s`, `asm/main.s`, `asm/hal.s`, `asm/divmod.s` | **Assembly**: the complete program, as the organisers' Makefile assembles it |
| `firmware.bin` | **Binary**: the ROM image, IMEM word 0 first |
| `firmware.txt` | The IMEM `case` lines, `32'h00400000: r_Instruction = 32'h0FC12117;` ... (the organisers' format) |
| `firmware.dmp` | The disassembly of the linked program |
| `firmware.elf` | The linked program |
| `firmware.hex` | One 32-bit word per line, for our RTL testbenches |

## How it is built

```sh
make                 # needs make, python3 and a RISC-V GNU toolchain
make TC=riscv-none-elf    # the toolchain we used: xPack GNU RISC-V Embedded GCC 13.2.0
```

1. **C to assembly** (our step): `gcc -S` for `lane/main.c`, `lib/hal.c` and
   `lib/divmod.c`; the start-up code `bsp/crt0.S` is preprocessed.
2. **Assembly to firmware** (the organisers' step): the organisers' Makefile
   (`tools/rvbl-firmware-builder/Makefile`, unchanged) assembles and links the `.s` files,
   and writes `firmware.bin`, `firmware.txt` and `firmware.dmp` with their `bin2rom.py`.
   Only the linker script is ours: `bsp/custom.ld` is theirs with the chip's 8 kB of data
   memory and two small additions, each marked in the file.
3. **Checks** (`check_image.py`): every instruction is one the core executes (RV32I,
   Zmmul, Xicrc), and the image fits the instruction memory.

The link uses no C library and no libgcc (`-nostdlib`, as the organisers' Makefile links),
so the assembly in `out/lane/asm/` is the whole program. The core has no divider, so
`lib/divmod.c` supplies the division routines that libgcc would.

`make APP=selftest` builds the firmware self-test (`selftest/main.c`), which the testbench
`tb_selftest.v` runs on the RTL.

## Files

| File | What it does |
|---|---|
| `lane/main.c` | The application: frame parser, tag checks, vehicle tracking, the decision, records, authentication |
| `lib/hal.c`, `include/hal.h` | Drivers: UART send and receive, GPIO, CRC-16, Chaskey-12 |
| `include/rvbl2.h` | The memory map, the peripheral registers, and the Xicrc instructions as C functions |
| `lib/divmod.c` | 32-bit division and remainder in software |
| `bsp/crt0.S` | Start-up: stack pointer, copy `.data`, clear `.bss`, call `main` |
| `bsp/custom.ld` | Memory layout (the organisers' linker script, 8 kB DMEM) |

## How the firmware works

**One loop that never waits.** `main()` runs one loop, about 170 clock cycles per turn. Each
turn it:

1. takes a received byte from the UART, if there is one, and gives it to the frame parser;
2. reads the GPIO pins; a change starts or ends a vehicle;
3. decides the vehicle that has left, when the line has been quiet for a moment;
4. advances the long jobs by one slice: the authentication tag (4 of its 12 rounds) and
   the ROM measurement (64 words);
5. sends the next byte of the output queue, when the UART transmitter is free.

**UART in.** The UART holds one received byte (`RXDATA`, flag `RXDONE`). The firmware polls
`RXDONE` and moves the byte into a 64-byte receive queue, and clears `RXDONE` by writing
`CONTROL`. It does this in the main loop and inside every long loop, so a byte never waits
more than about 250 cycles, against 2,630 cycles per byte at 115,200 bps. The parser is a
state machine: start byte `0xA5`, type, length, payload, CRC. Each byte is added to the
running CRC with one `crcb` instruction as it arrives, so at the end of the frame the CRC is
already known.

**UART out.** Records go into a 128-byte output queue. The loop sends the next byte whenever
`TXDONE` says the transmitter is free: it writes `TXDATA`, then sets `TRANSMIT` in `CONTROL`.

**CRC (Xicrc).** The chip's own CRC instructions do all CRC work:
- frames: one `crcb` per received byte;
- tag reads: the RFID tag's CRC is 14 `crcb` and one `xori` (the standard's CRC is our
  CRC-16 inverted);
- records: 6 `crcb` per 8-byte record;
- the ROM measurement: one `crcw` per 32-bit word of the whole program.

**Multiply (Zmmul).** Two uses:
- the hotlist and sighting tables are found by a multiplicative hash of the tag ID
  (`mul`);
- the clone test compares `distance × 360,000` with `speed limit × time` in 64 bits
  (`mul`, `mulh`, `mulhu`), so it needs no division.

**GPIO.** At start the firmware sets `DATADIR = 0xF0`: P3–P0 inputs, P7–P4 outputs. The
loop reads `DATAIN` every turn: P0 rising starts a vehicle, P0 falling ends it, P2:P1 give
its class, P3 closes the lane. After the decision the firmware writes `DATAOUT`: P4 charged,
P5 camera, P6 alarm, P7 lane closed.
