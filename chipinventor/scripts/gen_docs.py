#!/usr/bin/env python3
"""Generate NETLIST.md and BLOCK_METADATA.md from the blocks and the mirror.

Both documents are derived rather than written by hand, because both are the
kind of thing that goes quietly wrong: a transcribed port width or a net whose
direction was guessed produces a canvas that looks right and behaves wrong.
Everything here is read out of blocks/*.v and ci_top.v, which are the same
files the local verification actually runs, and the project parser is the one
check_export.py uses, so the documents and the export audit cannot disagree.

Stage 3 has two canvas projects (ci_top.v): the SoC, built on a copy of the
Phase 2 project and reused as IP, and the chip `top`. NETLIST.md covers both,
including the exact edits that turn the Phase 2 copy into the SoC; the edits
are derived by comparing against rtl_ref/, the frozen Phase 2 design.

Usage: python gen_docs.py
"""

import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BLOCKS = os.path.join(ROOT, "blocks")
CI_TOP = os.path.join(ROOT, "ci_top.v")
RTL_REF = os.path.join(ROOT, "rtl_ref")

_spec = importlib.util.spec_from_file_location("ce", os.path.join(HERE, "check_export.py"))
ce = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ce)

SOC_NAME = ce.SOC_NAME
PROJECTS = [SOC_NAME, "top"]
NEW_BLOCKS = {"gpio", "uart", "gpio_bits"}          # added in Stage 3
# Remade in Stage 3 as a new block (the platform cannot add ports to one that is
# placed, and editing it in place would also change the graded Phase 2 project), so
# its instance is placed afresh and every wire on it is drawn again.
REMADE_BLOCKS = {"address_decoder"}
PHASE2_PINS = {"clk_i", "rst_i"}

# One-line description shown on the block's form and in the docs.
DESCRIPTIONS = {
    "alu":                 "Purely combinational ALU, 11 operations (Table 9)",
    "branch_comparator":   "Evaluates the 6 RV32I branch conditions",
    "immediate_generator": "Extracts and sign-extends I/S/B/U/J immediates",
    "multiplier":          "MUL/MULH/MULHSU/MULHU, combinational (Zmmul, Table 10)",
    "crc_unit":            "CRC-16/CCITT-FALSE over 8/16/32 bits (Xicrc, Table 11)",
    "lsu":                 "Load/store unit: byte lanes, sign extension, write strobes",
    "address_decoder":     "Routes the memory transaction to IMEM, DMEM or the peripherals",
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
    "gpio":                "GPIO PIN controller: DATAOUT, DATAIN, DATADIR at 0xF0000000",
    "uart":                "UART serial controller, 8-N-1, 115200 bps, at 0xF1000000",
    "gpio_bits":           "Splits the GPIO buses into the 8 Inout Pins' C, D and pad bits",
}

# Why each instance exists, for the instance tables.
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
    "u_gpio":    "GPIO controller, slot 0 (0xF0000000)",
    "u_uart":    "UART controller, slot 1 (0xF1000000)",
    "u_soc":     "the SoC project, placed as IP",
    "u_bits":    "GPIO bus-to-pin splitter",
}

PORT_RE = re.compile(
    r"(?:\(\*.*?\*\)\s*)?\b(input|output|inout)\b\s+(?:wire|reg)?\s*"
    r"(\[[^\]]+\])?\s*([A-Za-z_]\w*)")


def resolve_width(width, params):
    """`[N_PINS-1:0]` with N_PINS = 8 -> `[7:0]`; plain widths unchanged."""
    if not width or not re.search(r"[A-Za-z_]", width):
        return width
    expr = width
    for name, val in params:
        expr = re.sub(r"\b%s\b" % re.escape(name), str(ce.verilog_int(val)), expr)
    m = re.match(r"^\[(.+):(.+)\]$", expr.replace(" ", ""))
    if not m or re.search(r"[A-Za-z_]", expr):
        sys.exit("cannot resolve port width %s" % width)
    return "[%d:%d]" % (eval(m.group(1), {}), eval(m.group(2), {}))   # digits and +-* only


