#!/usr/bin/env bash
# build_vtb.sh - compile tb_board (the whole DE10-Lite board) with Verilator.
#   bash stage4/de10lite/sim/build_vtb.sh [OUTDIR] [BAUD] [TICK_DIV] [SONAR_PERIOD]
# Verilator 5 (--timing), in WSL or Linux. Icarus runs the same testbench, but
# about a hundred times slower: check_board.py uses Icarus only for short runs.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-/tmp/lanex_vtb}"
baud="${2:-115200}"
tick="${3:-100}"
sonar="${4:-50000}"
mkdir -p "$out"
cd "$here"
verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style \
    --top-module tb_board -GBAUD="$baud" -GTICK_DIV="$tick" -GSONAR_PERIOD="$sonar" \
    -Mdir "$out/obj" -o vtb \
    sim/tb_board.v lanex_board.v lanex_data.v lanex_chip.v > "$out/build.log" 2>&1 \
    || { tail -30 "$out/build.log"; exit 1; }
echo "built $out/obj/vtb (BAUD $baud, TICK_DIV $tick, SONAR_PERIOD $sonar)"
