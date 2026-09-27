#!/usr/bin/env python3
"""Build the lane-controller replay page (the demo and the evidence page).

    python application/replay/gen_lane_replay.py [--out build/lane/replay.html]
    python application/replay/gen_lane_replay.py --standalone --out docs/demo/index.html

Inlines lane_core.js (the page's decoding, CRC-16, Chaskey-12 and blind-test
logic; test_lane_core.py tests it against the golden model) into
lane_replay.html (all three beside this file), with:

  transcripts   the chip's own output, as captured at tx_o when the ChipInventor
                export (application ROM) is simulated with tb_app_ci: the fast
                run (921,600 bps) and the taped-out rate (115,200 bps). They
                come from chipinventor/scripts/run_ci.sh's logs; the local mirror
                of the canvas stands in until there is an export.
  fingerprint   the firmware image's size and CRC, as the chip's 'I' reports it
  uartPath      the UART instance in the export, for the blind test's defparam
  emu           the emulator preview's log (build/emu_preview.log, written by
                scripts/run_all.sh): each ./emu line and the chip's answers
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CI = os.path.join(ROOT, "chipinventor")
BUILD = os.path.join(CI, "build")
sys.path.insert(0, os.path.join(ROOT, "application", "testbench"))
import lane_model as L  # noqa: E402


def transcript(candidates):
    """The first candidate whose logs all exist and every run in them passed.
    A candidate is one or more logs (the fast demo is three runs), read one
    after another as a pasted transcript would be."""
    for paths, prov in candidates:
        paths = [paths] if isinstance(paths, str) else paths
        if all(os.path.exists(p) for p in paths):
            text = "".join(open(p, encoding="utf-8", errors="replace").read() for p in paths)
            keep = [l for l in text.splitlines() if re.match(r"^(LANE|REC|PINS|====|TB_APP_CI)", l)]
            runs = sum(l.startswith("LANE") for l in keep)
            if runs and any(l.startswith("REC") for l in keep) and \
                    sum("ALL TESTS PASSED" in l for l in keep) == runs:
                return {"text": "\n".join(keep) + "\n", "prov": prov}
    sys.exit("no passing application transcript: run chipinventor/scripts/run_ci.sh first")


def emu_runs(path):
    """The emulator preview's log: each ./emu line, and the chip's answer to
    every option, as emu prints it. Only a log in which every line passed."""
    if not os.path.exists(path):
        sys.exit("%s missing: run scripts/run_all.sh (the emu_preview flow) first" % path)
    lines, cur = [], None
    for l in open(path, encoding="utf-8", errors="replace").read().splitlines():
        m = re.match(r"^-- (\d+)\. (.*)$", l)
        if m:
            cur = {"n": int(m.group(1)), "title": m.group(2), "cmd": "", "steps": [], "pass": False}
            lines.append(cur)
        elif cur and l.startswith("$ ./emu "):
            cur["cmd"] = l[2:]
        elif cur and re.match(r"^\[(ok|error)\] ", l):
            cur["steps"].append(l)
        elif cur and l == "PASS line %d" % cur["n"]:
            cur["pass"] = True
    if not lines or not all(x["pass"] and x["cmd"] for x in lines):
        sys.exit("%s: not every emulator line passed" % path)
    return lines


def uart_path():
    exp = os.path.join(CI, "export_stage3.v")
    if not os.path.exists(exp):
        return "dut.u_soc.u_uart"
    out = subprocess.run([sys.executable, os.path.join(CI, "scripts", "gen_ci_aliases.py"), exp],
                         capture_output=True, text=True).stdout
    soc = re.search(r"`define SOC\s+`DUT\.(\S+)", out).group(1)
    uart = re.search(r"`define UART\s+`SOC\.(\S+)", out).group(1)
    return "dut.%s.%s" % (soc, uart)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "lane", "replay.html"))
    ap.add_argument("--standalone", action="store_true",
                    help="wrap the page in a full HTML document, to host it as a file "
                         "(docs/demo/index.html is the copy GitHub Pages serves)")
    a = ap.parse_args()
    exp_note = ("Simulated with Icarus Verilog from our ChipInventor export (chipinventor/export_stage3.v) "
                "with the application ROM in imem")
    mir_note = ("Simulated with Icarus Verilog from the local mirror of the canvas (ci_top.v) "
                "with the application ROM in imem")
    data = {
        "transcripts": {
            "fast": transcript([
                (os.path.join(BUILD, "tb_app_platform.log"),
                 exp_note + "; UART at 921,600 bps, the platform's three runs (SCEN 0, 1, 2), each from reset. "
                 "Captured at the chip's tx_o pin."),
                ([os.path.join(BUILD, "tb_app_fast_s%d.log" % s) for s in range(3)],
                 mir_note + "; UART at 921,600 bps, three runs (SCEN 0, 1, 2), each from reset. "
                 "Captured at the chip's tx_o pin.")]),
            "true": transcript([
                (os.path.join(BUILD, "tb_app_true_export.log"),
                 exp_note + "; UART at 115,200 bps, the chip as taped out. Captured at the chip's tx_o pin."),
                (os.path.join(BUILD, "tb_app_ci.log"),
                 mir_note + "; UART at 115,200 bps. Captured at the chip's tx_o pin.")]),
        },
        "fingerprint": {},
        "uartPath": uart_path(),
        "emu": emu_runs(os.path.join(ROOT, "build", "emu_preview.log")),
    }
    rom = L.load_rom()
    if rom is None:
        sys.exit("application/firmware/out/lane/firmware.hex missing: run make in application/firmware")
    data["fingerprint"] = {"words": len(rom), "crc": L.rom_crc(rom), "file": "application/firmware (firmware.bin)"}
    tpl = open(os.path.join(HERE, "lane_replay.html"), encoding="utf-8").read()
    core = open(os.path.join(HERE, "lane_core.js"), encoding="utf-8").read()
    assert tpl.count("/*DATA*/null") == 1 and tpl.count("/*CORE*/") == 1
    html = tpl.replace("/*CORE*/", core).replace("/*DATA*/null", json.dumps(data, separators=(",", ":")))
    if a.standalone:
        html = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
                '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
                '<style>body{margin:0}</style>\n</head>\n<body>\n' + html + '\n</body>\n</html>\n')
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(html)
    print("wrote %s (%d bytes): transcripts %s; %d ./emu lines; ROM %d words CRC 0x%04X; UART %s"
          % (os.path.relpath(a.out, ROOT), len(html),
             ", ".join("%s %d records" % (k, v["text"].count("\nREC ") + v["text"].startswith("REC "))
                       for k, v in data["transcripts"].items()),
             len(data["emu"]), data["fingerprint"]["words"], data["fingerprint"]["crc"], data["uartPath"]))


if __name__ == "__main__":
    main()
