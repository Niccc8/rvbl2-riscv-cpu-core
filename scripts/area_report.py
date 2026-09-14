#!/usr/bin/env python3
"""
area_report.py - roll the per-module Sky130 areas from a Yosys
`stat -liberty` report up into a whole-SoC total.

Yosys reports "Chip area for module X" as that module's *local* area,
excluding submodules - so the top-level line reads 0.000000 for a purely
structural top like this one, and the number the Submission Guide asks for
(total cell area of the design) is the sum of every module's local area.

Usage: python3 scripts/area_report.py [synth/sky130_synth_stat.txt]
"""
import os
import re
import sys

BACKSLASH = chr(92)


def tidy(name):
    """Yosys names parametrized modules with an escaped paramod identifier."""
    name = name.replace(BACKSLASH, "")
    if "paramod" in name:
        return "dmem" if "dmem" in name else "imem"
    return name


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("synth", "sky130_synth_stat.txt")
    if not os.path.exists(path):
        sys.stderr.write("area_report.py: %s not found\n" % path)
        return 1

    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()

    # Anchor on the closing "': " rather than excluding quotes: Yosys' own
    # parametrized module names embed an apostrophe (e.g. DMEM_WORDS=s32'0000...),
    # so a [^']+ capture silently drops the largest module in the design.
    rows = re.findall(r"Chip area for module '(.+?)': ([0-9.]+)", text)
    if not rows:
        sys.stderr.write("area_report.py: no 'Chip area for module' lines found - "
                         "was stat run with -liberty?\n")
        return 1

    areas = [(tidy(n), float(a)) for n, a in rows]
    total = sum(a for _, a in areas)

    print("%-22s %16s   %7s" % ("Module", "Area (um^2)", "Share"))
    print("-" * 50)
    for name, area in sorted(areas, key=lambda r: -r[1]):
        share = (100.0 * area / total) if total else 0.0
        print("%-22s %16s   %6.2f%%" % (name, "{:,.2f}".format(area), share))
    print("-" * 50)
    print("%-22s %16s   %6s" % ("TOTAL", "{:,.2f}".format(total), ""))
    print("")
    print("Total cell area: %.2f um^2  (%.4f mm^2)" % (total, total / 1.0e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
