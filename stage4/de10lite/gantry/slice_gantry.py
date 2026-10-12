"""Slice the gantry plate for the Bambu Lab A1, ready for its SD card.

    python stage4/de10lite/gantry/slice_gantry.py      (after gantry_cad.py and render_gantry.py)

The print settings are YOUR Bambu Studio settings, taken from the traffic-light job you printed
(a1_bambu_studio_settings.json: Bambu Lab A1 0.4 nozzle, 0.20mm Standard @BBL A1, Generic PLA @BBL A1,
Textured PEI plate), with the overrides below. OrcaSlicer (portable, in build/tools/orca) slices the
project; the result is stamped as an A1 file (printer_model_id N2S, as Bambu Studio writes it), given a
plate thumbnail, and checked. Output: out/LaneX_gantry_A1.gcode.3mf.
"""
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
ORCA = os.path.join(ROOT, "build", "tools", "orca", "orca-slicer.exe")
OUT = os.path.join(HERE, "out")
TARGET = "LaneX_gantry_A1.gcode.3mf"

# Whole-plate changes to "0.20mm Standard @BBL A1", and why
OVERRIDES = {
    "enable_support": "0",               # the design needs none (checked layer by layer in gantry_cad.py)
    "brim_type": "no_brim",              # flat parts with big footprints; keeps clear of the A1's front calibration line
    "sparse_infill_pattern": "gyroid",   # equal stiffness in every direction
    "seam_position": "back",
}
# Per part: light up high, heavy down low (the mass that keeps it standing belongs in the feet)
PER_OBJECT = {
    "frame":   {"wall_loops": "2", "sparse_infill_density": "10%"},
    "footing": {"wall_loops": "4", "sparse_infill_density": "40%"},
    "tray":    {"wall_loops": "4", "sparse_infill_density": "40%"},
}


def project(src_3mf, dst_3mf, objects):
    cfg = json.load(open(os.path.join(HERE, "a1_bambu_studio_settings.json"), encoding="utf-8"))
    cfg.update(OVERRIDES)
    cfg["different_settings_to_system"] = [";".join(sorted(OVERRIDES)), "", ""]
    ms = ['<?xml version="1.0" encoding="UTF-8"?>', "<config>"]
    for i, name in enumerate(objects, start=1):
        ms.append('  <object id="%d">' % i)
        ms.append('    <metadata key="name" value="%s"/>' % name)
        ms.append('    <metadata key="extruder" value="1"/>')
        for k, v in PER_OBJECT.get(name, {}).items():
            ms.append('    <metadata key="%s" value="%s"/>' % (k, v))
        ms.append('    <part id="%d" subtype="normal_part">' % i)
        ms.append('      <metadata key="name" value="%s"/>' % name)
        ms.append('      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>')
        for k, v in PER_OBJECT.get(name, {}).items():
            ms.append('      <metadata key="%s" value="%s"/>' % (k, v))
        ms.append("    </part>")
        ms.append("  </object>")
    ms.append('  <plate>\n    <metadata key="plater_id" value="1"/>\n    <metadata key="plater_name" value="LaneX gantry"/>\n'
              '    <metadata key="locked" value="false"/>')
    for i in range(1, len(objects) + 1):
        ms.append('    <model_instance>\n      <metadata key="object_id" value="%d"/>\n      <metadata key="instance_id" value="0"/>\n    </model_instance>' % i)
    ms.append("  </plate>\n</config>")
    zin = zipfile.ZipFile(src_3mf)
    with zipfile.ZipFile(dst_3mf, "w", zipfile.ZIP_DEFLATED) as z:
        for n in zin.namelist():
            z.writestr(n, zin.read(n))
        z.writestr("Metadata/project_settings.config", json.dumps(cfg, indent=1))
        z.writestr("Metadata/model_settings.config", "\n".join(ms))


def slice_project(proj, outdir, target):
    if os.path.exists(os.path.join(outdir, target)):
        os.remove(os.path.join(outdir, target))
    r = subprocess.run([ORCA, "--slice", "0", "--arrange", "0", "--export-3mf", target, "--outputdir", outdir, proj],
                       capture_output=True, text=True, timeout=900, cwd=outdir)   # its log stays in out/
    loose = os.path.join(outdir, "plate_1.gcode")
    if os.path.exists(loose):
        os.remove(loose)
    if not os.path.exists(os.path.join(outdir, target)):
        raise SystemExit("OrcaSlicer failed: " + (r.stdout + r.stderr)[-1500:])
    return os.path.join(outdir, target)


