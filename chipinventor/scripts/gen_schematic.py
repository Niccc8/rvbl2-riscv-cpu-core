#!/usr/bin/env python3
"""Generate the two canvas schematics (SVG) from the design itself.

Hand-placing blocks and wires produces exactly the tangle you would expect.
This lays each project out the way a channel router does: blocks sit on a
column/row grid (several may stack in one cell), and every wire is routed
through reserved corridors between them, each corridor divided into tracks so
that no two nets ever share a line. Port coordinates, widths and directions all
come from blocks/*.v and ci_top.v, through the same parser check_export.py
uses, so the pictures cannot drift from the design or from the export audit.

Blocks are drawn like the platform renders them - inputs with pins down the left
edge, outputs down the right edge, name in the middle. Canvas pins are drawn as
pin symbols; an Inout Pin shows its C (data) and D (enable) terminals on the
left and its pad terminal on the right, exactly as on the canvas.

Two conventions keep the SoC readable:
  * Control signals are NOT routed. All of them come from u_ctrl to scattered
    destinations; they appear as named pins on the blocks that consume them,
    the off-page-connector convention real schematics use for high fan-out.
  * Clock and reset are tagged, not routed, on every block.

Stage 3 wires - the ones to add to the copy of the Phase 2 project - are drawn
in amber, so the SoC figure doubles as the edit list.

Outputs (build/):
    schematic.svg / schematic_{light,dark}.svg          the rvbl2_soc project
    schematic_top.svg / schematic_top_{light,dark}.svg  the chip project, top
The un-suffixed files use CSS variables, for the wiring-map page.

Usage: python gen_schematic.py [--check]
"""

import importlib.util
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

_spec = importlib.util.spec_from_file_location("gd", os.path.join(HERE, "gen_docs.py"))
gd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gd)

TAG_PINS = ("clk_i", "rst_i")      # tagged on every block, never routed

# ---------------------------------------------------------------------------
# Per-diagram configuration. PLACE maps an instance - or "pin:NAME" for a
# canvas pin - to (column, row) or (column, row, stack index). Column order is
# the dataflow order: a block sits to the right of what feeds it wherever
# possible, so forward wires never travel backwards.
# ---------------------------------------------------------------------------
SOC = dict(
    project=gd.SOC_NAME,
    out="schematic",
    place={
        "u_muxpc":   (0, 1),
        "u_pc":      (1, 1),
        "u_pcinc":   (2, 0),
        "pin:imem_rdata_i": (2, 1),
        "u_muxaddr": (2, 2),
        "pin:gpio_i": (3, 0, 0),
        "pin:rx_i":   (3, 0, 1),
        "u_decoder": (3, 1),
        "u_gpio":    (4, 0),
        "u_uart":    (4, 1),
        "u_dmem":    (4, 2),
        "pin:gpio_o":      (5, 0, 0),
        "pin:gpio_oe":     (5, 0, 1),
        "pin:tx_o":        (5, 1, 0),
        "pin:imem_addr_o": (5, 2, 0),
        "pin:imem_oe_o":   (5, 2, 1),
        "u_ir":      (6, 1),
        "u_irf":     (7, 0),
        "u_imm":     (7, 2),
        "u_rf":      (8, 1),
        # The execute units are all fed straight from the register file, so
        # they spread across two columns instead of stacking five deep.
        "u_muxa":    (9, 0),
        "u_muxb":    (9, 1),
        "u_bc":      (9, 2),
        "u_alu":     (10, 0),
        "u_mul":     (10, 1),
        "u_crc":     (10, 2),
        "u_lsu":     (11, 1),
        "u_wbmux":   (12, 1),
    },
    ctrl="u_ctrl",
    # u_ctrl has two routed inputs - ir from decode and branch_taken from
    # execute - so it sits mid-diagram to keep both short.
    ctrl_col=5,
    bands=[(0, 2, "Fetch"), (3, 5, "Memory system and peripherals"), (6, 7, "Decode"),
           (8, 8, "Registers"), (9, 10, "Execute"), (11, 12, "Memory access / writeback")],
    highlight=("u_gpio", "u_uart"),
    changed=("u_decoder",),
    mem=("u_dmem",),
    aria=("Schematic of the rvbl2_soc ChipInventor project: the RVBL-2 multicycle RISC-V "
          "core, data memory, GPIO and UART. Blocks run left to right in six stages - fetch, "
          "memory system and peripherals, decode, registers, execute, memory access and "
          "writeback - with inputs on each block's left edge and outputs on its right. The "
          "project's pins are drawn as pin symbols; wires added in Stage 3 are highlighted. "
          "The control unit sits underneath; its outputs appear as named pins on the blocks "
          "that consume them."),
)

