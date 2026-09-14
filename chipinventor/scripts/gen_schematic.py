#!/usr/bin/env python3
"""Generate the datapath schematic SVG from the design itself.

Hand-placing 20 blocks and 70-odd wires produces exactly the tangle you would
expect. This lays the diagram out the way a channel router does: blocks sit on a
column/row grid, and every wire is routed through reserved corridors between
them, with each corridor divided into tracks so that no two nets ever share a
line. Port coordinates, widths and directions all come from blocks/*.v and
ci_top.v, so the picture cannot drift from the design.

Blocks are drawn like the platform renders them - inputs with pins down the left
edge, outputs down the right edge, name in the middle.

Control signals are deliberately NOT routed. All thirteen of them come from one
block to scattered destinations, and drawing them is what turns a readable
schematic into a hairball. They appear instead as named pins on the blocks that
consume them, which is the off-page-connector convention every real schematic
uses for high-fanout control.

Outputs:
    build/schematic.svg        themed with CSS variables, for the artifact
    build/schematic_light.svg  literal colours, for rendering a preview
    build/schematic_dark.svg   likewise

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

# ---------------------------------------------------------------------------
# Placement. Column order is the dataflow order; a block may only sit to the
# right of everything that feeds it, so that forward wires never travel
# backwards. Rows stack blocks that are fed from the same place.
# ---------------------------------------------------------------------------
PLACE = {
    "u_muxpc":   (0, 1),
    "u_pc":      (1, 1),
    "u_pcinc":   (2, 0),
    "u_muxaddr": (2, 2),
    "u_decoder": (3, 1),
    "u_imem":    (4, 0),
    "u_dmem":    (4, 2),
    "u_ir":      (5, 1),
    "u_irf":     (6, 0),
    "u_imm":     (6, 2),
    "u_rf":      (7, 1),
    # The execute units are all fed straight from the register file, so they can
    # spread across two columns instead of stacking five deep in one - which is
    # what otherwise forces two empty rows across the entire diagram.
    "u_muxa":    (8, 0),
    "u_muxb":    (8, 1),
    "u_bc":      (8, 2),
    "u_alu":     (9, 0),
    "u_mul":     (9, 1),
    "u_crc":     (9, 2),
    "u_lsu":     (10, 1),
    "u_wbmux":   (11, 1),
}
CTRL = "u_ctrl"          # placed in its own band beneath the datapath
# Which column u_ctrl sits under. It only has two routed inputs - ir from the
# decode stage and branch_taken from execute - so parking it mid-diagram keeps
# both short instead of dragging them the full width of the canvas.
CTRL_COL = 4

STAGE_BANDS = [
    (0, 2, "Fetch"),
    (3, 4, "Memory system"),
    (5, 6, "Decode"),
    (7, 7, "Registers"),
    (8, 9, "Execute"),
    (10, 11, "Memory access / writeback"),
]

NEW_BLOCKS = {"u_irf", "u_wbmux"}
MEM_BLOCKS = {"u_imem", "u_dmem"}

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
MARGIN = 30
BAND_TOP = 26       # room above the datapath for the stage captions


def label(port, width):
    return port + ("" if width in ("1", "") else width)


class Block(object):
    def __init__(self, inst, module, role, ins, outs, drivers):
        self.inst, self.module, self.role = inst, module, role
        self.ins, self.outs = ins, outs
        # A pin is "tagged" when nothing is routed to it: control from u_ctrl,
        # and the clock and reset nets, which would otherwise add 10 wires that
        # tell the reader nothing.
        self.tag = {}
        for p, w in ins:
            src = drivers.get((inst, p))
            if p in ("clk_i", "rst_i"):
                self.tag[p] = "clk"
            elif src and src.startswith(CTRL + "."):
                self.tag[p] = "ctrl"
        self.w = self.h = 0
        self.x = self.y = 0

    def measure(self):
        # The name sits in the clear channel between the two columns of pin
        # labels, not at the block's centre - centring it is what made long
        # names on narrow blocks collide with their own left-hand labels.
        self.lpx = max([len(label(p, w)) for p, w in self.ins] or [0]) * CW
        self.rpx = max([len(label(p, w)) for p, w in self.outs] or [0]) * CW
        self.namew = max(len(self.inst) * NAME_CW, len(self.module) * 6.4)
        self.w = int(max(MIN_W,
                         2 * PAD_X + self.lpx + self.rpx + self.namew + 2 * LABEL_GAP))
        self.h = int(max(len(self.ins), len(self.outs)) * PITCH + 2 * PAD_Y)
        self.h = max(self.h, 62)

    def name_cx(self):
        """Centre of the clear channel between the left and right label columns."""
        lo = self.x + PAD_X + self.lpx
        hi = self.x + self.w - PAD_X - self.rpx
        return (lo + hi) / 2.0

    def pin_y(self, idx):
        return self.y + PAD_Y + idx * PITCH + PITCH / 2.0

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


def build():
    blocks_src = gd.load_blocks()
    instances = gd.parse_instances(os.path.join(ROOT, "ci_top.v"))
    nets = gd.build_netlist(blocks_src, instances)

    drivers = {}
    for name, e in nets.items():
        if e["src"]:
            for sink in e["sinks"]:
                drivers[sink] = "%s.%s" % e["src"]

    B = {}
    for module, inst, _ in instances:
        info = blocks_src[module]
        B[inst] = Block(
            inst, module, gd.ROLES.get(inst, ""),
            [(p, w) for d, w, p in info["ports"] if d == "input"],
            [(p, w) for d, w, p in info["ports"] if d == "output"],
            drivers)
    for b in B.values():
        b.measure()
    return B, nets


def route(B, nets):
    """Decide each wire's topology, then size the corridors it needs."""
    ncols = max(c for c, _ in PLACE.values()) + 1
    nrows = max(r for _, r in PLACE.values()) + 1

    routes = []   # (net, [(kind, channel_id, lo, hi, extra)])
    for name in sorted(nets):
        e = nets[name]
        if not e["src"] or not e["sinks"]:
            continue
        si, sp = e["src"]
        for di, dp in sorted(e["sinks"]):
            if di == CTRL and dp in ("clk_i", "rst_i"):
                continue
            if B[di].tag.get(dp):          # control or clock pin: shown as a tag
                continue
            routes.append((name, si, sp, di, dp))
    return routes, ncols, nrows


