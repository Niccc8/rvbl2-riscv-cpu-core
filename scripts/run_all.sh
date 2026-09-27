#!/usr/bin/env bash
# run_all.sh - compiles and runs every testbench in this repository, printing a
# one-line PASS/FAIL summary per testbench and a final tally. Also writes
# build/test_summary.md, which docs/VERIFICATION_REPORT.md quotes verbatim, so
# the published check counts are generated rather than maintained by hand.
#
# Requires: iverilog (Icarus Verilog). Run from a POSIX shell (Linux, macOS, or
# Git Bash / WSL on Windows). All intermediates go to build/, not /tmp, so the
# script does not depend on a system temp directory existing.
set -u
cd "$(dirname "$0")/.."   # repo root

BUILD=build
mkdir -p "$BUILD"

# DMEM_MACRO=1 builds every testbench against the OpenRAM hard-macro
# realization of dmem instead of the default behavioral array. Both must pass:
# the macro is optional, so the design has to be correct either way.
DMEM_MACRO=${DMEM_MACRO:-0}
if [ "$DMEM_MACRO" = "1" ]; then
    VFLAGS="-DDMEM_USE_SRAM_MACRO"
    EXTRA_V="macros/sky130_sram_2kbyte_1rw1r_32x512_8_sim.v"
    echo "DMEM realization: OpenRAM hard macro (4 x sky130_sram_2kbyte_1rw1r_32x512_8)"
else
    VFLAGS=""
    EXTRA_V=""
    echo "DMEM realization: behavioral register array (default)"
fi

UNIT_TBS="tb_alu tb_branch_comparator tb_immediate_generator tb_register_file \
tb_multiplier tb_crc_unit tb_lsu tb_imem tb_dmem tb_address_decoder tb_control_unit \
tb_gpio tb_uart"

INTEGRATION_TBS="tb_core tb_soc tb_reset tb_firmware tb_periph_soc"

TOTAL=0
FAILED=0
CHECKS=0
LOCKSTEP=0
FAILED_LIST=""
SUMMARY="$BUILD/test_summary.md"

: > "$SUMMARY"
echo "| Testbench | Level | Checks | Result |" >> "$SUMMARY"
echo "|---|---|---:|---|" >> "$SUMMARY"

# Sums every "==== <name>: N passed, M failed ====" line a testbench prints.
count_checks() {
    grep -oE '==== [^:]+: [0-9]+ passed' "$1" 2>/dev/null \
        | grep -oE '[0-9]+ passed' | grep -oE '^[0-9]+' \
        | awk '{s+=$1} END {print s+0}'
}

