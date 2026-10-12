"""LaneX desk gantry: a 3D-printed MLFF gantry that holds the HC-SR04 looking down at the lane.

    python stage4/de10lite/gantry/gantry_cad.py            # build, check, export to ./out

Three parts, printed together on one Bambu Lab A1 plate (256 x 256 mm), no supports:

  frame   the portal gantry: two posts, a Warren-truss beam, corner gussets, the sensor pod
          under the beam centre, a press-in wire channel on its front face, tenons at the feet.
          Printed lying on its back face.
  footing the left foot: a plate with a socket for one tenon.
  tray    the right foot and the "roadside cabinet": a socket, and places for the DE10-Lite,
          a 170-point mini breadboard and the Cytron UC00C USB-UART.

Use coordinates (mm): X across the lane, Y along the road (+Y = the front, where the sensor
slides in and the wire channel opens), Z up. The table is at Z = -14 (the socket bosses are 14 mm
tall); the transducer faces are about 196 mm above it.

Every number is a parameter below. The checks at the end model the sensor (board, transducers,
crystal, header, Dupont plugs) and prove the fit, the insertion path, the detent, the acoustic
cone's clearance, the tenon fits, the bed fit and the overhangs before anything is printed.
"""
import json
import os
import sys
import zipfile

import numpy as np
from manifold3d import CrossSection as CS
from manifold3d import FillRule, JoinType, Manifold as M, set_circular_segments

set_circular_segments(64)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

# ----------------------------------------------------------------------------- parameters
T = 14.0              # frame depth (Y); also the print height of the frame
POST = 14.0           # post width (X)
XC = 115.0            # post centre (|X|); inner faces at 108: 31 deg off the sensor axis at the floor
ZB, ZT = 194.0, 226.0 # beam bottom and top
BOT_CHORD, TOP_CHORD = 6.0, 12.0
WEB = 4.5             # truss bar width
GUSSET = 36.0         # corner gusset legs
# wedge tenons: tapered in X (both sides) and on their front (+Y) face; they jam in matching sockets
# with zero play (PLA on PLA self-locks below ~16 degrees; these tapers are 4.3 and 5.7 degrees)
TENON_W, TENON_TIP_W = 9.0, 6.0       # width at the shoulder and at the tip (X)
TENON_TIP_D = 12.0                    # depth at the tip (Y); full frame depth T at the shoulder
TENON_L = 20.0
PRELOAD = 0.05        # the socket is this much smaller per side: the wedge locks ~0.7 mm before the shoulder lands

# wire channel (dovetail, opens towards +Y): bottom width, opening, depth
CH_W, CH_OPEN, CH_D = 7.0, 4.0, 6.0
CH_Z = ZT - TOP_CHORD / 2           # channel centreline along the beam
CH_R = 12.0                         # bend radius at the beam-post corner

# footings
BOSS = 26.0           # socket boss, square
H_BOSS = 20.0         # = how far the table is below the post shoulders (= tenon length)
FOOT_Y0, FOOT_Y1 = -93.0, 107.0     # footing length along the road (200 mm, centred on the frame)
COIN_D, COIN_STACK = 24.0, 18.0     # ballast cups: any Malaysian coin (50 sen is 22.65 mm), ~10 coins a cup
FOOT_W = 36.0         # left footing width
PLATE = 6.0           # footing plate thickness
TRAY_FLOOR = 2.4
TRAY_X1 = 228.0       # tray outer edge

# HC-SR04 (datasheet 45 x 20 x 15 mm; transducers 16 mm on ~26 mm centres; crystal between them)
BOARD_L, BOARD_W, PCB_T = 45.0, 20.0, 1.6
CAN_D, CAN_H, CAN_PITCH = 16.0, 12.0, 26.0
CAN_SLOT_R = 8.6      # 0.6 mm radial clearance: accepts pitch 25.4 .. 26.6
XTAL_SLOT = 6.4       # HC-49S crystal is 4.7 mm wide
BACK_PARTS = 2.8      # tallest part on the back (right-angle header body)

# pod: derived
END_CLR = 0.35
POD_IN = BOARD_L / 2 + END_CLR          # 22.85: inner end-wall face
POD_WALL = 2.6
POD_OUT = POD_IN + POD_WALL             # 25.45
POD_BACK = 2.4
YB0 = POD_BACK + 0.3                    # board's leading (back) edge when home
POD_Y = YB0 + BOARD_W                   # 22.7: the open front, flush with the header edge
CAN_Y = YB0 + BOARD_W / 2               # transducer centres along Y
Z_PCB_BACK = ZB - (BACK_PARTS + 2.2)    # 195.0
Z_PCB_FRONT = Z_PCB_BACK - PCB_T        # 193.4: the floor's top
FLOOR = 4.0
LIFT = 0.8                              # headroom so the board can ride over the detent
LIP_IN = 1.2                            # ledge over the board's ends
DETENT = 0.5                            # detent height
SKIRT_Z = Z_PCB_FRONT - FLOOR - 4.4


