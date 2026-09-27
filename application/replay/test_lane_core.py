#!/usr/bin/env python3
"""Run the replay page's own logic (lane_core.js) in QuickJS and check
it against independent references:

  1. Chaskey-12 against the reference implementation's test vectors, and
     against lane_model.py's Chaskey on random messages; CRC-16 and the Gen2
     tag CRC against lane_model.py.
  2. decode/verify on the golden model's showcase output: every CRC and every
     'A' tag verifies; a flipped bit fails both.
  3. The blind test: for several seeds, both rates, the page's scenario is
     played through the golden model (LaneModel); the page's predicted records
     and pins must equal the model's byte for byte.
  4. The transcript parser, including the platform's three runs pasted
     together (the 'A' counter restarts at each run's LANE header).
  5. With --sim: the testbench the page generates for a blind scenario runs on
     the exported chip (application ROM) under Icarus Verilog, and the chip's
     transcript, parsed by the page, must equal the page's prediction.

    python application/replay/test_lane_core.py [--sim]
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "application", "testbench"))
import lane_model as L  # noqa: E402

try:
    import quickjs
except ImportError:
    sys.exit("SKIP quickjs not installed (python -m pip install quickjs)")

passed = failed = 0


def check(ok, what):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL " + what)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", action="store_true", help="also run a generated blind testbench on the export")
    a = ap.parse_args()
    ctx = quickjs.Context()
    ctx.eval(open(os.path.join(HERE, "lane_core.js"), encoding="utf-8").read())
    js = lambda expr: json.loads(ctx.eval("JSON.stringify(%s)" % expr))   # noqa: E731

    # 1. primitives
    key = list(L.CHASKEY_KEY)
    for n, tag in L.CHASKEY_VECTORS.items():
        got = js("LaneCore.hex(LaneCore.chaskey12(%s, %s, 8))" % (key, list(range(n))))
        check(got == tag, "Chaskey-12 vector, %d-byte message" % n)
    rng = random.Random(5)
    for _ in range(40):
        k = [rng.getrandbits(8) for _ in range(16)]
        m = [rng.getrandbits(8) for _ in range(rng.randint(0, 70))]
        check(js("LaneCore.hex(LaneCore.chaskey12(%s, %s, 8))" % (k, m)) == L.chaskey12(bytes(k), bytes(m)).hex(),
              "Chaskey-12 equals the model's, random message")
        check(js("LaneCore.crc16(%s)" % m) == L.crc16(bytes(m)), "CRC-16 equals the model's")
        e = m[:12] + [0] * (12 - len(m[:12]))
        check(js("LaneCore.gen2Crc(12288, %s)" % e) == L.gen2_crc(0x3000, bytes(e)), "Gen2 CRC")

    # 2. verify the model's showcase stream; a flipped bit is caught
    out = L.showcase_scenario().run().out
    recs = [list(out[i:i + 8]) for i in range(0, len(out), 8)]
    v = js("LaneCore.verify(%s)" % json.dumps(recs))
    check(all(d["crcOk"] for d in v), "every showcase record's CRC verifies")
    auth = [d for d in v if d["kind"] == "A"]
    check(len(auth) == 7 and all(d["authOk"] for d in auth), "every showcase 'A' tag verifies (7)")
    bad = [r[:] for r in recs]
    k = next(i for i, r in enumerate(bad) if r[0] == 0x56)
    bad[k][4] ^= 1                                      # the fare, one bit
    v2 = js("LaneCore.verify(%s)" % json.dumps(bad))
    check(not v2[k]["crcOk"] and not v2[k + 1]["authOk"], "a flipped fare bit fails the CRC and the tag")

    # 3. blind scenarios, predicted by the page, played through the model
    for seed in (1, 2, 3, 42, 2026, 777):
        for fast in (True, False):
            b = js("LaneCore.makeBlind({seed:%d, n:12, fast:%s})" % (seed, "true" if fast else "false"))
            sc = L.Scenario()
            for kind, val in b["events"]:
                if kind == "G":
                    sc.pins(val)
                else:
                    sc.send(bytes(val))
            m = sc.run()
            model_recs = [list(m.out[i:i + 8]) for i in range(0, len(m.out), 8)]
            check(model_recs == b["expect"], "blind seed %d fast=%s: the page predicts every record" % (seed, fast))
            check([p >> 4 for p in m.vehicle_pins] == b["pins"],
                  "blind seed %d fast=%s: the page predicts every vehicle's pins" % (seed, fast))
    kinds = js("LaneCore.KINDS")
    b = js("LaneCore.makeBlind({seed:9, n:80, fast:true})")
    check(set(v["kind"] for v in b["plan"]) == set(kinds), "80 vehicles of seed 9 cover every kind")

    # 4. parse a transcript
    t = "LANE x UART 33 clocks/bit\nREC 0 @100 56000011fa003c7b ok\nPINS 0 @90 0001 ok\n" \
        '{"kind":"V","pins":1,"rec":"56000011fa003c7b"}\nnoise\n4100db5f9a6a8fdf\n'
    p = js("LaneCore.parseTranscript(%s)" % json.dumps(t))
    check(len(p["recs"]) == 3 and p["nb"] == 33 and p["pins"][0]["bits"] == 1, "transcript parser")

    # 5. the platform's three runs pasted together: each starts from reset, so
    # the 'A' counter restarts at every LANE header
    log = []
    for s, (name, sc) in enumerate(L.platform_scenarios()):
        out = sc.run().out
        log.append("LANE LaneX toll lane controller on RVBL-2 SCEN=%d %s UART 33 clocks/bit" % (s, name))
        log += ["REC %d @%d %s ok" % (i // 8, 1000 + i, out[i:i + 8].hex()) for i in range(0, len(out), 8)]
    p = js("LaneCore.parseTranscript(%s)" % json.dumps("\n".join(log)))
    check([r["label"] for r in p["runs"]] == ["SCEN 0 lane-a", "SCEN 1 lane-b", "SCEN 2 identity"],
          "three pasted runs are told apart")
    got = [r["bytes"] for r in p["recs"]]
    v = js("LaneCore.verify(%s, null, null, %s)" % (json.dumps(got), json.dumps([r["run"] for r in p["recs"]])))
    auth = [d for d in v if d["kind"] == "A"]
    check(len(auth) >= 5 and all(d["authOk"] for d in auth) and all(d["crcOk"] for d in v),
          "three pasted runs: every record verifies, the counter restarting per run (%d tags)" % len(auth))
    v1 = js("LaneCore.verify(%s)" % json.dumps(got))
    check(not all(d["authOk"] for d in v1 if d["kind"] == "A"),
          "three pasted runs read as one: the later runs' tags fail (the counter would be wrong)")

    if a.sim:
        sim_blind(js)
    print("==== test_lane_core: %d passed, %d failed ====" % (passed, failed))
    print("TEST_LANE_CORE: ALL TESTS PASSED" if not failed else "TEST_LANE_CORE: FAILURES PRESENT")
    return 1 if failed else 0


def sim_blind(js):
    """Generate a blind testbench with the page's code and run it on the export
    (application ROM swapped in) - the chip's answer against the page's."""
    exp = os.path.join(ROOT, "chipinventor", "export_stage3.v")
    src = exp if os.path.exists(exp) else None
    build = os.path.join(ROOT, "build", "lane")
    os.makedirs(build, exist_ok=True)
    rom = re.search(r"(?ms)^module imem\b.*?^endmodule",
                    open(os.path.join(ROOT, "chipinventor", "app", "imem_app.v")).read()).group(0)
    if src:
        text = open(src).read()
        text = re.sub(r"(?ms)^module imem\b.*?^endmodule", lambda m: rom, text)
        uart = uart_path(src)
    else:                                                 # the local mirror of the canvas
        blocks = os.path.join(ROOT, "chipinventor", "blocks")
        text = "".join(open(os.path.join(blocks, f)).read() + "\n" for f in sorted(os.listdir(blocks))
                       if f.endswith(".v") and f not in ("imem.v", "imem_mock.v"))
        text += open(os.path.join(ROOT, "chipinventor", "ci_top.v")).read() + "\n" + rom + "\n"
        uart = "dut.u_soc.u_uart"
    chip = os.path.join(build, "blind_chip.v")
    open(chip, "w").write(text)
    where = "export" if src else "mirror"
    for seed, n in ((314, 3), (2026, 3), (9, 4)):
        opt = "{seed:%d, n:%d, fast:true}" % (seed, n)
        b = js("LaneCore.makeBlind(%s)" % opt)
        tb = os.path.join(build, "blind_test.v")
        open(tb, "w", newline="\n").write(js("LaneCore.blindTestbench(LaneCore.makeBlind(%s), %s)"
                                             % (opt, json.dumps(uart))))
        vvp = os.path.join(build, "blind.vvp")
        r = subprocess.run(["iverilog", "-g2005", "-s", "testbench", "-o", vvp, chip, tb],
                           capture_output=True, text=True)
        check(r.returncode == 0, "the generated blind testbench compiles: " + r.stderr[:300])
        if r.returncode:
            return
        log = subprocess.run(["vvp", "-n", vvp], capture_output=True, text=True).stdout
        p = js("LaneCore.parseTranscript(%s)" % json.dumps(log))
        got = [r["bytes"] for r in p["recs"]]
        check(got == b["expect"], "blind seed %d on the %s: the chip's %d records equal the page's prediction"
              % (seed, where, len(got)))
        check([x["bits"] for x in p["pins"]] == b["pins"], "blind seed %d: the chip's pins equal the prediction" % seed)
        v = js("LaneCore.verify(%s)" % json.dumps(got))
        check(all(d["crcOk"] for d in v) and all(d["authOk"] for d in v if d["kind"] == "A"),
              "blind seed %d: every record from the chip verifies (CRC and Chaskey-12)" % seed)
        done = re.search(r"BLIND DONE \d+ records, (\d+) cycles", log)
        check(done and int(done.group(1)) == b["cycles"],
              "blind seed %d: the page's cycle estimate (%d) is the run's length" % (seed, b["cycles"]))
        print("     blind test (seed %d, %d vehicles: %s; %s): %d records, %s"
              % (seed, n, ", ".join(v["kind"] for v in b["plan"]), where, len(got), log.strip().splitlines()[-1]))


def uart_path(export):
    """dut.<SoC instance>.<uart instance>, as gen_ci_aliases.py resolves them."""
    sys.path.insert(0, os.path.join(ROOT, "chipinventor", "scripts"))
    out = subprocess.run([sys.executable, os.path.join(ROOT, "chipinventor", "scripts", "gen_ci_aliases.py"), export],
                         capture_output=True, text=True).stdout
    soc = re.search(r"`define SOC\s+`DUT\.(\S+)", out).group(1)
    uart = re.search(r"`define UART\s+`SOC\.(\S+)", out).group(1)
    return "dut.%s.%s" % (soc, uart)


if __name__ == "__main__":
    sys.exit(main())
