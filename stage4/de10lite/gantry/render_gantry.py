"""Coloured GLB scenes of the desk gantry for checking and for the deck:

    python stage4/de10lite/gantry/render_gantry.py      (after gantry_cad.py)

out/view_assembly.glb  the gantry assembled on the table, sensor in its pod, the electronics in the tray
out/view_pod.glb       the pod and the sensor, close up
out/view_plate.glb     the print plate as it goes on the A1
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "scripts", "stage4", "pitch"))
import gantry_cad as g  # noqa: E402
from glb import Material, Mesh, Model  # noqa: E402

PLA = Material("pla", "#ECEAE4", roughness=0.6)            # print colour: porcelain, as in the deck
PLA_DARK = Material("pla_dark", "#2B3034", roughness=0.55)
PCB = Material("pcb", "#1F5FA8", roughness=0.4)
CAN = Material("can", "#C2C7CC", roughness=0.3, metallic=0.8)
PIN = Material("pin", "#D9B44A", roughness=0.3, metallic=0.8)
PLUG = Material("plug", "#16191C", roughness=0.5)
FPGA = Material("fpga", "#1F3F7A", roughness=0.45)
BREAD = Material("bread", "#F2F0EA", roughness=0.7)
UART = Material("uart", "#C8372B", roughness=0.5)
TABLE = Material("table", "#3C4146", roughness=0.9)
AMBER = Material("amber", "#E27E00", roughness=0.4)


def flat(m):
    """manifold -> glb Mesh with flat (per-face) normals, for a crisp CAD look."""
    v, f = g.mesh_arrays(m)
    tri = v[f].reshape(-1, 3)
    n = np.cross(v[f][:, 1] - v[f][:, 0], v[f][:, 2] - v[f][:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    return Mesh(tri, np.repeat(n, 3, axis=0), np.arange(len(tri), dtype=np.uint32))


def zup_to_gltf(m):
    """CAD (Z up) -> glTF (Y up, +Z towards the viewer): the gantry's front (+Y) faces the camera."""
    return m.rotate((-90, 0, 0)).rotate((0, 180, 0))


def sensor_parts():
    y0 = g.YB0
    pcb = g.box(-g.BOARD_L / 2, g.BOARD_L / 2, y0, y0 + g.BOARD_W, g.Z_PCB_FRONT, g.Z_PCB_BACK)
    cans = g.union([g.M.cylinder(g.CAN_H, g.CAN_D / 2).translate((cx, y0 + g.BOARD_W / 2, g.Z_PCB_FRONT - g.CAN_H))
                    for cx in (-g.CAN_PITCH / 2, g.CAN_PITCH / 2)])
    pins = g.union([g.box(x - 0.32, x + 0.32, y0 + g.BOARD_W - 1.3, y0 + g.BOARD_W + 8.5, g.Z_PCB_BACK + 1.0, g.Z_PCB_BACK + 1.64)
                    for x in (-3.81, -1.27, 1.27, 3.81)])
    plugs = g.union([g.box(x - 1.27, x + 1.27, y0 + g.BOARD_W + 2.0, y0 + g.BOARD_W + 16.0, g.Z_PCB_BACK + 0.05, g.Z_PCB_BACK + 2.59)
                     for x in (-3.81, -1.27, 1.27, 3.81)])
    return pcb, cans, pins, plugs


def wires():
    """Four jumper wires: out of the plugs, up the drop channel, along the beam, down the right post."""
    pts = [(0, g.YB0 + g.BOARD_W + 16.0, g.Z_PCB_BACK + 1.3), (0, g.YB0 + g.BOARD_W + 24, g.Z_PCB_BACK + 4),
           (0, g.T - 3.5, g.ZB + 2), (0, g.T - 3.5, g.CH_Z), (g.XC - g.CH_R, g.T - 3.5, g.CH_Z),
           (g.XC, g.T - 3.5, g.CH_Z - g.CH_R), (g.XC, g.T - 3.5, 0), (g.XC, 19, -1.5), (g.XC, 19, -9),
           (g.XC + 2, 30, -10.6), (g.XC + 5, 52, -10.6)]
    out = []
    for k, dx in enumerate((-1.6, -0.55, 0.55, 1.6)):
        segs = []
        for (x0, y0, z0), (x1, y1, z1) in zip(pts[:-1], pts[1:]):
            a = np.array([x0 + dx, y0, z0])
            b = np.array([x1 + dx, y1, z1])
            d = b - a
            L = np.linalg.norm(d)
            c = g.M.cylinder(L, 0.6, 0.6, 8)
            # orient +Z onto d
            z = np.array([0, 0, 1.0])
            u = d / L
            ax = np.cross(z, u)
            s, cth = np.linalg.norm(ax), float(np.dot(z, u))
            if s > 1e-9:
                ang = np.degrees(np.arctan2(s, cth))
                k_ = ax / s
                # Rodrigues -> 4x3 matrix for transform()
                K = np.array([[0, -k_[2], k_[1]], [k_[2], 0, -k_[0]], [-k_[1], k_[0], 0]])
                R = np.eye(3) + np.sin(np.radians(ang)) * K + (1 - np.cos(np.radians(ang))) * K @ K
            else:
                R = np.eye(3) if cth > 0 else np.diag([1, -1, -1])
            T = np.hstack([R, a.reshape(3, 1)])
            segs.append(c.transform(T.tolist()))
            segs.append(g.M.sphere(0.6, 8).translate(tuple(b)))
        out.append(g.union(segs))
    return out