run_one() {
    tb=$1
    timeout_s=$2
    level=$3
    TOTAL=$((TOTAL+1))
    vvp_out="$BUILD/${tb}.vvp"
    log="$BUILD/${tb}.log"

    case "$tb" in
        tb_core|tb_soc|tb_reset|tb_firmware|tb_periph_soc)
            iverilog -g2005 $VFLAGS -o "$vvp_out" rtl/*.v $EXTRA_V "tb/${tb}.v" > "$log.compile" 2>&1
            ;;
        *)
            # Unit testbench: compile only the RTL file it names, so a failure
            # localises to that module rather than the whole design.
            rtl_guess="rtl/${tb#tb_}.v"
            if [ -f "$rtl_guess" ]; then
                iverilog -g2005 $VFLAGS -o "$vvp_out" "$rtl_guess" $EXTRA_V "tb/${tb}.v" > "$log.compile" 2>&1
            else
                iverilog -g2005 $VFLAGS -o "$vvp_out" rtl/*.v $EXTRA_V "tb/${tb}.v" > "$log.compile" 2>&1
            fi
            ;;
    esac

    if [ $? -ne 0 ]; then
        echo "COMPILE-FAIL  $tb"
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $tb(compile)"
        cat "$log.compile"
        echo "| \`$tb\` | $level | - | COMPILE-FAIL |" >> "$SUMMARY"
        return
    fi

    if command -v timeout > /dev/null 2>&1; then
        timeout "$timeout_s" vvp "$vvp_out" > "$log" 2>&1
    else
        vvp "$vvp_out" > "$log" 2>&1
    fi

    n=$(count_checks "$log")
    if grep -q "ALL TESTS PASSED" "$log"; then
        CHECKS=$((CHECKS+n))
        summary_line=$(grep -E "==== .* ====" "$log" | tail -1)
        echo "PASS          $tb   $summary_line"
        echo "| \`$tb\` | $level | $n | PASS |" >> "$SUMMARY"
    else
        echo "FAIL          $tb"
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $tb"
        tail -20 "$log"
        echo "| \`$tb\` | $level | $n | FAIL |" >> "$SUMMARY"
    fi
}

PY=python
if ! $PY -c "" > /dev/null 2>&1; then PY=python3; fi

echo "=============================================="
echo " Tooling"
echo "=============================================="
# The assembler extensions (.equ, la, 32-bit li) are checked against encodings
# taken from the official firmware; then the Stage 3 programs are assembled
# fresh into build/stage3/ for tb_periph_soc.
TOTAL=$((TOTAL+1))
if $PY scripts/test_asm.py > "$BUILD/test_asm.log" 2>&1 && grep -q "ALL TESTS PASSED" "$BUILD/test_asm.log"; then
    n=$(count_checks "$BUILD/test_asm.log"); CHECKS=$((CHECKS+n))
    echo "PASS          test_asm   $(grep -E '==== .* ====' "$BUILD/test_asm.log")"
    echo "| \`test_asm\` | Tooling | $n | PASS |" >> "$SUMMARY"
else
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST test_asm"
    echo "FAIL          test_asm"; tail -20 "$BUILD/test_asm.log"
    echo "| \`test_asm\` | Tooling | - | FAIL |" >> "$SUMMARY"
fi
if ! $PY scripts/gen_stage3_progs.py > "$BUILD/gen_stage3_progs.log" 2>&1; then
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST gen_stage3_progs"
    echo "FAIL          gen_stage3_progs"; cat "$BUILD/gen_stage3_progs.log"
fi

# Firmware is built with make and a RISC-V GNU toolchain, the organisers'
# Firmware Builder flow. Without them the flows that need firmware are skipped,
# not failed. TC is the toolchain prefix, found as the organisers' Makefile
# finds it (riscv32-unknown-elf, riscv64-unknown-elf), or xPack's
# riscv-none-elf (GCC 13.2.0, the organisers' release; ~/tools on Windows).
for d in "$HOME/tools/bin" "$HOME/tools/xpack-windows-build-tools-4.4.1-3/bin" \
         "${RISCV_GCC_BIN:-$HOME/tools/xpack-riscv-none-elf-gcc-13.2.0-2/bin}"; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
TC=""
for t in riscv32-unknown-elf riscv64-unknown-elf riscv-none-elf; do
    command -v "$t-gcc" > /dev/null 2>&1 && { TC=$t; break; }
done
HAVE_FW=0
if [ -n "$TC" ] && command -v make > /dev/null 2>&1; then
    HAVE_FW=1
    export RISCV_GCC_BIN="$(dirname "$(command -v "$TC-gcc")")"
fi
#   xcheck_gnu_as  asm.py and GNU as produce identical words for every program,
#                  and GNU as rebuilds the official firmware hex exactly
#   tb_selftest    the firmware self-test (application/firmware/selftest) on
#                  rtl/top.v: HAL, UART, GPIO, Xicrc, multiply, division,
#                  Chaskey-12 reference vectors
if [ $HAVE_FW = 1 ] && [ "$TC" = riscv-none-elf ]; then
    TOTAL=$((TOTAL+1))
    if $PY scripts/xcheck_gnu_as.py > "$BUILD/xcheck_gnu_as.log" 2>&1; then
        n=$(count_checks "$BUILD/xcheck_gnu_as.log"); CHECKS=$((CHECKS+n))
        echo "PASS          xcheck_gnu_as   $(grep -E '==== .* ====' "$BUILD/xcheck_gnu_as.log")"
        echo "| \`xcheck_gnu_as\` | Tooling | $n | PASS |" >> "$SUMMARY"
    else
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST xcheck_gnu_as"
        echo "FAIL          xcheck_gnu_as"; cat "$BUILD/xcheck_gnu_as.log"
        echo "| \`xcheck_gnu_as\` | Tooling | - | FAIL |" >> "$SUMMARY"
    fi
fi
if [ $HAVE_FW = 1 ]; then
    TOTAL=$((TOTAL+1))
    if make -C application/firmware APP=selftest TC=$TC > "$BUILD/tb_selftest.log" 2>&1 && \
       iverilog -g2005 -o "$BUILD/tb_selftest.vvp" rtl/*.v application/testbench/tb_selftest.v >> "$BUILD/tb_selftest.log" 2>&1 && \
       vvp -n "$BUILD/tb_selftest.vvp" >> "$BUILD/tb_selftest.log" 2>&1 && \
       grep -q "TB_SELFTEST: ALL TESTS PASSED" "$BUILD/tb_selftest.log"; then
        n=$(count_checks "$BUILD/tb_selftest.log"); CHECKS=$((CHECKS+n))
        echo "PASS          tb_selftest   $(grep -E '==== .* ====' "$BUILD/tb_selftest.log")"
        echo "| \`tb_selftest\` | Firmware | $n | PASS |" >> "$SUMMARY"
    else
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST tb_selftest"
        echo "FAIL          tb_selftest"; tail -30 "$BUILD/tb_selftest.log"
        echo "| \`tb_selftest\` | Firmware | - | FAIL |" >> "$SUMMARY"
    fi
else
    echo "SKIP          xcheck_gnu_as, tb_selftest   (needs make and a RISC-V GNU toolchain)"
fi

echo ""
echo "=============================================="
echo " Unit-level testbenches"
echo "=============================================="
for tb in $UNIT_TBS; do
    run_one "$tb" 120 "Unit"
done

echo ""
echo "=============================================="
echo " Integration-level testbenches"
echo "=============================================="
for tb in $INTEGRATION_TBS; do
    run_one "$tb" 300 "Integration"
done

# The ChipInventor mirror (chipinventor/) is verified by its own run_ci.sh. Two
# things only this flow can check, because chipinventor/ never reads outside
# itself: that its copies of the blocks and Stage 3 programs still match rtl/
# and tests/progs/stage3/, and that the canvas structure (ci_top.v) is the
# same machine as rtl/, cycle for cycle, on all seven programs.
echo ""
echo "=============================================="
echo " ChipInventor mirror"
echo "=============================================="
TOTAL=$((TOTAL+1))
if $PY scripts/check_ci_sync.py > "$BUILD/check_ci_sync.log" 2>&1; then
    n=$(count_checks "$BUILD/check_ci_sync.log"); CHECKS=$((CHECKS+n))
    echo "PASS          check_ci_sync   $(grep -E '==== .* ====' "$BUILD/check_ci_sync.log")"
    echo "| \`check_ci_sync\` | Mirror | $n | PASS |" >> "$SUMMARY"
else
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST check_ci_sync"
    echo "FAIL          check_ci_sync"; cat "$BUILD/check_ci_sync.log"
    echo "| \`check_ci_sync\` | Mirror | - | FAIL |" >> "$SUMMARY"
fi
TOTAL=$((TOTAL+1))
if $PY chipinventor/scripts/gen_ci_imem.py --check > "$BUILD/tb_ci_equiv.log" 2>&1 && \
   $PY chipinventor/scripts/make_ref.py --src rtl --prefix s3ref_ \
       --out "$BUILD/s3ref_renamed.v" >> "$BUILD/tb_ci_equiv.log" 2>&1 && \
   iverilog -g2005 -s tb_ci_equiv -o "$BUILD/tb_ci_equiv.vvp" \
       -Ptb_ci_equiv.ROM_WORDS=$(wc -l < chipinventor/build/rom_image.hex) \
       $(ls chipinventor/blocks/*.v | grep -v '/imem_mock\.v$') chipinventor/ci_top.v \
       "$BUILD/s3ref_renamed.v" tb/tb_ci_equiv.v >> "$BUILD/tb_ci_equiv.log" 2>&1 && \
   vvp "$BUILD/tb_ci_equiv.vvp" >> "$BUILD/tb_ci_equiv.log" 2>&1 && \
   grep -q "TB_CI_EQUIV: ALL TESTS PASSED" "$BUILD/tb_ci_equiv.log"; then
    # Per-cycle lockstep comparisons, tallied apart from the directed checks
    # so the headline count keeps meaning what it meant in Phase 2.
    n=$(count_checks "$BUILD/tb_ci_equiv.log"); LOCKSTEP=$((LOCKSTEP+n))
    echo "PASS          tb_ci_equiv   $(grep -E '==== .* ====' "$BUILD/tb_ci_equiv.log")"
    echo "| \`tb_ci_equiv\` | Mirror | $n lockstep comparisons | PASS |" >> "$SUMMARY"
else
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST tb_ci_equiv"
    echo "FAIL          tb_ci_equiv"; tail -20 "$BUILD/tb_ci_equiv.log"
    echo "| \`tb_ci_equiv\` | Mirror | - | FAIL |" >> "$SUMMARY"
fi

# ---------------------------------------------------------------------------
# Stage 3, in the order of the brief's workflow:
#   official      the Official Firmware Testbench (official-firmware-testbench/
#                 run.sh): the organisers' GPIO/UART test firmware, rebuilt by
#                 their Makefile, on the canvas chip and its export; ./emu lines
#   app_build     the application firmware (application/firmware): built by
#                 the organisers' Firmware Builder flow, ISA and size gates; the
#                 golden model's scenarios and every generated file current
#   tb_app        the Application Firmware Testbench: the firmware on
#                 rtl/top.v, every record and pin byte-for-byte against the
#                 golden model (application/testbench/lane_model.py); directed
#                 and showcase, plus fuzz and random with RUN_LONG=1
#   tb_app_ci     the platform testbench on the canvas design
#   emu_preview   the Emulator Preview: the ./emu command lines of
#                 application/emulator-preview/emu_commands.txt, on the chip
#   page_core     the replay page's own decoding and checking logic
# Stage 4 (AWS F2), kept for the next stage, with RUN_STAGE4=1 (needs stage4-aws/):
#   tb_cl, cosim  the F2 wrapper over AXI4-Lite, and the host tool against it
run_flow() {   # name, level, log, command...
    local name=$1 level=$2 log=$3; shift 3
    TOTAL=$((TOTAL+1))
    if "$@" > "$log" 2>&1 && grep -q "ALL TESTS PASSED\|: PASS$" "$log"; then
        n=$(count_checks "$log"); CHECKS=$((CHECKS+n))
        echo "PASS          $name   $(grep -E '==== .* ====' "$log" | tail -1)"
        echo "| \`$name\` | $level | $n | PASS |" >> "$SUMMARY"
    else
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $name"
        echo "FAIL          $name"; tail -20 "$log"
        echo "| \`$name\` | $level | - | FAIL |" >> "$SUMMARY"
    fi
}
CI_BLOCKS=$(ls chipinventor/blocks/*.v | grep -v -E '/imem(_mock)?\.v$')
echo ""
echo "=============================================="
echo " Stage 3: official firmware and application"
echo "=============================================="
official() { bash official-firmware-testbench/run.sh; }
run_flow official "Official firmware" "$BUILD/official.log" official
if [ $HAVE_FW = 1 ]; then
    if make -C application/firmware TC=$TC > "$BUILD/build_lane.log" 2>&1 && \
       $PY application/testbench/lane_model.py >> "$BUILD/build_lane.log" 2>&1 && \
       cmp -s application/firmware/out/lane/firmware.hex chipinventor/app/lane.hex && \
       $PY chipinventor/scripts/gen_ci_imem.py --check --image chipinventor/app/lane.hex \
           --out chipinventor/app/imem_app.v >> "$BUILD/build_lane.log" 2>&1 && \
       $PY application/testbench/gen_platform_tb.py --check >> "$BUILD/build_lane.log" 2>&1 && \
       $PY application/emulator-preview/gen_emu_preview.py --check \
           application/emulator-preview/emu_commands.txt \
           application/emulator-preview/tb_emu_preview.v >> "$BUILD/build_lane.log" 2>&1; then
        echo "OK            application firmware built (organisers' flow); generated files current"
    else
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST app_build"
        echo "FAIL          app_build (a generated file is stale? see $BUILD/build_lane.log)"
        tail -15 "$BUILD/build_lane.log"
    fi
    app_tb() {
        iverilog -g2005 -o "$BUILD/tb_app.vvp" rtl/*.v application/testbench/tb_app.v && \
        vvp -n "$BUILD/tb_app.vvp" +STIM=build/lane/$1.stim +EXP=build/lane/$1.exp
    }
    # the same firmware with the UART at 921,600 bps (the platform's fast run)
    app_tb_fast() {
        iverilog -g2005 -P tb_app.BAUD=921600 -P tb_app.GAP_BITS=60 -o "$BUILD/tb_app_fast.vvp" \
            rtl/*.v application/testbench/tb_app.v && \
        vvp -n "$BUILD/tb_app_fast.vvp" +STIM=build/lane/$1.stim +EXP=build/lane/$1.exp
    }
    run_flow tb_app "Application" "$BUILD/tb_app.log" app_tb directed
    run_flow tb_app_show "Application" "$BUILD/tb_app_show.log" app_tb showcase
    run_flow tb_app_fast "Application" "$BUILD/tb_app_fast.log" app_tb_fast showcase
    if [ "${RUN_LONG:-0}" = "1" ]; then
        run_flow tb_app_fuzz "Application" "$BUILD/tb_app_fuzz.log" app_tb fuzz
        run_flow tb_app_random "Application" "$BUILD/tb_app_random.log" app_tb random
    fi
    app_ci() {
        iverilog -g2005 -o "$BUILD/tb_app_ci.vvp" $CI_BLOCKS chipinventor/ci_top.v \
            chipinventor/app/imem_app.v chipinventor/app/tb_app_ci.v && vvp -n "$BUILD/tb_app_ci.vvp"
    }
    run_flow tb_app_ci "Application (platform tb)" "$BUILD/tb_app_ci.log" app_ci
    emu_preview() {
        iverilog -g2005 -s testbench -o "$BUILD/emu_preview.vvp" $CI_BLOCKS chipinventor/ci_top.v \
            chipinventor/app/imem_app.v application/emulator-preview/tb_emu_preview.v && \
        (cd "$BUILD" && vvp -n emu_preview.vvp)
    }
    run_flow emu_preview "Emulator preview" "$BUILD/emu_preview.log" emu_preview
    # one vehicle, for the report's waveform (application/testbench/tb_wave_app.v)
    wave_app() {
        iverilog -g2005 -s testbench -o "$BUILD/wave_app.vvp" $CI_BLOCKS chipinventor/ci_top.v \
            chipinventor/app/imem_app.v application/testbench/tb_wave_app.v && \
        (cd "$BUILD" && vvp -n wave_app.vvp) > "$BUILD/wave_app.out" 2>&1; cat "$BUILD/wave_app.out"
        if grep -q "completed successfully" "$BUILD/wave_app.out"; then
            echo "==== tb_wave_app: 3 passed, 0 failed ===="; echo "TB_WAVE_APP: ALL TESTS PASSED"
        fi
    }
    run_flow wave_app "Application waveform" "$BUILD/wave_app.log" wave_app
    # the replay page's own logic (lane_core.js) against the golden model, and a
    # blind testbench it generates, run on the export
    if $PY -c "import quickjs" > /dev/null 2>&1; then
        page_core() { $PY application/replay/test_lane_core.py --sim; }
        run_flow page_core "Replay page logic" "$BUILD/page_core.log" page_core
    else
        echo "SKIP          page_core   (python -m pip install quickjs)"
    fi
    if [ "${RUN_STAGE4:-0}" = "1" ] && [ -d stage4-aws ]; then
        echo ""
        echo "---- Stage 4 (AWS F2) ----"
        CL_SRC="stage4-aws/sim/xilinx_models.v stage4-aws/aws/rvbl2_cl.sv stage4-aws/aws/rvbl2_dut.sv stage4-aws/aws/rvbl2_imem.sv stage4-aws/aws/rvbl2_soc.sv"
        cl_tb() {
            make -C application/firmware APP=emu_demo APP_DIR=../../stage4-aws/emu_demo TC=$TC && \
            $PY stage4-aws/gen_aws_project.py && \
            iverilog -g2012 -o "$BUILD/tb_cl.vvp" $CL_SRC stage4-aws/tb/tb_cl.sv && vvp -n "$BUILD/tb_cl.vvp"
        }
        run_flow tb_cl "AWS F2 wrapper" "$BUILD/tb_cl.log" cl_tb
        if command -v wsl.exe > /dev/null 2>&1 && \
           wsl.exe -d Ubuntu-24.04 -- bash -lc 'command -v gcc' > /dev/null 2>&1; then
            cosim() {
                iverilog -g2012 -o "$BUILD/tb_cosim.vvp" $CL_SRC stage4-aws/tb/tb_cosim.sv && \
                wsl.exe -d Ubuntu-24.04 -- bash -lc "cd '$(wslpath -a . 2>/dev/null || echo /mnt/c${PWD#/c})' && \
                    gcc -std=gnu11 -O2 -Wall -Werror -DRVBL2_SIM -o build/rvbl2_sim stage4-aws/host/rvbl2_f2.c && \
                    export RVBL2_SIM_CMD='$(command -v vvp | sed 's#^/c#/mnt/c#').exe -n build/tb_cosim.vvp' && \
                    ./build/rvbl2_sim verdict chipinventor/firmware/validation_firmware.hex && \
                    ./build/rvbl2_sim attest application/firmware/out/lane/firmware.hex --plain && \
                    ./build/rvbl2_sim lane showcase --plain --rom application/firmware/out/lane/firmware.hex" | tr -d '\0'
            }
            run_flow cosim "Host tool x CL RTL" "$BUILD/cosim.log" cosim
        else
            echo "SKIP          cosim   (needs WSL with gcc)"
        fi
    fi
else
    echo "SKIP          application flows   (needs make and a RISC-V GNU toolchain)"
fi

# Gate-level equivalence needs a synthesized netlist; it is skipped rather than
# failed when one has not been generated yet.
echo ""
echo "=============================================="
echo " Gate-level equivalence"
echo "=============================================="
if [ -f synth/top_generic_synth.v ]; then
    if bash scripts/run_gl_equiv.sh > "$BUILD/tb_gatelevel.log" 2>&1; then
        TOTAL=$((TOTAL+1))
        n=$(count_checks "$BUILD/tb_gatelevel.log")
        CHECKS=$((CHECKS+n))
        echo "PASS          tb_gatelevel   $(grep -E '==== .* ====' "$BUILD/tb_gatelevel.log" | tail -1)"
        echo "| \`tb_gatelevel\` | Gate-level | $n | PASS |" >> "$SUMMARY"
    else
        TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST tb_gatelevel"
        echo "FAIL          tb_gatelevel"
        tail -20 "$BUILD/tb_gatelevel.log"
        echo "| \`tb_gatelevel\` | Gate-level | - | FAIL |" >> "$SUMMARY"
    fi
else
    echo "SKIP          tb_gatelevel   (run scripts/synth_yosys_generic.sh first)"
fi

echo "| **Total** | | **$CHECKS** | **$((TOTAL-FAILED))/$TOTAL PASS** |" >> "$SUMMARY"

echo ""
echo "=============================================="
echo " SUMMARY: $((TOTAL-FAILED))/$TOTAL testbenches passed, $CHECKS individual checks"
echo "          plus $LOCKSTEP lockstep comparisons (canvas mirror vs rtl/)"
echo "=============================================="
echo "Markdown summary written to $SUMMARY"
if [ $FAILED -gt 0 ]; then
    echo "FAILED:$FAILED_LIST"
    exit 1
fi
exit 0