def parse_block(path):
    """Return (name, params, ports) for a single-module block file."""
    with open(path) as fh:
        text = ce.strip_comments(fh.read())
    m = re.search(r"\bmodule\s+([A-Za-z_]\w*)\s*(#\s*\((.*?)\))?\s*\((.*?)\)\s*;",
                  text, re.DOTALL)
    if not m:
        sys.exit("could not parse a module header out of %s" % path)
    params = [(n, v.strip()) for n, v in re.findall(
        r"parameter\s+(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)\s*=\s*([^,\)\s]+)", m.group(3) or "")]
    ports = [(d, resolve_width((w or "").strip(), params), p)
             for d, w, p in PORT_RE.findall(m.group(4))]
    return m.group(1), params, ports


# imem_mock.v declares module `imem` on purpose - that is what makes it a
# drop-in swap of one Code field for the OpenLane run. It is skipped here so it
# does not overwrite the real imem's entry.
ALTERNATES = {"imem_mock.v": "imem"}


def load_blocks():
    out = {}
    for fname in sorted(os.listdir(BLOCKS)):
        if not fname.endswith(".v") or fname in ALTERNATES:
            continue
        name, params, ports = parse_block(os.path.join(BLOCKS, fname))
        out[name] = {"file": fname, "params": params, "ports": ports}
    return out


def load_project(name):
    with open(CI_TOP) as fh:
        proj = ce.parse_project(fh.read(), name)
    if proj is None or proj["problems"]:
        sys.exit("ci_top.v: cannot parse project %s %s" % (name, proj and proj["problems"]))
    return proj


def port_table(blocks):
    """module -> {port: (direction, width)}, the SoC project included as IP."""
    table = {m: {p: (d, w) for d, w, p in b["ports"]} for m, b in blocks.items()}
    table[SOC_NAME] = {p: (d, w) for d, w, p in load_project(SOC_NAME)["ports"]}
    return table


def build_netlist(proj, ports):
    """net -> {'width', 'src', 'sinks'} for one project.

    Endpoints are (owner, port): an instance pin is (instance, port); a project
    pin is ("PIN", name); an Inout Pin's terminals are ("C", pin) and ("D", pin).
    A pin written as `assign pin = net;` is a sink of that net.
    """
    nets = {}

    def entry(net, width=""):
        e = nets.setdefault(net, {"width": width, "src": None, "sinks": []})
        if width and not e["width"]:
            e["width"] = width
        return e

    for module, inst, _params, mapping in proj["instances"]:
        if module not in ports:
            sys.exit("instance %s uses module %s, which has no block file" % (inst, module))
        for port, net in mapping.items():
            if port not in ports[module]:
                sys.exit("instance %s connects unknown port .%s" % (inst, port))
            direction, width = ports[module][port]
            e = entry(net, width)
            if direction == "output":
                if e["src"] is not None:
                    sys.exit("net %s is driven twice" % net)
                e["src"] = (inst, port)
            else:
                e["sinks"].append((inst, port))

    tri = {pin for pin, _, _ in proj["tris"]}
    for direction, width, pin in proj["ports"]:
        if pin not in nets and pin not in dict(proj["aliases"]):
            continue
        if direction in ("input", "inout"):
            entry(pin, width)["src"] = ("PIN", pin)
        elif pin in nets:
            entry(pin, width)["sinks"].append(("PIN", pin))
    for pin, net in proj["aliases"]:
        entry(net)["sinks"].append(("PIN", pin))
    for pin, en, data in proj["tris"]:
        entry(en)["sinks"].append(("D", pin))
        entry(data)["sinks"].append(("C", pin))
    assert tri <= {p for _, _, p in proj["ports"]}
    return nets


def endpoint(e):
    owner, port = e
    if owner == "PIN":
        return "pin `%s`" % port
    if owner in ("C", "D"):
        return "pin `%s` **%s** (%s)" % (port, owner, "enable" if owner == "D" else "data")
    return "`%s.%s`" % (owner, port)


def connections(nets):
    """Every drawn wire as (net, width, source, sink), in a stable order."""
    out = []
    for net in sorted(nets):
        e = nets[net]
        if e["src"] is None:
            continue
        for s in sorted(e["sinks"]):
            out.append((net, e["width"], e["src"], s))
    return out