def finish(path, thumbs):
    """Stamp the A1 model id (as Bambu Studio does), fix the first-layer time, add thumbnails."""
    zin = zipfile.ZipFile(path)
    files = {n: zin.read(n) for n in zin.namelist()}
    zin.close()
    g = files["Metadata/plate_1.gcode"].decode("utf-8", "replace")
    si = files["Metadata/slice_info.config"].decode()
    si = re.sub(r'(key="printer_model_id" value=")[^"]*(")', r"\1N2S\2", si)
    first = first_layer_seconds(g)
    si = re.sub(r'(key="first_layer_time" value=")[^"]*(")', r"\g<1>%.6f\2" % first, si)
    files["Metadata/slice_info.config"] = si.encode()
    pj = json.loads(files["Metadata/plate_1.json"])
    pj["first_layer_time"] = first
    files["Metadata/plate_1.json"] = json.dumps(pj).encode()
    ms = files["Metadata/model_settings.config"].decode()
    if "thumbnail_file" not in ms:
        ms = ms.replace('<metadata key="gcode_file" value="Metadata/plate_1.gcode"/>',
                        '<metadata key="gcode_file" value="Metadata/plate_1.gcode"/>\n'
                        '    <metadata key="thumbnail_file" value="Metadata/plate_1.png"/>\n'
                        '    <metadata key="thumbnail_no_light_file" value="Metadata/plate_no_light_1.png"/>\n'
                        '    <metadata key="top_file" value="Metadata/top_1.png"/>\n'
                        '    <metadata key="pick_file" value="Metadata/pick_1.png"/>\n'
                        '    <metadata key="pattern_bbox_file" value="Metadata/plate_1.json"/>')
    files["Metadata/model_settings.config"] = ms.encode()
    for name, data in thumbs.items():
        files[name] = data
    files["Metadata/plate_1.gcode.md5"] = hashlib.md5(files["Metadata/plate_1.gcode"]).hexdigest().upper().encode()
    ct = files["[Content_Types].xml"].decode()
    if 'Extension="png"' not in ct:
        ct = ct.replace("</Types>", '<Default Extension="png" ContentType="image/png"/></Types>')
        files["[Content_Types].xml"] = ct.encode()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n, d in files.items():
            z.writestr(n, d)


def first_layer_seconds(g):
    m = re.search(r"; first_layer_time\s*[:=]\s*([\d.]+)", g)
    if m:
        return float(m.group(1))
    return 0.0


def thumbnails(p=None):
    """Plate pictures for the printer's screen (rendered through PowerPoint: out/thumb_plate.png)."""
    p = p or os.path.join(OUT, "thumb_plate.png")
    if not os.path.exists(p):
        return {}
    from PIL import Image
    im = Image.open(p).convert("RGB")
    w, h = im.size
    s = min(w, h)
    im = im.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
    out = {}
    for name, size in (("Metadata/plate_1.png", 512), ("Metadata/plate_1_small.png", 128),
                       ("Metadata/plate_no_light_1.png", 512), ("Metadata/top_1.png", 512), ("Metadata/pick_1.png", 512)):
        b = io.BytesIO()
        im.resize((size, size)).save(b, "PNG")
        out[name] = b.getvalue()
    return out