TOP = dict(
    project="top",
    out="schematic_top",
    place={
        "pin:rx_i": (0, 1),
        "u_soc":    (1, 1),
        "u_imem":   (2, 0),
        "u_bits":   (2, 1),
        "pin:tx_o": (3, 0, 0),
    },
    ctrl=None,
    bands=[(1, 1, "SoC project (IP)"), (2, 2, "Chip blocks"), (3, 3, "Chip pins")],
    highlight=("u_bits",),
    changed=(),
    mem=("u_imem",),
    aria=("Schematic of the top ChipInventor project, the chip: the rvbl2_soc project placed "
          "as IP, the instruction ROM, and gpio_bits, which fans the GPIO buses out to eight "
          "Inout Pins. Each Inout Pin takes its data on C and its enable on D, and its pad "
          "terminal feeds back into gpio_bits."),
)
for _n in range(8):
    TOP["place"]["pin:pins_io_%d" % _n] = (3, 1, _n)

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
PITCH = 21          # vertical spacing between pins on a block edge
PAD_Y = 16          # space above the first pin and below the last
CW = 5.35           # width of one character at the 8.9px pin-label size
NAME_CW = 7.6       # width of one character at the 13px block-name size
MIN_W = 142
LABEL_GAP = 13      # clear space either side of the block name
PAD_X = 8           # gap between a block's edge and its pin labels
TRACK = 13          # spacing between routing tracks inside a corridor
LABEL_MIN_RUN = 210 # only label a wire whose straight run is at least this long
CH_PAD = 14         # dead space at each end of a corridor
ROW_GAP_MIN = 58    # smallest horizontal corridor
STACK_GAP = 16      # vertical gap between blocks stacked in one cell
MARGIN = 30
BAND_TOP = 26       # room above the diagram for the stage captions


def label(port, width):
    return port + ("" if width in ("1", "") else width)


class Block(object):
    def __init__(self, inst, module, ins, outs, drivers, pin=None):
        self.inst, self.module = inst, module
        self.pin = pin                 # None, or "input" / "output" / "inout"
        self.name = inst[4:] if pin else inst
        self.ins, self.outs = ins, outs
        # A pin is "tagged" when nothing is routed to it: control from u_ctrl,
        # and the clock and reset nets.
        self.tag = {}
        for p, _w in ins:
            src = drivers.get((inst, p))
            if p in TAG_PINS:
                self.tag[p] = "clk"
            elif src and src[0] == "u_ctrl":
                self.tag[p] = "ctrl"
        self.w = self.h = 0
        self.x = self.y = 0

    def measure(self):
        if self.pin:
            self.lpx = max([len(p) for p, _ in self.ins] or [0]) * CW
            self.rpx = max([len(p) for p, _ in self.outs] or [0]) * CW
            self.namew = len(self.name) * NAME_CW
            self.w = int(max(104, 2 * PAD_X + self.lpx + self.rpx + self.namew + 2 * LABEL_GAP + 14))
            self.h = int(max(len(self.ins), len(self.outs), 1) * PITCH + 2 * 12)
            return
        # The name sits in the clear channel between the two columns of pin
        # labels, not at the block's centre, so long names never collide with
        # their own labels.
        self.lpx = max([len(label(p, w)) for p, w in self.ins] or [0]) * CW
        self.rpx = max([len(label(p, w)) for p, w in self.outs] or [0]) * CW
        self.namew = max(len(self.name) * NAME_CW, len(self.module) * 6.4)
        self.w = int(max(MIN_W, 2 * PAD_X + self.lpx + self.rpx + self.namew + 2 * LABEL_GAP))
        self.h = int(max(max(len(self.ins), len(self.outs)) * PITCH + 2 * PAD_Y, 62))

    def pad(self):
        return 12 if self.pin else PAD_Y

    def name_cx(self):
        lo = self.x + PAD_X + self.lpx
        hi = self.x + self.w - PAD_X - self.rpx
        return (lo + hi) / 2.0

    def pin_y(self, idx):
        return self.y + self.pad() + idx * PITCH + PITCH / 2.0

    def in_xy(self, port):
        for i, (p, _w) in enumerate(self.ins):
            if p == port:
                return self.x, self.pin_y(i)
        raise KeyError("%s has no input %s" % (self.inst, port))

    def out_xy(self, port):
        for i, (p, _w) in enumerate(self.outs):
            if p == port:
                return self.x + self.w, self.pin_y(i)
        raise KeyError("%s has no output %s" % (self.inst, port))


class Channel(object):
    """A routing corridor divided into tracks; segments of one net may share."""

    def __init__(self):
        self.tracks = []          # list of list of (lo, hi, net)

    def alloc(self, lo, hi, net, clearance=10):
        lo, hi = min(lo, hi), max(lo, hi)
        for i, segs in enumerate(self.tracks):
            if all(s[2] == net or s[1] < lo - clearance or s[0] > hi + clearance
                   for s in segs):
                segs.append((lo, hi, net))
                return i
        self.tracks.append([(lo, hi, net)])
        return len(self.tracks) - 1

    def n(self):
        return max(1, len(self.tracks))


def to_endpoint(end):
    """A netlist endpoint as a (drawing instance, port) pair."""
    owner, port = end
    if owner == "PIN":
        return ("pin:" + port, "pad" if port.startswith("pins_io_") else "pin")
    if owner in ("C", "D"):
        return ("pin:" + port, owner)
    return end