def phase2_delta(proj, nets):
    """Connections of the SoC that must be drawn on the copy of the Phase 2 project:
    the ones it does not have, plus every wire on a remade block."""
    ref_ports = {}
    with open(os.path.join(RTL_REF, "address_decoder.v")) as fh:
        _, _, ports = parse_block_text(fh.read())
        ref_ports["address_decoder"] = {p for _, _, p in ports}
    mod_of = {inst: mod for mod, inst, _, _ in proj["instances"]}

    def new_end(end):
        owner, port = end
        if owner in ("PIN", "C", "D"):
            return port not in PHASE2_PINS
        mod = mod_of[owner]
        if mod in NEW_BLOCKS or mod in REMADE_BLOCKS:
            return True
        return mod in ref_ports and port not in ref_ports[mod]

    return [c for c in connections(nets) if new_end(c[2]) or new_end(c[3])]


def parse_block_text(text):
    text = ce.strip_comments(text)
    m = re.search(r"\bmodule\s+(\w+)\s*(#\s*\((.*?)\))?\s*\((.*?)\)\s*;", text, re.S)
    return m.group(1), [], [(d, w, p) for d, w, p in PORT_RE.findall(m.group(4))]


def fmt_width(w):
    return w if w else "1 bit"


def params_text(params):
    m = re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", params)
    return ", ".join("%s = %s" % kv for kv in m) if m else ""


def project_section(name, proj, nets, lines):
    conns = connections(nets)
    lines.append("\n## Block instances (%d)\n" % len(proj["instances"]))
    lines.append("| Instance | Block | Parameters on the instance | Role |")
    lines.append("|---|---|---|---|")
    for module, inst, params, _ in proj["instances"]:
        mark = " (new)" if module in NEW_BLOCKS else ""
        lines.append("| `%s` | `%s`%s | %s | %s |"
                     % (inst, module, mark, params_text(params) or "-", ROLES.get(inst, "")))
    lines.append("\n## Pins (%d)\n" % len(proj["ports"]))
    lines.append("| Pin | Direction | Width |")
    lines.append("|---|---|---|")
    for d, w, p in proj["ports"]:
        lines.append("| `%s` | %s | %s |" % (p, d, fmt_width(w)))
    lines.append("\n## Wires (%d connections)\n" % len(conns))
    lines.append("One row per connection: drag from the source to the destination.\n")
    lines.append("| # | Net | Width | From | To |")
    lines.append("|---:|---|---|---|---|")
    for i, (net, w, s, d) in enumerate(conns, 1):
        lines.append("| %d | `%s` | %s | %s | %s |" % (i, net, fmt_width(w), endpoint(s), endpoint(d)))
    dangling = sorted(n for n, e in nets.items() if e["src"] and not e["sinks"])
    if dangling:
        lines.append("\nLeft unconnected on purpose (read by the testbench through the "
                     "hierarchy): %s." % ", ".join("`%s.%s`" % nets[n]["src"] for n in dangling))
    return len(conns)


