# The organisers' Firmware Builder (unchanged copy)

`Makefile`, `README.md`, `bsp/custom.ld`, `scripts/bin2rom.py` and `src/README.md` are an
unchanged copy of the `RVBL-Firmware-Builder` folder of the organisers' Stage 3 repository,
<https://github.com/championchip-experience-community/CCX_Malaysia_Edition_Stage_3>. They are
the organisers' work, not ours. They are here so that this repository builds on its own.

We use them as they are:

- `official-firmware-testbench/run.sh` builds the organisers' test firmware with them and
  checks that the result is their `firmware.txt`, byte for byte.
- `application/firmware/Makefile` compiles our C to assembly, then runs this `Makefile` on
  that assembly (with our linker script, which is this `bsp/custom.ld` with the chip's 8 kB
  of data memory).

The Makefile finds a `riscv32-unknown-elf` or `riscv64-unknown-elf` toolchain by itself.
Another prefix can be given on the command line, for example `make TC=riscv-none-elf` for the
xPack GNU RISC-V Embedded GCC 13.2.0 that we used.
