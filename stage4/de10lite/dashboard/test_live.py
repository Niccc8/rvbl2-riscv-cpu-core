#!/usr/bin/env python3
"""test_live.py - V6: LaneX Live's logic (live_core.js + lane_core.js, exactly as
inlined in lanex_live.html) run in QuickJS against the golden model.

    python stage4/de10lite/dashboard/test_live.py

  * the back-office buttons' frames equal lane_model.py's frames, byte for byte;
  * the page's demo stream: every record found, every signature verified, the
    totals equal the model's;
  * the bytes the laptop received in the board simulation (check_board.py's
    logs, if present): cut at random into USB-sized chunks, every record is
    found and equals the chip's, every 'A' verifies (the counter found by the
    page itself), across chip resets and tour mode;
  * a damaged byte costs only its own record (the page finds the next one), and
    a forged signature is reported as not verifying.
"""
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "stage4"))
sys.path.insert(0, os.path.join(ROOT, "application", "testbench"))
import gen_de10lite as D      # noqa: E402
import lane_model as L        # noqa: E402

try:
    import quickjs
except ImportError:
    sys.exit("SKIP quickjs not installed (python -m pip install quickjs)")

PAGE = os.path.join(ROOT, "stage4", "de10lite", "lanex_live.html")
fails, checks = [], 0


def check(ok, what):
    global checks
    checks += 1
    if not ok:
        fails.append(what)


def js_context():
    page = open(PAGE, encoding="utf-8").read()
    scripts = re.findall(r"<script>\n(.*?)\n</script>", page, re.S)
    ctx = quickjs.Context()
    for s in scripts[:3]:                      # lane_core, live_core, BOARD + DEMO (not the UI)
        ctx.eval(s)
    return ctx, json.loads(ctx.eval("JSON.stringify(BOARD)")), json.loads(ctx.eval("JSON.stringify(DEMO)"))


def feed(ctx, chunks):
    """[(bytes, t_ms)] through a fresh LiveCore.Lane; returns its records and stats."""
    ctx.eval("var lane = new LiveCore.Lane(BOARD); var got = [];")
    for b, t in chunks:
        ctx.eval("got = got.concat(lane.push(%s, %f));" % (json.dumps(list(b)), t))
    return (json.loads(ctx.eval("JSON.stringify(got)")), json.loads(ctx.eval("JSON.stringify(lane.stats)")))


