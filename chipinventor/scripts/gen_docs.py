#!/usr/bin/env python3
"""Generate NETLIST.md and BLOCK_METADATA.md from the blocks and the mirror.

Both documents are derived rather than written by hand, because both are the
kind of thing that goes quietly wrong: a transcribed port width or a net whose
direction was guessed produces a canvas that looks right and behaves wrong.
Everything here is read out of blocks/*.v and ci_top.v, which are the same
files the local verification actually runs.

Usage: python gen_docs.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BLOCKS = os.path.join(ROOT, "blocks")
CI_TOP = os.path.join(ROOT, "ci_top.v")

# One-line description shown on the block's form and in the docs.
DESCRIPTIONS = {
    "alu":                 "Purely combinational ALU, 11 operations (Table 9)",
    "branch_comparator":   "Evaluates the 6 RV32I branch conditions",
    "immediate_generator": "Extracts and sign-extends I/S/B/U/J immediates",
    "multiplier":          "MUL/MULH/MULHSU/MULHU, combinational (Zmmul, Table 10)",
    "crc_unit":            "CRC-16/CCITT-FALSE over 8/16/32 bits (Xicrc, Table 11)",
    "lsu":                 "Load/store unit: byte lanes, sign extension, write strobes",
    "address_decoder":     "Routes the memory transaction to IMEM or DMEM (Table 13)",
    "register_file":       "32 x 32-bit GPRs, x0 hardwired zero, async read",
    "pc_reg":              "Program counter, reset vector 0x00400000",
    "pc_incrementer":      "Dedicated PC+4 adder, separate from the ALU",
    "ir_reg":              "Instruction register, loaded once per instruction",
    "control_unit":        "6-state FSM and every datapath control signal",
    "imem":                "Instruction/constant ROM, combinational read",
    "dmem":                "Data SRAM, synchronous read and byte-writable write",
    "mux2_32":             "Generic 2-to-1 32-bit multiplexer",
    "wb_mux_32":           "Writeback source multiplexer, 5 inputs",
    "ir_fields":           "Extracts rs1/rs2/rd register addresses from the instruction",
}

# Why each instance exists, for the netlist document's instance table.
ROLES = {
    "u_ctrl":    "control FSM",
    "u_pc":      "program counter",
    "u_pcinc":   "PC+4 adder",
    "u_ir":      "instruction register",
    "u_irf":     "instruction field extractor",
    "u_rf":      "register file",
    "u_imm":     "immediate generator",
    "u_muxa":    "ALU operand A select (rs1 vs PC)",
    "u_muxb":    "ALU operand B select (rs2 vs immediate)",
    "u_alu":     "arithmetic/logic unit",
    "u_bc":      "branch comparator",
    "u_mul":     "multiplier",
    "u_crc":     "CRC unit",
    "u_lsu":     "load/store unit",
    "u_wbmux":   "writeback source select",
    "u_muxaddr": "memory address select (PC vs ALU result)",
    "u_muxpc":   "next-PC select (PC+4 vs branch/jump target)",
    "u_decoder": "address decoder",
    "u_imem":    "instruction ROM",
    "u_dmem":    "data memory",
}

PORT_RE = re.compile(
    r"(?:\(\*.*?\*\)\s*)?\b(input|output|inout)\b\s+(?:wire|reg)?\s*"
    r"(\[[^\]]+\])?\s*([A-Za-z_]\w*)")


def parse_block(path):
    """Return (name, params, ports) for a single-module block file."""
    with open(path) as fh:
        text = fh.read()
    text = re.sub(r"//[^\n]*", "", text)          # strip line comments

    m = re.search(r"\bmodule\s+([A-Za-z_]\w*)\s*(#\s*\((.*?)\))?\s*\((.*?)\)\s*;",
                  text, re.DOTALL)
    if not m:
        sys.exit("could not parse a module header out of %s" % path)

    name = m.group(1)
    params = []
    if m.group(3):
        for pname, pval in re.findall(r"parameter\s+([A-Za-z_]\w*)\s*=\s*([^,\)]+)",
                                      m.group(3)):
            params.append((pname, pval.strip()))

    ports = []
    for direction, width, pname in PORT_RE.findall(m.group(4)):
        ports.append((direction, (width or "").strip(), pname))
    return name, params, ports


# imem_mock.v declares module `imem` on purpose - that is what makes it a
# drop-in swap of one Code field for the OpenLane run. It is skipped here so it
# does not overwrite the real imem's entry; BLOCK_METADATA.md carries a note
# about it instead, since its form fields are identical by construction.
ALTERNATES = {"imem_mock.v": "imem"}


def load_blocks():
    out = {}
    for fname in sorted(os.listdir(BLOCKS)):
        if not fname.endswith(".v") or fname in ALTERNATES:
            continue
        name, params, ports = parse_block(os.path.join(BLOCKS, fname))
        out[name] = {"file": fname, "params": params, "ports": ports}
    return out


def parse_instances(path):
    """Return [(module, instance, {port: net})] from the structural mirror."""
    with open(path) as fh:
        text = fh.read()
    text = re.sub(r"//[^\n]*", "", text)

    body = text[re.search(r"\bmodule\s+top\b", text).start():]
    out = []
    for m in re.finditer(
            r"(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*(?:#\s*\([^;]*?\)\s*)?([A-Za-z_]\w*)[ \t]*\((.*?)\)\s*;",
            body, re.DOTALL):
        module, inst, conns = m.group(1), m.group(2), m.group(3)
        if module in ("module", "always", "assign", "wire", "reg", "input", "output"):
            continue
        mapping = {}
        for port, net in re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", conns):
            mapping[port] = net.strip()
        if mapping:
            out.append((module, inst, mapping))
    return out


def build_netlist(blocks, instances):
    """net -> {'width':..., 'src':(inst,port) or None, 'sinks':[(inst,port)]}"""
    nets = {}
    for module, inst, mapping in instances:
        info = blocks.get(module)
        if info is None:
            sys.exit("instance %s uses module %s, which has no block file" % (inst, module))
        dirs = {p: (d, w) for d, w, p in info["ports"]}
        for port, net in mapping.items():
            if port not in dirs:
                sys.exit("instance %s connects unknown port .%s" % (inst, port))
            direction, width = dirs[port]
            entry = nets.setdefault(net, {"width": width, "src": None, "sinks": []})
            if direction == "output":
                if entry["src"] is not None:
                    sys.exit("net %s is driven by both %s.%s and %s.%s"
                             % (net, entry["src"][0], entry["src"][1], inst, port))
                entry["src"] = (inst, port)
            else:
                entry["sinks"].append((inst, port))
    return nets


def fmt_width(w):
    return w if w else "1 bit"


def write_netlist_doc(blocks, instances, nets):
    inst_by_name = {inst: module for module, inst, _ in instances}

    lines = []
    lines.append("# Wiring checklist\n")
    lines.append("GENERATED by `scripts/gen_docs.py` from `ci_top.v` and `blocks/*.v` "
                 "- do not hand-edit.\n")
    lines.append("Every row below is one wire to draw on the ChipInventor canvas. "
                 "Tick them off as you go;\nthe count at the bottom is what a complete "
                 "project has.\n")

    lines.append("\n## Before you start\n")
    lines.append("- Name the two input pins exactly **`clk_i`** and **`rst_i`**. "
                 "The testbench instantiates\n  the project as "
                 "`top dut (.clk_i(clk), .rst_i(rst));` and will not compile otherwise.\n")
    lines.append("- The canvas **cannot slice a bus**. Every wire connects a whole port "
                 "to a whole port of\n  the same width. That is why `ir_fields` exists, "
                 "and why `funct3` comes from\n  `control_unit.op_size` rather than from "
                 "the instruction register.\n")
    lines.append("- **`lsu`'s port names read backwards.** `mem_data_o` is an **input** "
                 "and `core_data_i` is an\n  **output**. This is the easiest wire on the "
                 "whole canvas to get wrong.\n")
    lines.append("- Set `dmem`'s `DMEM_WORDS` parameter to **2048** on its instance. "
                 "Leaving it blank still\n  gives 2048 (the block's default), but setting "
                 "it explicitly makes the resize knob visible.\n")

    lines.append("\n## Block instances (%d)\n" % len(instances))
    lines.append("| Instance | Block | Role |")
    lines.append("|---|---|---|")
    for module, inst, _ in instances:
        lines.append("| `%s` | `%s` | %s |" % (inst, module, ROLES.get(inst, "")))

    src_nets = [(n, e) for n, e in nets.items() if e["src"]]
    top_nets = [(n, e) for n, e in nets.items() if not e["src"]]

    lines.append("\n## Top-level pins\n")
    lines.append("| Pin | Direction | Goes to |")
    lines.append("|---|---|---|")
    for net, entry in sorted(top_nets):
        dests = ", ".join("`%s.%s`" % (i, p) for i, p in sorted(entry["sinks"]))
        lines.append("| `%s` | input | %s |" % (net, dests))

    lines.append("\n## Wires (%d)\n" % len(src_nets))
    lines.append("Each row is one net: drag from the source port to every destination port.\n")
    lines.append("| # | Width | From | To |")
    lines.append("|---:|---|---|---|")
    for idx, (net, entry) in enumerate(sorted(src_nets), 1):
        si, sp = entry["src"]
        if not entry["sinks"]:
            dests = "*(unconnected - observed by the testbench only)*"
        else:
            dests = "<br>".join("`%s.%s`" % (i, p) for i, p in sorted(entry["sinks"]))
        lines.append("| %d | `%s` | `%s.%s` | %s |"
                     % (idx, fmt_width(entry["width"]), si, sp, dests))

    dangling = [n for n, e in src_nets if not e["sinks"]]
    lines.append("\n## Deliberately unconnected outputs\n")
    if dangling:
        for net in sorted(dangling):
            si, sp = nets[net]["src"]
            lines.append("- `%s.%s` - observed by the testbench through a hierarchical "
                         "reference, not wired\n  on the canvas. `top` has only the two "
                         "pins Table 5 mandates, so there is nowhere for it to go." % (si, sp))
    else:
        lines.append("*(none)*")

    total_wires = sum(len(e["sinks"]) for _, e in src_nets) + \
                  sum(len(e["sinks"]) for _, e in top_nets)
    lines.append("\n## Totals\n")
    lines.append("| | Count |")
    lines.append("|---|---:|")
    lines.append("| Block definitions to create | %d |" % len(blocks))
    lines.append("| Block instances to place | %d |" % len(instances))
    lines.append("| Input pins | %d |" % len(top_nets))
    lines.append("| Nets | %d |" % (len(src_nets) + len(top_nets)))
    lines.append("| Individual connections to draw | %d |" % total_wires)

    with open(os.path.join(ROOT, "NETLIST.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return len(src_nets) + len(top_nets), total_wires


def write_metadata_doc(blocks, instances):
    counts = {}
    for module, _, _ in instances:
        counts[module] = counts.get(module, 0) + 1

    lines = []
    lines.append("# Block form fields\n")
    lines.append("GENERATED by `scripts/gen_docs.py` from `blocks/*.v` - do not hand-edit.\n")
    lines.append("One section per block, giving exactly what goes in each field of "
                 "ChipInventor's Add Block\ndialog. Paste the matching file from "
                 "`blocks/` into the Code field; nothing in those files\nneeds editing "
                 "or trimming first.\n")
    lines.append("Author and Icon are yours to set. Leave Validate, Block Width, "
                 "Block Technology and the\ntwo HDL-Specific fields empty unless the "
                 "platform asks for them - the example project\nleaves them empty "
                 "and synthesises.\n")

    for name in sorted(blocks):
        info = blocks[name]
        ins = [(w, p) for d, w, p in info["ports"] if d == "input"]
        outs = [(w, p) for d, w, p in info["ports"] if d == "output"]
        inouts = [(w, p) for d, w, p in info["ports"] if d == "inout"]

        def fmt(lst):
            return ", ".join(("%s%s" % (p, w)) for w, p in lst) or "(none)"

        n = counts.get(name, 0)
        lines.append("\n## `%s`\n" % name)
        lines.append("```")
        lines.append("Name:               %s" % name)
        lines.append("Description:        %s" % DESCRIPTIONS.get(name, ""))
        lines.append("Code:               paste blocks/%s" % info["file"])
        lines.append("Number of Inputs:   %d" % len(ins))
        lines.append("Inputs:             %s" % fmt(ins))
        lines.append("Number of Outputs:  %d" % len(outs))
        lines.append("Outputs:            %s" % fmt(outs))
        lines.append("Number of Inouts:   %d" % len(inouts))
        lines.append("Inouts:             %s" % fmt(inouts))
        if info["params"]:
            lines.append("Parameters:         %s"
                         % ", ".join("%s = %s" % (a, b) for a, b in info["params"]))
        else:
            lines.append("Parameters:         (none)")
        lines.append("```")
        lines.append("")
        lines.append("Placed %d time%s on the canvas." % (n, "" if n == 1 else "s"))
        if name == "lsu":
            lines.append("")
            lines.append("> **Careful:** `mem_data_o` is an **input** and `core_data_i` "
                         "is an **output**. The names\n> read backwards; the directions "
                         "above are correct.")
        if name == "imem":
            lines.append("")
            lines.append("> **For the OpenLane / P&R run, paste `blocks/imem_mock.v` "
                         "into this same block instead.**\n> Every field above stays as "
                         "it is - the mock declares the same module name and the\n> same "
                         "ports, so it is a swap of the Code field and nothing else. It "
                         "holds three\n> instructions instead of 742 words, which is what "
                         "the firmware repository's own\n> README recommends for "
                         "synthesis. Paste `blocks/imem.v` back for the testbench run.")
        if name == "crc_unit":
            lines.append("")
            lines.append("> **Operand order:** `rs1_data` is the **data**, `rs2_data` is "
                         "the **running CRC**.\n> That is the order the official "
                         "validation firmware uses (`crcb s0, s1, s0`).\n> The ports are "
                         "in the usual rs1/rs2 order on the canvas - nothing special to "
                         "do\n> here - but do not \"helpfully\" swap the two wires.")
        if name == "dmem":
            lines.append("")
            lines.append("> `DMEM_WORDS` is the resize knob. 2048 is the full 8 kB "
                         "(Table 6/13) and 65,536\n> flip-flops. If place-and-route "
                         "cannot absorb that, 1024 or 512 works with no other\n> change "
                         "anywhere: the block reads 0 and writes nothing above the "
                         "instantiated array,\n> which Block Guide 4.3 explicitly permits.")

    with open(os.path.join(ROOT, "BLOCK_METADATA.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    blocks = load_blocks()
    instances = parse_instances(CI_TOP)
    nets = build_netlist(blocks, instances)
    n_nets, n_conns = write_netlist_doc(blocks, instances, nets)
    write_metadata_doc(blocks, instances)
    print("wrote NETLIST.md (%d blocks, %d instances, %d nets, %d connections)"
          % (len(blocks), len(instances), n_nets, n_conns))
    print("wrote BLOCK_METADATA.md")


if __name__ == "__main__":
    main()