def build(cfg):
    blocks_src = gd.load_blocks()
    ports = gd.port_table(blocks_src)
    proj = gd.load_project(cfg["project"])
    nets = gd.build_netlist(proj, ports)
    new = set()
    if cfg["project"] == gd.SOC_NAME:
        new = {(n, to_endpoint(d)) for n, _w, _s, d in gd.phase2_delta(proj, nets)}
    # (in `top` every wire is new, so none is singled out)

    drivers = {}
    for e in nets.values():
        if e["src"]:
            for sink in e["sinks"]:
                drivers[to_endpoint(sink)] = to_endpoint(e["src"])

    B = {}
    for module, inst, _params, _conns in proj["instances"]:
        io = ports[module]
        B[inst] = Block(inst, module,
                        [(p, w) for p, (d, w) in io.items() if d == "input"],
                        [(p, w) for p, (d, w) in io.items() if d == "output"], drivers)
    tri = {pin for pin, _, _ in proj["tris"]}
    for d, w, pin in proj["ports"]:
        if pin in TAG_PINS:
            continue
        key = "pin:" + pin
        if pin in tri:
            B[key] = Block(key, "inout pin", [("C", ""), ("D", "")], [("pad", "")], drivers, "inout")
        elif d == "input":
            B[key] = Block(key, "input pin" + (" " + w if w else ""), [], [("pin", w)], drivers, "input")
        else:
            B[key] = Block(key, "output pin" + (" " + w if w else ""), [("pin", w)], [], drivers, "output")
    missing = set(B) - set(cfg["place"]) - {cfg["ctrl"]}
    if missing:
        sys.exit("gen_schematic: no placement for %s" % ", ".join(sorted(missing)))
    for b in B.values():
        b.measure()
    return B, nets, new


def cell(cfg, inst):
    p = cfg["place"][inst]
    return (p[0], p[1], p[2] if len(p) > 2 else 0)


def route(B, nets, cfg):
    """Every routed wire as (net, src inst, src port, dst inst, dst port)."""
    routes = []
    for name in sorted(nets):
        e = nets[name]
        if not e["src"] or not e["sinks"]:
            continue
        si, sp = to_endpoint(e["src"])
        if si == "pin:" + name and name in TAG_PINS:
            continue
        for sink in sorted(e["sinks"]):
            di, dp = to_endpoint(sink)
            if di not in B or si not in B:
                continue
            if B[di].tag.get(dp):          # control or clock pin: shown as a tag
                continue
            routes.append((name, si, sp, di, dp))
    return routes


