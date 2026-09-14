#!/usr/bin/env python3
"""
check_synth_stats.py - post-synthesis sanity gates on the Yosys cell report.

Currently one gate, and the reason it exists: with an empty IMEM_INIT_FILE the
instruction ROM elaborates as all zeros and synthesis constant-folds the whole
array away, leaving a netlist whose imem is literally `assign data_o = 32'd0;`.
A design built from that netlist fetches 0x00000000 forever and executes
nothing, while every reported area figure silently excludes the ROM. Nothing
in the flow complains, so this check does.

Usage: python3 scripts/check_synth_stats.py [synth/generic_synth_stat.txt]
Exit code 0 if every gate passes, 1 otherwise.
"""
import os
import re
import sys


def module_cell_count(stat_text, name_fragment):
    """Cell count for the first module whose stat header contains the fragment.

    Yosys has used two stat formats: 'Number of cells: N' in the 0.3x/0.4x
    series and a bare 'N cells' column from 0.5x onward. Both are accepted so
    this gate does not silently pass on a newer or older toolchain.
    """
    for block in stat_text.split("\n=== "):
        header = block.split("\n", 1)[0]
        if name_fragment not in header:
            continue
        m = re.search(r"Number of cells:\s+(\d+)", block)
        if m:
            return int(m.group(1))
        m = re.search(r"^\s*(\d+)\s+cells\s*$", block, re.M)
        if m:
            return int(m.group(1))
        return 0
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("synth", "generic_synth_stat.txt")
    if not os.path.exists(path):
        sys.stderr.write("check_synth_stats.py: %s not found\n" % path)
        return 1

    with open(path, encoding="utf-8", errors="replace") as f:
        stat = f.read()

    failures = 0

    imem_cells = module_cell_count(stat, "imem")
    if imem_cells is None:
        print("FAIL: no imem module found in the synthesis statistics.")
        failures += 1
    elif imem_cells == 0:
        print("FAIL: imem synthesized to 0 cells - the instruction ROM was")
        print("      optimized away. Check that IMEM_INIT_FILE names a real,")
        print("      non-empty hex image and that $readmemh could open it.")
        failures += 1
    else:
        print("PASS: imem synthesized to %d cells (ROM contents preserved)." % imem_cells)

    dmem_cells = module_cell_count(stat, "dmem")
    if not dmem_cells:
        print("FAIL: dmem synthesized to 0 cells - the data memory was optimized away.")
        failures += 1
    else:
        print("PASS: dmem synthesized to %d cells." % dmem_cells)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