def main():
    ctx, board, demo = js_context()
    words = L.load_rom()

    # the page's constants are the board's
    check(bytes(board["key"]) == L.DEMO_KEY and board["romCrc"] == D.G.rom_crc(words)
          and board["romWords"] == len(words), "BOARD constants differ from the build")

    # back-office frames
    for name, p in (("CAb", 3), ("CAr", 1), ("LorrY", 2)):
        epc = D.PRESETS[p][1]
        got = json.loads(ctx.eval("JSON.stringify(LiveCore.Frames.hotAdd(BOARD, %s))" % json.dumps(name)))
        check(bytes(got) == L.f_hot_add(epc), "hotAdd %s frame" % name)
        got = json.loads(ctx.eval("JSON.stringify(LiveCore.Frames.hotDel(BOARD, %s))" % json.dumps(name)))
        check(bytes(got) == L.f_hot_del(epc), "hotDel %s frame" % name)
    for closed in (0, 1):
        got = json.loads(ctx.eval("JSON.stringify(LiveCore.Frames.lane(BOARD, %s))" % ("true" if closed else "false")))
        check(bytes(got) == L.f_config(D.GANTRY, closed, L.DEFAULT_FARES), "lane closed=%d frame" % closed)
    check(bytes(json.loads(ctx.eval("JSON.stringify(LiveCore.Frames.query())"))) == L.f_query(), "query frame")
    check(bytes(json.loads(ctx.eval("JSON.stringify(LiveCore.Frames.identify())"))) == L.f_identify(), "identify frame")

    # the demo stream
    t, chunks = 0.0, []
    for delay, h in demo:
        t += delay
        chunks.append((bytes.fromhex(h), t))
    recs, st = feed(ctx, chunks)
    check(len(recs) == len(demo), "demo: %d records found of %d" % (len(recs), len(demo)))
    a = [r for r in recs if r["kind"] == "A"]
    check(a and all(r["authOk"] for r in a), "demo: a signature did not verify")
    check([r["counter"] for r in a] == list(range(len(a))), "demo: counters %s" % [r["counter"] for r in a])
    vs = [r for r in recs if r["kind"] == "V"]
    want_rev = sum(r["fare"] for r in vs if r["code"] in (0, 2))
    check(st["vehicles"] == len(vs) and st["revenue"] == want_rev and
          st["alarms"] == sum(r["code"] in (3, 4) for r in vs), "demo: totals %s" % st)
    check([r["code"] for r in vs] == [0, 2, 3, 4, 0, 1, 5, 0, 1], "demo: story %s" % [r["code"] for r in vs])
    ident = [r for r in recs if r["kind"] == "I"]
    check(ident and ident[0]["romOk"], "demo: the identity record does not match the build")

    # damage: one flipped byte in the 3rd record; a forged tag in the 4th 'A'
    stream = b"".join(bytes.fromhex(h) for _, h in demo)
    bad = bytearray(stream)
    bad[2 * 8 + 3] ^= 0x10
    recs, _ = feed(ctx, [(bytes(bad[i:i + 5]), i * 0.05) for i in range(0, len(bad), 5)])
    check(len(recs) == len(demo) - 1, "damage: %d records found, want %d" % (len(recs), len(demo) - 1))
    forged = bytearray(stream)
    forged[7 * 8 + 4] ^= 0x01                  # the 4th 'A' record's tag ...
    body = bytes(forged[7 * 8:7 * 8 + 6])
    forged[7 * 8 + 6:7 * 8 + 8] = L.crc16(body).to_bytes(2, "little")   # ... with a valid CRC
    recs, _ = feed(ctx, [(bytes(forged), 0.0)])
    a = [r for r in recs if r["kind"] == "A"]
    check(len(a) == len(demo) // 2 and [r["authOk"] for r in a].count(False) == 1 and not a[3]["authOk"],
          "forgery: %s" % [r["authOk"] for r in a])
    check(a[4]["authOk"] and a[4]["counter"] == 4, "forgery: the next record lost its counter")

    # the board simulation's laptop stream (check_board.py's full-pass logs)
    rng = random.Random(7)
    nlogs = 0
    for name in ("matrix", "host", "tour", "edges"):
        log = os.path.join(ROOT, "build", "de10lite", name + "_full.log")
        if not os.path.exists(log):
            continue
        nlogs += 1
        tx, chip = [], []
        for line in open(log):
            p = line.split()
            if p and p[0] == "T":
                tx.append((int(p[2], 16), int(p[1]) / 3125.0))     # board ms in that pass
            elif p and p[0] == "C":
                chip.append(int(p[2], 16))
        # USB-serial delivers what has arrived in chunks of any size, but never
        # holds bytes back across a pause: a chunk ends at a gap over 5 ms
        chunks, i = [], 0
        while i < len(tx):
            n = 1
            limit = rng.choice((1, 2, 3, 8, 13, 32, 64))
            while i + n < len(tx) and n < limit and tx[i + n][1] - tx[i + n - 1][1] <= 5.0:
                n += 1
            chunks.append((bytes(b for b, _ in tx[i:i + n]), tx[i + n - 1][1]))
            i += n
        recs, st = feed(ctx, chunks)
        want = [bytes(chip[i:i + 8]).hex() for i in range(0, len(chip) - 7, 8)]
        check([r["hex"] for r in recs] == want, "%s: the page's records differ from the chip's" % name)
        a = [r for r in recs if r["kind"] == "A"]
        check(all(r["authOk"] for r in a), "%s: %d of %d signatures did not verify"
              % (name, sum(not r["authOk"] for r in a), len(a)))
        print("  %-7s %4d records, %3d signatures verified, %d vehicles, RM %.2f" % (
            name, len(recs), len(a), st["vehicles"], st["revenue"] / 100))
    check(nlogs > 0 or os.environ.get("LIVE_NO_SIM"), "no board simulation logs (run check_board.py first)")

    print("LIVE %s: %d checks, %d failed" % ("PASS" if not fails else "FAIL", checks, len(fails)))
    for f in fails:
        print("    " + f)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