def layout(B, routes, cfg):
    place = cfg["place"]
    ctrl = cfg["ctrl"]
    ncols = max(v[0] for v in place.values()) + 1
    nrows = max(v[1] for v in place.values()) + 1
    vch = [Channel() for _ in range(ncols + 1)]
    hch = [Channel() for _ in range(nrows + 2)]   # +1 for the band under u_ctrl

    colw = [0] * ncols
    cells = {}
    for inst in place:
        c, r, k = cell(cfg, inst)
        colw[c] = max(colw[c], B[inst].w)
        cells.setdefault((c, r), []).append((k, inst))
    for v in cells.values():
        v.sort()
    cellh = {k: sum(B[i].h for _, i in v) + STACK_GAP * (len(v) - 1) for k, v in cells.items()}
    rowh = [max([h for (c, r), h in cellh.items() if r == row] or [0]) for row in range(nrows)]

    def do_place(vsize, hsize):
        xs, x = [], MARGIN
        for c in range(ncols):
            x += vsize[c]
            xs.append(x)
            x += colw[c]
        x += vsize[ncols]
        ys, y = [], MARGIN + BAND_TOP
        for r in range(nrows):
            y += hsize[r]
            ys.append(y)
            y += rowh[r]
        y += hsize[nrows]
        cy = y
        if ctrl:
            y += B[ctrl].h + hsize[nrows + 1]
        for (c, r), v in cells.items():
            yy = ys[r] + (rowh[r] - cellh[(c, r)]) // 2
            for _, inst in v:
                B[inst].x = xs[c] + (colw[c] - B[inst].w if B[inst].pin == "output" else 0)
                B[inst].y = yy
                yy += B[inst].h + STACK_GAP
        if ctrl:
            B[ctrl].x = xs[cfg["ctrl_col"]]
            B[ctrl].y = cy
        return xs, ys, cy, x, y

    xs, ys, cy, W, H = do_place([90] * (ncols + 1), [ROW_GAP_MIN] * (nrows + 2))

    # -- topology first, tracks second --------------------------------------
    # A net that fans out shares one vertical trunk, so every track is booked
    # over the union of the runs that use it.
    def prov_hy(hc):
        return ys[hc] if hc < nrows else (cy if hc == nrows else H)

    def prov_vx(c):
        return (xs[c] - 45.0) if c < ncols else W

    plans = []
    for name, si, sp, di, dp in routes:
        sx, sy = B[si].out_xy(sp)
        dx, dy = B[di].in_xy(dp)
        sc = cell(cfg, si)[0] if si != ctrl else cfg["ctrl_col"]
        dc = cell(cfg, di)[0] if di != ctrl else cfg["ctrl_col"]
        dr = cell(cfg, di)[1] if di != ctrl else nrows + 1
        vc, vc2 = sc + 1, dc
        p = dict(net=name, si=si, sp=sp, di=di, dp=dp, sx=sx, sy=sy, dx=dx, dy=dy, vc=vc)
        if vc == vc2:
            p.update(kind="Z")
        else:
            p.update(kind="U", hc=dr, vc2=vc2)
        plans.append(p)

    def span(d, k, lo, hi):
        d[k] = (min(d[k][0], lo), max(d[k][1], hi)) if k in d else (lo, hi)

    trunk_y, hseg_x, vin_y = {}, {}, {}
    for p in plans:
        span(trunk_y, (p["net"], p["vc"]), p["sy"], p["sy"])
        if p["kind"] == "Z":
            span(trunk_y, (p["net"], p["vc"]), p["dy"], p["dy"])
        else:
            hy_p = prov_hy(p["hc"])
            span(trunk_y, (p["net"], p["vc"]), hy_p, hy_p)
            span(hseg_x, (p["net"], p["hc"]),
                 min(prov_vx(p["vc"]), prov_vx(p["vc2"])), max(prov_vx(p["vc"]), prov_vx(p["vc2"])))
            span(vin_y, (p["net"], p["vc2"]), min(hy_p, p["dy"]), max(hy_p, p["dy"]))

    tt = {k: vch[k[1]].alloc(v[0], v[1], k[0]) for k, v in trunk_y.items()}
    th = {k: hch[k[1]].alloc(v[0], v[1], k[0]) for k, v in hseg_x.items()}
    tv = {k: vch[k[1]].alloc(v[0], v[1], k[0]) for k, v in vin_y.items()}
    for p in plans:
        p["vt"] = tt[(p["net"], p["vc"])]
        if p["kind"] == "U":
            p["ht"] = th[(p["net"], p["hc"])]
            p["vt2"] = tv[(p["net"], p["vc2"])]

    # -- final geometry from the track counts --------------------------------
    vsize = [max(58, vch[c].n() * TRACK + 2 * CH_PAD) for c in range(ncols + 1)]
    hsize = [max(ROW_GAP_MIN, hch[r].n() * TRACK + 2 * CH_PAD) for r in range(nrows + 2)]
    hsize[0] = max(hsize[0], 54)
    if not ctrl:
        hsize[nrows + 1] = 0
    xs, ys, cy, W, H = do_place(vsize, hsize)

    def vx(c, t):
        base = xs[c] - vsize[c] if c < ncols else W - vsize[c]
        return base + CH_PAD + t * TRACK

    def hy(r, t):
        if r < nrows:
            base = ys[r] - hsize[r]
        elif r == nrows:
            base = cy - hsize[nrows]
        else:
            base = B[ctrl].y + B[ctrl].h
        return base + CH_PAD + t * TRACK

    # Only the topology carries over from the provisional grid; every
    # coordinate is re-read from the blocks at their final positions.
    for p in plans:
        sx, sy = B[p["si"]].out_xy(p["sp"])
        dx, dy = B[p["di"]].in_xy(p["dp"])
        if p["kind"] == "Z":
            x = vx(p["vc"], p["vt"])
            p["pts"] = [(sx, sy), (x, sy), (x, dy), (dx, dy)]
        else:
            x1, x2 = vx(p["vc"], p["vt"]), vx(p["vc2"], p["vt2"])
            y = hy(p["hc"], p["ht"])
            p["pts"] = [(sx, sy), (x1, sy), (x1, y), (x2, y), (x2, dy), (dx, dy)]
    return plans, xs, ys, W, H, colw, rowh, vsize, hsize


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def segments(p):
    return list(zip(p["pts"], p["pts"][1:]))


