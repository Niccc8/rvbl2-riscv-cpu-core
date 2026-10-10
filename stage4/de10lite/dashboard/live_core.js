/*
 * live_core.js - LaneX Live's logic, kept out of the page so test_live.py can
 * run it (in QuickJS) against the golden model and the board simulation.
 * gen_de10lite.py inlines it, with lane_core.js, into lanex_live.html.
 *
 * It decides nothing for the chip. It cuts the board's byte stream (a copy of
 * the chip's own UART output) into 8-byte records, recomputes each CRC-16 and
 * each Chaskey-12 tag independently, keeps the lane's totals, and builds the
 * back-office frames the page's buttons send.
 *
 * BOARD (from gen_de10lite.py): { key, gantry, proto, romWords, romCrc, fares,
 * presets: [{name, epc}] } - the same values the board's fabric uses.
 */
var LiveCore = (function () {
  "use strict";
  var C = LaneCore;
  var KINDS = { 0x56: "V", 0x41: "A", 0x45: "E", 0x51: "Q", 0x49: "I" };
  var GAP_MS = 60;            // a record's bytes come back to back: a longer pause starts afresh
  var SEARCH = 65536;         // counters tried when the record counter is not known yet

  function frame(type, payload) {
    var body = [type, payload.length].concat(payload);
    var c = C.crc16(body);
    return [0xA5].concat(body, [c & 255, c >> 8]);
  }
  function le16(v) { return [v & 255, (v >>> 8) & 255]; }

  function Lane(board) {
    this.board = board;
    this.key = board.key;
    this.buf = [];
    this.lastT = null;
    this.dropped = 0;           // bytes skipped while finding a record boundary
    this.lastSigned = null;     // the 'V' or 'I' the next 'A' authenticates
    this.ctr = null;            // the next 'A' record's counter, once known
    this.ver = board.proto;
    this.stats = { vehicles: 0, revenue: 0, alarms: 0, camera: 0, records: 0, crcOk: 0,
                   signed: 0, signedOk: 0, errors: 0 };
    this.identity = null;       // the chip's last 'I' record, checked against the build
  }

  // Feed received bytes (t: milliseconds). Returns the records found, decoded and checked.
  Lane.prototype.push = function (bytes, t) {
    var out = [];
    if (this.lastT !== null && t - this.lastT > GAP_MS && this.buf.length) {
      this.dropped += this.buf.length;
      this.buf = [];
    }
    this.lastT = t;
    for (var i = 0; i < bytes.length; i++) {
      this.buf.push(bytes[i] & 255);
      if (this.buf.length < 8) continue;
      var r = this.buf.slice(0, 8);
      if (KINDS[r[0]] && C.crc16(r.slice(0, 6)) === (r[6] | r[7] << 8)) {
        this.buf = [];
        out.push(this.record(r, t));
      } else {
        this.buf.shift();                     // not a record boundary: slide by one byte
        this.dropped++;
      }
    }
    return out;
  };

  // Try counters for an 'A' record's tag; the expected one (and a few after it) first.
  Lane.prototype.findCounter = function (signed, a) {
    var want = C.hex(a.slice(2, 6)), self = this;
    function ok(ctr) {
      return C.hex(C.chaskey12(self.key, C.authMessage(signed, self.board.gantry, ctr, self.ver), 4)) === want;
    }
    if (this.ctr !== null) {
      for (var k = 0; k < 8; k++) if (ok((this.ctr + k) >>> 0)) return (this.ctr + k) >>> 0;
    }
    for (var c = 0; c < SEARCH; c++) if (ok(c)) return c;
    return null;
  };

  Lane.prototype.record = function (r, t) {
    var d = C.decode(r), s = this.stats, b = this.board;
    d.t = t;
    d.hex = C.hex(r);
    s.records++;
    s.crcOk++;                                 // (only CRC-valid records are cut from the stream)
    if (d.kind === "V") {
      s.vehicles++;
      if (d.code === 0 || d.code === 2) s.revenue += d.fare;      // charged, or charged at the physical class
      if (d.code === 3 || d.code === 4) s.alarms++;
      if (d.code >= 1 && d.code <= 4) s.camera++;
      this.lastSigned = r;
    } else if (d.kind === "I") {
      this.ver = d.proto;
      this.lastSigned = r;
      this.ctr = null;                         // a fresh boot measures first: the counter may restart
      d.romOk = d.proto === b.proto && d.romWords === b.romWords && d.romCrc === b.romCrc;
      this.identity = d;
    } else if (d.kind === "A") {
      s.signed++;
      var sg = this.lastSigned;
      d.forKind = sg ? String.fromCharCode(sg[0]) : null;
      d.forSeq = sg ? sg[1] : null;
      var ctr = sg && sg[1] === r[1] ? this.findCounter(sg, r) : null;
      d.authOk = ctr !== null;
      d.counter = ctr;
      if (d.authOk) { s.signedOk++; this.ctr = (ctr + 1) >>> 0; }
      this.lastSigned = null;
    } else if (d.kind === "E") {
      s.errors++;
    }
    return d;
  };

  // The back office's frames (the chip checks their CRC; the board forwards them whole)
  function presetEpc(board, name) {
    for (var i = 0; i < board.presets.length; i++) if (board.presets[i].name === name) return C.unhex(board.presets[i].epc);
    throw new Error("no preset " + name);
  }
  var Frames = {
    hotAdd: function (board, name) { return frame(0x48, presetEpc(board, name).concat([1])); },
    hotDel: function (board, name) { return frame(0x68, presetEpc(board, name)); },
    lane: function (board, closed) {
      var p = [board.gantry, closed ? 1 : 0];
      board.fares.forEach(function (f) { p = p.concat(le16(f)); });
      return frame(0x43, p);
    },
    query: function () { return frame(0x51, []); },
    identify: function () { return frame(0x49, []); }
  };

  var CLASS_NAMES = ["motorcycle", "car", "van", "lorry", "taxi", "bus"];
  function className(c) { return CLASS_NAMES[c] || (c === 7 ? "no tag" : "class " + c); }
  function ringgit(sen) { return "RM " + (sen / 100).toFixed(2); }

  return { Lane: Lane, Frames: Frames, frame: frame, className: className, ringgit: ringgit, KINDS: KINDS };
})();
