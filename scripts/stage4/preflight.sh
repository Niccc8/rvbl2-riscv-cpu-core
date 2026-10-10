#!/usr/bin/env bash
# preflight.sh - the Stage 4 pre-flight gate. Run before EVERY AWS synthesis; build only
# on "PREFLIGHT: GO". Evidence goes to build/stage4/; the summary to
# build/stage4/preflight_summary.txt (copied into docs/stage4/06_verification.md).
#
#   bash scripts/stage4/preflight.sh            # ~20 min
#   PREFLIGHT_SCALE=1.0 bash scripts/stage4/preflight.sh   # emu's real 50 ms waits (~1.5 h)
#
# Runs from Git Bash on Windows (Verilator and Yosys through WSL Ubuntu-24.04) or on
# Linux directly. Needs the organisers' files in stage4/vendor/ (stage4/README.md).
#   G1 riscv.sv is generated and current; its ROM equals firmware.hex; vendor hashes
#   G2 Verilator -sv -Wall lint with the real top.sv: no error, only waived warnings
#   G3 system simulation: the organisers' emu.c -> top.sv -> riscv.sv, all 12 lines
#      + bring-up + 2 negative lines, for the build file and the fallback
#   G4 emu's start-up window, an undriven pin read as 0 and as 1 (emulator preview)
#   G5 Yosys synth_xilinx (UltraScale+): no latch, no problem, DMEM in RAMB36E2
#   G6 timing estimate on the synthesized netlist at the core clock
#   G7 five one-line mutants, each caught by the G3 simulation
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
B=build/stage4
mkdir -p "$B"
SUM="$B/preflight_summary.txt"
SCALE="${PREFLIGHT_SCALE:-0.1}"
PY=python; $PY -c "" 2>/dev/null || PY=python3
TOP_SHA=0fd7391018a38aeeaef7
EMU_SHA=31e4ca7c3d4c4f08dd89
FAIL=0
: > "$SUM"
say() { echo "$*" | tee -a "$SUM"; }
ok()  { say "PASS  $1  $2"; }
bad() { say "FAIL  $1  $2"; FAIL=$((FAIL+1)); }

# Linux tools: native if present, else WSL
if command -v verilator > /dev/null 2>&1 && command -v yosys > /dev/null 2>&1; then
    LX() { bash -c "$1"; }