def validate(B, plans):
    problems = []
    # 1. No wire may run through a block (touching an edge is how it reaches a pin).
    rects = [(b.x, b.y, b.x + b.w, b.y + b.h, b.inst) for b in B.values()]
    for p in plans:
        for (x1, y1), (x2, y2) in segments(p):
            lo_x, hi_x = min(x1, x2), max(x1, x2)
            lo_y, hi_y = min(y1, y2), max(y1, y2)
            for bx1, by1, bx2, by2, inst in rects:
                if hi_x <= bx1 + 0.5 or lo_x >= bx2 - 0.5:
                    continue
                if hi_y <= by1 + 0.5 or lo_y >= by2 - 0.5:
                    continue
                problems.append("net %s crosses block %s" % (p["net"], inst))
    # 2. No two different nets may run along the same line.
    horiz, vert = {}, {}
    for p in plans:
        for (x1, y1), (x2, y2) in segments(p):
            if abs(y1 - y2) < 0.5:
                horiz.setdefault(round(y1, 1), []).append((min(x1, x2), max(x1, x2), p["net"]))
            elif abs(x1 - x2) < 0.5:
                vert.setdefault(round(x1, 1), []).append((min(y1, y2), max(y1, y2), p["net"]))
    for coord, segs in list(horiz.items()) + list(vert.items()):
        for i in range(len(segs)):
            for j in range(i + 1, len(segs)):
                a, b = segs[i], segs[j]
                if a[2] != b[2] and a[0] < b[1] - 1 and b[0] < a[1] - 1:
                    problems.append("nets %s and %s overlap at %s" % (a[2], b[2], coord))
    # 3. Blocks may not overlap each other.
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            a, b = rects[i], rects[j]
            if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
                problems.append("blocks %s and %s overlap" % (a[4], b[4]))
    return sorted(set(problems))


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
THEMED = {
    "ink": "var(--ink)", "ink2": "var(--ink-2)", "muted": "var(--muted)",
    "rule": "var(--rule-2)", "panel": "var(--panel-2)", "panel1": "var(--panel)",
    "brass": "var(--brass)", "brassbg": "var(--brass-bg)", "brassink": "var(--brass-ink)",
    "wire": "var(--wire)", "band": "var(--band)", "new": "var(--new)",
}
LIGHT = {
    "ink": "#161b22", "ink2": "#3a434f", "muted": "#5c6673", "rule": "#c6cdd8",
    "panel": "#eef1f5", "panel1": "#ffffff", "brass": "#8a5d0c",
    "brassbg": "#fbf3e2", "brassink": "#6d4a09", "wire": "#4a5462", "band": "#f0f2f6",
    "new": "#c26a00",
}
DARK = {
    "ink": "#e7eaef", "ink2": "#c2c9d4", "muted": "#929caa", "rule": "#333b46",
    "panel": "#1c2129", "panel1": "#161a21", "brass": "#e0a63e",
    "brassbg": "#231c0c", "brassink": "#f0c778", "wire": "#8d97a6", "band": "#141922",
    "new": "#ff9f1c",
}


