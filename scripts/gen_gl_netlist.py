#!/usr/bin/env python3
"""
gen_gl_netlist.py - prepare the Yosys generic-synthesis netlist for
side-by-side gate-level equivalence simulation against the RTL.

tb_gatelevel.v instantiates the RTL core and the synthesized core in the same
simulation, so their module names must not collide. This script copies
synth/top_generic_synth.v, prefixing every module it defines (and every
instantiation of one) with `gl_`, and giving the two escaped parametrized
module names (imem/dmem) plain identifiers a testbench can reference.

Usage: python3 scripts/gen_gl_netlist.py [in.v] [out.v]
"""
import os
import re
import sys

# Modules the RTL also defines - these are the names that would collide.
MODULES = [
    "address_decoder", "alu", "branch_comparator", "control_unit", "crc_unit",
    "immediate_generator", "ir_reg", "lsu", "multiplier", "pc_incrementer",
    "pc_reg", "register_file", "riscv_core", "top",
]

DECL_RE = re.compile(r"^module ([A-Za-z_][A-Za-z0-9_]*)\(")
INST_RE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*) (u_[A-Za-z0-9_]*) \($")
# Yosys names parametrized modules with an escaped identifier ending in the
# base module name, e.g. \$paramod$<hash>\imem or \$paramod\dmem\WORDS=...
PARAMOD_RE = re.compile(r"\\?[$]paramod[^\s]*?\\?(imem|dmem)\b[^\s]*\s")


def convert(src: str) -> str:
    out = []
    for line in src.split("\n"):
        m = DECL_RE.match(line)
        if m and m.group(1) in MODULES:
            line = line.replace("module " + m.group(1) + "(",
                                "module gl_" + m.group(1) + "(", 1)
        else:
            m2 = INST_RE.match(line)
            if m2 and m2.group(1) in MODULES:
                line = "  gl_" + m2.group(1) + " " + m2.group(2) + " ("
        out.append(line)
    text = "\n".join(out)

    # Escaped parametrized module names -> plain gl_imem / gl_dmem.
    def repl(m):
        return "gl_" + m.group(1) + " "
    text = PARAMOD_RE.sub(repl, text)
    return text


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "synth", "top_generic_synth.v")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "build", "gl_netlist.v")

    if not os.path.exists(src):
        sys.stderr.write(
            "gen_gl_netlist.py: %s not found - run scripts/synth_yosys_generic.sh first\n" % src)
        return 1

    with open(src, encoding="utf-8") as f:
        text = convert(f.read())

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)

    n = len(re.findall(r"^module ", text, re.M))
    print("Wrote %s (%d modules renamed for co-simulation)" % (dst, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
