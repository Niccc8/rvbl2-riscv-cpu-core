#!/usr/bin/env python3
"""Audit a top.v exported from ChipInventor against the verified design.

Wiring 72 connections by hand on a canvas is the one step of this migration
that no generator protects. This checks the result mechanically:

  1. Every block's source in the export still matches blocks/*.v, ignoring
     comments and synthesis attributes (the platform rebuilds module headers
     from its own form fields, so attributes on PORTS do not survive - see the
     report this prints).
  2. The ROM is bit-identical to blocks/imem.v, all 742 words.
  3. The netlist is graph-identical to ci_top.v: same instances, and the same
     partition of pins into nets. Net names and instance names are ignored,
     because the platform generates both and changes them on every export.
     This is the check that a swapped or missing wire fails.
  4. Per-instance parameters are as intended (dmem's DMEM_WORDS).

(3) is the important one. It compares against ci_top.v, which
scripts/tb_mirror_equiv.v has already proven behaviourally identical to the
verified rtl_ref design - so a passing export inherits that proof.

Usage:
    python check_export.py [path/to/top.v]
"""

import argparse
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_TOP = os.path.join(ROOT, "top.v")
CI_TOP = os.path.join(ROOT, "ci_top.v")
BLOCKS = os.path.join(ROOT, "blocks")

# imem_mock.v declares the same module name as imem.v on purpose; it is an
# alternative Code field, never present in the same export.
SKIP_BLOCKS = {"imem_mock.v"}

EXPECTED_PARAMS = {"dmem": "DMEM_WORDS", }
EXPECTED_PARAM_VALUES = {"dmem": "2048"}

INST_RE = re.compile(
    r"(?ms)^\s*([A-Za-z_]\w*)\s*(#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
    r"([A-Za-z_]\w*)\s*\(\s*((?:\s*\.\w+\s*\([^)]*\)\s*,?)+)\s*\)\s*;")

NOT_A_MODULE = {"module", "wire", "reg", "input", "output", "assign", "always",
                "localparam", "parameter", "endmodule"}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def modules(text, keep_attrs=False):
    """module name -> normalised body (comments and attributes removed)."""
    out = {}
    for m in re.finditer(r"(?ms)^module\s+(\w+).*?^endmodule", text):
        body = strip_comments(m.group(0))
        if not keep_attrs:
            body = re.sub(r"\(\*.*?\*\)", "", body)
        out[m.group(1)] = re.sub(r"\s+", " ", body).strip()
    return out


def rom_words(text):
    return dict((int(i), int(v, 16)) for i, v in
                re.findall(r"20'd(\d+)\s*:\s*data_o = 32'h([0-9a-fA-F]{8});", text))


