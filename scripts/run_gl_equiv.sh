#!/usr/bin/env bash
# run_gl_equiv.sh - gate-level equivalence check (§17 stage 16).
#
# Prepares the Yosys generic-synthesis netlist for co-simulation (renaming its
# modules so they can coexist with the RTL ones), then runs tb_gatelevel.v,
# which drives the RTL core and the synthesized core in lockstep and compares
# the core's full external interface every cycle.
#
# Requires synth/top_generic_synth.v - produce it with
# scripts/synth_yosys_generic.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

BUILD=build
mkdir -p "$BUILD"

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

if [[ ! -f synth/top_generic_synth.v ]]; then
    echo "ERROR: synth/top_generic_synth.v not found."
    echo "       Run: bash scripts/synth_yosys_generic.sh"
    exit 1
fi

"$PYTHON" scripts/gen_gl_netlist.py synth/top_generic_synth.v "$BUILD/gl_netlist.v"

# -s names the single root: without it iverilog also elaborates `top` (which
# nothing here instantiates) with its default parameters, producing a
# spurious $readmemh size warning from a module this test never uses.
DMEM_MACRO=${DMEM_MACRO:-0}
if [ "$DMEM_MACRO" = "1" ]; then
    VFLAGS="-DDMEM_USE_SRAM_MACRO"
    EXTRA_V="macros/sky130_sram_2kbyte_1rw1r_32x512_8_sim.v"
else
    VFLAGS=""
    EXTRA_V=""
fi

iverilog -g2005 $VFLAGS -s tb_gatelevel -o "$BUILD/tb_gatelevel.vvp" rtl/*.v $EXTRA_V "$BUILD/gl_netlist.v" tb/tb_gatelevel.v
vvp "$BUILD/tb_gatelevel.vvp"