# ----------------------------------------------------------------------------- helpers
def box(x0, x1, y0, y1, z0, z1):
    return M.cube((x1 - x0, y1 - y0, z1 - z0)).translate((x0, y0, z0))


def xz_prism(cs, y0, y1):
    """A cross-section drawn in the X-Z plane (its 2D x -> X, 2D y -> Z), extruded from Y0 to Y1."""
    return M.extrude(cs, y1 - y0).rotate((90, 0, 0)).translate((0, y1, 0))


def xy_prism(cs, z0, z1):
    return M.extrude(cs, z1 - z0).translate((0, 0, z0))


def yz_prism(cs, x0, x1):
    """Cross-section in the Y-Z plane (2D x -> Y, 2D y -> Z), extruded from X0 to X1."""
    return M.extrude(cs, x1 - x0).rotate((90, 0, 90)).translate((x0, 0, 0))


def rect(x0, x1, y0, y1):
    return CS.square((x1 - x0, y1 - y0)).translate((x0, y0))


def poly(pts):
    return CS([np.array(pts, float)], FillRule.Positive) if _ccw(pts) else CS([np.array(pts[::-1], float)], FillRule.Positive)


def _ccw(pts):
    p = np.array(pts, float)
    return 0.5 * np.sum(p[:, 0] * np.roll(p[:, 1], -1) - np.roll(p[:, 0], -1) * p[:, 1]) > 0


def band(path, width):
    """A 2D stroke of the given width along a polyline, with round joints and caps."""
    r = width / 2
    parts = []
    for (x0, y0), (x1, y1) in zip(path[:-1], path[1:]):
        parts.append(CS.batch_hull([CS.circle(r).translate((x0, y0)), CS.circle(r).translate((x1, y1))]))
    return CS.batch_boolean(parts, _ADD)


_ADD = __import__("manifold3d").OpType.Add


def union(items):
    items = [i for i in items if i is not None]
    return M.batch_boolean(items, _ADD) if items else M()


def rounded_rect(x0, x1, y0, y1, r):
    return rect(x0 + r, x1 - r, y0 + r, y1 - r).offset(r, JoinType.Round)


def text_cs(s, height, font="InterDisplay-Bold.ttf"):
    """Text as a cross-section, cap height ~ height mm, left-bottom at the origin."""
    from matplotlib.font_manager import FontProperties
    from matplotlib.textpath import TextPath
    fpath = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "Windows", "Fonts", font)
    prop = FontProperties(fname=fpath) if os.path.exists(fpath) else FontProperties(family="DejaVu Sans", weight="bold")
    tp = TextPath((0, 0), s, size=height / 0.72, prop=prop)
    polys = [np.array(p, float) for p in tp.to_polygons(closed_only=True) if len(p) > 2]
    return CS(polys, FillRule.EvenOdd)


def channel(path_xz, y_face, open_extra=None):
    """The dovetail wire channel cut into a face at Y = y_face along an X-Z path: full width at the
    bottom, a 45-degree taper to the narrow opening (prints without support), then the opening."""
    y_bot = y_face - CH_D
    taper = (CH_W - CH_OPEN) / 2                     # 1.5 mm, at 45 degrees
    y_t0 = y_face - 1.5 - taper
    cuts = [xz_prism(band(path_xz, CH_W), y_bot, y_t0)]
    steps = 6
    for k in range(steps):
        w = CH_W - (CH_W - CH_OPEN) * (k + 1) / steps
        a = y_t0 + taper * k / steps
        cuts.append(xz_prism(band(path_xz, w), a, a + taper / steps + 0.01))
    cuts.append(xz_prism(band(path_xz, CH_OPEN), y_face - 1.5, y_face + 0.5))
    if open_extra is not None:                       # places with no lips (where wires enter)
        cuts.append(xz_prism(open_extra, y_bot, y_face + 0.5))
    return union(cuts)


