"""Close-up preview scenes: the sensor pod (empty and loaded) and the cabinet tray with its electronics.

    python stage4/de10lite/gantry/render_parts.py      -> out/view_tray.glb, out/view_pod_empty.glb
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gantry_cad as g  # noqa: E402
import render_gantry as r  # noqa: E402
from glb import Material, Model  # noqa: E402

SHELL = Material("shell", "#8E96A0", roughness=0.3, metallic=0.8)    # connector shells
BLUE_D = Material("vga", "#2E5C9E", roughness=0.5)
BB_TOP = Material("bb", "#F2F0EA", roughness=0.7)
HOLES = Material("holes", "#3A3F44", roughness=0.8)


def tray_scene():
    tr = g.tray()
    fl = -g.H_BOSS + g.TRAY_FLOOR
    x0, x1, y0, y1 = g.DE10_PCB
    zp = fl + 10.0
    pcb = g.box(x0, x1, y0, y1, zp, zp + 1.6)
    stand = g.union([g.M.cylinder(10, 2.6).translate((x, y, fl)) for x in (x0 + 4, x1 - 4) for y in (y0 + 4, y1 - 4)])
    gpio = g.box(x1 - 9, x1 - 4, y0 + 20, y0 + 72, zp + 1.6, zp + 10)
    fpga = g.box((x0 + x1) / 2 - 12, (x0 + x1) / 2 + 12, (y0 + y1) / 2 - 12, (y0 + y1) / 2 + 12, zp + 1.6, zp + 3.0)
    vga = g.box(x0 + 20, x0 + 51, y1 - 6, y1 + 6.0, zp - 2.0, zp + 12.5)          # D-SUB at the VGA end
    usb = g.box(x1 - 32, x1 - 20, y0 - 3.0, y0 + 13, zp + 1.6, zp + 12.6)          # USB-B at the other end
    bx0, bx1, by0, by1 = g.BREAD
    bb = g.box(bx0 + 2.75, bx1 - 2.75, by0 + 2.75, by1 - 2.75, fl, fl + 8.5)
    rows = g.union([g.box(bx0 + 8 + 2.54 * i - 0.5, bx0 + 8 + 2.54 * i + 0.5, by0 + 9, by1 - 9, fl + 8.45, fl + 8.6)
                    for i in range(28)])
    ux0, ux1, uy0, uy1 = g.UC00C
    ucx = (ux0 + ux1) / 2
    uc = g.box(ucx - 10.6, ucx + 10.6, uy0 + 2.6, uy0 + 42.4, fl, fl + 1.6)
    micro = g.box(ucx - 4, ucx + 4, uy0 + 40.0, uy0 + 43.5, fl + 1.6, fl + 4.6)
    hdr = g.box(ucx - 7.6, ucx + 7.6, uy0 + 2.6, uy0 + 5.2, fl + 1.6, fl + 10.1)
    post = g.frame() ^ g.box(g.XC - 10, g.XC + 10, -1, 30, -g.H_BOSS - 1, 40)      # the post's foot, seated
    m = Model("tray")
    for mat, part in ((r.PLA, tr), (r.PLA, post), (r.FPGA, pcb), (r.CAN, stand), (r.PLUG, gpio), (r.PLUG, fpga),
                      (BLUE_D, vga), (SHELL, usb), (BB_TOP, bb), (HOLES, rows), (r.UART, uc), (SHELL, micro), (r.PLUG, hdr)):
        m.add(mat, r.flat(r.zup_to_gltf(part)))
    return m.recentre()


def pod_empty():
    m = Model("pod_empty")
    m.add(r.PLA, r.flat(r.zup_to_gltf(g.frame() ^ g.box(-40, 40, -5, 60, 170, 240))))
    return m.recentre()


if __name__ == "__main__":
    out = os.path.join(HERE, "out")
    for name, fn in (("view_tray", tray_scene), ("view_pod_empty", pod_empty)):
        print(name, fn().save(os.path.join(out, name + ".glb")))