def layout(B, nets, routes, ncols, nrows):
    vch = [Channel() for _ in range(ncols + 1)]
    hch = [Channel() for _ in range(nrows + 2)]   # +1 for the band under u_ctrl

    # -- provisional geometry, good enough to detect track conflicts ---------
    colw = [0] * ncols
    rowh = [0] * nrows
    for inst, (c, r) in PLACE.items():
        colw[c] = max(colw[c], B[inst].w)
        rowh[r] = max(rowh[r], B[inst].h)

    def place(vsize, hsize):
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
        y += B[CTRL].h + hsize[nrows + 1]
        for inst, (c, r) in PLACE.items():
            B[inst].x = xs[c]
            B[inst].y = ys[r] + (rowh[r] - B[inst].h) // 2
        B[CTRL].x = xs[CTRL_COL]
        B[CTRL].y = cy
        return xs, ys, cy, x, y

    prov_v = [90] * (ncols + 1)
    prov_h = [ROW_GAP_MIN] * (nrows + 2)
    xs, ys, cy, W, H = place(prov_v, prov_h)

    # -- topology first, tracks second --------------------------------------
    # A net that fans out shares one vertical trunk, so every track has to be
    # booked over the union of the runs that use it. Booking each run
    # separately is what produced overlapping wires: the first booking
    # reserved a point, and the rest quietly landed on other nets' tracks.
    def prov_hy(hc):
        return ys[hc] if hc < nrows else (cy if hc == nrows else H)

    def prov_vx(c):
        return (xs[c] - vsize_prov(c) / 2.0) if c < ncols else W

    def vsize_prov(_c):
        return 90.0

    plans = []
    for name, si, sp, di, dp in routes:
        sx, sy = B[si].out_xy(sp)
        dx, dy = B[di].in_xy(dp)
        sc = PLACE[si][0]
        dc = PLACE[di][0] if di != CTRL else CTRL_COL
        dr = PLACE[di][1] if di != CTRL else nrows + 1
        vc, vc2 = sc + 1, dc
        p = dict(net=name, si=si, sp=sp, di=di, dp=dp,
                 sx=sx, sy=sy, dx=dx, dy=dy, vc=vc)
        if vc == vc2:
            p.update(kind="Z")
        else:
            p.update(kind="U", hc=dr, vc2=vc2)
        plans.append(p)

    span = lambda d, k, lo, hi: d.__setitem__(
        k, (min(d[k][0], lo), max(d[k][1], hi)) if k in d else (lo, hi))

    trunk_y, hseg_x, vin_y = {}, {}, {}
    for p in plans:
        span(trunk_y, (p["net"], p["vc"]), p["sy"], p["sy"])
        if p["kind"] == "Z":
            span(trunk_y, (p["net"], p["vc"]), p["dy"], p["dy"])
        else:
            hy_p = prov_hy(p["hc"])
            span(trunk_y, (p["net"], p["vc"]), hy_p, hy_p)
            span(hseg_x, (p["net"], p["hc"]),
                 min(prov_vx(p["vc"]), prov_vx(p["vc2"])),
                 max(prov_vx(p["vc"]), prov_vx(p["vc2"])))
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
    xs, ys, cy, W, H = place(vsize, hsize)

    def vx(c, t):
        base = xs[c] - vsize[c] if c < ncols else W - vsize[c]
        return base + CH_PAD + t * TRACK

    def hy(r, t):
        if r < nrows:
            base = ys[r] - hsize[r]
        elif r == nrows:
            base = cy - hsize[nrows]
        else:
            base = B[CTRL].y + B[CTRL].h
        return base + CH_PAD + t * TRACK

    # The plans were booked against the provisional grid; every coordinate has
    # to be re-read from the blocks now that they have moved to their final
    # positions. Only the topology - which corridor, which track - carries over.
    for p in plans:
        sx, sy = B[p["si"]].out_xy(p["sp"])
        dx, dy = B[p["di"]].in_xy(p["dp"])
        p.update(sx=sx, sy=sy, dx=dx, dy=dy)
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

    # 1. No wire may run through a block.
    rects = [(b.x, b.y, b.x + b.w, b.y + b.h, b.inst) for b in B.values()]
    for p in plans:
        for (x1, y1), (x2, y2) in segments(p):
            lo_x, hi_x = min(x1, x2), max(x1, x2)
            lo_y, hi_y = min(y1, y2), max(y1, y2)
            for bx1, by1, bx2, by2, inst in rects:
                # touching a block edge is how a wire reaches a pin
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
                if a[2] == b[2]:
                    continue
                if a[0] < b[1] - 1 and b[0] < a[1] - 1:
                    problems.append("nets %s and %s overlap at %s" % (a[2], b[2], coord))
    return sorted(set(problems))


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
THEMED = {
    "ink": "var(--ink)", "ink2": "var(--ink-2)", "muted": "var(--muted)",
    "rule": "var(--rule-2)", "panel": "var(--panel-2)", "panel1": "var(--panel)",
    "brass": "var(--brass)", "brassbg": "var(--brass-bg)", "brassink": "var(--brass-ink)",
    "wire": "var(--wire)", "band": "var(--band)",
}
LIGHT = {
    "ink": "#161b22", "ink2": "#3a434f", "muted": "#5c6673", "rule": "#c6cdd8",
    "panel": "#eef1f5", "panel1": "#ffffff", "brass": "#8a5d0c",
    "brassbg": "#fbf3e2", "brassink": "#6d4a09", "wire": "#4a5462", "band": "#f0f2f6",
}
DARK = {
    "ink": "#e7eaef", "ink2": "#c2c9d4", "muted": "#929caa", "rule": "#333b46",
    "panel": "#1c2129", "panel1": "#161a21", "brass": "#e0a63e",
    "brassbg": "#231c0c", "brassink": "#f0c778", "wire": "#8d97a6", "band": "#141922",
}


