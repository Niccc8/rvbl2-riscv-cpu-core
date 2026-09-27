#!/usr/bin/env python3
"""Audit a ChipInventor export against the verified design.

Wiring the canvas by hand is the one step no generator protects. Stage 3 has
two projects - the SoC (reused as IP) and the chip `top` - and the BLOCKS
export of `top` contains both. This checks the export mechanically:

  1. Every block's source still matches blocks/*.v (comments and attributes
     ignored), and the imem block holds one of our ROMs bit for bit (KNOWN_ROMS:
     the validation ROM, the application ROM, or the official test firmware's).
  2. The SoC module is there, named SOC_NAME, and `top` instantiates it once.
  3. Each project's pins match ci_top.v: names, directions, widths, and no
     duplicates (the platform accepts two pins with one name silently).
  4. Each project's netlist is graph-identical to ci_top.v: same instances,
     same partition of pins into nets. Net and instance names are ignored,
     because the platform generates both. `assign pin = net;` aliases and the
     Inout Pins' `assign pin = D ? C : 1'bZ;` are part of the graph, so a
     swapped, missing or crossed wire fails here - including a C/D swap.
  5. Each Inout Pin's polarity, stated plainly: D (the enable) must come from
     gpio_bits.dN_o (DATADIR) and C (the data) from gpio_bits.cN_o (DATAOUT).
     A swap compiles and exports cleanly but drives the pin whenever DATAOUT
     is 1, even as an input.
  6. Block parameters, resolved against the block defaults: dmem DMEM_WORDS,
     gpio SLOT/N_PINS, uart SLOT/CLK_FREQ_HZ/BAUD_RATE.

(4) compares against ci_top.v, which tb_mirror_equiv.v proves cycle-identical
to the frozen Phase 2 core and tb_chipinventor.v verifies end to end - so a
passing export inherits both.

Usage:
    python check_export.py [path/to/export.v]
"""

import argparse
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_EXPORT = os.path.join(ROOT, "export_stage3.v")
CI_TOP = os.path.join(ROOT, "ci_top.v")
BLOCKS = os.path.join(ROOT, "blocks")

SOC_NAME = "rvbl2_soc"     # the SoC project's name on the canvas = its module name
SOC_MARKER = "control_unit"

# imem_mock.v declares the same module name as imem.v on purpose; it is an
# alternative Code field, never present in the same export.
SKIP_BLOCKS = {"imem_mock.v"}

# The imem block's Code field holds whichever program was last pasted. Any of
# these is ours; the export is named by the one it holds. The official test
# firmware's ROM lives outside chipinventor/ and is recognised only if present.
KNOWN_ROMS = [
    ("the validation ROM", os.path.join(BLOCKS, "imem.v")),
    ("the application ROM", os.path.join(ROOT, "app", "imem_app.v")),
    ("the official test firmware's ROM",
     os.path.join(os.path.dirname(ROOT), "official-firmware-testbench", "imem_official.v")),
]

# Resolved value every instance of these blocks must have (explicit or default).
EXPECTED_PARAMS = {
    "dmem": {"DMEM_WORDS": 2048},
    "gpio": {"SLOT": 0, "N_PINS": 8},
    "uart": {"SLOT": 1, "CLK_FREQ_HZ": 30303030, "BAUD_RATE": 115200},
}

INST_RE = re.compile(
    r"(?ms)^\s*([A-Za-z_]\w*)\s*(#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
    r"([A-Za-z_]\w*)\s*\(\s*((?:\s*\.\w+\s*\([^)]*\)\s*,?)*)\s*\)\s*;")
PORT_RE = re.compile(r"\b(input|output|inout)\b\s*(?:wire|reg)?\s*(\[[^\]]+\])?\s*(\w+)")
ASSIGN_RE = re.compile(r"(?m)^\s*assign\s+(\w+)(?:\s*\[[^\]]*\])?\s*=\s*([^;]+);")
TRI_RE = re.compile(r"^(\w+)(?:\s*\[[^\]]*\])?\s*\?\s*(\w+)(?:\s*\[[^\]]*\])?\s*:\s*1'b[zZ]$")
NOT_A_MODULE = {"module", "wire", "reg", "input", "output", "inout", "assign", "always",
                "localparam", "parameter", "endmodule", "genvar", "generate"}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def modules(text, keep_attrs=False):
    """module name -> normalised source (comments and attributes removed)."""
    out = {}
    for m in re.finditer(r"(?ms)^module\s+(\w+).*?^endmodule", text):
        body = strip_comments(m.group(0))
        if not keep_attrs:
            body = re.sub(r"\(\*.*?\*\)", "", body)
        out[m.group(1)] = re.sub(r"\s+", " ", body).strip()
    return out