else
    case "$ROOT" in                                   # Git Bash /c/... or C:/... -> /mnt/c/...
        /[a-z]/*) WROOT="/mnt$ROOT" ;;
        [A-Za-z]:*) WROOT="/mnt/$(echo "${ROOT:0:1}" | tr 'A-Z' 'a-z')${ROOT:2}" ;;
        *) echo "cannot map $ROOT into WSL"; exit 2 ;;
    esac
    LX() { wsl -d Ubuntu-24.04 -- bash -lc "cd '$WROOT' && $1"; }
fi

say "Stage 4 pre-flight, $(date '+%Y-%m-%d %H:%M'), commit $(git rev-parse --short HEAD)$(git diff --quiet || echo '+dirty')"
say ""

# ---- G1 ------------------------------------------------------------------------
if $PY scripts/stage4/gen_riscv_sv.py --check > /dev/null && \
   $PY scripts/stage4/gen_riscv_sv.py --check --clock bufgce_div --out stage4/riscv_bufgce_div.sv > /dev/null; then
    ok G1 "riscv.sv and riscv_bufgce_div.sv are current (regenerated from rtl/ + firmware.hex)"
else bad G1 "a generated file is stale: run scripts/stage4/gen_riscv_sv.py"; fi
if $PY - <<'EOF'
import re, sys
hexw = [int(l, 16) for l in open("application/firmware/out/lane/firmware.hex") if l.strip() and not l.startswith(("//", "@"))]
for f in ("stage4/riscv.sv", "stage4/riscv_bufgce_div.sv"):
    t = open(f).read()
    rom = [int(v, 16) for v in re.findall(r"12'd\d+: rom_word = 32'h([0-9a-f]{8});", t)]
    if rom != hexw:
        sys.exit("%s: ROM differs from firmware.hex" % f)
    for bad in ("$readmem", "`timescale", "`default_nettype", "`define", "`include", "\ninitial", " initial begin"):
        if bad in t:
            sys.exit("%s contains %s" % (f, bad))
    mods = re.findall(r"^module\s+(\w+)", t, re.M)
    if not all(m in ("RISCV", "Transmitter", "Receiver") or m.startswith("rvbl2_") for m in mods):
        sys.exit("%s: unexpected module name" % f)
print("ROM %d words identical to firmware.hex in both files; no file I/O, directives or initial blocks; modules RISCV, Transmitter, Receiver, rvbl2_* only" % len(hexw))
EOF
then ok G1 "ROM bit-identical to firmware.hex; no \$readmemh/\`timescale/\`define/initial; module names safe"
else bad G1 "ROM or content check"; fi
s1=$(sha256sum stage4/vendor/top.sv 2>/dev/null | cut -c1-20); s2=$(sha256sum stage4/vendor/emu.c 2>/dev/null | cut -c1-20)
if [ "$s1" = "$TOP_SHA" ] && [ "$s2" = "$EMU_SHA" ]; then
    ok G1 "organisers' top.sv ($TOP_SHA...) and emu.c ($EMU_SHA...) unchanged"
else bad G1 "stage4/vendor/top.sv or emu.c missing or modified (top $s1, emu $s2)"; fi

# ---- G2 ------------------------------------------------------------------------
for f in riscv riscv_bufgce_div; do
    LX "verilator --lint-only -sv -Wall -Istage4/sim -Istage4/vendor --top-module top stage4/sim/unisim_models.v stage4/sim/sh_ddr_stub.v stage4/$f.sv stage4/vendor/top.sv" > "$B/lint_$f.log" 2>&1
    if $PY - "$B/lint_$f.log" "stage4/$f.sv" <<'EOF'
import re, sys
log, sv = sys.argv[1], sys.argv[2]
waive = [l.split() for l in open("stage4/sim/lint_waivers.txt") if l.strip() and not l.startswith("#")]
errs, unwaived, n = [], [], 0
for l in open(log):
    m = re.match(r"%(Error|Warning)-(\w+): ([^:]+):\d+:\d+: (.*)", l)
    if not m:
        if l.startswith("%Error:") and "Exiting due to" in l and "error" in l:
            errs.append(l.strip())
        continue
    kind, rule, f, msg = m.groups()
    if kind == "Error":
        errs.append(l.strip()); continue
    if f != sv:
        continue                     # the organisers' top.sv and our sim stubs
    n += 1
    if rule == "DECLFILENAME" or any(rule == r and ("'%s'" % s) in msg for r, s in waive):
        continue
    unwaived.append(l.strip())
if errs or unwaived:
    print("\n".join(errs + unwaived)); sys.exit(1)
print("0 errors; %d warnings in %s, all in the waiver list" % (n, sv))
EOF
    then ok G2 "Verilator -sv -Wall, $f.sv + real top.sv: 0 errors, only waived rtl/ warnings"
    else bad G2 "lint $f.sv (see $B/lint_$f.log)"; fi
done

# ---- G3 ------------------------------------------------------------------------
LINES=application/emulator-preview/emu_commands.txt
for f in riscv riscv_bufgce_div; do
    if LX "bash scripts/stage4/build_emu_sys.sh stage4/$f.sv /tmp/rvbl2_pf_$f" > "$B/emu_sys_build_$f.log" 2>&1; then
        LX "cd /tmp/rvbl2_pf_$f && ./sim_emu --lines \"\$OLDPWD/$LINES\" --scale $SCALE --negative" > "$B/emu_sys_$f.log" 2>&1
        r=$(grep -a "^==== emu_sys" "$B/emu_sys_$f.log")
        if grep -aq "EMU_SYS: ALL TESTS PASSED" "$B/emu_sys_$f.log"; then
            ok G3 "$f.sv: organisers' emu.c on top.sv, 12 lines + bring-up + 2 negatives at ${SCALE}x emu waits: $r"
        else bad G3 "$f.sv: $r (see $B/emu_sys_$f.log)"; fi
    else bad G3 "$f.sv: system simulator build failed ($B/emu_sys_build_$f.log)"; fi
done

# ---- G4 ------------------------------------------------------------------------
if command -v iverilog > /dev/null 2>&1; then
    CI_BLOCKS=$(ls chipinventor/blocks/*.v | grep -v -E '/imem(_mock)?\.v$')
    for P in 0 1; do
        iverilog -g2005 -s testbench -P testbench.PULL=1\'b$P -o "$B/preview_p$P.vvp" $CI_BLOCKS \
            chipinventor/ci_top.v chipinventor/app/imem_app.v application/emulator-preview/tb_emu_preview.v && \
            (cd "$B" && vvp -n "preview_p$P.vvp" > "preview_p$P.log" 2>&1)
        r=$(grep -a "^==== tb_emu_preview" "$B/preview_p$P.log")
        if grep -aq "EMULATOR PREVIEW: ALL TESTS PASSED" "$B/preview_p$P.log"; then
            ok G4 "emu start-up window, undriven pin 0 reads $P, stale pins 7-1: $r"
        else bad G4 "undriven pin reads $P: $r"; fi
    done
else say "SKIP  G4  iverilog not found (run on the Windows side)"; fi

# ---- G5 + G6 --------------------------------------------------------------------
for f in riscv riscv_bufgce_div; do
    cat > "$B/synth_$f.ys" <<EOF
read_verilog -lib -specify +/xilinx/cells_sim.v
read_verilog -lib +/xilinx/cells_xtra.v
read_verilog -sv stage4/$f.sv
hierarchy -check -top RISCV
proc
check -assert
synth_xilinx -family xcup -top RISCV -iopad -flatten -nolutram
tee -o $B/yosys_stat_$f.txt stat
select -assert-none t:LDCE t:LDPE t:\$dlatch t:\$_DLATCH_*
check -assert
write_json $B/synth_$f.json
EOF
    if LX "yosys -q -l $B/yosys_$f.log $B/synth_$f.ys" > /dev/null 2>&1; then
        ram=$(awk '/RAMB36E2/{print $2}' "$B/yosys_stat_$f.txt"); dsp=$(awk '/DSP48E2/{print $2}' "$B/yosys_stat_$f.txt")
        lut=$(awk '/LUT[1-6] /{s+=$2} END{print s}' "$B/yosys_stat_$f.txt"); ff=$(awk '/FD[RSCP]E /{s+=$2} END{print s}' "$B/yosys_stat_$f.txt")
        if [ "${ram:-0}" = "2" ]; then
            ok G5 "$f.sv: Yosys synth_xilinx xcup: no latch, check clean; RAMB36E2 $ram (DMEM), DSP48E2 $dsp, LUT $lut, FF $ff"
        else bad G5 "$f.sv: DMEM not in block RAM (RAMB36E2=${ram:-0})"; fi
        period=64; [ $f = riscv_bufgce_div ] && period=32
        $PY scripts/stage4/sta_estimate.py "$B/synth_$f.json" $period > "$B/sta_$f.txt"; rc=$?
        line=$(grep "longest path" "$B/sta_$f.txt" | sed 's/ into.*//'); use=$(grep -o "uses [0-9]* %" "$B/sta_$f.txt")
        if [ $rc -eq 0 ]; then ok G6 "$f.sv @ ${period} ns: $line, $use of the period (pessimistic model): GO"
        elif [ $f = riscv_bufgce_div ] && grep -q "slack [0-9]" "$B/sta_$f.txt"; then
            say "NOTE  G6  $f.sv @ ${period} ns: $line, $use: positive slack, below the 2x bar (fallback only)"
        else bad G6 "$f.sv @ ${period} ns: $line, $use"; fi
    else bad G5 "$f.sv: Yosys failed or found a latch/problem ($B/yosys_$f.log)"; fi
done

# ---- G7 ------------------------------------------------------------------------
for m in reset txdone rxdone pins; do
    $PY scripts/stage4/gen_riscv_sv.py --mutate $m --out "$B/mutants/riscv_$m.sv" > /dev/null
done
$PY scripts/stage4/gen_riscv_sv.py --core-hz 250000000 --out "$B/mutants/riscv_divider.sv" > /dev/null
LX "bash scripts/stage4/mutants.sh" > "$B/mutants_run.log" 2>&1
if grep -aq "MUTANTS: ALL CAUGHT" "$B/mutants.log"; then
    ok G7 "$(grep -a '^==== mutants' "$B/mutants.log") (reset polarity, UART divider, o_Tx_Done, o_Rx_Done, pin direction)"
else bad G7 "a mutant survived ($B/mutants.log)"; fi

say ""
if [ $FAIL -eq 0 ]; then say "PREFLIGHT: GO"; else say "PREFLIGHT: NO-GO ($FAIL failed)"; fi
exit $FAIL