def emit(B, plans, xs, ys, W, H, colw, rowh, vsize, hsize, C, bg=None):
    o = []
    a = o.append
    a('<svg class="schematic" id="sch" viewBox="0 0 %d %d" '
      'xmlns="http://www.w3.org/2000/svg" role="img" aria-label="%s">'
      % (W, H, ARIA))
    a('<defs><marker id="ah" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="6.5" '
      'markerHeight="6.5" orient="auto-start-reverse">'
      '<path d="M0,1.2 L8.6,5 L0,8.8 z" fill="%s"/></marker></defs>' % C["wire"])
    if bg:
        a('<rect width="%d" height="%d" fill="%s"/>' % (W, H, bg))

    # Stage bands. Alternating tints, so the six pipeline stages read as
    # distinct regions rather than one grey slab behind everything.
    a('<g class="bands">')
    band_top = MARGIN + BAND_TOP - 10
    band_bot = ys[len(rowh) - 1] + rowh[-1] + 12
    for i, (c0, c1, name) in enumerate(STAGE_BANDS):
        x0 = xs[c0] - vsize[c0] + 6
        x1 = xs[c1] + colw[c1] + vsize[c1 + 1] - 6
        if i % 2 == 0:
            a('<rect x="%d" y="%d" width="%d" height="%d" rx="9" fill="%s"/>'
              % (x0, band_top, x1 - x0, band_bot - band_top, C["band"]))
        a('<text x="%d" y="%d" text-anchor="middle" font-family="var(--mono)" '
          'font-size="10.5" font-weight="600" letter-spacing="1.6" fill="%s">%s</text>'
          % ((x0 + x1) / 2, MARGIN + 8, C["muted"], name.upper()))
    a('</g>')

    # wires
    a('<g class="wires" fill="none" stroke-linejoin="round" stroke-linecap="round">')
    for p in plans:
        d = "M" + " L".join("%.1f,%.1f" % pt for pt in p["pts"])
        wide = nets_width.get(p["net"], "") == "[31:0]"
        a('<path class="w" data-net="%s" d="%s" stroke="%s" stroke-width="%s" '
          'marker-end="url(#ah)"/>'
          % (p["net"], d, C["wire"], "1.7" if wide else "1.15"))
    a('</g>')

    # junction dots where a trunk fans out
    a('<g class="dots">')
    seen = {}
    for p in plans:
        seen.setdefault(p["net"], []).append(p["pts"])
    for net, paths in seen.items():
        if len(paths) < 2:
            continue
        counts = {}
        for pts in paths:
            for pt in pts[1:-1]:
                counts[(round(pt[0], 1), round(pt[1], 1))] = \
                    counts.get((round(pt[0], 1), round(pt[1], 1)), 0) + 1
        for (x, y), n in counts.items():
            if n >= 2:
                a('<circle class="jn" data-net="%s" cx="%.1f" cy="%.1f" r="3.1" fill="%s"/>'
                  % (net, x, y, C["wire"]))
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
        # Short hops between adjacent blocks are already named by the pins at
        # both ends, so labelling them only adds ink that crowds the wire on
        # the track above. Long-haul buses are the ones worth naming.
        if abs(x2 - x1) < max(LABEL_MIN_RUN, len(text) * 5.4 + 12):
            continue
        placed.add(p["net"])
        a('<text class="wl" data-net="%s" x="%.1f" y="%.1f" text-anchor="middle" '
          'font-family="var(--mono)" font-size="9" fill="%s">%s</text>'
          % (p["net"], (x1 + x2) / 2, y1 - 4.5, C["muted"], text.strip()))
    a('</g>')

    # blocks
    a('<g class="blocks">')
    for inst in list(PLACE) + [CTRL]:
        b = B[inst]
        cls = "blk"
        stroke, fill, sw = C["rule"], C["panel"], "1.2"
        if inst in NEW_BLOCKS:
            cls += " new"; stroke, sw = C["brass"], "1.7"
        elif inst in MEM_BLOCKS:
            cls += " mem"; fill, sw = C["panel1"], "1.5"
        elif inst == CTRL:
            cls += " ctrl"; stroke, fill, sw = C["brass"], C["brassbg"], "1.5"
        a('<g class="%s" data-inst="%s">' % (cls, inst))
        a('<rect x="%d" y="%d" width="%d" height="%d" rx="7" fill="%s" stroke="%s" '
          'stroke-width="%s"/>' % (b.x, b.y, b.w, b.h, fill, stroke, sw))
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

    # The control signals are not drawn as wires - thirteen nets from one block
    # to scattered pins is exactly what turns a schematic into a tangle. They
    # are listed here instead, which is the same information in a form that
    # stays readable, and mirrors the control tables printed alongside CPU
    # datapath figures in textbooks.
    cb = B[CTRL]
    tx = cb.x + cb.w + 74
    ty = cb.y + 4

    # Legend, in the empty band to the left of the control unit.
    lx, ly = MARGIN + 6, cb.y + 4
    a('<g class="legend-svg">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" '
      'font-weight="600" letter-spacing="1.2" fill="%s">HOW TO READ THIS</text>'
      % (lx, ly, C["muted"]))
    rows = [
        ("wire32", "32-bit data bus"),
        ("wire", "narrow bus or single strobe"),
        ("dot", "junction - a dot means connected, a bare crossing does not"),
        ("pin", "pin: inputs down the left edge, outputs down the right"),
        ("ctrlpin", "control pin, driven by u_ctrl (see the table opposite)"),
        ("new", "block that did not exist before the migration"),
    ]
    for i, (kind, text) in enumerate(rows):
        yy = ly + 26 + i * 22
        if kind == "wire32":
            a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.7" fill="none" '
              'marker-end="url(#ah)"/>' % (lx, yy, lx + 30, yy, C["wire"]))
        elif kind == "wire":
            a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.15" fill="none" '
              'marker-end="url(#ah)"/>' % (lx, yy, lx + 30, yy, C["wire"]))
        elif kind == "dot":
            a('<path d="M%.1f,%.1f L%.1f,%.1f M%.1f,%.1f L%.1f,%.1f" stroke="%s" '
              'stroke-width="1.4" fill="none"/>'
              % (lx, yy, lx + 30, yy, lx + 15, yy - 8, lx + 15, yy + 8, C["wire"]))
            a('<circle cx="%.1f" cy="%.1f" r="3.1" fill="%s"/>' % (lx + 15, yy, C["wire"]))
        elif kind == "new":
            a('<rect x="%.1f" y="%.1f" width="30" height="13" rx="3" fill="none" '
              'stroke="%s" stroke-width="1.7"/>' % (lx, yy - 7, C["brass"]))
        else:
            col = C["brass"] if kind == "ctrlpin" else C["wire"]
            a('<circle cx="%.1f" cy="%.1f" r="3" fill="%s" stroke="%s" stroke-width="1.1"/>'
              % (lx + 22, yy, C["panel1"], col))
            if kind == "ctrlpin":
                a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.1" '
                  'stroke-dasharray="2.5 2" fill="none"/>' % (lx + 6, yy, lx + 18, yy, col))
            else:
                a('<path d="M%.1f,%.1f L%.1f,%.1f" stroke="%s" stroke-width="1.4" '
                  'fill="none"/>' % (lx, yy, lx + 19, yy, col))
        a('<text x="%.1f" y="%.1f" font-family="var(--sans)" font-size="10.5" fill="%s">'
          '%s</text>' % (lx + 42, yy + 3.5, C["ink2"], text))
    a('</g>')

    a('<g class="ctrltable">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" '
      'font-weight="600" letter-spacing="1.2" fill="%s">'
      'CONTROL FAN-OUT &#8212; shown as pins on each block, not routed</text>'
      % (tx, ty, C["brass"]))
    rows_per_col = 4
    colw_t = 368
    for i, (sig, dests) in enumerate(CTRL_FANOUT):
        cx = tx + (i // rows_per_col) * colw_t
        cy2 = ty + 26 + (i % rows_per_col) * 34
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9.6" '
          'font-weight="600" fill="%s">%s</text>' % (cx, cy2, C["brassink"], sig))
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9" fill="%s">'
          '&#8594; %s</text>' % (cx + 10, cy2 + 13, C["muted"], dests))
    a('</g>')

    # Cycle counts, in the space the control block leaves at the far right.
    # The FSM is the thing a reader most often wants alongside a datapath, and
    # nothing else in the picture says how long an instruction actually takes.
    ttx = tx + 4 * colw_t + 30
    a('<g class="timing">')
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="11" '
      'font-weight="600" letter-spacing="1.2" fill="%s">FSM &#8212; CYCLES PER '
      'INSTRUCTION</text>' % (ttx, ty, C["muted"]))
    a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9" fill="%s">'
      'RESET &#8594; FETCH &#8594; DECODE &#8594; EXECUTE &#8594; MEMORY &#8594; WRITEBACK'
      '</text>' % (ttx, ty + 22, C["ink2"]))
    for i, (cls, n, path) in enumerate([
            ("branch", "3", "EXECUTE returns straight to FETCH"),
            ("store", "4", "EXECUTE, MEMORY, then FETCH"),
            ("ALU / mul / crc / jump", "4", "EXECUTE, WRITEBACK"),
            ("fence / ecall / ebreak / illegal", "4", "WRITEBACK, but writes no register"),
            ("load", "5", "EXECUTE, MEMORY, WRITEBACK")]):
        yy = ty + 46 + i * 19
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9.2" fill="%s">'
          '%s</text>' % (ttx, yy, C["ink2"], cls))
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9.2" '
          'font-weight="600" text-anchor="end" fill="%s">%s</text>'
          % (ttx + 232, yy, C["brassink"], n))
        a('<text x="%.1f" y="%.1f" font-family="var(--mono)" font-size="9" fill="%s">'
          '%s</text>' % (ttx + 246, yy, C["muted"], path))
    a('</g>')

    a('</svg>')
    return "\n".join(o)


