#!/usr/bin/env python3
"""Write build/wiring_map.html: the Stage 3 canvas wiring guide as one page.

Everything on the page is generated from the same sources the verification
uses - the two schematics from gen_schematic.py (layout-checked), the
connection lists from gen_docs.py (the parser check_export.py audits the
export with), and the block form fields from blocks/*.v - so the page cannot
disagree with the design it describes. The pass count comes from the last
local run of the platform testbench (build/tb.log), when there is one.

Run gen_schematic.py first (run_ci.sh does). Usage: python gen_wiring_map.py
"""

import html
import importlib.util
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
OUT = os.path.join(BUILD, "wiring_map.html")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gd = load("gen_docs")
gs = load("gen_schematic")
E = html.escape


def label(end):
    owner, port = end
    if owner == "PIN":
        return {"k": "pin", "t": port}
    if owner in ("C", "D"):
        return {"k": "term", "t": port, "x": owner}
    return {"k": "port", "i": owner, "p": port}


def rows(project, ports):
    proj = gd.load_project(project)
    nets = gd.build_netlist(proj, ports)
    new = set()
    if project == gd.SOC_NAME:
        new = {(n, d) for n, _w, _s, d in gd.phase2_delta(proj, nets)}
    out = []
    for net, w, s, d in gd.connections(nets):
        out.append({
            "id": "%s|%s|%s.%s" % (project, net, d[0], d[1]),
            "n": net, "w": w or "1 bit",
            "s": label(s), "d": label(d),
            "si": gs.to_endpoint(s)[0], "di": gs.to_endpoint(d)[0],
            "new": project != gd.SOC_NAME or (net, d) in new,
        })
    # Stage 3 wires first in the SoC list; each group keeps net order.
    out.sort(key=lambda r: (not r["new"], r["n"], r["id"]))
    return proj, out


def block_card(name, info):
    ins = [(p, w) for d, w, p in info["ports"] if d == "input"]
    outs = [(p, w) for d, w, p in info["ports"] if d == "output"]
    fmt = lambda lst: ", ".join(p + w for p, w in lst)            # noqa: E731
    fields = [
        ("Name", name),
        ("Description", gd.DESCRIPTIONS.get(name, "")),
        ("Code", "paste blocks/%s" % info["file"]),
        ("Number of Inputs", str(len(ins))),
        ("Inputs", fmt(ins)),
        ("Number of Outputs", str(len(outs))),
        ("Outputs", fmt(outs)),
        ("Parameters", ", ".join("%s = %s" % p for p in info["params"]) or "(none)"),
    ]
    tag = "changed" if name == "address_decoder" else "new"
    out = ['<article class="form"><header><h3>%s</h3><span class="chip %s">%s</span></header><dl>'
           % (E(name), tag, tag)]
    for k, v in fields:
        copy = k in ("Inputs", "Outputs")
        out.append('<div class="fld"><dt>%s</dt><dd><code>%s</code>%s</dd></div>'
                   % (E(k), E(v), '<button class="copy" type="button" data-copy="%s">Copy</button>'
                      % E(v, quote=True) if copy else ""))
    out.append("</dl></article>")
    return "".join(out)


def svg(name):
    with io.open(os.path.join(BUILD, name + ".svg"), encoding="utf-8") as fh:
        return fh.read()


def tb_count():
    try:
        with open(os.path.join(BUILD, "tb.log")) as fh:
            m = re.search(r"==== testbench: (\d+) passed, 0 failed", fh.read())
        return "{:,}".format(int(m.group(1))) if m else None
    except IOError:
        return None