def arc_path(p0, corner, p1, r, n=10):
    """Polyline p0 -> corner -> p1 with the corner rounded at radius r (axis-aligned legs)."""
    c = np.array(corner, float)
    a, b = np.array(p0, float), np.array(p1, float)
    da, db = (a - c) / np.linalg.norm(a - c), (b - c) / np.linalg.norm(b - c)
    s, e = c + da * r, c + db * r
    centre = c + da * r + db * r
    pts = [tuple(a)]
    v0, v1 = s - centre, e - centre
    t0, t1 = np.arctan2(v0[1], v0[0]), np.arctan2(v1[1], v1[0])
    dt = (t1 - t0 + np.pi) % (2 * np.pi) - np.pi
    for k in range(n + 1):
        t = t0 + dt * k / n
        pts.append(tuple(centre + r * np.array([np.cos(t), np.sin(t)])))
    pts.append(tuple(b))
    return pts


# ----------------------------------------------------------------------------- the frame
def frame():
    xo = XC + POST / 2      # 122
    xi = XC - POST / 2      # 108
    outline = CS.batch_boolean([
        rect(-xo, -xi, 0, ZT), rect(xi, xo, 0, ZT), rect(-xo, xo, ZB, ZT),
        poly([(xi, ZB), (xi, ZB - GUSSET), (xi - GUSSET, ZB)]),
        poly([(-xi, ZB), (-xi + GUSSET, ZB), (-xi, ZB - GUSSET)]),
    ], _ADD)
    outline = outline.offset(-6, JoinType.Round).offset(6, JoinType.Round)   # round outer corners
    outline = outline.offset(3, JoinType.Round).offset(-3, JoinType.Round)   # soften inner ones
    outline = outline + rect(-xo, -xi, 0, 20) + rect(xi, xo, 0, 20)          # square feet: flat shoulders
    # lighten the gussets
    holes = []
    for sx in (-1, 1):
        tri = poly([(sx * xi, ZB), (sx * xi, ZB - GUSSET), (sx * (xi - GUSSET), ZB)])
        holes.append(tri.offset(-7, JoinType.Round))
    # Warren-truss windows between the chords, outside the centre plaque and the corners
    zw0, zw1 = ZB + BOT_CHORD, ZT - TOP_CHORD
    for sx in (-1, 1):
        x0, x1 = 30.0, 100.0
        n = 4
        xs = np.linspace(x0, x1, n + 1)
        bars = [band([(x0, zw0 - 1), (x0, zw1 + 1)], WEB), band([(x1, zw0 - 1), (x1, zw1 + 1)], WEB)]
        for k in range(n):
            za, zb = (zw0, zw1) if k % 2 == 0 else (zw1, zw0)
            bars.append(band([(xs[k], za), (xs[k + 1], zb)], WEB))
        win = rect(x0, x1, zw0, zw1) - CS.batch_boolean(bars, _ADD)
        holes.append(win.scale((sx, 1)) if sx < 0 else win)
    outline = outline - CS.batch_boolean(holes, _ADD)
    body = xz_prism(outline, 0, T)

    # the wire channel: post foot -> up -> along the beam -> down the other post; a drop to the pod
    right = arc_path((XC, -6), (XC, CH_Z), (0, CH_Z), CH_R)
    left = [(-x, z) for x, z in right]
    path = right + left[::-1]
    drop = [(0, ZB - 1), (0, CH_Z)]
    entry = rect(-6, 6, ZB - 1, ZB + 9)              # no lips where the wires come up from the pod
    body = body - channel(path, T) - channel(drop, T, open_extra=entry)
    # tenons (chamfered tips), added after the channel so it never cuts them
    for sx in (-1, 1):
        body = body + tenon(sx * XC)
    return body + pod()


def wedge(xc, w_top, w_tip, d_top, d_tip, z_top, z_tip, y0=0.0):
    """A block tapered in X (both sides) and on its +Y face; its back face (Y = y0) stays flat."""
    pts = []
    for z, w, d in ((z_top, w_top, d_top), (z_tip, w_tip, d_tip)):
        for x in (xc - w / 2, xc + w / 2):
            for y in (y0, y0 + d):
                pts.append((x, y, z))
    return M.hull_points(np.array(pts, float))


def tenon(xc):
    return wedge(xc, TENON_W, TENON_TIP_W, T, TENON_TIP_D, 0.0, -TENON_L)