def rom_words(text):
    """word index -> value, from an imem block in either coding: the flat
    `20'dN: data_o = ...` case, or the two-level one gen_ci_imem.py emits
    (`14'dH: case (word_addr[5:0]) 6'dL: data_o = ...`, index H*64+L)."""
    words = dict((int(i), int(v, 16)) for i, v in
                 re.findall(r"20'd(\d+)\s*:\s*data_o = 32'h([0-9a-fA-F]{8});", text))
    for hi, body in re.findall(r"14'd(\d+)\s*:\s*case\s*\(\s*word_addr\[5:0\]\s*\)(.*?)endcase",
                               text, re.S):
        for lo, v in re.findall(r"6'd(\d+)\s*:\s*data_o = 32'h([0-9a-fA-F]{8});", body):
            words[int(hi) * 64 + int(lo)] = int(v, 16)
    return words


def verilog_int(s):
    """4'd1, 32'h10, 30303030 -> int; None if not a plain literal."""
    s = s.strip().replace("_", "")
    m = re.match(r"^(?:\d+)?'([dhbo])([0-9a-fA-F]+)$", s)
    if m:
        return int(m.group(2), {"d": 10, "h": 16, "b": 2, "o": 8}[m.group(1)])
    return int(s) if re.match(r"^\d+$", s) else None


def block_defaults():
    """module -> {param: default int} from blocks/*.v headers."""
    out = {}
    for fn in os.listdir(BLOCKS):
        if not fn.endswith(".v") or fn in SKIP_BLOCKS:
            continue
        text = strip_comments(open(os.path.join(BLOCKS, fn)).read())
        m = re.search(r"\bmodule\s+(\w+)\s*#\s*\((.*?)\)\s*\(", text, re.S)
        if m:
            out[m.group(1)] = {p: verilog_int(v) for p, v in re.findall(
                r"parameter\s+(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,)\s]+)", m.group(2))}
    return out


def parse_project(text, name):
    """One project module -> dict(ports, instances, aliases, tris).

    ports      [(direction, width, name)]
    instances  [(module, instance, params_text, {port: net})]
    aliases    [(pin, net)]            from `assign pin = net;`
    tris       [(pin, enable, data)]   from `assign pin = en ? data : 1'bZ;`
    """
    text = strip_comments(text)
    m = re.search(r"(?ms)^\s*module\s+%s\s*\((.*?)\)\s*;(.*?)^\s*endmodule" % re.escape(name), text)
    if not m:
        return None
    ports = [(d, (w or "").replace(" ", ""), n) for d, w, n in PORT_RE.findall(m.group(1))]
    body = m.group(2)
    insts, aliases, tris, problems = [], [], [], []
    for im in INST_RE.finditer(body):
        mod, params, inst, conns = im.group(1), im.group(2) or "", im.group(3), im.group(4)
        if mod in NOT_A_MODULE:
            continue
        pins = {}
        for p, n in re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", conns):
            n = re.sub(r"\s*\[[^\]]*\]$", "", n)   # `seen_o[7:0]` - the whole pin
            if n:
                pins[p] = n
        insts.append((mod, inst, params.strip(), pins))
    for lhs, rhs in ASSIGN_RE.findall(body):
        rhs = rhs.strip()
        t = TRI_RE.match(rhs)
        if t:
            tris.append((lhs, t.group(1), t.group(2)))
        elif re.match(r"^\w+(\s*\[[^\]]*\])?$", rhs):
            aliases.append((lhs, re.sub(r"\s*\[.*$", "", rhs)))
        else:
            problems.append("%s: unexpected logic `assign %s = %s`" % (name, lhs, rhs))
    return dict(ports=ports, instances=insts, aliases=aliases, tris=tris, problems=problems)