def main():
    blocks = gd.load_blocks()
    ports = gd.port_table(blocks)
    soc, soc_rows = rows(gd.SOC_NAME, ports)
    top, top_rows = rows("top", ports)
    n_new = sum(r["new"] for r in soc_rows)
    checks = tb_count()
    soc_pins = [(d, w, p) for d, w, p in soc["ports"] if p not in gd.PHASE2_PINS]
    soc_w = int(re.search(r'viewBox="0 0 (\d+)', svg("schematic")).group(1))
    top_w = int(re.search(r'viewBox="0 0 (\d+)', svg("schematic_top")).group(1))

    data = {"soc": soc_rows, "top": top_rows, "w": {"soc": soc_w, "top": top_w}}
    forms = "".join(block_card(n, blocks[n]) for n in ("gpio", "uart", "gpio_bits", "address_decoder"))
    pin_list = ", ".join("<code>%s%s</code> %s" % (E(p), E(w), d) for d, w, p in soc_pins)

    page = TEMPLATE
    for k, v in {
        "@@SOC_NAME@@": gd.SOC_NAME,
        "@@N_NEW@@": str(n_new),
        "@@N_SOC@@": str(len(soc_rows)),
        "@@N_TOP@@": str(len(top_rows)),
        "@@N_SOC_INST@@": str(len(soc["instances"])),
        "@@CHECKS@@": ('<div class="stat"><b>%s</b><span>platform checks passing</span></div>'
                       % checks) if checks else "",
        "@@SOC_PINS@@": pin_list,
        "@@SVG_SOC@@": svg("schematic"),
        "@@SVG_TOP@@": svg("schematic_top"),
        "@@FORMS@@": forms,
        "@@DATA@@": json.dumps(data, separators=(",", ":")),
    }.items():
        page = page.replace(k, v)
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(page)
    print("wrote %s (%s: %d connections, %d new; top: %d)"
          % (OUT, gd.SOC_NAME, len(soc_rows), n_new, len(top_rows)))


