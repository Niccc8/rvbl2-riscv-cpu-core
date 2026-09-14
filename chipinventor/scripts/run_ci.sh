#!/usr/bin/env bash
# run_ci.sh - verify the ChipInventor migration locally, before anything is
# pasted into the platform.
#
# Everything here runs against files inside chipinventor/ only. Nothing outside
# this directory is read or written, so the original file-driven flow in the
# repository root is untouched and can be picked up unchanged.
#
# Requires: iverilog (Icarus Verilog) and python. Run from any directory.
set -u
cd "$(dirname "$0")/.."   # chipinventor/

BUILD=build
mkdir -p "$BUILD"

PY=python
if ! $PY -c "" > /dev/null 2>&1; then PY=python3; fi

FAILED=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED+1)); }

# ---------------------------------------------------------------------------
step "1/12  Official validation firmware is intact"
# The vendored copy must match the audited upstream bytes exactly, and must
# still parse to 259 contiguous words at 0x00400000. The firmware is
# position-dependent - it derives its .bss base from the PC - so a shifted or
# truncated image would not fail loudly on its own.
if $PY scripts/gen_validation_hex.py --check; then ok "vendored firmware matches the audited bytes"
else bad "official firmware image is stale or amended upstream"; fi

# ---------------------------------------------------------------------------
step "2/12  Supplementary firmware image is current"
# Must be exactly tb_firmware_prog.s plus the appended coverage block, and must
# still be position-independent: it is placed at 0x00400800 because word 0 of
# the ROM belongs to the official firmware.
if $PY scripts/gen_ci_firmware.py --check; then ok "firmware source is current"
else bad "firmware source is stale - run scripts/gen_ci_firmware.py"; fi

# ---------------------------------------------------------------------------
step "3/12  Generated ROM matches both firmware images"
# Guards against the imem block drifting from the hex images it was generated
# from, which would be invisible at simulation time since both are inside the
# design, and against either image being placed at the wrong offset.
if $PY scripts/gen_ci_imem.py --check; then ok "blocks/imem.v matches both images"
else bad "blocks/imem.v is stale - run scripts/gen_ci_imem.py"; fi

# ---------------------------------------------------------------------------
step "4/12  Testbench constants match the firmware"
if $PY scripts/check_consistency.py; then ok "testbench constants are current"
else bad "testbench constants are stale"; fi

