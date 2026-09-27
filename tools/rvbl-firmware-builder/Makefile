# Confidencial - Propriedade do CPA Wernher von Braun

SRC_DIR     = src
BSP_DIR     = bsp
OBJ_DIR     = build
SCRIPTS_DIR = scripts

SRCS = $(wildcard $(SRC_DIR)/*.s)
OBJS = $(patsubst $(SRC_DIR)/%.s,$(OBJ_DIR)/%.o,$(SRCS))

ELF = $(OBJ_DIR)/firmware.elf
BIN = $(OBJ_DIR)/firmware.bin
TXT = $(OBJ_DIR)/firmware.txt
DMP = $(OBJ_DIR)/firmware.dmp

TC = $(shell command -v riscv32-unknown-elf-gcc >/dev/null 2>&1 && echo riscv32-unknown-elf || echo riscv64-unknown-elf)
AS      = $(TC)-as
GCC     = $(TC)-gcc
OBJDMP  = $(TC)-objdump
OBJCPY  = $(TC)-objcopy
SIZE    = $(TC)-size
BIN2ROM = $(SCRIPTS_DIR)/bin2rom.py

CFLAGS  = -Wall -march=rv32i_zmmul -mabi=ilp32
LDFLAGS = -nostdlib -T $(BSP_DIR)/custom.ld

.PHONY: all clean check-source

all: check-source $(TXT) $(DMP)

check-source:
	@test -n "$(SRCS)" || (echo "Error: place the assembly source at src/main.s"; exit 1)

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.s | $(OBJ_DIR)
	$(AS) $(CFLAGS) $< -o $@

$(ELF): $(OBJS) | $(OBJ_DIR)
	$(GCC) $(CFLAGS) $(LDFLAGS) $^ -o $@
	$(SIZE) $@

$(DMP): $(ELF)
	$(OBJDMP) -D $< > $@

$(BIN): $(ELF)
	$(OBJCPY) -O binary $< $@

$(TXT): $(BIN)
	python3 $(BIN2ROM) $< > $@

$(OBJ_DIR):
	mkdir -p $@

clean:
	rm -rf $(OBJ_DIR)