def emit(B, plans, geom, cfg, new, ctrl_fanout, C, bg=None):
    xs, ys, W, H, colw, rowh, vsize, hsize = geom
    o = []
    a = o.append
    a('<svg class="schematic" id="sch-%s" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" '
      'role="img" aria-label="%s">' % (cfg["project"], W, H, cfg["aria"]))
    a('<defs>')
    for mid, col in (("ah", C["wire"]), ("ahn", C["new"])):
        a('<marker id="%s-%s" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="6.5" '
          'markerHeight="6.5" orient="auto-start-reverse"><path d="M0,1.2 L8.6,5 L0,8.8 z" '
          'fill="%s"/></marker>' % (mid, cfg["project"], col))
    a('</defs>')
    if bg:
        a('<rect width="%d" height="%d" fill="%s"/>' % (W, H, bg))

    # Stage bands, alternating tints.
    a('<g class="bands">')
    band_top = MARGIN + BAND_TOP - 10
    band_bot = ys[len(rowh) - 1] + rowh[-1] + 12
    for i, (c0, c1, name) in enumerate(cfg["bands"]):
        x0 = xs[c0] - vsize[c0] + 6
        x1 = xs[c1] + colw[c1] + vsize[c1 + 1] - 6
        if i % 2 == 0:
            a('<rect x="%d" y="%d" width="%d" height="%d" rx="9" fill="%s"/>'
              % (x0, band_top, x1 - x0, band_bot - band_top, C["band"]))
        a('<text x="%d" y="%d" text-anchor="middle" font-family="var(--mono)" font-size="10.5" '
          'font-weight="600" letter-spacing="1.6" fill="%s">%s</text>'
          % ((x0 + x1) / 2, MARGIN + 8, C["muted"], name.upper()))
    a('</g>')

    # wires: Stage 3 wires in amber, drawn last so they sit on top
    a('<g class="wires" fill="none" stroke-linejoin="round" stroke-linecap="round">')
    for p in sorted(plans, key=lambda q: (q["net"], (q["di"], q["dp"])) in new):
        d = "M" + " L".join("%.1f,%.1f" % pt for pt in p["pts"])
        wide = nets_width.get(p["net"], "") == "[31:0]"
        is_new = (p["net"], (p["di"], p["dp"])) in new
        a('<path class="w%s" data-net="%s" d="%s" stroke="%s" stroke-width="%s" '
          'marker-end="url(#%s-%s)"/>'
          % (" new" if is_new else "", p["net"], d, C["new"] if is_new else C["wire"],
             ("2.1" if wide else "1.5") if is_new else ("1.7" if wide else "1.15"),
             "ahn" if is_new else "ah", cfg["project"]))
    a('</g>')

    # junction dots where a trunk fans out
    a('<g class="dots">')
    seen = {}
    for p in plans:
        seen.setdefault(p["net"], []).append(p)
    for net, ps in seen.items():
        if len(ps) < 2:
            continue
        counts = {}
        for p in ps:
            for pt in p["pts"][1:-1]:
                k = (round(pt[0], 1), round(pt[1], 1))
                counts.setdefault(k, []).append((p["net"], (p["di"], p["dp"])) in new)
        for (x, y), flags in counts.items():
            if len(flags) >= 2:
                a('<circle class="jn" data-net="%s" cx="%.1f" cy="%.1f" r="3.1" fill="%s"/>'
                  % (net, x, y, C["new"] if all(flags) else C["wire"]))
    a('</g>')

    # wire labels, one per net, on its longest horizontal run
    a('<g class="wlabels">')
    placed = set()
    for p in sorted(plans, key=lambda q: -run_len(q)):
        if p["net"] in placed:
            continue
        seg = longest_horizontal(p)
        if not seg:
            continue
        (x1, y1), (x2, _y2) = seg
        text = p["net"] + " " + nets_width.get(p["net"], "")
        if abs(x2 - x1) < max(LABEL_MIN_RUN, len(text) * 5.4 + 12):
            continue
        placed.add(p["net"])
        a('<text class="wl" data-net="%s" x="%.1f" y="%.1f" text-anchor="middle" '
          'font-family="var(--mono)" font-size="9" fill="%s">%s</text>'
          % (p["net"], (x1 + x2) / 2, y1 - 4.5, C["muted"], text.strip()))
    a('</g>')

    # blocks and pins
    a('<g class="blocks">')
    order = list(cfg["place"]) + ([cfg["ctrl"]] if cfg["ctrl"] else [])
    for inst in order:
        b = B[inst]
        if b.pin:
            emit_pin(a, b, C)
            continue
        cls, stroke, fill, sw = "blk", C["rule"], C["panel"], "1.2"
        if inst in cfg["highlight"]:
            cls += " new"; stroke, sw = C["new"], "1.9"
        elif inst in cfg["changed"]:
            cls += " changed"; stroke, sw = C["new"], "1.4"
        elif inst in cfg["mem"]:
            cls += " mem"; fill, sw = C["panel1"], "1.5"
        elif inst == cfg["ctrl"]:
            cls += " ctrl"; stroke, fill, sw = C["brass"], C["brassbg"], "1.5"
        a('<g class="%s" data-inst="%s">' % (cls, inst))
        dash = ' stroke-dasharray="6 3"' if inst in cfg["changed"] else ""
        a('<rect x="%d" y="%d" width="%d" height="%d" rx="7" fill="%s" stroke="%s" '
          'stroke-width="%s"%s/>' % (b.x, b.y, b.w, b.h, fill, stroke, sw, dash))
        cx, cy = b.name_cx(), b.y + b.h / 2.0
        a('<text class="bn" x="%.1f" y="%.1f" text-anchor="middle" font-family="var(--mono)" '
          'font-size="12.5" font-weight="600" fill="%s">%s</text>' % (cx, cy - 3, C["ink"], inst))
        a('<text class="bm" x="%.1f" y="%.1f" text-anchor="middle" font-family="var(--sans)" '
          'font-size="9" fill="%s">%s</text>' % (cx, cy + 10, C["muted"], b.module))
        for i, (p, w) in enumerate(b.ins):
            y = b.pin_y(i)
            kind = b.tag.get(p)
            col = C["brass"] if kind == "ctrl" else (C["muted"] if kind == "clk" else C["wire"])
            a('<circle cx="%d" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
              % (b.x, y, C["panel1"], col))
            if kind:
                a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.1" '
                  'stroke-dasharray="2.5 2" fill="none"/>' % (b.x - 11, y, b.x - 3, y, col))
            a('<text x="%.1f" y="%.1f" text-anchor="start" font-family="var(--mono)" '
              'font-size="8.9" fill="%s">%s</text>'
              % (b.x + PAD_X, y + 3, C["brassink"] if kind == "ctrl" else C["ink2"], label(p, w)))
        for i, (p, w) in enumerate(b.outs):
            y = b.pin_y(i)
            a('<circle cx="%d" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
              % (b.x + b.w, y, C["panel1"], C["wire"]))
            a('<text x="%.1f" y="%.1f" text-anchor="end" font-family="var(--mono)" '
              'font-size="8.9" fill="%s">%s</text>' % (b.x + b.w - PAD_X, y + 3, C["ink2"], label(p, w)))
        a('</g>')
    a('</g>')

    if cfg["ctrl"]:
        emit_ctrl_extras(a, B[cfg["ctrl"]], ctrl_fanout, C)
    else:
        emit_top_extras(a, B, W, H, C)
    a('</svg>')
    return "\n".join(o)