# ---------------------------------------------------------------------------
step "5/12  Mirror equivalence: ci_top.v vs the verified original"
# The load-bearing check. ci_top flattens away riscv_core, turns four inline
# assigns and one case into real mux blocks, adds ir_fields, feeds funct3 from
# control_unit's op_size, and swaps a $readmemh ROM for a generated case-ROM.
# This runs both designs in lockstep and compares complete architectural state
# every cycle, so any of those going subtly wrong shows up here.
if $PY scripts/make_ref.py > "$BUILD/make_ref.log" 2>&1; then
    if iverilog -g2005 -s tb_mirror_equiv -o "$BUILD/mirror.vvp" \
            $(ls blocks/*.v | grep -v '/imem_mock\.v$') ci_top.v \
            "$BUILD/ref_renamed.v" scripts/tb_mirror_equiv.v \
            > "$BUILD/mirror.compile" 2>&1; then
        vvp "$BUILD/mirror.vvp" > "$BUILD/mirror.log" 2>&1
        if grep -q "TB_MIRROR_EQUIV: ALL TESTS PASSED" "$BUILD/mirror.log"; then
            ok "$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$BUILD/mirror.log" | tail -1)"
        else
            bad "mirror equivalence"; tail -20 "$BUILD/mirror.log"
        fi
    else
        bad "mirror equivalence did not compile"; cat "$BUILD/mirror.compile"
    fi
else
    bad "could not build the renamed reference"; cat "$BUILD/make_ref.log"
fi

# ---------------------------------------------------------------------------
# blocks/imem_mock.v declares the same module name as blocks/imem.v (that is
# what makes it a drop-in), so the two can never be elaborated together. Every
# build below picks exactly one of them.
BLOCKS_NO_IMEM=$(ls blocks/*.v | grep -vE '/imem(_mock)?\.v$')

step "6/12  Combined suite against the local mirror"
# This is the same file that gets pasted into the platform's testbench field.
# SUITE 2A inside it is the official validation firmware run.
if iverilog -g2005 -s testbench -o "$BUILD/tb.vvp" \
        $BLOCKS_NO_IMEM blocks/imem.v ci_top.v tb_chipinventor.v \
        > "$BUILD/tb.compile" 2>&1; then
    vvp "$BUILD/tb.vvp" > "$BUILD/tb.log" 2>&1
    if grep -q "^ALL TESTS PASSED" "$BUILD/tb.log"; then
        ok "$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$BUILD/tb.log" | tail -1)"
    else
        bad "combined suite"; grep -E '^\[FAIL\]|failed' "$BUILD/tb.log" | head -30
    fi
else
    bad "combined suite did not compile"; cat "$BUILD/tb.compile"
fi

# ---------------------------------------------------------------------------
step "7/12  OFFICIAL VALIDATION FIRMWARE VERDICT"
# The competition criterion, pulled out of the suite log so it is its own
# pass/fail line rather than something to go looking for: x4 = 0 is PASS.
if grep -q "OFFICIAL VALIDATION FIRMWARE: x4 = 00000000  PASS" "$BUILD/tb.log" 2>/dev/null; then
    ok "$(grep -oE 'Firmware settled after [0-9]+ cycles at pc=[0-9a-f]+ \([a-z_]+\)' "$BUILD/tb.log" | head -1)"
    ok "x4 = 00000000 - the official firmware PASSES on this core"
else
    bad "official validation firmware did not pass"
    grep -E "Firmware settled|x4 = |_error was|the branch into _error" "$BUILD/tb.log" 2>/dev/null | head -10
fi

# ---------------------------------------------------------------------------
step "8/12  Mock IMEM drives the core (this is what OpenLane synthesises)"
# blocks/imem_mock.v is what gets pasted for the P&R run, so it is the version
# of the design that gets taped out - but it is not exercised by the suite
# above and could rot unnoticed. Build the whole core against it and run the
# firmware repository's own three-instruction program.
if iverilog -g2005 -s tb_mock_imem -o "$BUILD/mock.vvp" \
        $BLOCKS_NO_IMEM blocks/imem_mock.v ci_top.v scripts/tb_mock_imem.v \
        > "$BUILD/mock.compile" 2>&1; then
    vvp "$BUILD/mock.vvp" > "$BUILD/mock.log" 2>&1
    if grep -q "TB_MOCK_IMEM: ALL TESTS PASSED" "$BUILD/mock.log"; then
        ok "mock ROM runs on the core: x5=10, x6=5, x7=15"
    else
        bad "mock IMEM"; tail -10 "$BUILD/mock.log"
    fi
else
    bad "mock IMEM did not compile"; cat "$BUILD/mock.compile"
fi

# ---------------------------------------------------------------------------
step "9/12  Blocks are free of constructs the platform cannot resolve"
# The platform compiles block source with no defines and no filesystem, so an
# unresolved `ifdef leaves a block with no body and $readmemh silently loads
# nothing. Both failure modes are quiet, which is why they are checked here
# rather than left to be noticed in a synthesis report.
# Comments are stripped first: several blocks discuss these constructs in their
# headers precisely because they had to be removed, and matching that prose
# would make this check cry wolf. (Line comments only - no block uses /* */.)
STRIP='{ line = $0; sub(/\/\/.*/, "", line); }'

