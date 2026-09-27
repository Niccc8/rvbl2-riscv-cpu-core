#!/usr/bin/env bash
# run_ci.sh - verify the ChipInventor design locally, before anything is
# pasted into the platform.
#
# Everything here runs against files inside chipinventor/ only. Nothing outside
# this directory is read or written, so the original file-driven flow in the
# repository root is untouched and can be picked up unchanged. (The root flow,
# scripts/run_all.sh, checks the other direction: that blocks/ and
# firmware/stage3/ still match rtl/ and tests/progs/stage3/.)
#
# Stage 3 has two canvas projects - rvbl2_soc (reused as IP) and the chip
# `top` - mirrored locally by ci_top.v. Steps 14-15 audit the platform's export
# of `top`, saved as export_stage3.v; until it exists they are skipped. The
# Phase 2 export (top.v) is kept untouched as the graded project's evidence.
#
# Requires: iverilog (Icarus Verilog) and python. Run from any directory.
set -u
cd "$(dirname "$0")/.."   # chipinventor/

BUILD=build
mkdir -p "$BUILD"
EXPORT=export_stage3.v

PY=python
if ! $PY -c "" > /dev/null 2>&1; then PY=python3; fi

FAILED=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED+1)); }

# Runs the combined suite against a netlist and reports it. $1 label, $2 log
# stem, then the sources. The platform elaborates the export on its own, so a
# port-width mismatch (which iverilog pads with only a warning) is a failure.
run_suite() {
    label=$1; stem=$2; shift 2
    if iverilog -g2005 -s testbench -o "$BUILD/$stem.vvp" "$@" > "$BUILD/$stem.compile" 2>&1; then
        if grep -q "expects .* bits, got" "$BUILD/$stem.compile"; then
            bad "$label: port width mismatch"; grep "expects" "$BUILD/$stem.compile" | head -10
            return
        fi
        vvp "$BUILD/$stem.vvp" > "$BUILD/$stem.log" 2>&1
        if grep -q "^ALL TESTS PASSED" "$BUILD/$stem.log" && \
           grep -q "x4 = 00000000  PASS" "$BUILD/$stem.log"; then
            ok "$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$BUILD/$stem.log" | tail -1) - $label"
        else
            bad "$label"; grep -E '^\[FAIL\]|failed|x4 = ' "$BUILD/$stem.log" | head -20
        fi
    else
        bad "$label did not compile"; head -20 "$BUILD/$stem.compile"
    fi
}