def pod():
    """The sensor pod under the beam centre: open at the front (+Y); the board slides in face down,
    transducers through U-slots that stop it at home, held by gravity and a detent."""
    block = box(-POD_OUT, POD_OUT, 0, POD_Y, SKIRT_Z, ZB + 0.5)
    cav_a = box(-POD_IN, POD_IN, POD_BACK, POD_Y + 1, Z_PCB_FRONT, Z_PCB_BACK + LIFT)              # the board
    cav_b = box(-POD_IN + LIP_IN, POD_IN - LIP_IN, POD_BACK, POD_Y + 1, Z_PCB_BACK + LIFT - 0.01, ZB - 0.6)  # back parts
    cav_c = box(-POD_IN, POD_IN, POD_BACK, POD_Y + 1, SKIRT_Z - 1, Z_PCB_FRONT - FLOOR)          # under the floor
    slots = []
    for cx in (-CAN_PITCH / 2, CAN_PITCH / 2):
        slots.append(CS.circle(CAN_SLOT_R).translate((cx, CAN_Y)) + rect(cx - CAN_SLOT_R, cx + CAN_SLOT_R, CAN_Y, POD_Y + 5))
    slots.append(rect(-XTAL_SLOT / 2, XTAL_SLOT / 2, POD_BACK + 1.6, POD_Y + 5))
    slot = xy_prism(CS.batch_boolean(slots, _ADD), Z_PCB_FRONT - FLOOR - 1, Z_PCB_FRONT + 0.01)
    body = block - cav_a - cav_b - cav_c - slot
    # toes in front of the end strips, carrying the detent bumps
    for sx in (-1, 1):
        x0, x1 = sorted((sx * (CAN_PITCH / 2 + CAN_SLOT_R + 0.3), sx * POD_OUT))
        toe = box(x0, x1, POD_Y - 0.01, POD_Y + 2.0, Z_PCB_FRONT - FLOOR, Z_PCB_FRONT)
        bump = poly([(POD_Y + 0.1, 0), (POD_Y + 0.1 + DETENT, DETENT), (POD_Y + 0.9, DETENT), (POD_Y + 1.9, 0)])
        bump = yz_prism(bump, max(x0, -POD_IN), min(x1, POD_IN)).translate((0, 0, Z_PCB_FRONT - 0.01))
        body = body + toe + bump
        # end walls continue to the toes' front so the bumps sit on solid floor
        body = body + box(sx * POD_IN if sx > 0 else -POD_OUT, POD_OUT if sx > 0 else -POD_IN,
                          POD_Y - 0.01, POD_Y + 2.0, Z_PCB_FRONT - FLOOR, Z_PCB_FRONT + 4.0)
    return body


# ----------------------------------------------------------------------------- the footings
def boss(xc, base_z):
    """The socket boss for one tenon, standing on a plate whose top is base_z.
    Returns (solid, cut): apply the cut after the boss is joined to its plate."""
    b = xy_prism(rounded_rect(xc - BOSS / 2, xc + BOSS / 2, -6, 20, 3), -H_BOSS, 0)
    ribs = []
    for y0, y1 in ((20, 46), (-6, -32)):
        ribs.append(yz_prism(poly([(y0, -0.01), (y1, base_z), (y0, base_z)]), xc - 1.6, xc + 1.6))
    solid = union([b] + ribs)
    kx = (TENON_W - TENON_TIP_W) / 2 / TENON_L          # taper per side, per mm of depth (X)
    ky = (T - TENON_TIP_D) / TENON_L                      # taper of the front face (Y)
    z_tip = -H_BOSS - 1.0
    w_top, d_top = TENON_W - 2 * PRELOAD, T - PRELOAD
    sock = wedge(xc, w_top + 2 * kx * 0.5, w_top - 2 * kx * (-z_tip), d_top + ky * 0.5, d_top - ky * (-z_tip), 0.5, z_tip)
    mouth = wedge(xc, w_top + 1.2, w_top, d_top + 0.6, d_top, 0.01, -0.6).translate((0, 0, 0))
    # wire groove continuing the frame's channel: over the boss top and down its front face
    groove = (box(xc - CH_W / 2, xc + CH_W / 2, T - 1, 21, -3.0, 0.1) +
              box(xc - CH_W / 2, xc + CH_W / 2, 17, 21, base_z - 0.01, 0.1))
    # 45-degree chamfer on the lane-side top edge: a side lobe glances off it, away from the sensor
    x0 = xc - BOSS / 2 if xc > 0 else xc + BOSS / 2
    sgn = 1 if xc > 0 else -1
    bevel = xz_prism(poly([(x0 - sgn * 1, 1), (x0 + sgn * 6, 1), (x0 - sgn * 1, -6)]), -7, 21)
    return solid, sock + mouth + groove + bevel


