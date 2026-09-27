#!/usr/bin/env bash
# run.sh - the Official Firmware Testbench, end to end.
#
#   1. Rebuild the official firmware from main.s with the organisers' Firmware
#      Builder (tools/rvbl-firmware-builder, unchanged) and prove the result is
#      the organisers' firmware.txt, byte for byte. Also leaves firmware.bin and
#      firmware.dmp beside it. Skipped if make or a RISC-V toolchain is missing.
#   2. Check imem_official.v holds exactly those instructions.
#   3. Run tb_official_firmware.v on the chip - the ChipInventor canvas design
#      (chipinventor/ci_top.v + blocks/) and, if present, the platform's own
#      export (chipinventor/export_stage3.v) - with this IMEM.
#   4. Run the emulator preview of the ./emu lines in emu_commands.txt.
# Logs go to logs/; the waveform to logs/official_firmware.vcd.
#
# Needs iverilog and python. Run from anywhere.
set -u
cd "$(dirname "$0")"
ROOT=..
PY=python3; command -v python3 > /dev/null 2>&1 && python3 -c "" 2>/dev/null || PY=python
mkdir -p logs build
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED+1)); }

# ---- 1. the organisers' build flow --------------------------------------------
for d in "$HOME/tools/bin" "$HOME/tools/xpack-windows-build-tools-4.4.1-3/bin" \
         "$HOME/tools/xpack-riscv-none-elf-gcc-13.2.0-2/bin"; do [ -d "$d" ] && PATH="$d:$PATH"; done
TC=""
for t in riscv32-unknown-elf riscv64-unknown-elf riscv-none-elf; do
    command -v "$t-gcc" > /dev/null 2>&1 && { TC=$t; break; }
done
if [ -n "$TC" ] && command -v make > /dev/null 2>&1; then
    rm -rf build/fw && mkdir -p build/fw/src
    cp firmware/main.s build/fw/src/
    if make -C build/fw -f "$PWD/$ROOT/tools/rvbl-firmware-builder/Makefile" \
            BSP_DIR="$PWD/$ROOT/tools/rvbl-firmware-builder/bsp" \
            SCRIPTS_DIR="$PWD/$ROOT/tools/rvbl-firmware-builder/scripts" TC=$TC > logs/build.log 2>&1 && \
       diff <(tr -d '\r' < build/fw/build/firmware.txt) <(tr -d '\r' < firmware/firmware.txt) > /dev/null; then
        cp build/fw/build/firmware.bin build/fw/build/firmware.dmp firmware/
        ok "organisers' Makefile rebuilds firmware.txt from main.s, identical ($TC)"
    else
        bad "the rebuilt firmware.txt differs from the organisers' (see logs/build.log)"
    fi
else
    printf 'SKIP rebuild of the firmware (needs make and a RISC-V GNU toolchain)\n'
fi

# ---- 2. the IMEM ---------------------------------------------------------------
if $PY gen_imem.py --check; then :; else bad "imem_official.v is stale"; fi

# ---- 3. the testbench on the chip ------------------------------------------------
BLOCKS=$(ls $ROOT/chipinventor/blocks/*.v | grep -v -E '/imem(_mock)?\.v$')
run_tb() {   # label, log, sources...
    label=$1; log=$2; shift 2
    if iverilog -g2005 -s testbench -o build/tb.vvp "$@" > "logs/$log" 2>&1 && \
       (cd build && vvp -n tb.vvp) >> "logs/$log" 2>&1 && \
       grep -q "completed successfully\|ALL TESTS PASSED" "logs/$log"; then
        ok "$label"
        grep -E '^==== ' "logs/$log"
        return 0
    fi
    bad "$label (see logs/$log)"; tail -5 "logs/$log"; return 1
}
run_tb "official firmware on the canvas design" tb_official_firmware.log \
    $BLOCKS $ROOT/chipinventor/ci_top.v imem_official.v tb_official_firmware.v && \
    cp build/testbench.vcd logs/official_firmware.vcd
run_tb "the short waveform run (tb_wave_official.v)" tb_wave_official.log \
    $BLOCKS $ROOT/chipinventor/ci_top.v imem_official.v tb_wave_official.v && \
    cp build/testbench.vcd logs/wave_official.vcd
EXPORT=$ROOT/chipinventor/export_stage3.v
if [ -f "$EXPORT" ]; then
    # put the official firmware's IMEM into the export's imem (it holds whichever ROM was pasted last)
    $PY - "$EXPORT" imem_official.v build/export_official.v <<'EOF'
import re, sys
exp, rom, out = sys.argv[1:]
new = re.search(r"(?ms)^module imem\b.*?^endmodule", open(rom).read()).group(0)
text, n = re.subn(r"(?ms)^module imem\b.*?^endmodule", lambda m: new, open(exp).read())
if n != 1:
    sys.exit("expected one imem module in the export, found %d" % n)
open(out, "w").write(text)
EOF
    run_tb "official firmware on the ChipInventor export" tb_official_firmware_export.log \
        build/export_official.v tb_official_firmware.v
fi

# ---- 4. the emulator preview -------------------------------------------------------
if $PY $ROOT/application/emulator-preview/gen_emu_preview.py --check emu_commands.txt tb_emu_preview.v; then
    run_tb "emulator preview (emu_commands.txt)" tb_emu_preview.log \
        $BLOCKS $ROOT/chipinventor/ci_top.v imem_official.v tb_emu_preview.v
else
    bad "tb_emu_preview.v is stale"
fi

[ $FAILED -eq 0 ] && echo "OFFICIAL FIRMWARE TESTBENCH: ALL TESTS PASSED" || echo "OFFICIAL FIRMWARE TESTBENCH: $FAILED FAILED"
exit $FAILED
