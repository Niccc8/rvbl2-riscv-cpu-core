# RV32I Assembly Firmware Builder

This repository converts an RV32I assembly program into the machine instructions used by the processor instruction memory (IMEM). It can be reused with the provided GPIO and UART test firmware or with a new application firmware.

## Requirements

- GNU Make;
- Python 3;
- RISC-V GNU toolchain using the `riscv32-unknown-elf` or `riscv64-unknown-elf` prefix.

The available toolchain is detected automatically. The generated program uses the RV32 architecture in both cases.

## Repository structure

```text
.
├── Makefile
├── bsp/
│   └── custom.ld
├── scripts/
│   └── bin2rom.py
└── src/
    └── main.s
```

## Usage

Place the assembly program in:

```text
src/main.s
```

Run the Makefile from the repository root:

```shell
make
```

The generated files are placed in `build/`:

| File | Purpose |
|---|---|
| `main.o` | Assembled object file |
| `firmware.elf` | Linked program |
| `firmware.bin` | Binary program image |
| `firmware.dmp` | Assembly listing for inspection |
| `firmware.txt` | Machine instructions formatted for the IMEM |

The file used for processor integration is:

```text
build/firmware.txt
```

## Loading the instructions into the IMEM

Copy the lines from `build/firmware.txt` into the `case` statement of the processor instruction memory:

```verilog
always @(*) begin
    case (i_Address)
        32'h00400000: r_Instruction = 32'hXXXXXXXX;
        32'h00400004: r_Instruction = 32'hXXXXXXXX;
        // Remaining instructions from firmware.txt

        default: r_Instruction = 32'h00000000;
    endcase
end
```

Replace the previous program instructions, but keep the `case`, `default`, and `endcase` structure.

## Using another firmware

To generate instructions for another program, replace `src/main.s` with the new assembly source and run the Makefile again. The Makefile, linker script, and conversion script do not need to be changed.

To remove the generated files before rebuilding:

```shell
make clean
```