TEMPLATE = r"""<title>RVBL-2 Stage 3 Wiring Map</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600;700&display=swap">
<style>
:root{
  --ground:#f4f6f8; --panel:#ffffff; --panel-2:#eef1f5;
  --ink:#161b22; --ink-2:#3a434f; --muted:#5c6673;
  --rule:#dbe0e8; --rule-2:#c6cdd8;
  --brass:#8a5d0c; --brass-ink:#6d4a09; --brass-bg:#fbf3e2;
  --new:#c26a00; --new-bg:#fff1dc; --wire:#4a5462; --band:#f0f2f6; --focus:#1f5fbf;
  --shadow:0 1px 2px rgba(16,22,30,.06),0 4px 14px rgba(16,22,30,.05);
  --sans:"IBM Plex Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  color-scheme:dark;
  --ground:#0e1116; --panel:#161a21; --panel-2:#1c2129;
  --ink:#e7eaef; --ink-2:#c2c9d4; --muted:#929caa;
  --rule:#242a33; --rule-2:#333b46;
  --brass:#e0a63e; --brass-ink:#f0c778; --brass-bg:#231c0c;
  --new:#ff9f1c; --new-bg:#2a1c08; --wire:#8d97a6; --band:#141922; --focus:#7fb0ff;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 4px 16px rgba(0,0,0,.3);
}}
:root[data-theme="dark"]{
  color-scheme:dark;
  --ground:#0e1116; --panel:#161a21; --panel-2:#1c2129;
  --ink:#e7eaef; --ink-2:#c2c9d4; --muted:#929caa;
  --rule:#242a33; --rule-2:#333b46;
  --brass:#e0a63e; --brass-ink:#f0c778; --brass-bg:#231c0c;
  --new:#ff9f1c; --new-bg:#2a1c08; --wire:#8d97a6; --band:#141922; --focus:#7fb0ff;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 4px 16px rgba(0,0,0,.3);
}
*{box-sizing:border-box}
body{background:var(--ground);color:var(--ink);font-family:var(--sans);font-size:15px;
  line-height:1.6;-webkit-font-smoothing:antialiased}
.wrap{max-width:1500px;margin:0 auto;padding-inline:22px;padding-block:40px 80px}
code,.mono{font-family:var(--mono)}
p code,li code,.card code{background:var(--panel-2);border:1px solid var(--rule);border-radius:4px;
  padding:1px 5px;font-size:12.5px}

header.top{border-bottom:1px solid var(--rule);padding-bottom:26px;margin-bottom:28px}
.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
  color:var(--brass);font-weight:600;margin:0 0 10px}
h1{font-size:clamp(28px,4.6vw,42px);line-height:1.1;margin:0 0 12px;font-weight:700;
  letter-spacing:-.022em;text-wrap:balance}
.lede{font-size:17px;color:var(--ink-2);margin:0;max-width:66ch}
.stats{display:flex;flex-wrap:wrap;gap:10px;margin-top:22px}
.stat{background:var(--panel);border:1px solid var(--rule);border-radius:8px;padding:10px 16px;
  box-shadow:var(--shadow)}
.stat b{display:block;font-family:var(--mono);font-size:21px;font-weight:600;line-height:1.15;
  font-variant-numeric:tabular-nums}
.stat span{display:block;font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;
  color:var(--muted);margin-top:3px;font-weight:500}
.stat.new b{color:var(--new)}

section{margin-top:46px}
h2{font-size:13px;font-family:var(--mono);font-weight:600;letter-spacing:.11em;text-transform:uppercase;
  color:var(--muted);margin:0 0 6px;padding-bottom:8px;border-bottom:1px solid var(--rule)}
.sub{color:var(--ink-2);margin:12px 0 20px;max-width:76ch}

.cards{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(270px,1fr))}
.card{background:var(--panel);border:1px solid var(--rule);border-radius:10px;padding:15px 18px}
.card h3{margin:0 0 6px;font-size:14.5px;font-weight:600}
.card p{margin:0;font-size:13.5px;color:var(--ink-2);line-height:1.55}
.card.warn{border-color:var(--new);background:var(--new-bg)}

.tabs{display:flex;gap:0;border:1px solid var(--rule);border-radius:9px;overflow:hidden;width:max-content;
  max-width:100%;box-shadow:var(--shadow);margin:6px 0 22px}
.tabs button{font:600 13px var(--mono);color:var(--ink-2);background:var(--panel);border:0;
  border-right:1px solid var(--rule);padding:10px 16px;cursor:pointer}
.tabs button:last-child{border-right:0}
.tabs button[aria-selected="true"]{background:var(--brass-bg);color:var(--brass-ink)}
button:focus-visible,input:focus-visible{outline:2px solid var(--focus);outline-offset:2px}

ol.steps{margin:0 0 22px;padding-left:22px;max-width:86ch;color:var(--ink-2)}
ol.steps li{margin:4px 0}
ol.steps b{color:var(--ink)}

.figbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:10px}
.figbar .sp{flex:1}
.seg{display:flex;border:1px solid var(--rule);border-radius:8px;overflow:hidden}
.seg button{font:12px var(--mono);color:var(--ink-2);background:var(--panel);border:0;
  border-right:1px solid var(--rule);padding:8px 12px;cursor:pointer}
.seg button:last-child{border-right:0}
.seg button.on{background:var(--brass-bg);color:var(--brass-ink);font-weight:600}
.hint{font-size:12.5px;color:var(--muted)}
.btn{font:500 12.5px var(--sans);color:var(--ink-2);background:var(--panel);border:1px solid var(--rule);
  border-radius:8px;padding:8px 13px;cursor:pointer}
.btn:hover{color:var(--ink);border-color:var(--rule-2)}
.scroller{background:var(--panel);border:1px solid var(--rule);border-radius:12px;overflow:auto;
  padding:10px;max-height:80vh}
svg.schematic{display:block;height:auto}
figcaption{font-size:13px;color:var(--muted);margin-top:10px;max-width:84ch}

svg.dim .blk path,svg.dim .blk rect,svg.dim .blk text,svg.dim .blk circle{opacity:.22}
svg.dim .bands,svg.dim .ctrltable,svg.dim .legend-svg{opacity:.22}
svg.dim .wires path,svg.dim .wlabels text,svg.dim .dots circle{opacity:.1}
svg.dim path.hl{opacity:1!important;stroke:var(--focus)!important;stroke-width:3!important}
svg.dim text.hl{opacity:1!important;fill:var(--focus)!important;font-weight:600}
svg.dim circle.hl{opacity:1!important;fill:var(--focus)!important}
svg.dim .blk.hl path,svg.dim .blk.hl rect,svg.dim .blk.hl text,svg.dim .blk.hl circle{opacity:1}
svg.dim .blk.hl>rect,svg.dim .blk.hl>path{stroke:var(--focus)!important;stroke-width:2.2!important}

.toolbar{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:26px 0 12px}
.search{flex:1 1 240px;display:flex;align-items:center;background:var(--panel);border:1px solid var(--rule);
  border-radius:8px;padding:0 12px}
.search input{flex:1;border:0;background:transparent;color:var(--ink);font:13.5px var(--mono);
  padding:9px 0;outline:none;min-width:0}
.progress{display:flex;align-items:center;gap:10px;font:12.5px var(--mono);color:var(--muted);
  font-variant-numeric:tabular-nums}
.bar{width:120px;height:6px;border-radius:3px;background:var(--panel-2);border:1px solid var(--rule);overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--new);transition:width .18s}
.tablewrap{background:var(--panel);border:1px solid var(--rule);border-radius:12px;overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
thead th{text-align:left;font:600 10.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;
  color:var(--muted);padding:11px 13px;border-bottom:1px solid var(--rule-2);white-space:nowrap}
tbody td{padding:8px 13px;border-bottom:1px solid var(--rule);vertical-align:top}
tbody tr:last-child td{border-bottom:0}
tbody tr{cursor:pointer}
tbody tr:hover{background:var(--panel-2)}
tbody tr.sel{background:var(--brass-bg)}
tbody tr.done td{color:var(--muted)}
tbody tr.done .net{text-decoration:line-through}
td.chk{width:1%;padding-right:0}
td.chk input{width:16px;height:16px;accent-color:var(--new);cursor:pointer;margin-top:2px}
td.num{font-family:var(--mono);color:var(--muted);text-align:right;width:1%;font-variant-numeric:tabular-nums}
.net{font-family:var(--mono);font-weight:500;white-space:nowrap}
.wd{font:11.5px var(--mono);color:var(--muted);white-space:nowrap}
.ep{font:12.5px var(--mono);white-space:nowrap}
.ep .i{color:var(--brass-ink);font-weight:500}
.ep.pin{background:var(--panel-2);border:1px solid var(--rule);border-radius:4px;padding:1px 6px}
.ep .t{font-weight:700;color:var(--new)}
.chip{font:600 10px var(--mono);letter-spacing:.06em;text-transform:uppercase;border-radius:999px;
  padding:2px 8px;border:1px solid var(--new);color:var(--new);white-space:nowrap}
.chip.changed{border-style:dashed}
.empty{padding:22px;color:var(--muted);text-align:center}

.forms{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.form{background:var(--panel);border:1px solid var(--rule);border-radius:10px;padding:14px 16px;min-width:0}
.form header{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px}
.form h3{margin:0;font:600 14px var(--mono)}
.form dl{margin:0;display:grid;gap:6px}
.fld{display:grid;grid-template-columns:128px 1fr;gap:10px;align-items:start}
.fld dt{font-size:12px;color:var(--muted)}
.fld dd{margin:0;display:flex;gap:8px;align-items:flex-start;min-width:0}
.fld code{font-size:12px;color:var(--ink-2);overflow-wrap:anywhere}
.copy{font:11px var(--mono);color:var(--ink-2);background:var(--panel-2);border:1px solid var(--rule);
  border-radius:5px;padding:2px 7px;cursor:pointer;flex:none}
ol.after{max-width:86ch;color:var(--ink-2);padding-left:22px}
ol.after li{margin:6px 0}
footer{margin-top:56px;padding-top:20px;border-top:1px solid var(--rule);font-size:13px;color:var(--muted);max-width:96ch}
@media (max-width:640px){
  .wrap{padding-inline:16px;padding-block:28px 60px}
  .fld{grid-template-columns:1fr}
}
@media (prefers-reduced-motion:reduce){.bar i{transition:none}}
</style>

<div class="wrap">
<header class="top">
  <p class="eyebrow">ChipInventor &middot; RVBL-2 &middot; Stage 3 Part 1 &middot; GPIO + UART</p>
  <h1>RVBL-2 Stage 3 Wiring Map</h1>
  <p class="lede">What to change on the canvas, in the order to change it: the edits that turn a
  copy of the Phase 2 project into <code>@@SOC_NAME@@</code>, then the new chip project
  <code>top</code> around it. Click a wire in a checklist to trace it on the schematic; tick it
  once it is drawn. Ticks stay in this browser only.</p>
  <div class="stats">
    <div class="stat"><b>2</b><span>canvas projects</span></div>
    <div class="stat new"><b>@@N_NEW@@</b><span>wires to draw in the SoC</span></div>
    <div class="stat"><b>@@N_SOC@@</b><span>SoC connections in all</span></div>
    <div class="stat new"><b>@@N_TOP@@</b><span>chip-top connections</span></div>
    <div class="stat"><b>3</b><span>new blocks</span></div>
    @@CHECKS@@
  </div>
</header>

<section aria-labelledby="h-first">
  <h2 id="h-first">Before you wire anything</h2>
  <div class="cards">
    <div class="card warn"><h3>Copy the Phase 2 project first</h3>
      <p>The platform keeps no history. Make every Stage 3 edit on a copy; the graded project
      stays as it is.</p></div>
    <div class="card warn"><h3>Inout Pins: C is data, D is enable</h3>
      <p>The export writes <code>assign pin = D ? C : 1'bZ;</code>. Wire <code>cN_o</code> to
      <b>C</b> and <code>dN_o</code> to <b>D</b>. A swap still compiles, so the export checker
      tests every pin's polarity.</p></div>
    <div class="card"><h3>Name the SoC project <code>@@SOC_NAME@@</code></h3>
      <p>Its module in the export is named after the project, and both the checker and the
      FPGA wrapper look for that name.</p></div>
    <div class="card"><h3>One parameter to set</h3>
      <p>On the <code>uart</code> instance, <code>CLK_FREQ_HZ = 30303030</code> (the 33&nbsp;ns
      clock: 263 clocks per bit at 115200&nbsp;bps). Leave every other parameter blank; the
      block defaults are correct.</p></div>
  </div>
</section>

<section aria-labelledby="h-proj">
  <h2 id="h-proj">The two projects</h2>
  <div class="tabs" role="tablist" aria-label="Canvas project">
    <button type="button" role="tab" id="tab-soc" aria-selected="true" aria-controls="panel-soc">1 &middot; @@SOC_NAME@@</button>
    <button type="button" role="tab" id="tab-top" aria-selected="false" aria-controls="panel-top">2 &middot; top (the chip)</button>
  </div>

  <div id="panel-soc" role="tabpanel" aria-labelledby="tab-soc">
    <ol class="steps">
      <li>On the copy of the Phase 2 project, <b>delete the <code>imem</code> instance</b>; its three wires go with it.</li>
      <li><b>Make the new <code>address_decoder</code> block</b> (fields below), delete the old <code>u_decoder</code> and place the new one as <code>u_decoder</code>.</li>
      <li><b>Create <code>gpio</code> and <code>uart</code></b> (fields below), place one of each, and set <code>CLK_FREQ_HZ = 30303030</code> on the uart.</li>
      <li><b>Add the pins</b>: @@SOC_PINS@@.</li>
      <li><b>Draw the @@N_NEW@@ amber wires</b>: the Stage 3 wires and every wire on <code>u_decoder</code>. Every grey wire is already there from Phase 2.</li>
    </ol>
    <figure>
      <div class="figbar">
        <div class="seg" data-fig="soc" role="group" aria-label="Zoom">
          <button type="button" data-z="fit" class="on">Fit</button><button type="button" data-z="0.6">60%</button><button type="button" data-z="1">100%</button><button type="button" data-z="out" aria-label="Zoom out">&minus;</button><button type="button" data-z="in" aria-label="Zoom in">+</button>
        </div>
        <span class="hint" data-hint="soc"></span><span class="sp"></span>
        <button class="btn" type="button" data-clear="soc">Clear highlight</button>
      </div>
      <div class="scroller" id="sc-soc">@@SVG_SOC@@</div>
      <figcaption>Generated from <code>ci_top.v</code> by <code>gen_schematic.py</code>, which
      fails the build if a wire crosses a block or two nets share a line. Amber: to draw on the Phase 2 copy (new in Stage 3, or on the remade u_decoder).
      Control signals and clock/reset are shown as tagged pins, not routed.</figcaption>
    </figure>
    <div class="toolbar">
      <div class="seg" data-list="soc" role="group" aria-label="Which wires">
        <button type="button" data-f="new" class="on">Stage 3 edits (@@N_NEW@@)</button><button type="button" data-f="all">Whole project (@@N_SOC@@)</button>
      </div>
      <label class="search"><input id="q-soc" type="search" placeholder="Filter by net, block or port" aria-label="Filter SoC wires"></label>
      <div class="progress"><span id="pct-soc"></span><span class="bar"><i id="bar-soc"></i></span></div>
      <button class="btn" type="button" data-reset="soc">Reset ticks</button>
    </div>
    <div class="tablewrap"><table><thead><tr><th></th><th>#</th><th>Net</th><th>Width</th><th>From</th><th>To</th></tr></thead>
      <tbody id="tb-soc"></tbody></table></div>
    <p class="empty" id="none-soc" hidden>No wire matches that filter.</p>
  </div>

  <div id="panel-top" role="tabpanel" aria-labelledby="tab-top" hidden>
    <ol class="steps">
      <li><b>Create a new project <code>top</code></b> and place <code>@@SOC_NAME@@</code> from the IP list, <code>imem</code>, and the new <code>gpio_bits</code>.</li>
      <li><b>Add the pins</b> <code>clk_i</code>, <code>rst_i</code>, <code>rx_i</code> (inputs), <code>tx_o</code> (output) and eight <b>Inout Pins</b> <code>pins_io_0</code>&hellip;<code>pins_io_7</code>, one per GPIO bit.</li>
      <li><b>Draw the @@N_TOP@@ wires.</b> For each Inout Pin N: <code>cN_o</code> &rarr; C, <code>dN_o</code> &rarr; D, right-hand terminal &rarr; <code>pN_i</code>.</li>
    </ol>
    <figure>
      <div class="figbar">
        <div class="seg" data-fig="top" role="group" aria-label="Zoom">
          <button type="button" data-z="fit" class="on">Fit</button><button type="button" data-z="0.6">60%</button><button type="button" data-z="1">100%</button><button type="button" data-z="out" aria-label="Zoom out">&minus;</button><button type="button" data-z="in" aria-label="Zoom in">+</button>
        </div>
        <span class="hint" data-hint="top"></span><span class="sp"></span>
        <button class="btn" type="button" data-clear="top">Clear highlight</button>
      </div>
      <div class="scroller" id="sc-top">@@SVG_TOP@@</div>
      <figcaption>Every wire in this project is new. <code>clk_i</code> and <code>rst_i</code>
      are shown as tags on <code>u_soc</code>; wire them to the pins of the same name.</figcaption>
    </figure>
    <div class="toolbar">
      <label class="search"><input id="q-top" type="search" placeholder="Filter by net, block or port" aria-label="Filter chip wires"></label>
      <div class="progress"><span id="pct-top"></span><span class="bar"><i id="bar-top"></i></span></div>
      <button class="btn" type="button" data-reset="top">Reset ticks</button>
    </div>
    <div class="tablewrap"><table><thead><tr><th></th><th>#</th><th>Net</th><th>Width</th><th>From</th><th>To</th></tr></thead>
      <tbody id="tb-top"></tbody></table></div>
    <p class="empty" id="none-top" hidden>No wire matches that filter.</p>
  </div>
</section>

<section aria-labelledby="h-forms">
  <h2 id="h-forms">Add Block form fields</h2>
  <p class="sub">The three new blocks and the changed decoder. Paste the file named in Code
  unedited; every other block is exactly as in the Phase 2 project.</p>
  <div class="forms">@@FORMS@@</div>
</section>

<section aria-labelledby="h-after">
  <h2 id="h-after">After wiring</h2>
  <ol class="after">
    <li>In <code>top</code>, press <b>BLOCKS</b> and save the generated file as <code>chipinventor/export_stage3.v</code>.</li>
    <li>Run <code>bash chipinventor/scripts/run_ci.sh</code>. It audits the export against the verified design (every wire, both projects, pin polarity, parameters), then runs the whole platform testbench on the export itself.</li>
    <li>Paste <code>build/tb_platform.v</code>, which it writes with the export's instance names, into the platform's testbench field.</li>
  </ol>
</section>

<footer>Generated by <code>chipinventor/scripts/gen_wiring_map.py</code> from <code>ci_top.v</code>
and <code>blocks/*.v</code>, the same sources the local checks run on:
<code>ci_top.v</code> matches the frozen Phase 2 core cycle for cycle, and the platform testbench passes on it.
The Phase 2 wiring map remains the record for the graded project.</footer>
</div>

<script>
const DATA = @@DATA@@;
const store = {
  get(k){ try { return JSON.parse(localStorage.getItem(k) || "null"); } catch(e){ return null; } },
  set(k, v){ try { localStorage.setItem(k, JSON.stringify(v)); } catch(e){} }
};
const KEY = "rvbl2-s3-ticks-v1";
const ticks = new Set(store.get(KEY) || []);
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function ep(e){
  if (e.k === "pin") return '<span class="ep pin">pin ' + esc(e.t) + "</span>";
  if (e.k === "term") return '<span class="ep pin">pin ' + esc(e.t) + ' <span class="t">' + esc(e.x) +
    "</span> " + (e.x === "D" ? "enable" : "data") + "</span>";
  return '<span class="ep"><span class="i">' + esc(e.i) + "</span>." + esc(e.p) + "</span>";
}
function hay(r){
  const t = e => e.k === "port" ? e.i + "." + e.p : "pin " + e.t + (e.x ? " " + e.x : "");
  return (r.n + " " + t(r.s) + " " + t(r.d)).toLowerCase();
}

const P = {};
["soc", "top"].forEach(id => {
  P[id] = { rows: DATA[id], filter: id === "soc" ? "new" : "all", zoom: null,
            svg: document.querySelector("#sc-" + id + " svg"), sc: document.getElementById("sc-" + id),
            tb: document.getElementById("tb-" + id), q: document.getElementById("q-" + id) };
});

function render(id){
  const p = P[id], needle = p.q.value.trim().toLowerCase();
  let shown = 0, n = 0;
  p.tb.innerHTML = p.rows.map(r => {
    if (p.filter === "new" && !r.new) return "";
    if (needle && hay(r).indexOf(needle) === -1) return "";
    shown++; n++;
    const done = ticks.has(r.id);
    return '<tr class="' + (done ? "done" : "") + '" data-id="' + esc(r.id) + '" data-net="' + esc(r.n) + '">' +
      '<td class="chk"><input type="checkbox" ' + (done ? "checked " : "") + 'aria-label="Mark as drawn"></td>' +
      '<td class="num">' + n + "</td><td><span class=\"net\">" + esc(r.n) + "</span> " +
      (id === "soc" && r.new ? '<span class="chip">new</span>' : "") + "</td>" +
      '<td class="wd">' + esc(r.w) + "</td><td>" + ep(r.s) + "</td><td>" + ep(r.d) + "</td></tr>";
  }).join("");
  document.getElementById("none-" + id).hidden = shown > 0;
  progress(id);
}
function progress(id){
  const scope = P[id].rows.filter(r => P[id].filter === "all" || r.new);
  const done = scope.filter(r => ticks.has(r.id)).length;
  document.getElementById("pct-" + id).textContent = done + " / " + scope.length + " drawn";
  document.getElementById("bar-" + id).style.width = (scope.length ? 100 * done / scope.length : 0) + "%";
}

function fit(id){ return Math.min(1, (P[id].sc.clientWidth - 24) / DATA.w[id]); }
function applyZoom(id){
  const p = P[id], z = p.zoom === null ? fit(id) : p.zoom;
  p.svg.style.width = (DATA.w[id] * z) + "px";
  document.querySelector('[data-hint="' + id + '"]').textContent = p.zoom === null
    ? "Fitted to " + Math.round(fit(id) * 100) + "%. Zoom in to read port names." : "Scroll inside the frame to pan.";
}
document.querySelectorAll("[data-fig]").forEach(g => g.addEventListener("click", e => {
  const b = e.target.closest("button"); if (!b) return;
  const id = g.dataset.fig, p = P[id], v = b.dataset.z, cur = p.zoom === null ? fit(id) : p.zoom;
  p.zoom = v === "fit" ? null : v === "in" ? Math.min(2, cur * 1.3) : v === "out" ? Math.max(0.12, cur / 1.3) : parseFloat(v);
  g.querySelectorAll("button").forEach(x => x.classList.toggle("on", x === b && ["fit","0.6","1"].includes(v)));
  applyZoom(id);
}));

function highlight(id, row){
  const p = P[id];
  p.tb.querySelectorAll("tr").forEach(r => r.classList.toggle("sel", r === row));
  p.svg.querySelectorAll(".hl").forEach(el => el.classList.remove("hl"));
  if (!row){ p.svg.classList.remove("dim"); return; }
  const r = p.rows.find(x => x.id === row.dataset.id);
  p.svg.querySelectorAll('[data-net="' + CSS.escape(r.n) + '"]').forEach(el => el.classList.add("hl"));
  [r.si, r.di].forEach(i => { const g = p.svg.querySelector('.blk[data-inst="' + CSS.escape(i) + '"]'); if (g) g.classList.add("hl"); });
  p.svg.classList.add("dim");
}

["soc", "top"].forEach(id => {
  const p = P[id];
  p.tb.addEventListener("click", e => {
    const row = e.target.closest("tr"); if (!row) return;
    if (e.target.matches("input[type=checkbox]")){
      if (e.target.checked) ticks.add(row.dataset.id); else ticks.delete(row.dataset.id);
      row.classList.toggle("done", e.target.checked); store.set(KEY, [...ticks]); progress(id); return;
    }
    highlight(id, row.classList.contains("sel") ? null : row);
  });
  p.q.addEventListener("input", () => { highlight(id, null); render(id); });
  document.querySelector('[data-clear="' + id + '"]').addEventListener("click", () => highlight(id, null));
  document.querySelector('[data-reset="' + id + '"]').addEventListener("click", () => {
    p.rows.forEach(r => ticks.delete(r.id)); store.set(KEY, [...ticks]); render(id); highlight(id, null);
  });
  const seg = document.querySelector('[data-list="' + id + '"]');
  if (seg) seg.addEventListener("click", e => {
    const b = e.target.closest("button"); if (!b) return;
    p.filter = b.dataset.f; seg.querySelectorAll("button").forEach(x => x.classList.toggle("on", x === b));
    highlight(id, null); render(id);
  });
  render(id);
});

const tabs = [...document.querySelectorAll('[role="tab"]')];
function show(id){
  tabs.forEach(t => { const on = t.id === "tab-" + id; t.setAttribute("aria-selected", on); });
  ["soc", "top"].forEach(x => document.getElementById("panel-" + x).hidden = x !== id);
  applyZoom(id);
  try { sessionStorage.setItem("rvbl2-s3-tab", id); } catch(e){}
}
tabs.forEach(t => t.addEventListener("click", () => show(t.id.slice(4))));
let start = location.hash === "#top" ? "top" : "soc";
try { if (!location.hash) start = sessionStorage.getItem("rvbl2-s3-tab") || start; } catch(e){}
show(start);
addEventListener("resize", () => ["soc", "top"].forEach(id => { if (P[id].zoom === null) applyZoom(id); }));

document.querySelectorAll(".copy").forEach(b => b.addEventListener("click", () => {
  const done = () => { b.textContent = "Copied"; setTimeout(() => b.textContent = "Copy", 1400); };
  const fallback = () => { const r = document.createRange(); r.selectNodeContents(b.previousElementSibling);
    const s = getSelection(); s.removeAllRanges(); s.addRange(r); b.textContent = "Selected"; };
  try { navigator.clipboard.writeText(b.dataset.copy).then(done, fallback); } catch(e){ fallback(); }
}));
</script>
"""

if __name__ == "__main__":
    main()