def emit_pin(a, b, C):
    """A canvas pin: a tag-shaped outline, pointed on the side the signal leaves."""
    x0, y0, x1, y1 = b.x, b.y, b.x + b.w, b.y + b.h
    t = 12
    if b.pin in ("input", "output"):   # points the way the signal flows: right
        pts = [(x0, y0), (x1 - t, y0), (x1, (y0 + y1) / 2), (x1 - t, y1), (x0, y1)]
    else:                              # inout: pointed both ends
        pts = [(x0 + t, y0), (x1 - t, y0), (x1, (y0 + y1) / 2), (x1 - t, y1), (x0 + t, y1),
               (x0, (y0 + y1) / 2)]
    a('<g class="blk pin" data-inst="%s">' % b.inst)
    a('<path d="M%s z" fill="%s" stroke="%s" stroke-width="1.4"/>'
      % (" L".join("%.1f,%.1f" % p for p in pts), C["panel1"], C["ink2"]))
    cx = (x0 + x1) / 2.0 + (4 if b.pin != "output" else -2)
    if b.pin == "inout":
        cx = b.x + PAD_X + b.lpx + (b.w - 2 * PAD_X - b.lpx - b.rpx) / 2.0
    a('<text class="bn" x="%.1f" y="%.1f" text-anchor="middle" font-family="var(--mono)" '
      'font-size="11.5" font-weight="600" fill="%s">%s</text>' % (cx, (y0 + y1) / 2 - 1, C["ink"], b.name))
    a('<text class="bm" x="%.1f" y="%.1f" text-anchor="middle" font-family="var(--sans)" '
      'font-size="8.5" fill="%s">%s</text>' % (cx, (y0 + y1) / 2 + 10, C["muted"], b.module))
    for i, (p, _w) in enumerate(b.ins):
        y = b.pin_y(i)
        a('<circle cx="%d" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
          % (b.x, y, C["panel1"], C["wire"]))
        if b.pin == "inout":
            a('<text x="%.1f" y="%.1f" text-anchor="start" font-family="var(--mono)" '
              'font-size="9.5" font-weight="600" fill="%s">%s</text>'
              % (b.x + PAD_X + 4, y + 3.5, C["brassink"], p))
    for i, (p, _w) in enumerate(b.outs):
        y = b.pin_y(i)
        a('<circle cx="%d" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
          % (b.x + b.w, y, C["panel1"], C["wire"]))
    a('</g>')


def legend_rows(a, lx, ly, rows, C):
    for i, (kind, text) in enumerate(rows):
        yy = ly + 26 + i * 22
        if kind in ("wire32", "wire", "new"):
            col = C["new"] if kind == "new" else C["wire"]
            a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="%s" fill="none"/>'
              % (lx, yy, lx + 30, yy, col, "2.1" if kind == "new" else ("1.7" if kind == "wire32" else "1.15")))
        elif kind == "dot":
            a('<path d="M%.1f,%.1f L%.1f,%.1f M%.1f,%.1f L%.1f,%.1f" stroke="%s" '
              'stroke-width="1.4" fill="none"/>'
              % (lx, yy, lx + 30, yy, lx + 15, yy - 8, lx + 15, yy + 8, C["wire"]))
            a('<circle cx="%.1f" cy="%.1f" r="3.1" fill="%s"/>' % (lx + 15, yy, C["wire"]))
        elif kind == "newblk":
            a('<rect x="%.1f" y="%.1f" width="30" height="13" rx="3" fill="none" '
              'stroke="%s" stroke-width="1.9"/>' % (lx, yy - 7, C["new"]))
        elif kind == "chgblk":
            a('<rect x="%.1f" y="%.1f" width="30" height="13" rx="3" fill="none" stroke="%s" '
              'stroke-width="1.4" stroke-dasharray="6 3"/>' % (lx, yy - 7, C["new"]))
        elif kind == "pinglyph":
            a('<path d="M%.1f,%.1f L%.1f,%.1f L%.1f,%.1f L%.1f,%.1f L%.1f,%.1f z" fill="none" '
              'stroke="%s" stroke-width="1.4"/>'
              % (lx, yy - 7, lx + 22, yy - 7, lx + 30, yy, lx + 22, yy + 7, lx, yy + 7, C["ink2"]))
        else:
            col = C["brass"] if kind == "ctrlpin" else C["muted"]
            a('<circle cx="%.1f" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
              % (lx + 22, yy, C["panel1"], col))
            a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.1" '
              'stroke-dasharray="2.5 2" fill="none"/>' % (lx + 6, yy, lx + 18, yy, col))
        a('<text x="%.1f" y="%.1f" font-family="var(--sans)" font-size="10.5" fill="%s">'
          '%s</text>' % (lx + 42, yy + 3.5, C["ink2"], text))


CTRL_TABLE_X = 470       # offset from the left margin: between the legend and u_ctrl
CTRL_TABLE_W = 2 * 368
CTRL_TABLE_H = 30 + 7 * 34


def ctrl_table_rect(cb):
    x, y = MARGIN + CTRL_TABLE_X, cb.y + 4 - 14
    return x, y, x + CTRL_TABLE_W, y + CTRL_TABLE_H


