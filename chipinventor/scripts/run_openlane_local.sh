#!/usr/bin/env bash
# run_openlane_local.sh - stage this design into a local OpenLane tree, run the
# flow, check the result, and bring the artifacts back to the project.
#
# Run inside WSL, after scripts/setup_openlane_wsl.sh has completed once:
#
#     bash /mnt/c/.../chipinventor/scripts/run_openlane_local.sh
#
# Options:
#     --tag NAME      name the run (default: a UTC timestamp)
#     --dry-run       stage the design and stop, without running the flow
#     --             everything after this is passed through to flow.tcl
#                     (e.g. -from routing, -overwrite)
#
# There are deliberately no per-run tuning flags. openlane/config.json is the
# deliverable - the file the competition expects us to supply and that the
# platform should have been reading - so it is the single place settings live.
# A run-time override layer would mean a result could come from settings that
# are not in that file, which is exactly the ambiguity we are trying to remove.
# Tune by editing config.json; the run copies config.tcl back so what actually
# ran is always recoverable.
#
# Environment:
#     OPENLANE_DIR    default $HOME/OpenLane
#     ROUTING_CORES   thread count for global routing; leave unset for the
#                     default. Lower it (8, 4) if routing runs out of memory.
#
# The Windows tree stays the single source of truth: config.json and src/ are
# copied in on every run and the design directory is cleared first, so a stale
# netlist from a previous run can never be silently reused.
set -u

cd "$(dirname "$0")/.."   # chipinventor/
ROOT=$(pwd)

OPENLANE_DIR=${OPENLANE_DIR:-$HOME/OpenLane}
DESIGN=rvbl2
TAG=$(date -u +%Y%m%d-%H%M%S)
DRY=0
PASSTHRU=()

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)      TAG=$2; shift 2 ;;
        --dry-run)  DRY=1; shift ;;
        --)         shift; PASSTHRU=("$@"); break ;;
        *)          printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