def net_signatures(proj, soc_module):
    """Partition every endpoint into nets, then forget net and instance names.

    Endpoints: (block module, port) for instance pins - with the SoC IP module
    written as "SOC" - ("PIN", name) for the project's own pins, and
    ("D", pin) / ("C", pin) for an Inout Pin's enable and data terminals.
    """
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        parent[find(a)] = find(b)

    ends = collections.defaultdict(list)
    pins = {n for _, _, n in proj["ports"]}
    for mod, _inst, _params, conns in proj["instances"]:
        kind = "SOC" if mod == soc_module else mod
        for port, net in conns.items():
            ends[net].append((kind, port))
    for pin, net in proj["aliases"]:
        union(pin, net)
    for pin, en, data in proj["tris"]:
        ends[en].append(("D", pin))
        ends[data].append(("C", pin))
    for p in pins:
        ends[p].append(("PIN", p))

    groups = collections.defaultdict(list)
    for net, e in ends.items():
        groups[find(net)].extend(e)
    return collections.Counter(tuple(sorted(v)) for v in groups.values())


def find_soc_module(text):
    """Name of the module `top` instantiates that itself contains the core."""
    bodies = {m.group(1): m.group(0) for m in
              re.finditer(r"(?ms)^\s*module\s+(\w+)\b.*?^\s*endmodule", strip_comments(text))}
    if "top" not in bodies:
        return None, 0
    top = parse_project(text, "top")
    found = [(mod, inst) for mod, inst, _, _ in top["instances"]
             if mod in bodies and re.search(r"(?m)^\s*%s\b" % SOC_MARKER, bodies[mod])]
    return (found[0][0] if found else None), len(found)


def compare_project(label, exp, ref, exp_soc, problems):
    """Pins, instance mix and graph of one project; returns printable notes."""
    # ---- pins ----
    names = [n for _, _, n in exp["ports"]]
    dup = sorted(n for n, c in collections.Counter(names).items() if c > 1)
    if dup:
        problems.append("%s: duplicate pin name(s) %s" % (label, ", ".join(dup)))
    if sorted(exp["ports"], key=lambda p: p[2]) != sorted(ref["ports"], key=lambda p: p[2]):
        e, r = set(exp["ports"]), set(ref["ports"])
        for d, w, n in sorted(r - e, key=lambda p: p[2]):
            problems.append("%s: pin missing or different: %s %s%s" % (label, d, n, w))
        for d, w, n in sorted(e - r, key=lambda p: p[2]):
            problems.append("%s: unexpected pin: %s %s%s" % (label, d, n, w))
    else:
        print("OK   %s: %d pins, names, directions and widths as ci_top.v"
              % (label, len(exp["ports"])))

    # ---- instance mix ----
    kind = lambda m: "SOC" if m in (exp_soc, SOC_NAME) else m   # noqa: E731
    ce = collections.Counter(kind(m) for m, _, _, _ in exp["instances"])
    cr = collections.Counter(kind(m) for m, _, _, _ in ref["instances"])
    if ce != cr:
        for mod in sorted(set(ce) | set(cr)):
            if ce[mod] != cr[mod]:
                problems.append("%s: %s placed %d time(s), ci_top.v has %d"
                                % (label, mod, ce[mod], cr[mod]))
    else:
        print("OK   %s: %d instances, same block mix as ci_top.v" % (label, len(exp["instances"])))

    # ---- graph ----
    se = net_signatures(exp, exp_soc)
    sr = net_signatures(ref, SOC_NAME)
    only_exp, only_ref = se - sr, sr - se
    # A net that exists in ci_top.v only to park an unused output is not a
    # wiring error: the platform simply leaves the port out.
    stub = lambda k: len(k) == 1 and k[0][0] not in ("PIN", "C", "D")   # noqa: E731
    real_exp = [k for k in only_exp if not stub(k)]
    real_ref = [k for k in only_ref if not stub(k)]
    if not real_exp and not real_ref:
        extra = sorted("%s.%s" % k[0] for k in only_ref)
        print("OK   %s: netlist graph-identical to ci_top.v (%d nets%s)"
              % (label, sum(se.values()),
                 "; unconnected in the export: " + ", ".join(extra) if extra else ""))
    else:
        for k in real_exp:
            problems.append("%s: net in the export that ci_top.v does not have: %s"
                            % (label, " + ".join("%s.%s" % p for p in k)))
        for k in real_ref:
            problems.append("%s: net in ci_top.v missing or split in the export: %s"
                            % (label, " + ".join("%s.%s" % p for p in k)))


