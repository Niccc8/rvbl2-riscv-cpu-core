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
tb_multiplier tb_crc_unit tb_lsu tb_imem tb_dmem tb_address_decoder tb_control_unit"

INTEGRATION_TBS="tb_core tb_soc tb_reset tb_firmware"

TOTAL=0
FAILED=0
CHECKS=0
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
        tb_core|tb_soc|tb_reset|tb_firmware)
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
echo "=============================================="
echo "Markdown summary written to $SUMMARY"
if [ $FAILED -gt 0 ]; then
    echo "FAILED:$FAILED_LIST"
    exit 1
fi
exit 0
