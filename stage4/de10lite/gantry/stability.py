"""How hard you must push the gantry to tip it over, and how far it can lean.

    python stage4/de10lite/gantry/stability.py      (after slice_gantry.py: it uses the sliced masses)

Rigid-body statics: the gantry tips about the edge of its footprint when the push's moment beats the
weight's. Masses come from the slicer (out/slice_report.json); each part's centre of gravity is its
solid's centroid (the infill is even, so this is close). The push is horizontal, at the top of the beam.
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gantry_cad as g  # noqa: E402

G = 9.81


def centroid(m):
    v, f = g.mesh_arrays(m)
    a, b, c = v[f[:, 0]], v[f[:, 1]], v[f[:, 2]]
    vol = np.einsum("ij,ij->i", a, np.cross(b, c)) / 6.0
    return (vol[:, None] * (a + b + c) / 4.0).sum(0) / vol.sum()


def analyse(parts, extras, y_front, y_back, x_left, x_right, z_table, z_push):
    """parts: [(mass_g, (x, y, z))]. Returns the push (N) to tip each way and the lean angle."""
    m = sum(p[0] for p in parts + extras)
    c = sum(p[0] * np.array(p[1]) for p in parts + extras) / m
    h_cg = c[2] - z_table
    h_push = z_push - z_table
    W = m / 1000 * G
    out = {"mass_g": round(m, 1), "cog_height_mm": round(h_cg, 1)}
    for name, d in (("forward", y_front - c[1]), ("backward", c[1] - y_back),
                    ("sideways", min(x_right - c[0], c[0] - x_left))):
        out[name] = {"push_N": round(W * d / h_push, 2), "push_grams_force": round(W * d / h_push / G * 1000),
                     "lean_deg": round(float(np.degrees(np.arctan2(d, h_cg))), 1)}
    return out


def main():
    rep = json.load(open(os.path.join(HERE, "out", "slice_report.json")))
    mass = rep["masses_g"]
    fr, ft, tr = g.frame(), g.footing(), g.tray()
    parts = [(mass["frame"], centroid(fr)), (mass["footing"], centroid(ft)), (mass["tray"], centroid(tr))]
    sensor = [(9.0, (0.0, g.CAN_Y, g.Z_PCB_FRONT))]                  # HC-SR04 ~9 g
    table = -g.H_BOSS
    top = g.ZT
    foot = dict(y_front=g.FOOT_Y1, y_back=g.FOOT_Y0, x_left=-g.XC - g.FOOT_W / 2, x_right=g.TRAY_X1,
                z_table=table, z_push=top)
    coins = [(4 * 10 * 5.66, (-g.XC, (g.FOOT_Y0 + g.FOOT_Y1) / 2, table + g.PLATE + 9))]   # 40 x 50-sen coins
    cases = {
        "printed parts + sensor (worst case: tray empty, no coins)": analyse(parts, sensor, **foot),
        "+ 40 coins (50 sen) in the four cups": analyse(parts, sensor + coins, **foot),
    }
    # your previous traffic-light stand, from its own G-code weights and part sizes, for comparison:
    # a 150 x 150 x 30 base, a 20 x 20 post 204.5 mm, an L-arm and the sensor head (~250 mm tall)
    old = [(175.25, (0, 0, 15)), (73.73 * 0.7, (0, 0, 30 + 102)), (73.73 * 0.3, (0, 60, 225)), (42.41, (0, 40, 230)), (9.0, (0, 75, 220))]
    cases["your previous stand (estimate)"] = analyse(old, [], y_front=75, y_back=-75, x_left=-75, x_right=75, z_table=0, z_push=250)
    width = max(len(k) for k in cases)
    print("Push at the top of the beam needed to tip it over (and how far it can lean first):")
    for k, r in cases.items():
        f, b, s = r["forward"], r["backward"], r["sideways"]
        print("  %s  %5.0f g total  forward %.2f N (%d gf, %.0f deg)  back %.2f N (%.0f deg)  side %.2f N (%.0f deg)" % (
            k.ljust(width), r["mass_g"], f["push_N"], f["push_grams_force"], f["lean_deg"], b["push_N"], b["lean_deg"],
            s["push_N"], s["lean_deg"]))
    print("Joint play: wedge tenons lock with zero clearance (gantry_cad.py check); a 0.2 mm slip fit over a 13 mm")
    print("socket would rock %.1f deg, %.1f mm at the beam." % (np.degrees(np.arctan2(0.4, 13)), (g.ZT + g.H_BOSS) * 0.4 / 13))
    json.dump(cases, open(os.path.join(HERE, "out", "stability.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