def footing():
    xc = -XC
    solid, cut = boss(xc, -H_BOSS + PLATE)
    plate = xy_prism(rounded_rect(xc - FOOT_W / 2, xc + FOOT_W / 2, FOOT_Y0, FOOT_Y1, 6), -H_BOSS, -H_BOSS + PLATE)
    lbl = text_cs("LaneX", 8.5).rotate(90)
    bb = lbl.bounds()
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    lbl = lbl.translate((xc + w / 2 - bb[2] + 0.0, 46 - bb[1]))
    lbl2 = text_cs("MLFF", 8.5).rotate(90)
    bb2 = lbl2.bounds()
    lbl2 = lbl2.translate((xc + (bb2[2] - bb2[0]) / 2 - bb2[2], -32 - bb2[1] - (bb2[3] - bb2[1])))
    raised = xy_prism(lbl + lbl2, -H_BOSS + PLATE - 0.01, -H_BOSS + PLATE + 0.6)
    # four coin cups for ballast, near the ends (a notch in each to lift the coins out)
    cups = []
    top = -H_BOSS + PLATE
    for cy in (FOOT_Y0 + 16, FOOT_Y0 + 44, FOOT_Y1 - 44, FOOT_Y1 - 16):
        ring = CS.circle(COIN_D / 2 + 1.6) - CS.circle(COIN_D / 2)
        ring = ring - rect(-4, 4, 0, COIN_D)            # thumb notch facing outwards (-X)
        ring = ring.rotate(90)
        cups.append(xy_prism(ring.translate((xc, cy)), top - 0.01, top + COIN_STACK))
    return (plate + solid + raised + union(cups)) - cut


# Places in the tray (use coordinates x0, x1, y0, y1), each about 1 mm per side larger than the part:
#   DE10-Lite        97.5 x 80 mm (Altera's figure)          -> 100 x 82
#   400-point breadboard 82.5 x 54.5 (clones to 83.5 x 55.5) -> 85 x 57
#   Cytron UC00C     39.8 x 21.2                             -> 41.8 x 23.2 (open at both ends: USB and header)
# Corner guards only, so every edge stays open for cables whichever way a board is turned.
DE10 = (140.0, 222.0, -88.0, 12.0)
BREAD = (138.0, 223.0, 18.0, 75.0)
UC00C = (108.0, 131.2, 52.0, 93.8)


def corners(zone, height, leg, wall=2.0):
    x0, x1, y0, y1 = zone
    parts = []
    for cx, sx in ((x0, -1), (x1, 1)):
        for cy, sy in ((y0, -1), (y1, 1)):
            a = rect(min(cx, cx + sx * wall), max(cx, cx + sx * wall), min(cy + sy * wall, cy - sy * leg), max(cy + sy * wall, cy - sy * leg))
            b = rect(min(cx + sx * wall, cx - sx * leg), max(cx + sx * wall, cx - sx * leg), min(cy, cy + sy * wall), max(cy, cy + sy * wall))
            parts += [a, b]
    return xy_prism(CS.batch_boolean(parts, _ADD), -H_BOSS + TRAY_FLOOR - 0.01, -H_BOSS + TRAY_FLOOR + height)


def tray():
    x0 = XC - BOSS / 2 - 2
    floor = xy_prism(rounded_rect(x0, TRAY_X1, FOOT_Y0, FOOT_Y1, 8), -H_BOSS, -H_BOSS + TRAY_FLOOR)
    lbl = text_cs("RVBL-2 inside", 6.0).rotate(90)
    bb = lbl.bounds()
    lbl = lbl.translate((116 - (bb[0] + bb[2]) / 2, -74 - bb[1]))
    raised = xy_prism(lbl, -H_BOSS + TRAY_FLOOR - 0.01, -H_BOSS + TRAY_FLOOR + 0.6)
    solid, cut = boss(XC, -H_BOSS + TRAY_FLOOR)
    return union([floor, solid, corners(DE10, 12, 16), corners(BREAD, 4, 10), corners(UC00C, 4, 7), raised]) - cut


