#!/usr/bin/env bash
# synth_yosys_generic.sh - RTL -> generic-cell gate-level netlist via Yosys.
# Confirms elaboration, latch-freedom and synthesizability, and produces a real
# gate-level netlist plus a cell-count report even without a target PDK.
#
# The ROM image matters: with an empty IMEM_INIT_FILE the instruction memory
# elaborates as all zeros and synthesis constant-folds the entire array away,
# leaving a netlist with no instruction memory in it at all. The memory gates
# in scripts/check_synth_stats.py fail the run if that ever happens again, so
# it cannot silently reach a physical flow.
#
# Set $YOSYS to use a Yosys that is not on PATH (e.g. an OSS CAD Suite install).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

YOSYS=${YOSYS:-yosys}

# Python is `python3` on most systems and `python` on Windows installs; use
# whichever exists so the script runs unchanged on both.
PYTHON=${PYTHON:-}
if [ -z "$PYTHON" ]; then
    # Probe by running it: Windows ships a `python3` shim that exists on PATH
    # but only prints a Microsoft Store advert, so presence alone is not enough.
    if python3 -c "" > /dev/null 2>&1; then PYTHON=python3
    elif python -c "" > /dev/null 2>&1; then PYTHON=python
    else
        echo "ERROR: no working Python interpreter found (tried python3, python)."
        exit 1
    fi
fi

IMEM_WORDS=${1:-471}
DMEM_WORDS=${2:-2048}
IMEM_INIT=${3:-tests/progs/tb_firmware_prog.hex}

mkdir -p synth build

if [[ ! -f "$IMEM_INIT" ]]; then
    echo "ERROR: ROM image '$IMEM_INIT' not found."
    echo "       Run: $PYTHON scripts/gen_firmware_test.py"
    exit 1
fi

cat > build/_synth_generic.ys << EOF
read_verilog -DSYNTHESIS -sv rtl/alu.v rtl/branch_comparator.v rtl/immediate_generator.v \
    rtl/register_file.v rtl/pc_reg.v rtl/ir_reg.v rtl/pc_incrementer.v \
    rtl/multiplier.v rtl/crc_unit.v rtl/lsu.v rtl/imem.v rtl/dmem.v \
    rtl/address_decoder.v rtl/control_unit.v rtl/riscv_core.v rtl/top.v
chparam -set IMEM_WORDS ${IMEM_WORDS} top
chparam -set DMEM_WORDS ${DMEM_WORDS} top
chparam -set IMEM_INIT_FILE "${IMEM_INIT}" top
hierarchy -check -top top
synth -top top
opt -purge
tee -o synth/generic_synth_stat.txt stat
write_verilog -noattr synth/top_generic_synth.v
EOF

echo "Running Yosys generic synthesis (IMEM_WORDS=${IMEM_WORDS}, DMEM_WORDS=${DMEM_WORDS}, ROM=${IMEM_INIT})..."
"$YOSYS" -s build/_synth_generic.ys > synth/generic_synth_full.log 2>&1
echo "Done. Cell counts: synth/generic_synth_stat.txt   Netlist: synth/top_generic_synth.v"
echo ""

echo "---- Latch check (must be empty) ----"
if grep -qi '\$_DLATCH' synth/generic_synth_full.log; then
    echo "FAIL: latch cells found!"
    grep -i '\$_DLATCH' synth/generic_synth_full.log
    exit 1
fi
echo "PASS: no \$_DLATCH cells - design is latch-free."
echo ""

echo "---- Memory-content gates ----"
"$PYTHON" scripts/check_synth_stats.py synth/generic_synth_stat.txt
echo ""

echo "---- Cell summary ----"
sed -n '/=== design hierarchy ===/,$p' synth/generic_synth_stat.txt