BAD_CONSTRUCTS=$(awk "$STRIP"'
    line ~ /`ifdef|`ifndef|`include|\$readmemh|\$fopen|\$fscanf/ {
        printf "%s:%d:%s\n", FILENAME, FNR, line
    }' blocks/*.v)
if [ -z "$BAD_CONSTRUCTS" ]; then
    ok "no ifdef / include / file I/O in any block"
else
    bad "blocks contain constructs the platform cannot resolve:"
    echo "$BAD_CONSTRUCTS"
fi

# An initial block inside a block would reach synthesis on the platform, since
# there is no way to pass -DSYNTHESIS there.
INITIALS=$(awk "$STRIP"'
    line ~ /(^|[^A-Za-z_0-9])initial([^A-Za-z_0-9]|$)/ { print FILENAME }' blocks/*.v | sort -u)
# (blocks/*.v here deliberately includes imem_mock.v - it gets pasted into the
# platform too, so it is held to the same rules.)
if [ -z "$INITIALS" ]; then
    ok "no initial blocks in any block (nothing leaks into synthesis)"
else
    bad "these blocks contain an initial block, which would reach synthesis:"
    echo "$INITIALS"
fi

# ---------------------------------------------------------------------------
step "10/12  Schematic layout is clean"
# The diagram is generated from ci_top.v by a channel router, so it cannot drift
# from the design - but a placement change can still produce a wire that runs
# through a block or two nets sharing a line. Both are checked geometrically.
if $PY scripts/gen_schematic.py --check > "$BUILD/schematic.log" 2>&1; then
    ok "$(grep -m1 'canvas' "$BUILD/schematic.log" | sed 's/^ *//')"
else
    bad "schematic layout has overlaps:"; head -20 "$BUILD/schematic.log"
fi

# ---------------------------------------------------------------------------
# Steps 11 and 12 only run once the project has been wired on the canvas and
# exported (the BLOCKS button). Before that there is nothing to check, so they
# are skipped rather than failed.
if [ -f top.v ]; then
    step "11/12  Exported netlist matches the verified design"
    # Wiring 72 connections by hand is the one step no generator protects.
    # This compares the export to ci_top.v as a graph - same instances, same
    # partition of pins into nets - so a swapped or missing wire fails here
    # rather than as a puzzling simulation result.
    if $PY scripts/check_export.py top.v > "$BUILD/export.log" 2>&1; then
        sed 's/^/     /' "$BUILD/export.log"
        ok "top.v is wired identically to ci_top.v"
    else
        bad "exported netlist does not match the design:"
        cat "$BUILD/export.log"
    fi

    step "12/12  Combined suite against the EXPORTED netlist"
    # The real thing: the same testbench, re-aliased to the platform's
    # auto-generated instance names, run against the netlist the canvas
    # actually produced. build/tb_platform.v is what gets pasted.
    cp tb_chipinventor.v "$BUILD/tb_platform.v"
    if $PY scripts/gen_ci_aliases.py top.v --write "$BUILD/tb_platform.v" > "$BUILD/alias.log" 2>&1; then
        if iverilog -g2005 -s testbench -o "$BUILD/platform.vvp" \
                top.v "$BUILD/tb_platform.v" > "$BUILD/platform.compile" 2>&1; then
            vvp "$BUILD/platform.vvp" > "$BUILD/platform.log" 2>&1
            if grep -q "^ALL TESTS PASSED" "$BUILD/platform.log" && \
               grep -q "x4 = 00000000  PASS" "$BUILD/platform.log"; then
                ok "$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$BUILD/platform.log" | tail -1) on the exported netlist"
                ok "official firmware PASSES on the exported netlist"
                ok "paste build/tb_platform.v into the platform's testbench field"
            else
                bad "suite failed on the exported netlist"
                grep -E '^\[FAIL\]|failed|x4 = ' "$BUILD/platform.log" | head -20
            fi
        else
            bad "suite did not compile against top.v"; head -20 "$BUILD/platform.compile"
        fi
    else
        bad "could not re-alias the testbench"; cat "$BUILD/alias.log"
    fi
else
    printf '\n=== 11-12  Exported netlist ===\n'
    printf 'SKIP no top.v yet - export the project (BLOCKS button) into chipinventor/\n'
fi

# ---------------------------------------------------------------------------
printf '\n========================================\n'
if [ $FAILED -eq 0 ]; then
    printf ' ALL CHECKS PASSED - safe to paste into ChipInventor\n'
    printf '========================================\n'
    exit 0
else
    printf ' %d CHECK(S) FAILED - do not paste yet\n' "$FAILED"
    printf '========================================\n'
    exit 1
fi