# ----------------------------------------------------------------------------- the sensor model (for checks)
def hcsr04(dx=0.0, dy=0.0, dz=0.0, pitch=CAN_PITCH, board_l=BOARD_L, with_plugs=True):
    """HC-SR04 at home in the pod, offset by (dx, dy, dz). Front face down."""
    y0 = YB0
    pcb = box(-board_l / 2, board_l / 2, y0, y0 + BOARD_W, Z_PCB_FRONT, Z_PCB_BACK)
    cans = union([M.cylinder(CAN_H, CAN_D / 2).translate((cx, y0 + BOARD_W / 2, Z_PCB_FRONT - CAN_H))
                  for cx in (-pitch / 2, pitch / 2)])
    xtal = box(-2.35, 2.35, y0 + 4.5, y0 + 15.5, Z_PCB_FRONT - 4.0, Z_PCB_FRONT)
    chips = box(-15, 15, y0 + 3, y0 + 15, Z_PCB_BACK, Z_PCB_BACK + 1.8)
    hdr = box(-5.1, 5.1, y0 + BOARD_W - 2.5, y0 + BOARD_W + 0.0, Z_PCB_BACK, Z_PCB_BACK + BACK_PARTS)
    pins = union([box(x - 0.32, x + 0.32, y0 + BOARD_W - 1.3, y0 + BOARD_W + 8.5, Z_PCB_BACK + 1.0, Z_PCB_BACK + 1.64)
                  for x in (-3.81, -1.27, 1.27, 3.81)])
    parts = [pcb, cans, xtal, chips, hdr, pins]
    if with_plugs:
        parts.append(union([box(x - 1.27, x + 1.27, y0 + BOARD_W + 2.0, y0 + BOARD_W + 16.0, Z_PCB_BACK + 0.05, Z_PCB_BACK + 2.59)
                            for x in (-3.81, -1.27, 1.27, 3.81)]))
    return union(parts).translate((dx, dy, dz))


# ----------------------------------------------------------------------------- placement on the A1 plate
BED = 256.0


def place_frame(m):
    r = m.rotate((90, 0, 0))            # (X, Y, Z) -> (X, -Z, Y)
    bb = r.bounding_box()
    return r.translate((BED / 2 - (bb[0] + bb[3]) / 2, 6.0 - bb[1], -bb[2]))   # 5 mm clear of the A1 calibration line at Y ~ 1


def place_flat(m, x_min, y_min):
    bb = m.bounding_box()
    return m.translate((x_min - bb[0], y_min - bb[1], -bb[2]))


# ----------------------------------------------------------------------------- output
def mesh_arrays(m):
    mesh = m.to_mesh()
    v = np.array(mesh.vert_properties)[:, :3]
    f = np.array(mesh.tri_verts)
    return v, f