def instances(path):
    text = strip_comments(open(path).read())
    m = re.search(r"\bmodule\s+top\b", text)
    if not m:
        sys.exit("FAIL %s has no `top` module" % path)
    body = text[m.start():]
    body = body[:body.index("endmodule")]
    out = []
    for im in INST_RE.finditer(body):
        mod, params, inst, conns = im.group(1), im.group(2) or "", im.group(3), im.group(4)
        if mod in NOT_A_MODULE:
            continue
        pins = dict((p, n.strip())
                    for p, n in re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", conns))
        out.append((mod, inst, params.strip(), pins))
    return out


def net_signatures(insts):
    """Partition pins into nets, then forget the net and instance names.

    Two netlists with the same Counter here are wired identically up to
    renaming - which is exactly the equivalence the platform's auto-generated
    names force us to work in.
    """
    nets = collections.defaultdict(list)
    for mod, _inst, _params, pins in insts:
        for port, net in pins.items():
            nets[net].append((mod, port))
    return collections.Counter(tuple(sorted(v)) for v in nets.values())


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("top", nargs="?", default=DEFAULT_TOP)
    args = ap.parse_args()

    if not os.path.exists(args.top):
        sys.exit("FAIL %s does not exist - export the project first (BLOCKS button)"
                 % args.top)

    top_text = open(args.top).read()
    problems = []
    notes = []

    # ---- 1. block sources ------------------------------------------------
    exported = modules(top_text)
    ours = {}
    for fn in sorted(os.listdir(BLOCKS)):
        if fn.endswith(".v") and fn not in SKIP_BLOCKS:
            ours.update(modules(open(os.path.join(BLOCKS, fn)).read()))

    for name in sorted(ours):
        if name not in exported:
            problems.append("block %s is missing from the export" % name)
        elif exported[name] != ours[name]:
            problems.append("block %s differs from blocks/%s.v" % (name, name))
    extra = set(exported) - set(ours) - {"top"}
    if extra:
        problems.append("export contains unexpected modules: %s" % ", ".join(sorted(extra)))
    if not problems:
        print("OK   all %d block sources match blocks/*.v" % len(ours))

    # Attributes on PORT declarations do not survive the platform's Add Block
    # form, which rebuilds the module header from its own Inputs/Outputs
    # fields. Report which ones were lost rather than failing: the attributes
    # that matter for the zero-output-top sweep are the ones on the storage
    # arrays, and those are internal declarations that do survive.
    with_attrs_ours = modules(
        "\n".join(open(os.path.join(BLOCKS, f)).read()
                  for f in sorted(os.listdir(BLOCKS))
                  if f.endswith(".v") and f not in SKIP_BLOCKS), keep_attrs=True)
    with_attrs_exp = modules(top_text, keep_attrs=True)
    for name in sorted(set(with_attrs_ours) & set(with_attrs_exp)):
        n_ours = with_attrs_ours[name].count("(* keep *)")
        n_exp = with_attrs_exp[name].count("(* keep *)")
        if n_exp < n_ours:
            notes.append("%s: %d of %d (* keep *) attributes dropped by the platform"
                         % (name, n_ours - n_exp, n_ours))

    # ---- 2. ROM ----------------------------------------------------------
    rom_exp = rom_words(top_text)
    rom_ours = rom_words(open(os.path.join(BLOCKS, "imem.v")).read())
    if rom_exp != rom_ours:
        diff = next((k for k in sorted(set(rom_exp) | set(rom_ours))
                     if rom_exp.get(k) != rom_ours.get(k)), None)
        problems.append("ROM differs from blocks/imem.v (first at word %s: export=%s ours=%s)"
                        % (diff, rom_exp.get(diff), rom_ours.get(diff)))
    else:
        print("OK   ROM is bit-identical to blocks/imem.v (%d words)" % len(rom_exp))

    # ---- 3. connectivity -------------------------------------------------
    exp_insts = instances(args.top)
    ref_insts = instances(CI_TOP)

    exp_counts = collections.Counter(m for m, _, _, _ in exp_insts)
    ref_counts = collections.Counter(m for m, _, _, _ in ref_insts)
    if exp_counts != ref_counts:
        for mod in sorted(set(exp_counts) | set(ref_counts)):
            if exp_counts[mod] != ref_counts[mod]:
                problems.append("instance count for %s: export has %d, ci_top.v has %d"
                                % (mod, exp_counts[mod], ref_counts[mod]))
    else:
        print("OK   %d instances, same block mix as ci_top.v" % len(exp_insts))

    se, sr = net_signatures(exp_insts), net_signatures(ref_insts)
    if se == sr:
        print("OK   netlist is graph-identical to ci_top.v (%d nets)" % sum(se.values()))
    else:
        only_exp, only_ref = se - sr, sr - se
        # A net that exists in ci_top.v purely to park an unused output is not
        # a wiring error: the platform simply omits the port instead.
        def is_stub(k):
            return len(k) == 1
        real_exp = {k: c for k, c in only_exp.items() if not is_stub(k)}
        real_ref = {k: c for k, c in only_ref.items() if not is_stub(k)}
        if not real_exp and not real_ref:
            stubs = sorted("%s.%s" % k[0] for k in only_ref)
            print("OK   netlist is graph-identical to ci_top.v "
                  "(%d nets; unconnected in the export: %s)"
                  % (sum(se.values()), ", ".join(stubs)))
        else:
            for k, c in real_exp.items():
                problems.append("net in the export that ci_top.v does not have: %s"
                                % " + ".join("%s.%s" % p for p in k))
            for k, c in real_ref.items():
                problems.append("net in ci_top.v missing or split in the export: %s"
                                % " + ".join("%s.%s" % p for p in k))

    # ---- 4. parameters ---------------------------------------------------
    for mod, inst, params, _ in exp_insts:
        want = EXPECTED_PARAMS.get(mod)
        if want is None:
            continue
        m = re.search(r"\.%s\s*\(\s*([^)]*?)\s*\)" % want, params)
        if not m:
            problems.append("%s instance %s has no %s parameter - it will fall back "
                            "to the block default" % (mod, inst, want))
        elif m.group(1) != EXPECTED_PARAM_VALUES[mod]:
            problems.append("%s.%s is %s, expected %s"
                            % (mod, want, m.group(1), EXPECTED_PARAM_VALUES[mod]))
        else:
            print("OK   %s %s = %s" % (mod, want, m.group(1)))

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