def check_polarity(top, problems):
    """Each Inout Pin: D from gpio_bits.dN_o, C from gpio_bits.cN_o."""
    drivers = {}
    for mod, _inst, _params, conns in top["instances"]:
        if mod == "gpio_bits":
            for port, net in conns.items():
                drivers[net] = port
    alias = dict(top["aliases"])
    ok = 0
    for pin, en, data in sorted(top["tris"]):
        n = pin.rsplit("_", 1)[-1]
        d_src, c_src = drivers.get(alias.get(en, en)), drivers.get(alias.get(data, data))
        if d_src == "d%s_o" % n and c_src == "c%s_o" % n:
            ok += 1
        elif d_src == "c%s_o" % n and c_src == "d%s_o" % n:
            problems.append("%s: C and D are SWAPPED - wire c%s_o to C and d%s_o to D"
                            % (pin, n, n))
        else:
            problems.append("%s: D (enable) comes from %s and C (data) from %s; expected "
                            "gpio_bits.d%s_o and gpio_bits.c%s_o" % (pin, d_src, c_src, n, n))
    if ok == len(top["tris"]) and ok:
        print("OK   Inout Pin polarity: all %d pins have D = DATADIR[n], C = DATAOUT[n]" % ok)


def check_params(insts, problems):
    defaults = block_defaults()
    for mod, inst, params, _ in insts:
        want = EXPECTED_PARAMS.get(mod)
        if not want:
            continue
        given = {p: verilog_int(v) for p, v in
                 re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", params)}
        for p in given:
            if p not in defaults.get(mod, {}):
                problems.append("%s %s: unknown parameter %s" % (mod, inst, p))
        shown = []
        for p, v in sorted(want.items()):
            got = given.get(p, defaults.get(mod, {}).get(p))
            if got != v:
                problems.append("%s %s: %s resolves to %s, expected %d%s"
                                % (mod, inst, p, got, v,
                                   "" if p in given else " (left at the block default)"))
            else:
                shown.append("%s=%d%s" % (p, v, "" if p in given else " (default)"))
        if len(shown) == len(want):
            print("OK   %s parameters: %s" % (mod, ", ".join(shown)))


def core_module(text):
    """Name of the module that instantiates control_unit directly (the SoC)."""
    for m in re.finditer(r"(?ms)^\s*module\s+(\w+)\b.*?^\s*endmodule", strip_comments(text)):
        if re.search(r"(?m)^\s*%s\b" % SOC_MARKER, m.group(0)):
            return m.group(1)
    return None


def check_soc_only(text, ref_text):
    """An export of the SoC project on its own, before `top` exists: every block
    the SoC uses matches blocks/*.v, and its pins, instances, netlist and
    parameters match ci_top.v's rvbl2_soc. The module name is whatever the
    platform chose; it only has to be rvbl2_soc once placed as IP in `top`."""
    problems = []
    soc_mod = core_module(text)
    if soc_mod is None:
        sys.exit("FAIL no module in the export instantiates %s - is this the SoC project?"
                 % SOC_MARKER)
    ref = parse_project(ref_text, SOC_NAME)
    used = {m for m, _, _, _ in ref["instances"]}
    exported = modules(text)
    ours = {}
    for fn in sorted(os.listdir(BLOCKS)):
        if fn.endswith(".v") and fn not in SKIP_BLOCKS:
            ours.update(modules(open(os.path.join(BLOCKS, fn)).read()))
    for name in sorted(used):
        if name not in exported:
            problems.append("block %s is missing from the export" % name)
        elif exported[name] != ours[name]:
            problems.append("block %s differs from blocks/%s.v - re-paste its Code field"
                            % (name, name))
    if not problems:
        print("OK   all %d block sources the SoC uses match blocks/*.v" % len(used))
    extra = set(exported) - used - {soc_mod}
    if extra:
        problems.append("export contains unexpected modules: %s" % ", ".join(sorted(extra)))
    print("OK   SoC module found: %s%s" % (soc_mod, "" if soc_mod == SOC_NAME else
          " (fine here; placed as IP in top it must export as %s)" % SOC_NAME))
    exp = parse_project(text, soc_mod)
    problems.extend(exp["problems"])
    compare_project(SOC_NAME, exp, ref, soc_mod, problems)
    check_params(exp["instances"], problems)
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", nargs="?", default=DEFAULT_EXPORT)
    args = ap.parse_args()
    if not os.path.exists(args.export):
        sys.exit("FAIL %s does not exist - export the chip project first (BLOCKS button)"
                 % args.export)

    text = open(args.export).read()
    ref_text = open(CI_TOP).read()
    problems, notes = [], []

    # An export of the SoC project alone: no module wraps the core.
    if find_soc_module(text)[0] is None and core_module(text) is not None:
        print("SoC-only export (no chip `top` around it) - checking rvbl2_soc alone")
        problems = check_soc_only(text, ref_text)
        if problems:
            print()
            for p in problems:
                print("FAIL %s" % p, file=sys.stderr)
            sys.exit(1)
        print("PASS the SoC project is wired exactly as ci_top.v")
        return

    # ---- 1. block sources and the ROM -----------------------------------
    exported = modules(text)
    ours = {}
    for fn in sorted(os.listdir(BLOCKS)):
        if fn.endswith(".v") and fn not in SKIP_BLOCKS:
            ours.update(modules(open(os.path.join(BLOCKS, fn)).read()))
    n_bad = len(problems)
    for name in sorted(ours):
        if name not in exported:
            problems.append("block %s is missing from the export" % name)
        elif name == "imem":
            continue                    # the ROM: checked against KNOWN_ROMS below
        elif exported[name] != ours[name]:
            problems.append("block %s differs from blocks/%s.v - re-paste its Code field"
                            % (name, name))
    if len(problems) == n_bad:
        print("OK   all %d block sources match blocks/*.v" % len(ours))

    with_attrs_ours = modules("\n".join(
        open(os.path.join(BLOCKS, f)).read() for f in sorted(os.listdir(BLOCKS))
        if f.endswith(".v") and f not in SKIP_BLOCKS), keep_attrs=True)
    with_attrs_exp = modules(text, keep_attrs=True)
    for name in sorted(set(with_attrs_ours) & set(with_attrs_exp)):
        n_ours = with_attrs_ours[name].count("(* keep *)")
        n_exp = with_attrs_exp[name].count("(* keep *)")
        if n_exp < n_ours:
            notes.append("%s: %d of %d (* keep *) attributes dropped by the platform"
                         % (name, n_ours - n_exp, n_ours))

    rom_exp = rom_words(text)
    held = None
    for label, path in KNOWN_ROMS:
        if os.path.exists(path):
            src = open(path).read()
            if modules(src).get("imem") == exported.get("imem") and rom_words(src) == rom_exp:
                held = (label, path)
                break
    if "imem" not in exported:
        pass                            # already reported as missing
    elif held:
        print("OK   imem holds %s (%s), bit-identical, %d words"
              % (held[0], os.path.relpath(held[1], ROOT).replace(os.sep, "/"), len(rom_exp)))
    else:
        rom_ours = rom_words(open(os.path.join(BLOCKS, "imem.v")).read())
        diff = next((k for k in sorted(set(rom_exp) | set(rom_ours))
                     if rom_exp.get(k) != rom_ours.get(k)), None)
        problems.append("imem holds none of our ROMs - re-paste its Code field "
                        "(against blocks/imem.v, first difference at word %s: export=%s ours=%s)"
                        % (diff, rom_exp.get(diff), rom_ours.get(diff)))

    # ---- 2. the two projects --------------------------------------------
    soc_mod, n_soc = find_soc_module(text)
    if soc_mod is None or n_soc != 1:
        problems.append("top must instantiate the SoC project exactly once (found %d)" % n_soc)
    elif soc_mod != SOC_NAME:
        problems.append("the SoC project exports as `%s`; name the project %s (the FPGA "
                        "wrapper instantiates it by that name)" % (soc_mod, SOC_NAME))
    else:
        print("OK   SoC project exported as module %s, instantiated once in top" % SOC_NAME)
    extra = set(exported) - set(ours) - {"top", soc_mod}
    if extra:
        problems.append("export contains unexpected modules: %s" % ", ".join(sorted(extra)))

    if soc_mod:
        for label, mod_exp, mod_ref in ((SOC_NAME, soc_mod, SOC_NAME), ("top", "top", "top")):
            exp, ref = parse_project(text, mod_exp), parse_project(ref_text, mod_ref)
            problems.extend(exp["problems"])
            compare_project(label, exp, ref, soc_mod, problems)
            check_params(exp["instances"], problems)
        check_polarity(parse_project(text, "top"), problems)

    # ---- report ----------------------------------------------------------
    for n in notes:
        print("note %s" % n)
    if problems:
        print()
        for p in problems:
            print("FAIL %s" % p, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