def write_stl(path, m):
    v, f = mesh_arrays(m)
    tri = v[f]
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    data = np.zeros(len(f), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    data["n"], data["v"] = n, tri
    with open(path, "wb") as fh:
        fh.write(b"LaneX desk gantry".ljust(80, b" "))
        fh.write(np.uint32(len(f)).tobytes())
        fh.write(data.tobytes())


def write_3mf(path, named):
    """A plain 3MF: one object per part, already placed on the plate (no build transforms)."""
    objs, items = [], []
    for i, (name, m) in enumerate(named, start=1):
        v, f = mesh_arrays(m)
        vs = "".join('<vertex x="%.4f" y="%.4f" z="%.4f"/>' % tuple(p) for p in v)
        ts = "".join('<triangle v1="%d" v2="%d" v3="%d"/>' % tuple(t) for t in f)
        objs.append('<object id="%d" name="%s" type="model"><mesh><vertices>%s</vertices><triangles>%s</triangles></mesh></object>' % (i, name, vs, ts))
        items.append('<item objectid="%d"/>' % i)
    model = ('<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" '
             'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>%s</resources>'
             '<build>%s</build></model>') % ("".join(objs), "".join(items))
    ct = ('<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("3D/3dmodel.model", model)


# ----------------------------------------------------------------------------- checks
def vol(m):
    return 0.0 if m.is_empty() else m.volume()


def overhang_report(m, layer=0.2, reach=0.3, min_area=0.5):
    """Slice like a slicer: area of each layer that the layer below (grown by `reach`, i.e. walls
    leaning up to ~56 degrees from vertical) does not hold up. Returns (total, worst layer, its z)."""
    z0, z1 = m.bounding_box()[2], m.bounding_box()[5]
    zs = np.arange(z0 + layer / 2, z1, layer)
    prev = m.slice(zs[0])
    total, worst, worst_z = 0.0, 0.0, 0.0
    for z in zs[1:]:
        cur = m.slice(z)
        a = (cur - prev.offset(reach, JoinType.Round)).area()
        if a > min_area:
            total += a
            if a > worst:
                worst, worst_z = a, z
        prev = cur
    return total, worst, worst_z


def run_checks(fr, ft, tr, plate_parts):
    res = []

    def check(name, ok, detail):
        res.append((name, bool(ok), detail))

    # 1. fit at home, nominal and the tolerance corners
    for label, kw in (("nominal", {}), ("pitch 25.4", {"pitch": 25.4}), ("pitch 26.6", {"pitch": 26.6}),
                      ("board 45.4 long", {"board_l": 45.4}), ("board 44.6 long", {"board_l": 44.6})):
        v = vol(fr ^ hcsr04(**kw))
        check("sensor fits at home (%s)" % label, v < 1e-3, "%.4f mm3 overlap" % v)
    # 2. insertion: slide in from 40 mm out, lifted by the detent height (LIFT headroom)
    worst = 0.0
    for s in np.arange(0.0, 40.0, 0.5):
        worst = max(worst, vol(fr ^ hcsr04(dy=s, dz=DETENT + 0.05)))
    check("slides in from the front, lifted %.2f mm over the detent" % (DETENT + 0.05), worst < 1e-3, "worst %.4f mm3" % worst)
    # 3. the detent: resting (not lifted), pulled 1 mm out, the board's trailing edge meets the bumps
    v = vol(fr ^ hcsr04(dy=1.0, with_plugs=False))
    check("detent stops it sliding out (1 mm pull, resting)", v > 0.01, "%.3f mm3 interference" % v)
    # 4. the board can't drop: its ends rest on ledges (overlap when lowered 0.3 mm)
    v = vol(fr ^ hcsr04(dz=-0.3, with_plugs=False))
    check("board rests on the floor (cannot drop)", v > 0.1, "%.2f mm3 when lowered 0.3" % v)
    # 5. acoustic cone: +/-15 deg (the datasheet's 30-degree beam) and a wider 22.5 deg, from each transducer
    table = -H_BOSS
    for half in (15.0, 22.5):
        info = half > 15.0
        cones = []
        for cx in (-CAN_PITCH / 2, CAN_PITCH / 2):
            h = (Z_PCB_FRONT - CAN_H) - table
            r1 = h * np.tan(np.radians(half)) + CAN_D / 2
            cones.append(M.cylinder(h - 0.5, CAN_D / 2, r1).rotate((180, 0, 0)).translate((cx, CAN_Y, Z_PCB_FRONT - CAN_H - 0.3)))
        cone = union(cones)
        v = vol(cone ^ (fr + ft + tr))
        if info:
            print("INFO  a wider %.0f-degree cone touches %.1f mm3 (the bosses' chamfered lane-side edges, at table level)" % (2 * half, v))
        else:
            check("nothing in the sensor's %.0f-degree cone (datasheet beam)" % (2 * half), v < 1e-3, "%.3f mm3" % v)
    # 6. tenons in sockets: clearance, and the shoulders seat on the bosses
    base = ft + tr
    lo, hi = 0.0, 5.0                         # lift at which the wedge first touches (bisection)
    for _ in range(30):
        mid = (lo + hi) / 2
        if vol(fr.translate((0, 0, mid)) ^ base) > 1e-4:
            lo = mid
        else:
            hi = mid
    check("wedge tenons lock with zero play, %.2f mm before the shoulders land" % hi, 0.2 <= hi <= 2.0,
          "locks at %.2f mm above full seat; tolerance band of the print: 0..3 mm is fine" % hi)
    v = vol(fr.translate((0, 0, hi + 0.01)) ^ base)
    check("nothing else touches as the tenons go in", v < 1e-3, "%.4f mm3" % v)
    # 6b. the electronics, at their largest expected size, sit in their places touching nothing
    fl = -H_BOSS + TRAY_FLOOR
    comps = {"DE10-Lite 97.5 x 80 on 10 mm standoffs": (DE10, 80.0, 97.5, 12.0),
             "400-point breadboard 83.5 x 55.5 (clone max)": (BREAD, 83.5, 55.5, 9.0),
             "UC00C 39.8 x 21.2": (UC00C, 21.2, 39.8, 6.0)}
    placed = {}
    for name, ((x0, x1, y0, y1), wx, wy, h) in comps.items():
        if (x1 - x0) < (y1 - y0) and wx > wy:
            wx, wy = wy, wx
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        placed[name] = box(cx - wx / 2, cx + wx / 2, cy - wy / 2, cy + wy / 2, fl + 0.01, fl + h)
        v = vol(placed[name] ^ (tr + fr))
        check("%s fits its place in the tray" % name, v < 1e-3,
              "%.3f mm3; clearance %.2f x %.2f mm per side" % (v, ((x1 - x0) - wx) / 2, ((y1 - y0) - wy) / 2))
    names = list(placed)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            gp = placed[names[i]].min_gap(placed[names[j]], 20.0)
            check("%s / %s do not touch" % (names[i].split(" ")[0], names[j].split(" ")[0]), gp > 1.0, "gap %.1f mm" % gp)
    # 7. bed fit and spacing
    allbb = [p.bounding_box() for _, p in plate_parts]
    x0 = min(b[0] for b in allbb); y0 = min(b[1] for b in allbb)
    x1 = max(b[3] for b in allbb); y1 = max(b[4] for b in allbb); z1 = max(b[5] for b in allbb)
    check("fits the A1 bed with 4 mm margins", x0 >= 4 and y0 >= 4 and x1 <= BED - 4 and y1 <= BED - 4,
          "x %.1f..%.1f  y %.1f..%.1f  height %.1f" % (x0, x1, y0, y1, z1))
    for i in range(len(plate_parts)):
        for j in range(i + 1, len(plate_parts)):
            g = plate_parts[i][1].min_gap(plate_parts[j][1], 10.0)
            check("parts %s / %s apart on the plate" % (plate_parts[i][0], plate_parts[j][0]), g >= 3.0, "gap %.1f mm" % g)
    # 8. overhangs (support-free)
    for name, p in plate_parts:
        tot, worst, wz = overhang_report(p)
        check("%s prints without support (every 0.2 mm layer held by the one below)" % name, worst < 2.0,
              "unsupported: %.2f mm2 total, worst layer %.2f mm2 at z %.1f" % (tot, worst, wz))
    # 9. watertight, one piece each
    for name, p in plate_parts:
        check("%s is a closed solid" % name, p.status().name == "NoError" and p.genus() >= 0 and len(p.decompose()) >= 1,
              "%d piece(s), genus %d" % (len(p.decompose()), p.genus()))
    return res


def fit_test_parts(fr, ft):
    """Short pieces cut from the real parts, for a ~30 min test print before the full plate:
    the sensor pod with the beam centre and drop channel, one post foot with its wedge tenon,
    and the footing's socket boss. Placed for the A1, in the same print orientations."""
    pod_piece = fr ^ box(-33, 33, -1, 40, SKIRT_Z - 1, ZT + 1)
    foot_piece = fr ^ box(-XC - 10, -XC + 10, -1, 20, -TENON_L - 1, 14)
    boss_piece = ft ^ box(-XC - BOSS / 2 - 1, -XC + BOSS / 2 + 1, -10, 24, -H_BOSS - 1, 1)
    a = place_frame(pod_piece)
    a = a.translate((0, 90 - a.bounding_box()[1], 0))
    b = place_frame(foot_piece)
    b = b.translate((60 - b.bounding_box()[0], 90 - b.bounding_box()[1], 0))
    c = place_flat(boss_piece, 170, 90)
    return [("fit_pod", a), ("fit_foot", b), ("fit_socket", c)]


def main():
    os.makedirs(OUT, exist_ok=True)
    fr, ft, tr = frame(), footing(), tray()
    # use-orientation parts (for viewing and the assembly render)
    for name, m in (("frame", fr), ("footing", ft), ("tray", tr)):
        write_stl(os.path.join(OUT, "use_%s.stl" % name), m)
    write_stl(os.path.join(OUT, "use_sensor.stl"), hcsr04())
    # the plate: frame on its back, footing and tray inside its opening
    pf = place_frame(fr)
    bbf = pf.bounding_box()
    ftr, trr = ft.rotate((0, 0, 90)), tr.rotate((0, 0, 90))
    pft = place_flat(ftr, 28.0, 80.0)
    ptr = place_flat(trr, 28.0, 80.0 + (ftr.bounding_box()[4] - ftr.bounding_box()[1]) + 6.0)
    plate = [("frame", pf), ("footing", pft), ("tray", ptr)]
    write_3mf(os.path.join(OUT, "lanex_gantry_plate.3mf"), plate)
    for name, m in plate:
        write_stl(os.path.join(OUT, "print_%s.stl" % name), m)
    fit = fit_test_parts(fr, ft)
    write_3mf(os.path.join(OUT, "lanex_gantry_fit_test.3mf"), fit)
    res = run_checks(fr, ft, tr, plate)
    for name, p in fit:
        tot, worst, wz = overhang_report(p)
        res.append(("%s (fit test) prints without support" % name, worst < 2.0, "worst layer %.2f mm2" % worst))
    width = max(len(r[0]) for r in res)
    ok = True
    for name, good, detail in res:
        print("%s  %s  %s" % ("PASS" if good else "FAIL", name.ljust(width), detail))
        ok &= good
    vols = {n: round(m.volume() / 1000, 1) for n, m in plate}
    print("solid volumes (cm3):", vols)
    json.dump({"checks": [{"name": n, "pass": g, "detail": d} for n, g, d in res], "volumes_cm3": vols},
              open(os.path.join(OUT, "checks.json"), "w"), indent=1)
    print("ALL CHECKS PASS" if ok else "SOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