def assembly():
    fr, ft, tr = g.frame(), g.footing(), g.tray()
    pcb, cans, pins, plugs = sensor_parts()
    base_z = -g.H_BOSS + g.TRAY_FLOOR
    x0, x1, y0, y1 = g.DE10
    de10 = g.box(x0 + 1, x1 - 1, y0 + 1, y1 - 1, base_z + 10, base_z + 11.6)            # on its 10 mm standoffs
    stand = g.union([g.M.cylinder(10, 1.8).translate((x, y, base_z)) for x in (x0 + 5, x1 - 5) for y in (y0 + 5, y1 - 5)])
    hdr = g.box(x1 - 9, x1 - 4, y0 + 20, y0 + 72, base_z + 11.6, base_z + 20)                # its GPIO header
    bx0, bx1, by0, by1 = g.BREAD
    bread = g.box(bx0 + 0.4, bx1 - 0.4, by0 + 0.4, by1 - 0.4, base_z, base_z + 8.5)
    ux0, ux1, uy0, uy1 = g.UC00C
    uc = g.box(ux0 + 0.4, ux1 - 0.4, uy0 + 0.3, uy1 - 0.3, base_z, base_z + 1.6)
    table = g.box(-150, 240, -95, 110, -g.H_BOSS - 3, -g.H_BOSS)
    m = Model("lanex_gantry")
    for mat, part in ((PLA, fr), (PLA, ft), (PLA, tr), (PCB, pcb), (CAN, cans), (PIN, pins), (PLUG, plugs),
                      (FPGA, de10), (CAN, stand), (PLUG, hdr), (BREAD, bread), (UART, uc), (TABLE, table)):
        m.add(mat, flat(zup_to_gltf(part)))
    cols = [AMBER, Material("w_red", "#C8372B"), Material("w_blk", "#16191C"), Material("w_wht", "#F2F0EA")]
    for mat, w in zip(cols, wires()):
        m.add(mat, flat(zup_to_gltf(w)))
    return m.recentre()


def pod_view():
    fr = g.frame() ^ g.box(-40, 40, -5, 60, 170, 240)
    pcb, cans, pins, plugs = sensor_parts()
    m = Model("pod")
    for mat, part in ((PLA, fr), (PCB, pcb), (CAN, cans), (PIN, pins), (PLUG, plugs)):
        m.add(mat, flat(zup_to_gltf(part)))
    return m.recentre()


def plate_view():
    fr, ft, tr = g.frame(), g.footing(), g.tray()
    pf = g.place_frame(fr)
    ftr, trr = ft.rotate((0, 0, 90)), tr.rotate((0, 0, 90))
    pft = g.place_flat(ftr, 28.0, 80.0)
    ptr = g.place_flat(trr, 28.0, 80.0 + (ftr.bounding_box()[4] - ftr.bounding_box()[1]) + 6.0)
    bed = g.box(0, 256, 0, 256, -2, 0)
    m = Model("plate")
    for mat, part in ((PLA, pf), (PLA, pft), (PLA, ptr), (PLA_DARK, bed)):
        m.add(mat, flat(part.rotate((-90, 0, 0))))
    return m.recentre()


def fit_view():
    fr, ft = g.frame(), g.footing()
    bed = g.box(0, 256, 0, 256, -2, 0)
    m = Model("fit")
    for _, part in g.fit_test_parts(fr, ft):
        m.add(PLA, flat(part.rotate((-90, 0, 0))))
    m.add(PLA_DARK, flat(bed.rotate((-90, 0, 0))))
    return m.recentre()


if __name__ == "__main__":
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    for name, fn in (("view_assembly", assembly), ("view_pod", pod_view), ("view_plate", plate_view), ("view_fit", fit_view)):
        print(name, fn().save(os.path.join(out, name + ".glb")), "triangles")