def emit_ctrl_extras(a, cb, ctrl_fanout, C):
    tx, ty = MARGIN + CTRL_TABLE_X, cb.y + 4
    lx, ly = MARGIN + 6, cb.y + 4
    a('<g class="legend-svg">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" font-weight="600" '
      'letter-spacing="1.2" fill="%s">HOW TO READ THIS</text>' % (lx, ly, C["muted"]))
    legend_rows(a, lx, ly, [
        ("new", "wire to draw on the Phase 2 copy (Stage 3, or on u_decoder)"),
        ("wire32", "32-bit bus, unchanged from Phase 2"),
        ("wire", "narrow bus or single strobe"),
        ("dot", "junction - a dot means connected, a bare crossing does not"),
        ("pinglyph", "project pin (canvas Input / Output Pin)"),
        ("newblk", "block new in Stage 3 (gpio, uart)"),
        ("chgblk", "block remade in Stage 3 (address_decoder: redraw all its wires)"),
        ("ctrlpin", "control pin, driven by u_ctrl (see the fan-out table)"),
        ("clkpin", "clk_i / rst_i: wire to the project pin of the same name"),
    ], C)
    a('</g>')
    a('<g class="ctrltable">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" font-weight="600" '
      'letter-spacing="1.2" fill="%s">CONTROL FAN-OUT &#8212; shown as pins on each block, '
      'not routed</text>' % (tx, ty, C["brass"]))
    for i, (sig, dests) in enumerate(ctrl_fanout):
        cx = tx + (i // 7) * 368
        cy2 = ty + 26 + (i % 7) * 34
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9.6" font-weight="600" '
          'fill="%s">%s</text>' % (cx, cy2, C["brassink"], sig))
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9" fill="%s">'
          '&#8594; %s</text>' % (cx + 10, cy2 + 13, C["muted"], dests))
    a('</g>')


def emit_top_extras(a, B, W, H, C):
    lx, ly = MARGIN + 6, H - 170
    a('<g class="legend-svg">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" font-weight="600" '
      'letter-spacing="1.2" fill="%s">HOW TO READ THIS</text>' % (lx, ly, C["muted"]))
    legend_rows(a, lx, ly, [
        ("wire32", "32-bit bus (every wire in this project is new in Stage 3)"),
        ("wire", "narrow bus or single bit"),
        ("pinglyph", "Inout Pin: C = data, D = enable, pad (right terminal) feeds back"),
        ("clkpin", "clk_i / rst_i: wire to the project pin of the same name"),
        ("newblk", "block new in Stage 3 (gpio_bits)"),
    ], C)
    a('</g>')


def run_len(p):
    return sum(abs(x2 - x1) for (x1, _), (x2, _) in segments(p))


def longest_horizontal(p):
    best, blen = None, 0
    for (x1, y1), (x2, y2) in segments(p):
        if abs(y1 - y2) < 0.5 and abs(x2 - x1) > blen:
            best, blen = ((x1, y1), (x2, y2)), abs(x2 - x1)
    return best


nets_width = {}


def generate(cfg, check):
    B, nets, new = build(cfg)
    for n, e in nets.items():
        nets_width[n] = e["width"]
    ctrl_fanout = []
    if cfg["ctrl"]:
        for port, _w in B[cfg["ctrl"]].outs:
            e = nets.get(port)
            if not e:
                continue
            if e["sinks"]:
                ctrl_fanout.append((port, "  ".join("%s.%s" % s for s in sorted(e["sinks"]))))
            else:
                ctrl_fanout.append((port, "unconnected &#8212; read by the testbench"))
    routes = route(B, nets, cfg)
    plans, xs, ys, W, H, colw, rowh, vsize, hsize = layout(B, routes, cfg)
    if not cfg["ctrl"]:
        H += 170                   # room for the legend under the chip diagram
    problems = validate(B, plans)
    if cfg["ctrl"]:
        # The control table is text: no wire may run through it either.
        x1, y1, x2, y2 = ctrl_table_rect(B[cfg["ctrl"]])
        if x2 > B[cfg["ctrl"]].x - 20:
            problems.append("control table runs into u_ctrl")
        for p in plans:
            for (ax, ay), (bx, by) in segments(p):
                if min(ax, bx) < x2 and max(ax, bx) > x1 and min(ay, by) < y2 and max(ay, by) > y1:
                    problems.append("net %s crosses the control table" % p["net"])
        problems = sorted(set(problems))
    for p in problems[:25]:
        print("LAYOUT %s: %s" % (cfg["project"], p), file=sys.stderr)
    geom = (xs, ys, W, H, colw, rowh, vsize, hsize)

    out = os.path.join(ROOT, "build")
    os.makedirs(out, exist_ok=True)
    for suffix, C, bg in (("", THEMED, None), ("_light", LIGHT, "#ffffff"),
                          ("_dark", DARK, "#161a21")):
        svg = emit(B, plans, geom, cfg, new, ctrl_fanout, C, bg)
        if suffix:
            svg = svg.replace("var(--mono)", "IBM Plex Mono, monospace")
            svg = svg.replace("var(--sans)", "IBM Plex Sans, sans-serif")
        with io.open(os.path.join(out, cfg["out"] + suffix + ".svg"), "w", encoding="utf-8") as fh:
            fh.write(svg)
    n_new = sum(1 for p in plans if (p["net"], (p["di"], p["dp"])) in new)
    print("%s  %s: canvas %dx%d, %d blocks/pins, %d routed wires (%d new)%s"
          % ("OK  " if not problems else "FAIL", cfg["project"], W, H, len(B), len(plans), n_new,
             "" if not problems else ", %d layout problem(s)" % len(problems)))
    return not problems


def main():
    check = "--check" in sys.argv
    ok = all([generate(SOC, check), generate(TOP, check)])
    if ok:
        print("OK   layout clean: no wire crosses a block, no two nets share a line")
    if check and not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
