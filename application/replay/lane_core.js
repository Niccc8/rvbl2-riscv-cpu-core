/*
 * lane_core.js - the replay page's verification and blind-test logic, kept out
 * of the page so test_lane_core.py can run it (in QuickJS) against the
 * golden model. gen_lane_replay.py inlines it into the page.
 *
 * Nothing here decides anything for the chip. It decodes the bytes the chip
 * sent, recomputes their CRC-16 and Chaskey-12 tags independently, and - for
 * the blind test - builds a fresh scenario, the testbench that plays it on the
 * platform, and this page's own prediction to compare the chip's answer with.
 */
var LaneCore = (function () {
  "use strict";

  var STATUS = ["CHARGED", "NO TAG", "CLASS MISMATCH", "HOTLIST", "CLONE", "FREE", "LANE CLOSED"];
  var FARES = [0, 250, 500, 750, 130, 380];                 // sen, classes 0..5
  var DEMO_KEY = bytes("RVBL-2 lane key!");
  var CODE_TO_CLASS = [1, 2, 3, 0];
  var CODE_FOR = { 1: 0, 2: 1, 3: 2, 0: 3 };

  function bytes(s) { var a = []; for (var i = 0; i < s.length; i++) a.push(s.charCodeAt(i) & 255); return a; }
  function hex(a) { return a.map(function (b) { return (b < 16 ? "0" : "") + b.toString(16); }).join(""); }
  function unhex(h) { var a = []; for (var i = 0; i + 1 < h.length; i += 2) a.push(parseInt(h.substr(i, 2), 16)); return a; }
  function le16(v) { return [v & 255, (v >>> 8) & 255]; }
  function le32(v) { return [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255]; }
  function rd32(a, i) { return (a[i] | a[i + 1] << 8 | a[i + 2] << 16 | a[i + 3] << 24) >>> 0; }

  // CRC-16/CCITT-FALSE: the chip's Xicrc instruction
  function crc16(data, crc) {
    crc = crc === undefined ? 0xFFFF : crc;
    for (var i = 0; i < data.length; i++) {
      crc ^= data[i] << 8;
      for (var k = 0; k < 8; k++) crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
    return crc;
  }
  function gen2Crc(pc, epc) { return crc16([pc >> 8, pc & 255].concat(epc)) ^ 0xFFFF; }

  // Chaskey-12 (Mouha 2015; ISO/IEC 29192-6:2019)
  function rotl(x, b) { return ((x << b) | (x >>> (32 - b))) >>> 0; }
  function permute(v) {
    for (var r = 0; r < 12; r++) {
      v[0] = (v[0] + v[1]) >>> 0; v[1] = rotl(v[1], 5); v[1] = (v[1] ^ v[0]) >>> 0; v[0] = rotl(v[0], 16);
      v[2] = (v[2] + v[3]) >>> 0; v[3] = rotl(v[3], 8); v[3] = (v[3] ^ v[2]) >>> 0;
      v[0] = (v[0] + v[3]) >>> 0; v[3] = rotl(v[3], 13); v[3] = (v[3] ^ v[0]) >>> 0;
      v[2] = (v[2] + v[1]) >>> 0; v[1] = rotl(v[1], 7); v[1] = (v[1] ^ v[2]) >>> 0; v[2] = rotl(v[2], 16);
    }
  }
  function times2(k) {
    return [((k[0] << 1) ^ (k[3] >>> 31 ? 0x87 : 0)) >>> 0, ((k[1] << 1) | (k[0] >>> 31)) >>> 0,
            ((k[2] << 1) | (k[1] >>> 31)) >>> 0, ((k[3] << 1) | (k[2] >>> 31)) >>> 0];
  }
  function words(a, i) { return [rd32(a, i), rd32(a, i + 4), rd32(a, i + 8), rd32(a, i + 12)]; }
  function chaskey12(key, msg, taglen) {
    var k = words(key, 0), k1 = times2(k), k2 = times2(k1), v = k.slice(), i, j;
    var nfull = msg.length ? Math.floor((msg.length - 1) / 16) : 0;
    for (i = 0; i < nfull; i++) {
      var m = words(msg, 16 * i);
      for (j = 0; j < 4; j++) v[j] = (v[j] ^ m[j]) >>> 0;
      permute(v);
    }
    var last = msg.slice(16 * nfull), l;
    if (msg.length && last.length === 16) l = k1;
    else { l = k2; last = last.concat([1]); while (last.length < 16) last.push(0); }
    var lb = words(last, 0);
    for (j = 0; j < 4; j++) v[j] = (v[j] ^ lb[j] ^ l[j]) >>> 0;
    permute(v);
    var out = [];
    for (j = 0; j < 4; j++) out = out.concat(le32((v[j] ^ l[j]) >>> 0));
    return out.slice(0, taglen || 8);
  }
  function authMessage(vrec, gantry, ctr) { return vrec.slice(0, 6).concat([gantry, 3]).concat(le32(ctr)); }

  // ---- records ------------------------------------------------------------
  var WHY = ["?", "frame CRC wrong", "length over 32", "unknown frame type", "wrong length for its type",
             "frame cut off mid-way"];
  function decode(r) {
    var d = { raw: r, kind: String.fromCharCode(r[0]), crcOk: crc16(r.slice(0, 6)) === (r[6] | r[7] << 8) };
    if (r[0] === 0x56) {
      d.seq = r[1]; d.status = STATUS[r[2]] || "?"; d.code = r[2]; d.phys = r[3] >> 4; d.tag = r[3] & 15;
      d.fare = r[4] | r[5] << 8;
    } else if (r[0] === 0x41) { d.seq = r[1]; d.tag32 = hex(r.slice(2, 6)); }
    else if (r[0] === 0x45) { d.reason = r[1]; d.why = WHY[r[1]] || "?"; d.type = r[2]; d.badFrames = r[3]; }
    else if (r[0] === 0x51) { d.vehicles = r[1] | r[2] << 8; d.badTag = r[3]; d.badFrame = r[4]; d.hot = r[5]; }
    else if (r[0] === 0x49) { d.proto = r[1]; d.romWords = r[2] | r[3] << 8; d.romCrc = r[4] | r[5] << 8; }
    return d;
  }
  // Check every record: CRC, and each 'A' against its 'V' with the key and
  // counter a toll back end would hold (counter from 0 at the first 'A').
  // runOf[i], when given, is record i's run: every run starts from reset, so
  // the counter starts again at 0 where the run changes.
  function verify(recs, key, gantry, runOf) {
    var ctr = 0, lastV = null, run = null;
    key = key || DEMO_KEY; gantry = gantry || 1;
    return recs.map(function (r, i) {
      var d = decode(r);
      if (runOf && runOf[i] !== run) { run = runOf[i]; ctr = 0; lastV = null; }
      if (d.kind === "V") lastV = r;
      if (d.kind === "A") {
        var want = lastV ? chaskey12(key, authMessage(lastV, gantry, ctr), 4) : null;
        d.authOk = !!(want && lastV[1] === r[1] && hex(want) === hex(r.slice(2, 6)));
        d.counter = ctr++;
        d.forSeq = lastV ? lastV[1] : null;
      }
      return d;
    });
  }

  // A transcript: the platform's simulation log (REC / PINS lines), the F2
  // host tool's --json lines, or bare 16-hex-digit records. Several logs may
  // be pasted one after another: each LANE header starts a new run, and every
  // record and pin sample carries its run's index.
  function parseTranscript(text) {
    var recs = [], pins = [], runs = [], nb = null, mode = null, m;
    function run() {
      if (!runs.length) runs.push({ label: "", nb: null, recs: 0 });
      return runs.length - 1;
    }
    text.split(/\r?\n/).forEach(function (line) {
      line = line.trim();
      if ((m = /^REC\s+(\d+)\s+@(\d+)\s+([0-9a-fA-F]{16})/.exec(line))) {
        recs.push({ bytes: unhex(m[3].toLowerCase()), cycle: +m[2], run: run() }); mode = mode || "platform";
        runs[runs.length - 1].recs++;
      } else if ((m = /^PINS\s+(\d+)\s+@(\d+)\s+([01]{4})/.exec(line))) {
        pins.push({ vehicle: +m[1], cycle: +m[2], bits: parseInt(m[3], 2), run: run() });
      } else if (/^LANE\b/.test(line)) {
        m = /UART\s+(\d+)\s+clocks\/bit/.exec(line);
        nb = m ? +m[1] : nb;
        var s = /SCEN=(\d+)\s+(\S+)/.exec(line), b = /seed\s+(\d+)/.exec(line);
        runs.push({ label: s ? "SCEN " + s[1] + " " + s[2] : b ? "blind test, seed " + b[1] : "run " + (runs.length + 1),
                    nb: m ? +m[1] : null, recs: 0 });
      } else if (line.charAt(0) === "{") {
        try {
          var o = JSON.parse(line);
          if (o.rec && /^[0-9a-f]{16}$/i.test(o.rec)) {
            recs.push({ bytes: unhex(o.rec.toLowerCase()), cycle: null, run: run() }); mode = mode || "f2";
            runs[runs.length - 1].recs++;
            if (o.kind === "V" && o.pins !== undefined) pins.push({ vehicle: pins.length, cycle: null, bits: o.pins, run: run() });
          }
        } catch (e) { /* not ours */ }
      } else if (/^[0-9a-fA-F]{16}$/.test(line)) {
        recs.push({ bytes: unhex(line.toLowerCase()), cycle: null, run: run() }); mode = mode || "hex";
        runs[runs.length - 1].recs++;
      }
    });
    return { recs: recs, pins: pins, nb: nb, mode: mode, runs: runs };
  }

  // ---- blind test -----------------------------------------------------------
  function rng(seed) {                                         // mulberry32
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function frame(type, payload) {
    var body = [type, payload.length].concat(payload), c = crc16(body);
    return [0xA5].concat(body, le16(c));
  }
  var F = {
    read: function (t, epc, rssi, stored) {
      var pc = 0x3000; stored = stored === undefined ? gen2Crc(pc, epc) : stored;
      return frame(0x52, le32(t).concat(le16(pc), epc, le16(stored), [rssi]));
    },
    time: function (t) { return frame(0x54, le32(t)); },
    config: function (g, closed) {
      var p = [g, closed]; FARES.forEach(function (f) { p = p.concat(le16(f)); }); return frame(0x43, p);
    },
    gantry: function (g, pos) { return frame(0x47, [g].concat(le16(pos))); },
    hot: function (epc) { return frame(0x48, epc.concat([1])); },
    sighting: function (epc, g, t) { return frame(0x53, epc.concat([g], le32(t))); },
    params: function (rssiMin, hold) { return frame(0x50, [rssiMin].concat(le16(500), le16(3000), le16(250), [hold], le16(48))); },
    key: function (k) { return frame(0x4B, k); },
    query: function () { return frame(0x51, []); }
  };
  var KINDS = ["charged", "taxi", "bus", "mismatch", "stolen", "clone", "no tag", "adjacent lane",
               "corrupted tag", "motorcycle", "lane closed"];

  // A fresh scenario: n vehicles of the chosen kinds, each with its own
  // random tag, five seconds apart (the reads carry their own times; the fast
  // run takes one or two reads a vehicle, to fit the platform's window). Returns the events to play and this
  // page's prediction of every record and every vehicle's pins.
  function makeBlind(opt) {
    var r = rng(opt.seed), n = opt.n, kinds = opt.kinds && opt.kinds.length ? opt.kinds : KINDS;
    var hold = opt.fast ? 8 : 64, floor = 30, t0 = 100000;
    function pick(a) { return a[Math.floor(r() * a.length)]; }
    function epc(cls) { var e = []; for (var i = 0; i < 12; i++) e.push(Math.floor(r() * 256)); e[0] = (e[0] & 0xF8) | cls; return e; }
    var ev = [], plan = [], hot = [], sights = [];
    for (var i = 0; i < n; i++) {
      var kind = pick(kinds), phys = pick([1, 1, 1, 2, 3]), tagc = phys, tag = null, reads = [], p3 = 0;
      if (kind === "taxi") { tagc = 4; phys = 1; }
      if (kind === "bus") { tagc = 5; phys = pick([2, 3]); }
      if (kind === "mismatch") { tagc = 1; phys = 3; }
      if (kind === "motorcycle") phys = 0;
      if (kind === "stolen" || kind === "clone") phys = tagc = 1;
      if (["no tag", "motorcycle"].indexOf(kind) < 0) tag = epc(kind === "adjacent lane" || kind === "corrupted tag" ? 1 : tagc);
      var nreads = 1 + Math.floor(r() * (opt.fast ? 2 : 3));
      for (var k = 0; tag && k < nreads; k++) reads.push({ rssi: 60 + Math.floor(r() * 60), bad: false });
      if (kind === "adjacent lane") reads = [{ rssi: 10 + Math.floor(r() * 19), bad: false }];
      if (kind === "corrupted tag") reads = [{ rssi: 90, bad: true }];
      if (kind === "stolen") hot.push(tag);
      if (kind === "clone") sights.push(tag);
      if (kind === "lane closed") p3 = 1;
      plan.push({ kind: kind, phys: phys, tagc: tag ? tagc : 7, tag: tag, reads: reads, p3: p3 });
    }
    // setup: key, parameters (RSSI floor 30), the other gantry 40 km away, the
    // stolen tags, and each clone's sighting there 30 s ago (gantry ID 1, the
    // lane open and the fares are the firmware's defaults)
    ev.push(["B", F.key(DEMO_KEY)], ["B", F.params(floor, hold)], ["B", F.gantry(2, 400)]);
    hot.forEach(function (e) { ev.push(["B", F.hot(e)]); });
    sights.forEach(function (e) { ev.push(["B", F.sighting(e, 2, t0 - 30000)]); });
    // prediction, by the protocol's decision table (application/PROTOCOL.md)
    var expect = [], pinsExp = [], seq = 0, ctr = 0, badTag = 0;
    plan.forEach(function (v, i) {
      var t = t0 + 5000 * i, code = CODE_FOR[v.phys];
      ev.push(["G", 1 | code << 1 | v.p3 << 3]);
      var good = 0;
      v.reads.forEach(function (rd, k) {
        var stored = rd.bad ? gen2Crc(0x3000, v.tag) ^ 0x0100 : undefined;
        ev.push(["B", F.read(t + 10 + k, v.tag, rd.rssi, stored)]);
        if (rd.bad) badTag++;
        else if (rd.rssi >= floor) good++;
      });
      ev.push(["G", v.p3 << 3]);
      if (v.p3) ev.push(["G", 0]);
      var st, fare = 0, tagc = good ? v.tagc : 7;
      if (v.p3) { st = 6; tagc = 7; }                       // closed: no tag is looked at
      else if (!good) st = v.phys === 0 ? 5 : 1;
      else if (v.kind === "stolen") st = 3;
      else if (v.kind === "clone") st = 4;
      else if (v.kind === "mismatch") { st = 2; fare = FARES[v.phys]; }
      else { st = 0; fare = FARES[tagc]; }
      var vr = [0x56, seq, st, (v.phys << 4) | tagc].concat(le16(fare));
      vr = vr.concat(le16(crc16(vr)));
      expect.push(vr);
      var ar = [0x41, seq].concat(chaskey12(DEMO_KEY, authMessage(vr, 1, ctr++), 4));
      expect.push(ar.concat(le16(crc16(ar))));
      var charged = st === 0 || st === 2, camera = st === 1 || st === 2 || st === 3 || st === 4, alarm = st === 3 || st === 4;
      pinsExp.push(v.p3 << 3 | alarm << 2 | camera << 1 | charged);
      v.status = STATUS[st]; v.fare = fare;
      seq = (seq + 1) & 255;
    });
    // one corrupted frame (the chip answers with an 'E'), then the stats
    var bad = F.time(t0 + 5000 * n); bad[5] ^= 4;
    ev.push(["B", bad]);
    var er = [0x45, 1, 0x54, 1, 0, 0]; expect.push(er.concat(le16(crc16(er))));
    ev.push(["B", F.query()]);
    var q = [0x51].concat(le16(n), [Math.min(badTag, 255), 1, hot.length]); expect.push(q.concat(le16(crc16(q))));
    return { events: ev, expect: expect, pins: pinsExp, plan: plan, fast: !!opt.fast, seed: opt.seed,
             cycles: blindCycles(ev, !!opt.fast) };
  }

  // The blind testbench's timing: the same as tb_app_ci / tb_app_ci_fast
  // (application/testbench/gen_platform_tb.py). Fast is 921,600 bps, the platform's run.
  function timing(fast) {
    return fast ? { nb: 33, gap: 30, rise: 1000, fall: 9000, drain: 40 }
                : { nb: 263, gap: 20, rise: 2000, fall: 16000, drain: 40 };
  }
  // How many clock cycles the testbench will take: the stimulus is fixed, so
  // this is exact up to the chip's last record.
  function blindCycles(ev, fast) {
    var T = timing(fast), c = 2005, pin = 0;
    ev.forEach(function (e) {
      if (e[0] === "G") { c += (pin & 1) && !(e[1] & 1) ? T.fall : T.rise; pin = e[1]; }
      else c += (e[1].length * 10 + T.gap) * T.nb;
    });
    return c + T.drain * 10 * T.nb;
  }
  // The ChipInventor simulator stops a run after a fixed wall-clock time; the
  // application's platform runs are sized to at most this many cycles.
  var PLATFORM_BUDGET = 140000;

  // The testbench that plays a blind scenario on the platform. It holds no
  // expected answers: it only drives the pins and prints what the chip sends.
  function blindTestbench(b, uartPath) {
    var T = timing(b.fast), ev = [], i, L = [];
    b.events.forEach(function (e) {
      if (e[0] === "G") ev.push(71, 1, e[1]);
      else { ev.push(66, e[1].length); ev = ev.concat(e[1]); }
    });
    L.push("`timescale 1ns/1ps");
    L.push("// blind_test.v - generated by the lane replay page, seed " + b.seed + ", " + b.plan.length + " vehicles.");
    L.push("// Plays a scenario on the canvas chip `top` (application ROM in imem) and prints");
    L.push("// every record the chip sends on tx_o. It holds NO expected answers: paste the");
    L.push("// log back into the page, which checks the chip against its own prediction.");
    L.push("module testbench;   // the platform runs the module named testbench");
    L.push("    localparam integer NB = " + T.nb + ", GAP = " + T.gap + " * NB, RISE = " + T.rise + ", FALL = " + T.fall + ";");
    L.push("    localparam integer N_EV = " + ev.length + ";");
    L.push("    reg clk = 0, rst = 1; always #16.5 clk = ~clk;");
    L.push("    integer cycles = 0; always @(posedge clk) cycles = cycles + 1;");
    L.push("    reg [3:0] pin_in = 4'h0; reg rx = 1'b1; wire tx;");
    L.push("    wire p0, p1, p2, p3, p4, p5, p6, p7;");
    L.push("    assign p0 = pin_in[0]; assign p1 = pin_in[1]; assign p2 = pin_in[2]; assign p3 = pin_in[3];");
    L.push("    assign (weak0, weak1) p4 = 1'b0; assign (weak0, weak1) p5 = 1'b0;");
    L.push("    assign (weak0, weak1) p6 = 1'b0; assign (weak0, weak1) p7 = 1'b0;");
    L.push("    top dut (.clk_i(clk), .rst_i(rst), .pins_io_0(p0), .pins_io_1(p1), .pins_io_2(p2), .pins_io_3(p3),");
    L.push("             .pins_io_4(p4), .pins_io_5(p5), .pins_io_6(p6), .pins_io_7(p7), .tx_o(tx), .rx_i(rx));");
    if (b.fast) L.push("    defparam " + uartPath + ".BAUD_RATE = 921600;   // the platform's fast run");
    L.push("    reg [7:0] ev [0:" + (ev.length - 1) + "];");
    L.push("    initial begin");
    for (i = 0; i < ev.length; i += 12)
      L.push("        " + ev.slice(i, i + 12).map(function (v, k) { return "ev[" + (i + k) + "]=8'd" + v + ";"; }).join(" "));
    L.push("    end");
    L.push("    reg [63:0] got = 0; integer nb = 0, n = 0, k; reg [7:0] b;");
    L.push("    always begin");
    L.push("        @(negedge tx); repeat (NB / 2) @(posedge clk);");
    L.push("        for (k = 0; k < 8; k = k + 1) begin repeat (NB) @(posedge clk); b[k] = tx; end");
    L.push("        repeat (NB) @(posedge clk);");
    L.push("        got = {got[55:0], b}; nb = nb + 1;");
    L.push("        if (nb == 8) begin nb = 0; $display(\"REC %0d @%0d %h\", n, cycles, got); n = n + 1; end");
    L.push("    end");
    L.push("    task send(input [7:0] d); integer j; begin");
    L.push("        rx = 0; repeat (NB) @(posedge clk);");
    L.push("        for (j = 0; j < 8; j = j + 1) begin rx = d[j]; repeat (NB) @(posedge clk); end");
    L.push("        rx = 1; repeat (NB) @(posedge clk); end endtask");
    L.push("    integer i, j, len, vn = 0; reg [3:0] prev;");
    L.push("    initial begin");
    L.push("        $display(\"LANE blind test seed " + b.seed + " UART %0d clocks/bit\", NB);");
    L.push("        repeat (5) @(posedge clk); rst = 0; repeat (2000) @(posedge clk);");
    L.push("        i = 0;");
    L.push("        while (i < N_EV) begin");
    L.push("            len = ev[i + 1];");
    L.push("            if (ev[i] == 71) begin");
    L.push("                prev = pin_in; pin_in = ev[i + 2];");
    L.push("                if (prev[0] && !pin_in[0]) begin");
    L.push("                    repeat (FALL) @(posedge clk);");
    L.push("                    $display(\"PINS %0d @%0d %b\", vn, cycles, {p7, p6, p5, p4}); vn = vn + 1;");
    L.push("                end else repeat (RISE) @(posedge clk);");
    L.push("            end else begin");
    L.push("                for (j = 0; j < len; j = j + 1) send(ev[i + 2 + j]);");
    L.push("                repeat (GAP) @(posedge clk);");
    L.push("            end");
    L.push("            i = i + 2 + len;");
    L.push("        end");
    L.push("        repeat (" + T.drain + " * 10 * NB) @(posedge clk);");
    L.push("        $display(\"BLIND DONE %0d records, %0d cycles\", n, cycles);");
    L.push("        $finish;");
    L.push("    end");
    L.push("endmodule");
    return L.join("\n") + "\n";
  }

  return { STATUS: STATUS, FARES: FARES, DEMO_KEY: DEMO_KEY, KINDS: KINDS, CODE_TO_CLASS: CODE_TO_CLASS,
           hex: hex, unhex: unhex, crc16: crc16, gen2Crc: gen2Crc, chaskey12: chaskey12,
           authMessage: authMessage, decode: decode, verify: verify, parseTranscript: parseTranscript,
           makeBlind: makeBlind, blindTestbench: blindTestbench, blindCycles: blindCycles,
           PLATFORM_BUDGET: PLATFORM_BUDGET, frames: F };
})();