# blocks/imem_mock.v declares the same module name as blocks/imem.v (that is
# what makes it a drop-in), so the two can never be elaborated together. Every
# build below picks exactly one of them.
BLOCKS_NO_IMEM=$(ls blocks/*.v | grep -vE '/imem(_mock)?\.v$')

# ---------------------------------------------------------------------------
step "1/16  Official validation firmware is intact"
# The vendored copy must match the audited upstream bytes exactly, and must
# still parse to 259 contiguous words at 0x00400000. The firmware is
# position-dependent, so a shifted or truncated image would not fail loudly.
if $PY scripts/gen_validation_hex.py --check; then ok "vendored firmware matches the audited bytes"
else bad "official firmware image is stale or amended upstream"; fi

# ---------------------------------------------------------------------------
step "2/16  Supplementary firmware image is current"
if $PY scripts/gen_ci_firmware.py --check; then ok "firmware source is current"
else bad "firmware source is stale - run scripts/gen_ci_firmware.py"; fi

# ---------------------------------------------------------------------------
step "3/16  Stage 3 program images are current and position-independent"
if $PY scripts/gen_ci_stage3.py --check; then :
else bad "Stage 3 images are stale - run scripts/gen_ci_stage3.py"; fi

# ---------------------------------------------------------------------------
step "4/16  Generated ROM matches every firmware image"
# Guards against the imem block drifting from the images it was generated
# from, and against any image being placed at the wrong offset.
if out=$($PY scripts/gen_ci_imem.py --check 2>&1); then echo "$out" | cut -c1-110
else bad "blocks/imem.v is stale - run scripts/gen_ci_imem.py"; echo "$out"; fi

# ---------------------------------------------------------------------------
step "5/16  Testbench constants match the firmware"
if $PY scripts/check_consistency.py; then :
else bad "testbench constants are stale"; fi

# ---------------------------------------------------------------------------
step "6/16  Mirror equivalence: ci_top.v vs the frozen Phase 2 core"
# The load-bearing check. ci_top flattens away riscv_core, turns inline logic
# into mux blocks, adds ir_fields and the Stage 3 peripherals, and swaps the
# ROM for a generated case-ROM. Both designs run the same programs in lockstep
# and complete architectural state is compared every cycle - and on every
# cycle the peripherals must be inert: tx_o idle, no pin enabled or driven.
if $PY scripts/make_ref.py > "$BUILD/make_ref.log" 2>&1; then
    if iverilog -g2005 -s tb_mirror_equiv -o "$BUILD/mirror.vvp" \
            -Ptb_mirror_equiv.ROM_WORDS=$(wc -l < "$BUILD/rom_image.hex") \
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
# crc_unit is rewritten as byte updates (faster to simulate); it must be the
# generator's output, and equal to the frozen Phase 2 block on every input.
if $PY scripts/gen_crc_xor.py --check > "$BUILD/crc_form.log" 2>&1 && \
   $PY scripts/gen_crc_xor.py --prove >> "$BUILD/crc_form.log" 2>&1; then
    ok "$(tail -1 "$BUILD/crc_form.log" | sed 's/^OK   //')"
else
    bad "blocks/crc_unit.v"; cat "$BUILD/crc_form.log"
fi

# ---------------------------------------------------------------------------
step "7/16  Combined suite against the local mirror"
# The same file that gets pasted into the platform's testbench field. SUITE 2A
# is the official validation firmware; SUITE 4 is Stage 3.
run_suite "combined suite on ci_top.v" tb $BLOCKS_NO_IMEM blocks/imem.v ci_top.v tb_chipinventor.v

# ---------------------------------------------------------------------------
step "8/16  OFFICIAL VALIDATION FIRMWARE VERDICT"
if grep -q "OFFICIAL VALIDATION FIRMWARE: x4 = 00000000  PASS" "$BUILD/tb.log" 2>/dev/null; then
    ok "$(grep -oE 'Firmware settled after [0-9]+ cycles at pc=[0-9a-f]+ \([a-z_]+\)' "$BUILD/tb.log" | head -1)"
    ok "x4 = 00000000 - the official firmware PASSES on this core"
else
    bad "official validation firmware did not pass"
    grep -E "Firmware settled|x4 = |_error was|the branch into _error" "$BUILD/tb.log" 2>/dev/null | head -10
fi

# ---------------------------------------------------------------------------
step "9/16  Mock IMEM drives the core (this is what OpenLane synthesises)"
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
step "10/16  Blocks are free of constructs the platform cannot resolve"
# The platform compiles block source with no defines and no filesystem, so an
# unresolved `ifdef leaves a block with no body and $readmemh silently loads
# nothing; an initial block would reach synthesis. Comments are stripped first
# (line comments only - no block uses /* */), since several headers discuss
# these very constructs.
STRIP='{ line = $0; sub(/\/\/.*/, "", line); }'
BAD_CONSTRUCTS=$(awk "$STRIP"'
    line ~ /`ifdef|`ifndef|`include|\$readmemh|\$fopen|\$fscanf|\/\*/ {
        printf "%s:%d:%s\n", FILENAME, FNR, line
    }' blocks/*.v)
if [ -z "$BAD_CONSTRUCTS" ]; then ok "no ifdef / include / file I/O / block comment in any block"
else bad "blocks contain constructs the platform cannot resolve:"; echo "$BAD_CONSTRUCTS"; fi
INITIALS=$(awk "$STRIP"'
    line ~ /(^|[^A-Za-z_0-9])initial([^A-Za-z_0-9]|$)/ { print FILENAME }' blocks/*.v | sort -u)
if [ -z "$INITIALS" ]; then ok "no initial blocks in any block (nothing leaks into synthesis)"
else bad "these blocks contain an initial block:"; echo "$INITIALS"; fi

# ---------------------------------------------------------------------------
step "11/16  Docs, schematics and wiring map regenerate cleanly"
# All derived from ci_top.v and blocks/*.v. The schematic router checks its
# own geometry: no wire through a block or a table, no two nets on one line.
if $PY scripts/gen_docs.py > "$BUILD/docs.log" 2>&1; then ok "$(head -1 "$BUILD/docs.log" | sed 's/^wrote //')"
else bad "gen_docs.py"; cat "$BUILD/docs.log"; fi
if $PY scripts/gen_schematic.py --check > "$BUILD/schematic.log" 2>&1; then
    sed 's/^/     /' "$BUILD/schematic.log"
else
    bad "schematic layout has problems:"; head -20 "$BUILD/schematic.log"
fi
if $PY scripts/gen_wiring_map.py > "$BUILD/wiring_map.log" 2>&1; then ok "build/wiring_map.html"
else bad "gen_wiring_map.py"; cat "$BUILD/wiring_map.log"; fi

# ---------------------------------------------------------------------------
step "12/16  Testbench alias block matches ci_top.v"
if $PY scripts/gen_ci_aliases.py ci_top.v --check tb_chipinventor.v; then :
else bad "alias block is stale - run gen_ci_aliases.py ci_top.v --write tb_chipinventor.v"; fi

# ---------------------------------------------------------------------------
step "13/16  Export tooling proven on a platform-format mock export"
# Steps 14-15 meet their real input only once the canvas is wired. Until then,
# the same tools run on build/mock_export.v - ci_top.v re-emitted in the
# platform's own format and naming - and on ten broken copies of it.
if $PY scripts/test_check_export.py > "$BUILD/test_export.log" 2>&1; then
    ok "$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$BUILD/test_export.log") - checker passes the mock, fails all 10 wiring faults"
else
    bad "export checker self-test"; cat "$BUILD/test_export.log"
fi
cp tb_chipinventor.v "$BUILD/tb_mock_platform.v"
if $PY scripts/gen_ci_aliases.py "$BUILD/mock_export.v" --write "$BUILD/tb_mock_platform.v" > /dev/null; then
    run_suite "dry run of step 15 on the mock export" mockplat "$BUILD/mock_export.v" "$BUILD/tb_mock_platform.v"
else
    bad "could not re-alias the testbench for the mock export"
fi

# ---------------------------------------------------------------------------
if [ -f "$EXPORT" ]; then
    step "14/16  Exported netlist matches the verified design"
    # Compares both projects to ci_top.v as graphs - same instances, same
    # partition of pins into nets - plus pins, parameters and every Inout
    # Pin's C/D polarity, so a swapped or missing wire fails here.
    if $PY scripts/check_export.py "$EXPORT" > "$BUILD/export.log" 2>&1; then
        sed 's/^/     /' "$BUILD/export.log"
        ok "$EXPORT is wired identically to ci_top.v"
    else
        bad "exported netlist does not match the design:"; cat "$BUILD/export.log"
    fi

    step "15/16  Combined suite against the EXPORTED netlist"
    # The real thing: the same testbench, re-aliased to the platform's
    # instance names, run on the netlist the canvas produced. The suite needs
    # the validation ROM; the export's imem holds whichever of our ROMs was
    # pasted last (step 14 named it), so the validation ROM goes in its place.
    # Nothing else in the export changes.
    EXPORT_V="$BUILD/export_validation.v"
    $PY - "$EXPORT" blocks/imem.v "$EXPORT_V" <<'EOF'
import re, sys
exp, rom, out = sys.argv[1:]
new = re.search(r"(?ms)^module imem\b.*?^endmodule", open(rom).read()).group(0)
old = open(exp).read()
text, n = re.subn(r"(?ms)^module imem\b.*?^endmodule", lambda m: new, old)
if n != 1:
    sys.exit("expected one imem module in the export, found %d" % n)
open(out, "w").write(text)
print("note the suite runs on %s with the validation ROM in imem%s" % (
    exp, "" if text == old else " (swapped in; the export holds another of our ROMs)"))
EOF
    cp tb_chipinventor.v "$BUILD/tb_platform.v"
    if $PY scripts/gen_ci_aliases.py "$EXPORT" --write "$BUILD/tb_platform.v" > "$BUILD/alias.log" 2>&1; then
        run_suite "combined suite on $EXPORT" platform "$EXPORT_V" "$BUILD/tb_platform.v"
        # The platform stops a run after a fixed wall-clock time, so there the
        # suite runs as PART 1..4. Each must pass on its own, and together they
        # must cover every check: the full count plus parts 2-4's monitor checks.
        total=$(grep -oE 'testbench: [0-9]+ passed' "$BUILD/platform.log" | grep -oE '[0-9]+' | tail -1)
        sum=0; parts_ok=1
        for part in 1 2 3 4; do
            if iverilog -g2005 -s testbench -P testbench.PART=$part -o "$BUILD/platform_p$part.vvp" \
                   "$EXPORT_V" "$BUILD/tb_platform.v" > "$BUILD/platform_p$part.log" 2>&1 && \
               vvp -n "$BUILD/platform_p$part.vvp" >> "$BUILD/platform_p$part.log" 2>&1 && \
               grep -q "^ALL TESTS PASSED" "$BUILD/platform_p$part.log"; then
                n=$(grep -oE 'part [0-9]+ of [0-9]+ done: [0-9]+ passed' "$BUILD/platform_p$part.log" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
                sum=$((sum + n))
            else
                parts_ok=0; bad "PART=$part of the combined suite failed on $EXPORT"; tail -10 "$BUILD/platform_p$part.log"
            fi
        done
        if [ $parts_ok -eq 1 ] && [ -n "$total" ] && [ $sum -eq $((total + 6)) ]; then
            ok "PART 1-4 each pass on $EXPORT: $sum checks = $total + 6 repeated monitor checks"
            ok "paste build/tb_platform.v into the platform's testbench field; run it with PART = 1, 2, 3, 4"
        elif [ $parts_ok -eq 1 ]; then
            bad "PART 1-4 total $sum checks, expected $total + 6"
        fi
    else
        bad "could not re-alias the testbench"; cat "$BUILD/alias.log"
    fi
else
    printf '\n=== 14-15  Exported netlist ===\n'
    printf 'SKIP no %s yet - export the chip project (BLOCKS button) into chipinventor/\n' "$EXPORT"
fi

step "16/16  Application ROM and its platform testbench (the lane controller)"
# The canvas is unchanged for the application: only the imem block's Code
# differs. app/imem_app.v must encode app/lane.hex exactly, and the platform
# testbench app/tb_app_ci.v must pass on the mirror with that ROM.
if $PY scripts/gen_ci_imem.py --check --image app/lane.hex --out app/imem_app.v > "$BUILD/app_rom.log" 2>&1; then
    tail -1 "$BUILD/app_rom.log"
else
    bad "app/imem_app.v does not match app/lane.hex"; cat "$BUILD/app_rom.log"
fi
if iverilog -g2005 -o "$BUILD/tb_app_ci.vvp" $(ls blocks/*.v | grep -v -E '/imem(_mock)?\.v$') ci_top.v \
       app/imem_app.v app/tb_app_ci.v > "$BUILD/tb_app_ci.log" 2>&1 && \
   vvp -n "$BUILD/tb_app_ci.vvp" >> "$BUILD/tb_app_ci.log" 2>&1 && \
   grep -q "TB_APP_CI: ALL TESTS PASSED" "$BUILD/tb_app_ci.log"; then
    ok "115,200 bps (as taped out): $(grep -E '^==== ' "$BUILD/tb_app_ci.log" | sed 's/^==== //; s/ ====$//')"
else
    bad "application testbench failed on the mirror"; tail -15 "$BUILD/tb_app_ci.log"
fi
# The fast variant names the UART instance, so it is aliased like the main
# suite: to ci_top.v for this check, and to the export (when there is one) for
# the file to paste, which is then also run on the export itself. It holds
# three runs (SCEN 0, 1, 2), each short enough for the platform's window.
APP_SCENS="0 1 2"
cp app/tb_app_ci_fast.v "$BUILD/tb_app_fast_mirror.v"
if $PY scripts/gen_ci_aliases.py ci_top.v --write "$BUILD/tb_app_fast_mirror.v" > /dev/null 2>&1; then
    for s in $APP_SCENS; do
        if iverilog -g2005 -P testbench.SCEN=$s -o "$BUILD/tb_app_fast_s$s.vvp" \
               $(ls blocks/*.v | grep -v -E '/imem(_mock)?\.v$') ci_top.v \
               app/imem_app.v "$BUILD/tb_app_fast_mirror.v" > "$BUILD/tb_app_fast_s$s.log" 2>&1 && \
           vvp -n "$BUILD/tb_app_fast_s$s.vvp" >> "$BUILD/tb_app_fast_s$s.log" 2>&1 && \
           grep -q "TB_APP_CI: ALL TESTS PASSED" "$BUILD/tb_app_fast_s$s.log"; then
            ok "921,600 bps (platform run): $(grep -E '^==== ' "$BUILD/tb_app_fast_s$s.log" | sed 's/^==== //; s/ ====$//')"
        else
            bad "fast application testbench (SCEN=$s) failed on the mirror"; tail -15 "$BUILD/tb_app_fast_s$s.log"
        fi
    done
else
    bad "could not alias the fast application testbench to ci_top.v"
fi
if [ -f "$EXPORT" ]; then
    cp app/tb_app_ci_fast.v "$BUILD/tb_app_platform.v"
    # swap the application ROM into the export's imem for this run
    $PY - "$EXPORT" app/imem_app.v "$BUILD/export_app.v" <<'EOF'
import re, sys
exp, rom, out = sys.argv[1:]
new = re.search(r"(?ms)^module imem\b.*?^endmodule", open(rom).read()).group(0)
text, n = re.subn(r"(?ms)^module imem\b.*?^endmodule", lambda m: new, open(exp).read())
if n != 1:
    sys.exit("expected one imem module in the export, found %d" % n)
open(out, "w").write(text)
EOF
    # build/tb_app_platform.log: the three runs' logs one after another, as
    # they would be pasted into the replay page
    : > "$BUILD/tb_app_platform.log"
    app_fail=0
    if $PY scripts/gen_ci_aliases.py "$EXPORT" --write "$BUILD/tb_app_platform.v" > /dev/null 2>&1; then
        for s in $APP_SCENS; do
            if iverilog -g2005 -P testbench.SCEN=$s -o "$BUILD/tb_app_platform_s$s.vvp" "$BUILD/export_app.v" \
                   "$BUILD/tb_app_platform.v" > "$BUILD/tb_app_platform_s$s.log" 2>&1 && \
               vvp -n "$BUILD/tb_app_platform_s$s.vvp" >> "$BUILD/tb_app_platform_s$s.log" 2>&1 && \
               grep -q "TB_APP_CI: ALL TESTS PASSED" "$BUILD/tb_app_platform_s$s.log"; then
                ok "on $EXPORT with the application ROM: $(grep -E '^==== ' "$BUILD/tb_app_platform_s$s.log" | sed 's/^==== //; s/ ====$//')"
            else
                bad "fast application testbench (SCEN=$s) failed on the export"; tail -15 "$BUILD/tb_app_platform_s$s.log"
                app_fail=1
            fi
            cat "$BUILD/tb_app_platform_s$s.log" >> "$BUILD/tb_app_platform.log"
        done
        [ $app_fail -eq 0 ] && \
            ok "paste build/tb_app_platform.v (and app/imem_app.v into imem); run it with SCEN = 0, 1, 2"
    else
        bad "could not alias the fast application testbench to $EXPORT"
    fi
    # and at the taped-out rate, for the replay page's second transcript
    if iverilog -g2005 -o "$BUILD/tb_app_true_export.vvp" "$BUILD/export_app.v" app/tb_app_ci.v \
           > "$BUILD/tb_app_true_export.log" 2>&1 && \
       vvp -n "$BUILD/tb_app_true_export.vvp" >> "$BUILD/tb_app_true_export.log" 2>&1 && \
       grep -q "TB_APP_CI: ALL TESTS PASSED" "$BUILD/tb_app_true_export.log"; then
        ok "on $EXPORT at 115,200 bps: $(grep -E '^==== ' "$BUILD/tb_app_true_export.log" | sed 's/^==== //; s/ ====$//')"
    else
        bad "application testbench (115,200 bps) failed on the export"; tail -15 "$BUILD/tb_app_true_export.log"
    fi
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
