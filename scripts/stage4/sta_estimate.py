#!/usr/bin/env python3
"""sta_estimate.py - a deliberately pessimistic static timing estimate of the
synthesized riscv.sv (Yosys synth_xilinx JSON netlist), for the pre-flight gate.

    python scripts/stage4/sta_estimate.py build/stage4/riscv_synth.json

It is not Vivado's timer: there is no placement. Every cell gets a fixed delay that
already includes a generous net delay, chosen at or above the UltraScale+ -2
datasheet values (DS923), so the estimate errs long. Paths start at flip-flop and
block-RAM outputs and end at their inputs; the DSP48E2 cells (no pipeline registers
here) and the carry chains are combinational. The verdict compares the longest path
with the core clock period (32 ns at 31.25 MHz).
"""
import json
import sys
from collections import defaultdict
from functools import lru_cache

# ns per cell, net delay included (pessimistic)
DELAY = {
    "LUT1": 0.55, "LUT2": 0.55, "LUT3": 0.55, "LUT4": 0.55, "LUT5": 0.55, "LUT6": 0.55,
    "INV": 0.55, "MUXF7": 0.30, "MUXF8": 0.30, "MUXF9": 0.30,
    "CARRY4": 0.40, "CARRY8": 0.40,
    "DSP48E2": 4.00,           # A/B -> P through the multiplier, no registers, + routing
}
SOURCE = {"FDRE": 0.60, "FDSE": 0.60, "FDCE": 0.60, "FDPE": 0.60,   # clk->Q + net
          "RAMB36E2": 2.20, "RAMB18E2": 2.20}                          # clk->DOUT (no out reg)
SETUP = {"FDRE": 0.15, "FDSE": 0.15, "FDCE": 0.15, "FDPE": 0.15, "RAMB36E2": 0.60, "RAMB18E2": 0.60}
CARRY_CASCADE = 0.10      # CO -> CI of the next CARRY in a chain (dedicated route)
CASCADE = True
IGNORE = {"BUFG", "MMCME4_BASE", "BUFGCE_DIV", "IBUF", "OBUF", "IOBUF", "OBUFT"}


def main(path, period=32.0):
    nl = json.load(open(path))
    top = next(m for m in nl["modules"].values() if m.get("attributes", {}).get("top"))
    cells = top["cells"]
    drivers = {}                      # bit -> (cell, delay at its output)
    loads = defaultdict(list)         # bit -> [cell]
    for name, c in cells.items():
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            for b in bits:
                if isinstance(b, str):
                    continue
                if dirs.get(port) == "output":
                    drivers[b] = name
                else:
                    loads[b].append((name, port))
    clock_bits = set()
    for name, c in cells.items():
        if c["type"] in ("BUFG", "MMCME4_BASE", "BUFGCE_DIV"):
            for b in c["connections"].get("O", []) + c["connections"].get("CLKOUT0", []):
                clock_bits.add(b)

    sys.setrecursionlimit(100000)

    @lru_cache(maxsize=None)
    def arrival(bit):
        """Latest arrival time at this net bit, and the path that gets there."""
        cname = drivers.get(bit)
        if cname is None:
            return 0.0, ()                                  # a primary input or a constant
        c = cells[cname]
        t = c["type"]
        if t in SOURCE:
            return SOURCE[t], (cname,)
        if t in IGNORE:
            return 0.0, ()
        d = DELAY.get(t)
        if d is None:
            raise SystemExit("no delay for cell type %s (%s)" % (t, cname))
        best, bpath = 0.0, ()
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port) == "output":
                continue
            for b in bits:
                if isinstance(b, str) or b in clock_bits:
                    continue
                a, p = arrival(b)
                # a carry chain's CI comes from the previous CARRY's CO over the
                # dedicated cascade, not a routed net (--flat-carry disables this)
                if CASCADE and t.startswith("CARRY") and port == "CI" and                         cells.get(drivers.get(b), {}).get("type", "").startswith("CARRY"):
                    a -= d - CARRY_CASCADE
                if a > best:
                    best, bpath = a, p
        return best + d, bpath + (cname,)

    worst = []
    for name, c in cells.items():
        t = c["type"]
        if t not in SETUP:
            continue
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port) != "input" or port in ("C", "CLKARDCLK", "CLKBWRCLK"):
                continue
            for b in bits:
                if isinstance(b, str) or b in clock_bits:
                    continue
                a, p = arrival(b)
                worst.append((a + SETUP[t], name, port, p))
    worst.sort(reverse=True)
    a, name, port, p = worst[0]
    kinds = defaultdict(int)
    for cn in p:
        kinds[cells[cn]["type"]] += 1
    print("endpoints checked: %d" % len(worst))
    print("longest path estimate: %.2f ns into %s.%s" % (a, name, port))
    print("  cells on it: " + ", ".join("%s x%d" % kv for kv in sorted(kinds.items())))
    print("  from: %s" % (p[0] if p else "-"))
    for a2, n2, p2, _ in worst[1:6]:
        print("  next: %.2f ns into %s.%s" % (a2, n2, p2))
    if "--trace" in sys.argv:
        for cn in p + (name,):
            src = cells[cn].get("attributes", {}).get("src", "")
            print("    %-9s %s" % (cells[cn]["type"], src.split("|")[0]))
    slack = period - a
    print("core clock %.2f ns (%.2f MHz): slack %.2f ns, path uses %.0f %% of the period"
          % (period, 1000 / period, slack, 100 * a / period))
    print("VERDICT: %s" % ("GO" if a < 0.5 * period else "NO-GO"))
    return 0 if a < 0.5 * period else 1


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--flat-carry" in sys.argv:
        CASCADE = False
    sys.exit(main(args[0], float(args[1]) if len(args) > 1 else 32.0))