def run_len(p):
    return sum(abs(x2 - x1) for (x1, _), (x2, _) in segments(p))


def longest_horizontal(p):
    best, blen = None, 0
    for (x1, y1), (x2, y2) in segments(p):
        if abs(y1 - y2) < 0.5 and abs(x2 - x1) > blen:
            best, blen = ((x1, y1), (x2, y2)), abs(x2 - x1)
    return best


ARIA = ("Datapath schematic of the RVBL-2 multicycle RISC-V core. Blocks are laid out "
        "left to right in six stages - fetch, memory system, decode, registers, execute, "
        "and memory access with writeback - with inputs as pins on each block's left edge "
        "and outputs on its right. The ALU result feeds back to the address multiplexer, "
        "the next-PC multiplexer, the load-store unit and the writeback multiplexer, whose "
        "output returns to the register file. The control unit sits in a band underneath; "
        "its outputs are shown as named pins on the blocks that consume them.")

nets_width = {}
CTRL_FANOUT = []


def main():
    check = "--check" in sys.argv
    B, nets = build()
    for n, e in nets.items():
        nets_width[n] = e["width"]

    # Control signals, in the order they appear on u_ctrl's edge, each with
    # every pin it drives. Unconnected outputs are called out as such: they are
    # read by the testbench through hierarchical references, not wired.
    for port, _w in B[CTRL].outs:
        e = nets.get(port)
        if not e:
            continue
        if e["sinks"]:
            CTRL_FANOUT.append((port, "  ".join("%s.%s" % s for s in sorted(e["sinks"]))))
        else:
            CTRL_FANOUT.append((port, "unconnected &#8212; read by the testbench"))
    routes, ncols, nrows = route(B, nets)
    plans, xs, ys, W, H, colw, rowh, vsize, hsize = layout(B, nets, routes, ncols, nrows)

    problems = validate(B, plans)
    if problems:
        for p in problems[:25]:
            print("LAYOUT: %s" % p, file=sys.stderr)
        print("LAYOUT: %d problem(s)" % len(problems), file=sys.stderr)
    else:
        print("OK   layout clean: no wire crosses a block, no two nets share a line")

    out = os.path.join(ROOT, "build")
    if not os.path.isdir(out):
        os.makedirs(out)
    for name, C, bg in (("schematic", THEMED, None),
                        ("schematic_light", LIGHT, "#ffffff"),
                        ("schematic_dark", DARK, "#161a21")):
        svg = emit(B, plans, xs, ys, W, H, colw, rowh, vsize, hsize, C, bg)
        if name != "schematic":
            svg = svg.replace("var(--mono)", "IBM Plex Mono, monospace")
            svg = svg.replace("var(--sans)", "IBM Plex Sans, sans-serif")
        with io.open(os.path.join(out, name + ".svg"), "w", encoding="utf-8") as fh:
            fh.write(svg)

    print("     canvas %dx%d, %d blocks, %d routed wires, %d columns"
          % (W, H, len(B), len(plans), ncols))
    if problems and check:
        sys.exit(1)


if __name__ == "__main__":
    main()