def write_netlist_doc(blocks, ports):
    soc, top = load_project(SOC_NAME), load_project("top")
    soc_nets, top_nets = build_netlist(soc, ports), build_netlist(top, ports)
    delta = phase2_delta(soc, soc_nets)

    L = []
    L.append("# Wiring checklist - Stage 3\n")
    L.append("GENERATED by `scripts/gen_docs.py` from `ci_top.v` and `blocks/*.v` - do not "
             "hand-edit.\n")
    L.append("Two canvas projects. `%s` is the core, data memory and peripherals, built on a "
             "**copy** of the graded Phase 2 project and then placed as IP inside `top`, the "
             "chip. `scripts/check_export.py` audits the export of `top` against this "
             "document's source, wire by wire.\n" % SOC_NAME)

    L.append("\n## Before you start\n")
    L.append("- **Copy the graded Phase 2 project first** and make every change on the copy. "
             "The platform keeps no version history.")
    L.append("- Name the SoC project exactly **`%s`**: the export names its module after the "
             "project, and both the checker and the FPGA wrapper expect that name." % SOC_NAME)
    L.append("- The canvas **cannot slice a bus** and **cannot draw a constant**. That is why "
             "`address_decoder` has `periph_chain_o` (a constant zero to start the read-back "
             "chain) and why `gpio_bits` exists.")
    L.append("- **Inout Pins: C is the data, D is the enable.** The platform writes "
             "`assign pin = D ? C : 1'bZ;`. Wire `gpio_bits.cN_o` to **C**, `gpio_bits.dN_o` "
             "to **D**, and the pin's right-hand terminal to `gpio_bits.pN_i`. A swap still "
             "compiles, so the checker tests it explicitly.")
    L.append("- `lsu`'s port names still read backwards: `mem_data_o` is an input, "
             "`core_data_i` an output.")
    L.append("- `rx_i` must idle high on the real chip; the testbench holds it high.")

    L.append("\n# Project 1: `%s`\n" % SOC_NAME)
    L.append("\n## From the Phase 2 copy, in order\n")
    L.append("1. Delete the `imem` instance (its 3 wires go with it).")
    L.append("2. Create the new `address_decoder` block (BLOCK_METADATA.md: the Stage 3 Code "
             "and all 14 ports, 4 of them new), delete the old `u_decoder` instance (its wires "
             "go with it) and place the new block as `u_decoder`. Every wire on it is in the "
             "list below.")
    L.append("3. Create the blocks `gpio` and `uart` (BLOCK_METADATA.md) and place one of each. "
             "On the `uart` instance set **`CLK_FREQ_HZ = 30303030`**; leave every other "
             "parameter blank.")
    L.append("4. Add the pins: %s." % ", ".join(
        "`%s%s` (%s)" % (p, w, d) for d, w, p in soc["ports"] if p not in PHASE2_PINS))
    L.append("5. Draw the %d connections below: the Stage 3 wires and every wire on "
             "`u_decoder`. Everything else stays as it was." % len(delta))
    L.append("\n### The %d connections to draw\n" % len(delta))
    L.append("| # | Net | Width | From | To |")
    L.append("|---:|---|---|---|---|")
    for i, (net, w, s, d) in enumerate(delta, 1):
        L.append("| %d | `%s` | %s | %s | %s |" % (i, net, fmt_width(w), endpoint(s), endpoint(d)))
    L.append("\n### The whole project, for checking\n")
    n_soc = project_section(SOC_NAME, soc, soc_nets, L)

    L.append("\n# Project 2: `top` (the chip)\n")
    L.append("A new project. Place `%s` (from the IP list), `imem` and `gpio_bits`. Add the "
             "pins below; `pins_io_0`..`pins_io_7` are **Inout Pins**, one per GPIO bit.\n"
             % SOC_NAME)
    n_top = project_section("top", top, top_nets, L)

    L.append("\n## Totals\n")
    L.append("| | `%s` | `top` |" % SOC_NAME)
    L.append("|---|---:|---:|")
    L.append("| Block instances | %d | %d |" % (len(soc["instances"]), len(top["instances"])))
    L.append("| Pins | %d | %d |" % (len(soc["ports"]), len(top["ports"])))
    L.append("| Connections | %d | %d |" % (n_soc, n_top))
    L.append("| To draw in Stage 3 | %d | %d |" % (len(delta), n_top))
    with open(os.path.join(ROOT, "NETLIST.md"), "w", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")
    return n_soc, n_top, len(delta)


def write_metadata_doc(blocks):
    counts = {}
    for name in PROJECTS:
        for module, _, _, _ in load_project(name)["instances"]:
            counts[module] = counts.get(module, 0) + 1

    L = []
    L.append("# Block form fields\n")
    L.append("GENERATED by `scripts/gen_docs.py` from `blocks/*.v` - do not hand-edit.\n")
    L.append("One section per block, giving exactly what goes in each field of "
             "ChipInventor's Add Block\ndialog. Paste the matching file from "
             "`blocks/` into the Code field; nothing in those files\nneeds editing "
             "or trimming first. Blocks marked **new** or **changed** are the Stage 3 work;\n"
             "every other block is exactly as in the Phase 2 project.\n")
    L.append("Author and Icon are yours to set. Leave Validate, Block Width, "
             "Block Technology and the\ntwo HDL-Specific fields empty unless the "
             "platform asks for them.\n")

    for name in sorted(blocks):
        info = blocks[name]
        ins = [(w, p) for d, w, p in info["ports"] if d == "input"]
        outs = [(w, p) for d, w, p in info["ports"] if d == "output"]
        inouts = [(w, p) for d, w, p in info["ports"] if d == "inout"]

        def fmt(lst):
            return ", ".join(("%s%s" % (p, w)) for w, p in lst) or "(none)"

        tag = " (new)" if name in NEW_BLOCKS else (" (changed)" if name == "address_decoder" else "")
        n = counts.get(name, 0)
        L.append("\n## `%s`%s\n" % (name, tag))
        L.append("```")
        L.append("Name:               %s" % name)
        L.append("Description:        %s" % DESCRIPTIONS.get(name, ""))
        L.append("Code:               paste blocks/%s" % info["file"])
        L.append("Number of Inputs:   %d" % len(ins))
        L.append("Inputs:             %s" % fmt(ins))
        L.append("Number of Outputs:  %d" % len(outs))
        L.append("Outputs:            %s" % fmt(outs))
        L.append("Number of Inouts:   %d" % len(inouts))
        L.append("Inouts:             %s" % fmt(inouts))
        L.append("Parameters:         %s" % (", ".join("%s = %s" % p for p in info["params"])
                                             or "(none)"))
        L.append("```")
        L.append("")
        L.append("Placed %d time%s." % (n, "" if n == 1 else "s"))
        if name == "lsu":
            L.append("\n> **Careful:** `mem_data_o` is an **input** and `core_data_i` is an "
                     "**output**. The names\n> read backwards; the directions above are correct.")
        if name == "imem":
            L.append("\n> Placed in `top`, not in the SoC. **For the OpenLane / P&R run, paste "
                     "`blocks/imem_mock.v`\n> into this same block instead** - same module name "
                     "and ports, so only the Code field changes.")
        if name == "crc_unit":
            L.append("\n> **Operand order:** `rs1_data` is the **data**, `rs2_data` the "
                     "**running CRC** - the order\n> the official firmware uses. Do not swap "
                     "the two wires.")
        if name == "dmem":
            L.append("\n> `DMEM_WORDS` is the resize knob: 2048 is the full 8 kB. 1024 or 512 "
                     "work with no other\n> change: the block reads 0 and writes nothing above "
                     "the instantiated array.")
        if name == "address_decoder":
            L.append("\n> **Changed in Stage 3:** four new ports for the peripheral region "
                     "0xF0000000-0xFFFFFFFF.\n> Make it as a new block with these fields, "
                     "replace the `u_decoder` instance, and redraw\n> all of its wires "
                     "(NETLIST.md lists them).")
        if name == "gpio":
            L.append("\n> Ports are written `[N_PINS-1:0]` in the code; with the default "
                     "`N_PINS = 8` they are the\n> 8-bit ports listed above. Leave `SLOT` and "
                     "`N_PINS` blank on the instance.")
        if name == "uart":
            L.append("\n> Set **`CLK_FREQ_HZ = 30303030`** on the instance (the 33 ns clock); "
                     "leave `SLOT` and\n> `BAUD_RATE` blank. The divisor is "
                     "round(30303030 / 115200) = 263 clocks per bit.")
        if name == "gpio_bits":
            L.append("\n> Wiring only. For each pin N: `cN_o` -> the Inout Pin's **C**, "
                     "`dN_o` -> its **D**,\n> and the pin's right-hand terminal -> `pN_i`.")

    with open(os.path.join(ROOT, "BLOCK_METADATA.md"), "w", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")


def main():
    blocks = load_blocks()
    ports = port_table(blocks)
    n_soc, n_top, n_delta = write_netlist_doc(blocks, ports)
    write_metadata_doc(blocks)
    print("wrote NETLIST.md (%s: %d connections, %d to draw on the Phase 2 copy; top: %d connections)"
          % (SOC_NAME, n_soc, n_delta, n_top))
    print("wrote BLOCK_METADATA.md (%d blocks)" % len(blocks))


if __name__ == "__main__":
    main()
