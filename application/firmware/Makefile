# Makefile - builds the lane-controller firmware the organisers' way.
#
#   make               the application:     out/lane/
#   make APP=selftest  the firmware self-test (runs on the RTL, see testbench/)
#   make clean
# A program in another folder: make APP=name APP_DIR=path/to/its/main.c's/folder
#
# Two steps:
#   1. C -> assembly (our step). The C sources are compiled to RISC-V assembly
#      (gcc -S) and the start-up code is preprocessed, into out/<APP>/asm/.
#      These .s files are the firmware in assembly form, the complete program:
#      no C library and no libgcc is linked.
#   2. assembly -> firmware (the organisers' step). The organisers' Firmware
#      Builder Makefile (tools/rvbl-firmware-builder, an unchanged copy) is run
#      on those .s files. It writes, into out/<APP>/:
#         firmware.elf   linked program
#         firmware.bin   binary image (IMEM word 0 first)
#         firmware.txt   the IMEM case lines:  32'h00400000: r_Instruction = ...
#         firmware.dmp   assembly listing (objdump -D)
#      Only the linker script is ours (bsp/custom.ld, the builder's with the
#      chip's 8 kB DMEM; see its header).
#   Then check_image.py proves every instruction is one the core executes
#   (RV32I, Zmmul, Xicrc), the image fits IMEM, and writes firmware.hex (one
#   word per line) for the RTL testbenches.
#
# Toolchain: any RISC-V GNU toolchain. As in the organisers' Makefile, the
# riscv32-unknown-elf- or riscv64-unknown-elf- prefix is found by itself;
# override with, for example, make TC=riscv-none-elf (xPack GCC 13.2.0).

APP     ?= lane
APP_DIR ?= $(APP)
BUILDER := ../../tools/rvbl-firmware-builder
OUT     := out/$(APP)
ASM     := $(OUT)/asm

TC ?= $(shell command -v riscv32-unknown-elf-gcc >/dev/null 2>&1 && echo riscv32-unknown-elf || echo riscv64-unknown-elf)
CC := $(TC)-gcc

# -march=rv32i_zmmul -mabi=ilp32   the core's ISA: RV32I + multiply, no divider
# -mstrict-align                   the core does not do misaligned accesses
# -msmall-data-limit=0 -mno-relax  no gp-relative data (start-up does not set gp)
# -ffreestanding                   no C library
CFLAGS := -march=rv32i_zmmul -mabi=ilp32 -mstrict-align -msmall-data-limit=0 -mno-relax \
          -O2 -ffreestanding -fno-pic -Wall -Wextra -Werror -Iinclude

S_OUT  := $(ASM)/crt0.s $(ASM)/main.s $(ASM)/hal.s $(ASM)/divmod.s

.PHONY: all asm clean

all: asm
	$(MAKE) -f $(BUILDER)/Makefile SRC_DIR=$(ASM) BSP_DIR=bsp OBJ_DIR=$(OUT) \
	        SCRIPTS_DIR=$(BUILDER)/scripts TC=$(TC)
	python3 check_image.py $(OUT) --tc $(TC)

asm: $(S_OUT)

$(ASM)/crt0.s: bsp/crt0.S | $(ASM)
	$(CC) -E -P $< -o $@

$(ASM)/main.s: $(APP_DIR)/main.c include/*.h | $(ASM)
	$(CC) $(CFLAGS) -S $< -o $@

$(ASM)/%.s: lib/%.c include/*.h | $(ASM)
	$(CC) $(CFLAGS) -S $< -o $@

$(ASM):
	mkdir -p $@

clean:
	rm -rf $(OUT)
