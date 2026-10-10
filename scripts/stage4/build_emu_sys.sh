#!/usr/bin/env bash
# build_emu_sys.sh - build the Stage 4 whole-system simulator (pre-flight G3).
# Runs in WSL/Linux (Verilator 5, gcc). Inputs: stage4/riscv.sv (generated), the
# organisers' top.sv and emu.c (stage4/vendor/, fetched unmodified), our AWS stubs.
#
#   bash scripts/stage4/build_emu_sys.sh [RISCV_SV] [OUTDIR]
#
# RISCV_SV defaults to stage4/riscv.sv (the mutation tests pass a mutant);
# OUTDIR defaults to /tmp/rvbl2_emu_sys. Produces OUTDIR/sim_emu and OUTDIR/libemu.so.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SV="${1:-$ROOT/stage4/riscv.sv}"
OUT="${2:-/tmp/rvbl2_emu_sys}"
V="$ROOT/stage4/vendor"
S="$ROOT/stage4/sim"
for f in "$V/top.sv" "$V/emu.c" "$V/cl_ports.vh" "$SV"; do
    [ -f "$f" ] || { echo "missing $f (see stage4/README.md: fetch the organisers' files)"; exit 2; }
done
mkdir -p "$OUT"
# emu.c exactly as published; only its main() is renamed so the simulator can call it
gcc -O2 -fPIC -shared -Dmain=emu_main -I"$S/emu_sys" "$V/emu.c" -o "$OUT/libemu.so"
cp "$SV" "$OUT/riscv.sv"
verilator --cc --exe --build -j 4 -O2 -sv -Wno-fatal -Wno-lint -Wno-style \
    -I"$S" -I"$V" --top-module top -Mdir "$OUT/obj" -o "$OUT/sim_emu" \
    -CFLAGS "-I$S/emu_sys -O2" -LDFLAGS "-ldl -rdynamic" \
    "$S/unisim_models.v" "$S/sh_ddr_stub.v" "$OUT/riscv.sv" "$V/top.sv" "$S/emu_sys/sim_main.cpp" \
    > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
echo "built $OUT/sim_emu"