FAILED=0
step() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED+1)); }
die()  { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[ -f /proc/version ] && grep -qi microsoft /proc/version \
    || die "run this inside WSL, not on the Windows side"
[ -d "$OPENLANE_DIR" ] \
    || die "$OPENLANE_DIR does not exist - run scripts/setup_openlane_wsl.sh first"
command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 \
    || die "docker is not usable - run scripts/setup_openlane_wsl.sh first"

# ---------------------------------------------------------------------------
step "1/5  The P&R netlist is current"
# openlane/src/top.v is generated from the exported top.v by gen_pnr_netlist.py.
# The export is upstream of it, so running P&R on a derivative older than its
# source is exactly the drift that generator exists to prevent.
[ -f openlane/src/top.v ] || die "openlane/src/top.v is missing - run scripts/gen_pnr_netlist.py"
if [ -f top.v ] && [ top.v -nt openlane/src/top.v ]; then
    die "top.v is newer than openlane/src/top.v - regenerate it:
         python scripts/gen_pnr_netlist.py --dmem-words 8"
fi
ok "openlane/src/top.v is at or ahead of the export"

# The whole exercise is comparability with the platform, so check the pin here
# too rather than trusting that setup ran against the same hashes.
if grep -q bdc9412b3e468c102d01b7cf6337be06ec6e9c9a \
        "$OPENLANE_DIR/dependencies/tool_metadata.yml" 2>/dev/null; then
    ok "PDK pin matches the platform (open_pdks bdc9412b)"
else
    printf 'note could not confirm the open_pdks pin in tool_metadata.yml\n'
fi

# ---------------------------------------------------------------------------
step "2/5  Staging designs/$DESIGN"
DDIR="$OPENLANE_DIR/designs/$DESIGN"
mkdir -p "$DDIR"
rm -rf "$DDIR/src" "$DDIR/config.json"
cp -r openlane/src "$DDIR/src"
cp openlane/config.json "$DDIR/config.json"
ok "$(ls "$DDIR/src" | wc -l) source file(s) + config.json -> $DDIR"

# Every key in config.json must be one OpenLane actually reads. There is no
# validation upstream - an unknown key is silently ignored - which is how
# CLOCK_TREE_SYNTH (a variable that does not exist in OpenLane 1) sat in this
# config looking like it was enabling CTS. Catching that here is cheap.
"${PY:-python3}" - "$DDIR/config.json" "$OPENLANE_DIR" <<'EOF' || die "config.json has unknown keys"
import json, os, re, sys
cfg, ol = json.load(open(sys.argv[1])), sys.argv[2]
valid = set()
cfgdir = os.path.join(ol, "configuration")
for fn in os.listdir(cfgdir):
    if fn.endswith(".tcl"):
        valid |= set(re.findall(r"set\s+::env\((\w+)\)",
                                open(os.path.join(cfgdir, fn)).read()))
# Design-level variables have no default in configuration/, so they never
# appear there; they are required and read by scripts/config/init.py.
valid |= {"DESIGN_NAME", "VERILOG_FILES", "CLOCK_PORT", "CLOCK_NET",
          "PL_TARGET_DENSITY", "PDK", "STD_CELL_LIBRARY", "DESIGN_IS_CORE",
          "VERILOG_INCLUDE_DIRS", "EXTRA_LEFS", "EXTRA_GDS_FILES"}
unknown = sorted(k for k in cfg if k not in valid)
if unknown:
    sys.exit("unknown OpenLane variable(s), silently ignored: " + ", ".join(unknown))
print("     all %d config keys are variables OpenLane reads" % len(cfg))
EOF

if [ "$DRY" -eq 1 ]; then
    printf '\n--dry-run: staged only, flow not started\n'
    exit 0
fi

# ---------------------------------------------------------------------------
step "3/5  Running the flow (tag: $TAG)"
# Rather than hand-rolling `docker run`, borrow OpenLane's own ENV_COMMAND -
# the variable its `make test` and `make mount` targets use. It already has the
# image tag for this checkout, the /openlane and PDK_ROOT bind mounts and the
# uid/gid mapping right, and it picks up ROUTING_CORES and DOCKER_MEMORY.
# A one-line makefile that `include`s theirs is the least invasive way to reach
# it; relative includes still resolve because make runs from $OPENLANE_DIR.
cd "$OPENLANE_DIR"
cat > .rvbl2.mk <<'EOF'
# Generated by chipinventor/scripts/run_openlane_local.sh - safe to delete.
include Makefile

.PHONY: rvbl2_run
rvbl2_run:
	cd $(OPENLANE_DIR) && $(ENV_COMMAND) sh -c "./flow.tcl $(FLOW_ARGS)"
EOF

FLOW_ARGS="-design $DESIGN -tag $TAG -overwrite ${PASSTHRU[*]+${PASSTHRU[*]}}"
printf '     flow.tcl %s\n' "$FLOW_ARGS"
make -f .rvbl2.mk rvbl2_run FLOW_ARGS="$FLOW_ARGS" \
     ${ROUTING_CORES:+ROUTING_CORES="$ROUTING_CORES"}
FLOW_RC=$?
RUN="$DDIR/runs/$TAG"
if [ $FLOW_RC -eq 0 ]; then ok "flow.tcl exited 0"; else bad "flow.tcl exited $FLOW_RC"; fi

# ---------------------------------------------------------------------------
step "4/5  Checking the result"
# "Did it finish" is the wrong question. This design has a two-pin top - clk_i,
# rst_i, no outputs - so a synthesis sweep would leave an empty netlist that
# sails through every later stage. The cell count is the load-bearing check.
STAT=$(ls "$RUN"/reports/synthesis/*stat*.rpt 2>/dev/null | tail -1)
if [ -n "$STAT" ]; then
    CELLS=$(awk '/Number of cells:/ {n=$NF} END {print n+0}' "$STAT")
    AREA=$(awk '/Chip area for/ {a=$NF} END {printf "%.0f", a+0}' "$STAT")
    if [ "$CELLS" -gt 10000 ]; then
        ok "synthesis: $CELLS cells, ${AREA} um2 - nothing was swept"
    else
        bad "synthesis: only $CELLS cells - the design was swept, check the (* keep *) attributes"
    fi
else
    bad "no synthesis stat report under $RUN/reports/synthesis"
fi

DEF=$(find "$RUN/results" -path '*floorplan*' -name '*.def' 2>/dev/null | sort | tail -1)
if [ -n "$DEF" ]; then
    # DIEAREA is in DBU; sky130 uses 1000 per micron.
    read -r DX DY <<< "$(awk '/^DIEAREA/ {print $7/1000, $8/1000; exit}' "$DEF")"
    ok "floorplan: die ${DX} x ${DY} um"
else
    bad "no floorplan DEF - the flow did not reach floorplan"
fi

if [ -f "$RUN/openlane.log" ] || [ -f "$RUN/flow_summary.log" ]; then
    if grep -rqE 'DPL-003[56]' "$RUN"/logs 2>/dev/null; then
        bad "detailed placement failed (DPL-0035/0036) - the die is still too small"
    else
        ok "no DPL-0035 / DPL-0036 - the platform's failure mode is gone"
    fi
fi

# The GDS has moved between OpenLane 1.x point releases (results/final/gds/ vs
# results/signoff/), so find it rather than assuming a path.
GDS=$(find "$RUN/results" -name '*.gds' -size +1k 2>/dev/null | sort | tail -1)
if [ -n "$GDS" ]; then
    ok "GDSII: $(du -h "$GDS" | cut -f1) at ${GDS#"$RUN/"}"
else
    bad "no GDS produced under $RUN/results"
fi

# Timing. This has to be its own gate: OpenLane does not fail the flow on a
# timing violation, so it will hand back a complete, DRC-clean, LVS-clean GDS
# that simply does not meet its clock constraint. Read the post-route
# multi-corner numbers, not the post-CTS single-corner ones - the two have
# disagreed by more than 13 ns on this design, and only these are signoff.
WORST=""
for f in "$RUN"/logs/signoff/*mcsta*.log; do
    [ -f "$f" ] || continue
    corner=$(basename "$f" | sed 's/.*mcsta\.//; s/\.log//')
    s=$(grep -A2 'report_worst_slack -max' "$f" | grep 'worst slack' | head -1 | awk '{print $3}')
    h=$(grep -A2 'report_worst_slack -min' "$f" | grep 'worst slack' | head -1 | awk '{print $3}')
    [ -n "$s" ] || continue
    printf '     %-4s setup %8s   hold %8s\n' "$corner" "$s" "$h"
    if [ -z "$WORST" ] || awk "BEGIN{exit !($s < $WORST)}"; then WORST=$s; fi
done
if [ -z "$WORST" ]; then
    bad "no multi-corner STA results under $RUN/logs/signoff"
elif awk "BEGIN{exit !($WORST < 0)}"; then
    bad "setup timing VIOLATED: worst $WORST ns across corners - raise CLOCK_PERIOD by at least that much"
else
    ok "setup timing met at all corners (worst $WORST ns)"
fi

METRICS=$(ls "$RUN"/reports/metrics.csv 2>/dev/null | tail -1)
if [ -n "$METRICS" ]; then
    # Print the few columns worth reading at a glance; the full row goes back
    # to the project directory below.
    "${PY:-python3}" - "$METRICS" <<'EOF' 2>/dev/null || true
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if rows:
    r = rows[-1]
    for k in ("flow_status", "total_runtime", "CellPer_mm^2", "wns", "spef_wns",
              "tns", "spef_tns", "antenna_violations", "magic_drc", "lvs_total_errors"):
        if k in r and r[k] not in ("", "-1"):
            print("     %-20s %s" % (k, r[k]))
EOF
fi

# ---------------------------------------------------------------------------
step "5/5  Copying artifacts back to the project"
# Results belong with the design, not only inside WSL where a `wsl --unregister`
# would take them with it.
OUT="$ROOT/openlane/runs/$TAG"
mkdir -p "$OUT"
# config.json is the input; config.tcl is every variable as OpenLane finally
# resolved it - the definitive record of what actually ran, and the thing to
# show the organisers. Keep both together.
cp "$ROOT/openlane/config.json" "$OUT/" 2>/dev/null
[ -f "$RUN/config.tcl" ] && cp "$RUN/config.tcl" "$OUT/" 2>/dev/null
[ -n "${METRICS:-}" ] && cp "$METRICS" "$OUT/" 2>/dev/null
[ -n "${GDS:-}" ]     && cp "$GDS" "$OUT/" 2>/dev/null
[ -n "${STAT:-}" ]    && cp "$STAT" "$OUT/synthesis.stat.rpt" 2>/dev/null
# The gate-level netlist and final DEF are the other two things worth keeping;
# their paths vary by point release, so search for them.
for pat in '*.nl.v' '*.def'; do
    f=$(find "$RUN/results" -name "$pat" 2>/dev/null | sort | tail -1)
    [ -n "$f" ] && cp "$f" "$OUT/" 2>/dev/null
done
[ -d "$RUN/reports/signoff" ] && cp -r "$RUN/reports/signoff" "$OUT/signoff" 2>/dev/null
for l in "$RUN/openlane.log" "$RUN/flow_summary.log"; do
    [ -f "$l" ] && cp "$l" "$OUT/" 2>/dev/null
done
ok "artifacts in openlane/runs/$TAG/ ($(ls "$OUT" | wc -l) item(s))"
printf '     full run directory: %s\n' "$RUN"

# ---------------------------------------------------------------------------
printf '\n========================================\n'
if [ $FAILED -eq 0 ]; then
    printf ' FLOW COMPLETE - all gates passed\n'
    printf '========================================\n'
    exit 0
else
    printf ' %d GATE(S) FAILED - see openlane/README.md "If it does not close"\n' "$FAILED"
    printf '========================================\n'
    exit 1
fi