def check(path):
    z = zipfile.ZipFile(path)
    g = z.read("Metadata/plate_1.gcode").decode("utf-8", "replace")
    si = z.read("Metadata/slice_info.config").decode()

    def meta(key):
        m = re.search(r'key="%s" value="([^"]*)"' % key, si)
        return m.group(1) if m else ""

    secs = float(meta("prediction") or 0)
    feats = sorted(set(re.findall(r";\s*FEATURE:\s*([^\n]+)", g)) | set(re.findall(r";TYPE:([^\n]+)", g)))
    xs, ys, zmax = [], [], 0.0
    cur_z = 0.0
    for line in g.splitlines():
        if line.startswith(("G1", "G0", "G2", "G3")):
            mz = re.search(r"Z([-\d.]+)", line)
            if mz:
                cur_z = float(mz.group(1))
            if " E" in line and "X" in line and "Y" in line and not re.search(r"E-", line):
                mx, my = re.search(r"X([-\d.]+)", line), re.search(r"Y([-\d.]+)", line)
                xs.append(float(mx.group(1)))
                ys.append(float(my.group(1)))
    support = [f for f in feats if "upport" in f]
    rows = [
        ("printer", "Bambu Lab A1 (printer_model_id %s), 0.4 mm nozzle" % meta("printer_model_id")),
        ("time", "%d h %02d min" % (secs // 3600, secs % 3600 // 60)),
        ("filament", "%s g of PLA" % meta("weight")),
        ("features", ", ".join(feats)),
        ("support", "none" if not support else ", ".join(support)),
        ("extrusion area", "X %.1f..%.1f  Y %.1f..%.1f (bed 0..256)" % (min(xs), max(xs), min(ys), max(ys))),
        ("thumbnail", "yes" if "Metadata/plate_1.png" in z.namelist() else "no"),
    ]
    for k, v in rows:
        print("  %-15s %s" % (k, v))
    for k in ("wall_loops", "sparse_infill_density", "brim_type", "enable_support", "curr_bed_type", "layer_height"):
        m = re.search(r"; %s = (.*)" % k, g)
        print("  %-15s %s" % (k, m.group(1) if m else "?"))
    ok = not support and meta("printer_model_id") == "N2S" and min(xs) >= 0 and max(xs) <= 256 and min(ys) >= 0 and max(ys) <= 256
    print("G-CODE CHECK:", "PASS" if ok else "FAIL")
    return ok, {"seconds": secs, "grams": float(meta("weight") or 0)}


def main():
    os.makedirs(os.path.join(OUT, "slice"), exist_ok=True)
    objects = ["frame", "footing", "tray"]
    proj = os.path.join(OUT, "slice", "lanex_gantry_project.3mf")
    project(os.path.join(OUT, "lanex_gantry_plate.3mf"), proj, objects)
    path = slice_project(proj, OUT, TARGET)
    finish(path, thumbnails())
    print(TARGET)
    ok, stats = check(path)
    # each part on its own, for its mass (the stability calculation needs it)
    masses = {}
    for name in objects:
        single = os.path.join(OUT, "slice", "single_%s.3mf" % name)
        src = zipfile.ZipFile(os.path.join(OUT, "lanex_gantry_plate.3mf"))
        model = src.read("3D/3dmodel.model").decode()
        keep = objects.index(name) + 1
        model = re.sub(r'<item objectid="(\d+)"/>', lambda m: m.group(0) if int(m.group(1)) == keep else "", model)
        tmp = os.path.join(OUT, "slice", "only_%s.3mf" % name)
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
            for n in src.namelist():
                z.writestr(n, model if n == "3D/3dmodel.model" else src.read(n))
        project(tmp, single, objects)
        p = slice_project(single, os.path.join(OUT, "slice"), "single_%s.gcode.3mf" % name)
        si = zipfile.ZipFile(p).read("Metadata/slice_info.config").decode()
        masses[name] = float(re.search(r'key="weight" value="([^"]*)"', si).group(1))
    print("  part masses (g):", masses)
    # the fit test
    fproj = os.path.join(OUT, "slice", "lanex_gantry_fit_project.3mf")
    project(os.path.join(OUT, "lanex_gantry_fit_test.3mf"), fproj, ["fit_pod", "fit_foot", "fit_socket"])
    fpath = slice_project(fproj, OUT, "LaneX_gantry_FIT_TEST_A1.gcode.3mf")
    finish(fpath, thumbnails(os.path.join(OUT, "thumb_fit.png")))
    print("LaneX_gantry_FIT_TEST_A1.gcode.3mf")
    fok, fstats = check(fpath)
    ok = ok and fok
    json.dump({"ok": ok, **stats, "masses_g": masses, "fit_test": fstats}, open(os.path.join(OUT, "slice_report.json"), "w"), indent=1)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
