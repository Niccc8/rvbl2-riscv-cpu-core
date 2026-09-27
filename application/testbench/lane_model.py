#!/usr/bin/env python3
"""lane_model.py - golden model, protocol and traffic generator for the RVBL-2
free-flow toll lane controller (the Stage 3 application, application/firmware).

This file is the specification in executable form. The C firmware
(application/firmware/lane/main.c) must produce byte-for-byte the same output stream and the
same pin states as LaneModel for every stimulus; tb_app.v and the host tool
check exactly that.

Protocol (every multi-byte field little-endian unless stated):

  Host -> chip frame   A5 | type | len | payload[len] | crc16
                       crc16 = CRC-16/CCITT-FALSE over type, len, payload
                       (the Xicrc instruction's own CRC). len <= 32.
    'R' 0x52 tag read      t_ms u32, pc u16, epc[12], stored_crc u16, rssi u8 (21)
    'T' 0x54 time          t_ms u32                                        (4)
    'C' 0x43 config        gantry u8, lane_closed u8, fare[6] u16 (sen)     (14)
    'G' 0x47 gantry pos    gantry u8, pos u16 (units of 0.1 km)            (3)
    'H' 0x48 hotlist add   epc[12], reason u8                              (13)
    'h' 0x68 hotlist del   epc[12]                                         (12)
    'S' 0x53 sighting      epc[12], gantry u8, t_ms u32                    (17)
    'Q' 0x51 query stats   -                                               (0)
    'P' 0x50 parameters    rssi_min u8, guard_ms u16, dedup_ms u16,
                           vmax_kmh u16, hold u8 (exit hold-off, loop
                           iterations; 0 counts as 1), timeout u16 (frame
                           timeout, loop iterations; 0 = never, the
                           default)                                       (10)
    'K' 0x4B record key    key[16]: Chaskey-12 key, authentication on and
                           the record counter reset to 0; len 0: off      (16|0)
    'I' 0x49 identify      -: the chip measures its own ROM              (0)

  Chip -> host record  always 8 bytes, last two = crc16 over bytes 0..5
    'V' 0x56 vehicle       seq u8, status u8, (phys<<4)|tag_class u8, fare u16
    'A' 0x41 authenticator seq u8, tag[4]: follows every 'V' while a key is
                           loaded. tag = the first 4 bytes of Chaskey-12
                           (ISO/IEC 29192-6) over the 12-byte message
                           V[0..5] | gantry | 0x03 | counter u32; the counter
                           counts 'A' records since the key was loaded
    'Q' 0x51 stats         vehicles u16, bad_tag u8, bad_frame u8, hotlist u8
    'E' 0x45 error         reason u8, type u8, bad_frame u8, 0, 0. Reasons:
                           1 frame CRC, 2 len > 32, 3 unknown type, 4 wrong
                           length for the type, 5 frame cut off (the line
                           went quiet mid-frame). One 'E' per burst: after an
                           'E', errors are only counted until a good frame
    'I' 0x49 identity      version u8 (3), rom_words u16, rom_crc u16: the
                           Xicrc CRC-16 (seed FFFF, each word MSB first) of
                           the ROM image from word 0, computed on the chip in
                           the background (answered within a few ms; records
                           made meanwhile may go first)

  Tag: Gen2 StoredCRC = CRC-16/EPC-C1G2 over the PC word (MSB first) and the
  12 EPC bytes = CCITT-FALSE, then XOR 0xFFFF. Registered class = epc[0] & 7.

  GPIO (DATADIR = 0xF0): inputs P0 vehicle present, P2:P1 class code from the
  classifier (00 class 1, 01 class 2, 10 class 3, 11 class 0 motorcycle),
  P3 lane closed. Outputs, held until the next vehicle: P4 charged,
  P5 camera fired, P6 security alarm; P7 = lane closed (live).

Decision for a vehicle, made when P0 falls:
  lane closed                         -> LANE_CLOSED  (6)
  no usable tag:  class 0             -> FREE         (5)
                  otherwise           -> NO_TAG       (1)  camera
  tag on hotlist                      -> HOTLIST      (3)  camera, alarm
  tag seen elsewhere too fast (clone) -> CLONE        (4)  camera, alarm
  registered class != physical class  -> CLASS_MISM.  (2)  camera, charged
                                         at the physical class's fare
  otherwise                           -> CHARGED      (0)  fare[tag class]
"""

import collections
import os
import random
import struct

PROTO = 3               # protocol version, reported by 'I'
SOF = 0xA5
MAX_LEN = 32
GUARD_MS = 500          # reads up to this long before P0 rises belong to the car
DEDUP_MS = 3000         # a tag charged here this recently is not charged again
VMAX_KMH = 250          # faster than this between gantries = clone
PENDING = 8             # reads remembered while no vehicle is present
VTAGS = 4               # distinct tags tracked per vehicle
HOT_SLOTS = 64
SEEN_SLOTS = 64
PROBES = 8
PC_96 = 0x3000          # Gen2 PC word for a 96-bit EPC
DEFAULT_FARES = [0, 250, 500, 750, 130, 380]   # sen, classes 0..5

ST_CHARGED, ST_NO_TAG, ST_MISMATCH, ST_HOTLIST, ST_CLONE, ST_FREE, ST_CLOSED = range(7)
STATUS_NAMES = ["CHARGED", "NO_TAG", "CLASS_MISMATCH", "HOTLIST", "CLONE", "FREE", "LANE_CLOSED"]
CODE_TO_CLASS = [1, 2, 3, 0]


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def gen2_crc(pc, epc):
    return crc16(bytes([pc >> 8, pc & 0xFF]) + bytes(epc)) ^ 0xFFFF


def rom_crc(words):
    """What the chip's 'I' reports: CRC-16 (seed FFFF) folding each ROM word MSB
    first, one Xicrc crcw per word."""
    return crc16(b"".join(w.to_bytes(4, "big") for w in words))


# ---- Chaskey-12 (Mouha 2015; ISO/IEC 29192-6:2019) ------------------------
M32 = 0xFFFFFFFF


def _rotl(x, b):
    return ((x << b) | (x >> (32 - b))) & M32


def _permute(v):
    for _ in range(12):
        v[0] = (v[0] + v[1]) & M32; v[1] = _rotl(v[1], 5); v[1] ^= v[0]; v[0] = _rotl(v[0], 16)
        v[2] = (v[2] + v[3]) & M32; v[3] = _rotl(v[3], 8); v[3] ^= v[2]
        v[0] = (v[0] + v[3]) & M32; v[3] = _rotl(v[3], 13); v[3] ^= v[0]
        v[2] = (v[2] + v[1]) & M32; v[1] = _rotl(v[1], 7); v[1] ^= v[2]; v[2] = _rotl(v[2], 16)


def _times2(k):
    return [((k[0] << 1) ^ (0x87 if k[3] >> 31 else 0)) & M32,
            ((k[1] << 1) | (k[0] >> 31)) & M32,
            ((k[2] << 1) | (k[1] >> 31)) & M32,
            ((k[3] << 1) | (k[2] >> 31)) & M32]


def chaskey12(key, msg, taglen=8):
    """Chaskey-12 MAC of msg under a 16-byte key; the first taglen tag bytes."""
    k = list(struct.unpack("<4I", bytes(key)))
    k1 = _times2(k)
    k2 = _times2(k1)
    v = list(k)
    msg = bytes(msg)
    nfull = (len(msg) - 1) // 16 if msg else 0         # blocks before the last
    for i in range(nfull):
        m = struct.unpack_from("<4I", msg, 16 * i)
        v = [a ^ b for a, b in zip(v, m)]
        _permute(v)
    last = msg[16 * nfull:]
    if msg and len(last) == 16:
        l = k1
    else:
        l = k2
        last = last + b"\x01" + b"\0" * (15 - len(last))
    v = [a ^ b ^ c for a, b, c in zip(v, struct.unpack("<4I", last), l)]
    _permute(v)
    v = [a ^ b for a, b in zip(v, l)]
    return struct.pack("<4I", *v)[:taglen]


# The Chaskey-12 reference implementation's own test vectors (Nicky Mouha,
# chaskey12.c, CC0; github.com/secworks/chaskey src/model): key 00 11 .. ff,
# message i = the bytes 0, 1, .. i-1, 8-byte tags. First, last and a spread.
CHASKEY_KEY = bytes.fromhex("00112233445566778899aabbccddeeff")
CHASKEY_VECTORS = {
    0: "dd3e1849d6824555", 1: "ed1da89ec93179ca", 2: "98fe20a343cd666f",
    3: "f6f418acdd7d9fa1", 11: "4d1a1815868a5aa8", 12: "7a7912c1999eae81",
    15: "6a3ee3d35c043397", 16: "d13970d7be9b2350", 17: "32acd914bfda3bc8",
    31: "fd42c39d08ab71a0", 32: "b465c2412610bf84", 33: "89c4a9ddb53e6991",
    47: "6dfaa705a8a06c70", 48: "aa047f07c5ae8db4", 63: "fc7f9df7991b87bc",
}


def auth_message(vrec, gantry, ctr):
    """The 12 bytes an 'A' record authenticates."""
    return bytes(vrec[:6]) + bytes([gantry, PROTO]) + struct.pack("<I", ctr & M32)


def frame(ftype, payload):
    body = bytes([ftype, len(payload)]) + bytes(payload)
    return bytes([SOF]) + body + struct.pack("<H", crc16(body))


def f_read(t, epc, rssi, pc=PC_96, stored=None):
    stored = gen2_crc(pc, epc) if stored is None else stored
    return frame(0x52, struct.pack("<IH", t, pc) + bytes(epc) + struct.pack("<HB", stored, rssi))


def f_time(t):
    return frame(0x54, struct.pack("<I", t))


def f_config(gantry, closed, fares):
    return frame(0x43, bytes([gantry, closed]) + struct.pack("<6H", *fares))


def f_gantry(g, pos):
    return frame(0x47, struct.pack("<BH", g, pos))


def f_hot_add(epc, reason=1):
    return frame(0x48, bytes(epc) + bytes([reason]))


def f_hot_del(epc):
    return frame(0x68, bytes(epc))


def f_sighting(epc, g, t):
    return frame(0x53, bytes(epc) + struct.pack("<BI", g, t))


def f_query():
    return frame(0x51, b"")


def record(kind, body5):
    b = bytes([kind]) + bytes(body5)
    return b + struct.pack("<H", crc16(b))


def epc_hash(epc):
    w0, w1, w2 = struct.unpack("<III", bytes(epc))
    h = ((w0 * 0x9E3779B1) ^ (w1 * 0x85EBCA77) ^ (w2 * 0xC2B2AE3D)) & 0xFFFFFFFF
    return (h * 0x27D4EB2F & 0xFFFFFFFF) >> 26          # 6 bits


class LaneModel:
    """Byte-exact model of the firmware. Feed it with rx_byte() and gpio().
    `rom` is the firmware image as 32-bit words (for 'I'); `cov` counts every
    decision path and boundary the stimulus reached (functional coverage)."""

    def __init__(self, rom=None):
        self.out = bytearray()           # every byte the chip transmits
        self.pins = 0                    # pins 7:4 as the chip drives them
        self.vehicle_pins = []           # pins 7:4 right after each vehicle record
        self.gantry, self.closed_cfg = 1, 0
        self.fares = list(DEFAULT_FARES)
        self.pos = [0] * 8
        self.now = 0
        self.seq = 0
        self.vehicles = self.bad_tag = self.bad_frame = 0
        self.rssi_min, self.guard, self.dedup, self.vmax, self.hold = 0, GUARD_MS, DEDUP_MS, VMAX_KMH, 64
        self.timeout = 0                    # frame timeout off until 'P' sets it
        self.key, self.ctr = None, 0     # Chaskey-12 key while authentication is on
        self.err_armed = True            # the next rejected frame gets an 'E'
        self.rom = rom
        self.cov = collections.Counter()
        self.hot = [None] * HOT_SLOTS    # epc bytes, or b"" tombstone
        self.hot_n = 0
        self.seen = [None] * SEEN_SLOTS  # (epc, gantry, t)
        self.pend = []                   # [(epc, rssi, t)]
        self.active = False
        self.vt = []                     # [[epc, count, rssi_max]]
        self.code = 0
        self.gp = 0                      # last GPIO input value seen
        self.st = 0                      # parser state
        self.buf = bytearray()
        self.need = 0

    # ---- parser, mirrors fw exactly ----------------------------------
    def rx_byte(self, b):
        if self.st == 0:
            if b == SOF:
                self.st, self.buf = 1, bytearray()
            return
        self.buf.append(b)
        if self.st == 1:                 # type
            self.st = 2
        elif self.st == 2:               # len
            if b > MAX_LEN:
                self.st = 0
                self._error(2, self.buf[0])
            else:
                self.need = b + 2
                self.st = 3
        else:
            self.need -= 1
            if self.need == 0:
                self.st = 0
                body, rx = bytes(self.buf[:-2]), self.buf[-2] | self.buf[-1] << 8
                if crc16(body) != rx:
                    self._error(1, body[0])
                else:
                    self._frame(body[0], body[2:])

    def line_idle(self):
        """The line has been quiet past the parser's inter-byte timeout: a frame
        left half-received (line noise, a host that died mid-frame) is dropped,
        so it can never hold a vehicle's decision back. Only while the timeout
        is on ('P'; off by default, for the emulator's slow byte-by-byte host)."""
        if self.timeout and self.st != 0:
            self.st = 0
            self._error(5, self.buf[0] if self.buf else 0)

    def _error(self, reason, ftype):
        self.bad_frame = min(self.bad_frame + 1, 255)
        self.cov["E%d" % reason] += 1
        if self.err_armed:
            self.out += record(0x45, bytes([reason, ftype, self.bad_frame, 0, 0]))
            self.err_armed = False
        else:
            self.cov["E suppressed"] += 1

    LENGTHS = {0x52: (21,), 0x54: (4,), 0x43: (14,), 0x47: (3,), 0x48: (13,), 0x68: (12,),
               0x53: (17,), 0x51: (0,), 0x50: (10,), 0x4B: (16, 0), 0x49: (0,)}

    def _frame(self, t, p):
        n = len(p)
        if t not in self.LENGTHS:
            return self._error(3, t)
        if n not in self.LENGTHS[t]:
            return self._error(4, t)
        self.err_armed = True
        if t == 0x52:
            tm, pc = struct.unpack_from("<IH", p, 0)
            epc = bytes(p[6:18])
            stored, rssi = struct.unpack_from("<HB", p, 18)
            self.now = max(self.now, tm)
            if gen2_crc(pc, epc) != stored:
                self.bad_tag = min(self.bad_tag + 1, 255)
                self.cov["tag CRC bad"] += 1
            elif rssi < self.rssi_min:
                self.cov["read below RSSI floor"] += 1
            elif self.active:
                self._vt_add(epc, rssi)
            else:
                if len(self.pend) == PENDING:
                    self.pend.pop(0)
                    self.cov["pending reads full"] += 1
                self.pend.append((epc, rssi, tm))
        elif t == 0x54:
            self.now = max(self.now, struct.unpack("<I", p)[0])
        elif t == 0x43:
            self.gantry, self.closed_cfg = p[0] & 7, p[1] & 1
            self.fares = list(struct.unpack_from("<6H", p, 2))
            self._update_p7()
        elif t == 0x47:
            self.pos[p[0] & 7] = p[1] | p[2] << 8
        elif t == 0x48:
            self._hot_add(bytes(p[:12]))
        elif t == 0x68:
            self._hot_del(bytes(p[:12]))
        elif t == 0x53:
            g, tm = struct.unpack_from("<BI", p, 12)
            self._seen_put(bytes(p[:12]), g & 7, tm)
        elif t == 0x51:
            self.out += record(0x51, struct.pack("<HBBB", self.vehicles & 0xFFFF,
                                                 self.bad_tag, self.bad_frame, self.hot_n))
        elif t == 0x50:
            self.rssi_min, self.guard, self.dedup, self.vmax, self.hold, self.timeout = struct.unpack("<BHHHBH", p)
            self.hold = self.hold or 1
            self.cov["parameters set"] += 1
        elif t == 0x4B:
            self.key, self.ctr = (bytes(p), 0) if n else (None, 0)
            self.cov["key loaded" if n else "key cleared"] += 1
        elif t == 0x49:
            if self.rom is None:
                raise ValueError("'I' needs LaneModel(rom=...)")
            self.out += record(0x49, struct.pack("<BHH", PROTO, len(self.rom), rom_crc(self.rom)))
            self.cov["identify"] += 1

    # ---- tables ----------------------------------------------------------
    def _hot_find(self, epc):
        h = epc_hash(epc)
        for i in range(PROBES):
            s = self.hot[(h + i) & (HOT_SLOTS - 1)]
            if s is None:
                return -1
            if s == epc:
                return (h + i) & (HOT_SLOTS - 1)
        return -1

    def _hot_add(self, epc):
        if self._hot_find(epc) >= 0:
            return
        h = epc_hash(epc)
        for i in range(PROBES):
            k = (h + i) & (HOT_SLOTS - 1)
            if not self.hot[k]:          # empty or tombstone
                self.cov["hotlist slot reused" if self.hot[k] == b"" else "hotlist add"] += 1
                self.hot[k] = epc
                self.hot_n += 1
                return
        self.cov["hotlist probe window full"] += 1

    def _hot_del(self, epc):
        k = self._hot_find(epc)
        if k >= 0:
            self.hot[k] = b""
            self.hot_n -= 1

    def _seen_get(self, epc):
        h = epc_hash(epc)
        for i in range(PROBES):
            s = self.seen[(h + i) & (SEEN_SLOTS - 1)]
            if s is None:
                return None
            if s[0] == epc:
                return s
        return None

    def _seen_put(self, epc, g, t):
        h = epc_hash(epc)
        victim, vt = -1, None
        for i in range(PROBES):
            k = (h + i) & (SEEN_SLOTS - 1)
            s = self.seen[k]
            if s is None or s[0] == epc:
                self.seen[k] = (epc, g, t)
                return
            if vt is None or s[2] < vt:
                victim, vt = k, s[2]
        self.seen[victim] = (epc, g, t)  # evict the oldest in the probe window
        self.cov["sighting evicted"] += 1

    # ---- vehicle ---------------------------------------------------------
    def _vt_add(self, epc, rssi):
        for e in self.vt:
            if e[0] == epc:
                e[1] += 1
                e[2] = max(e[2], rssi)
                return
        if len(self.vt) < VTAGS:
            self.vt.append([epc, 1, rssi])
        else:
            self.cov["tags per vehicle full"] += 1

    def _update_p7(self):
        closed = self.closed_cfg | (self.gp >> 3 & 1)
        self.pins = (self.pins & 0x70) | (closed << 7)

    def gpio(self, v):
        v &= 0x0F
        was = self.gp & 1
        self.gp = v
        if v & 1:
            self.code = (v >> 1) & 3     # class code, latched while present
        if not was and v & 1:
            self.active, self.vt = True, []
            for epc, rssi, tm in self.pend:
                if tm + self.guard >= self.now:
                    self.cov["read kept by the guard" if tm + self.guard > self.now
                             else "guard boundary (kept)"] += 1
                    self._vt_add(epc, rssi)
                else:
                    self.cov["read dropped by the guard"] += 1
            self.pend = []
        elif was and not v & 1:
            self._finalize()
        self._update_p7()

    def _finalize(self):
        self.active = False
        phys = CODE_TO_CLASS[self.code]
        closed = self.closed_cfg | (self.gp >> 3 & 1)
        best = None
        if len(self.vt) > 1:
            self.cov["several tags in one vehicle"] += 1
        for e in self.vt:
            s = self._seen_get(e[0])
            if s and s[1] == self.gantry and self.now - s[2] < self.dedup:
                self.cov["tag excluded: charged here moments ago"] += 1
                continue                  # charged here moments ago (tailgating)
            if s and s[1] == self.gantry and self.now - s[2] == self.dedup:
                self.cov["dedup boundary (charged again)"] += 1
            if best is not None and e[1] == best[1] and e[2] > best[2]:
                self.cov["tie broken by RSSI"] += 1
            if best is None or e[1] > best[1] or (e[1] == best[1] and e[2] > best[2]):
                best = e
        tagc, fare = 7, 0
        if closed:
            st = ST_CLOSED
        elif best is None:
            st = ST_FREE if phys == 0 else ST_NO_TAG
        else:
            epc = best[0]
            tagc = epc[0] & 7
            s = self._seen_get(epc)
            if self._hot_find(epc) >= 0:
                st = ST_HOTLIST
            elif s and s[1] != self.gantry and self._too_fast(s):
                st = ST_CLONE
            elif not self._class_ok(tagc, phys):
                st, fare = ST_MISMATCH, self.fares[phys]
            else:
                st, fare = ST_CHARGED, self.fares[tagc if tagc < 6 else phys]
            self._seen_put(epc, self.gantry, self.now)
        self.vehicles += 1
        self.cov[STATUS_NAMES[st]] += 1
        v = record(0x56, struct.pack("<BBBH", self.seq, st, (phys << 4) | tagc, fare))
        self.out += v
        if self.key is not None:
            tag = chaskey12(self.key, auth_message(v, self.gantry, self.ctr))[:4]
            self.out += record(0x41, bytes([self.seq]) + tag)
            self.ctr += 1
            self.cov["record authenticated"] += 1
        self.seq = (self.seq + 1) & 0xFF
        charged = st in (ST_CHARGED, ST_MISMATCH)
        camera = st in (ST_NO_TAG, ST_MISMATCH, ST_HOTLIST, ST_CLONE)
        alarm = st in (ST_HOTLIST, ST_CLONE)
        self.pins = (self.pins & 0x80) | charged << 4 | camera << 5 | alarm << 6
        self.vehicle_pins.append(self.pins)

    def _too_fast(self, s):
        dist = abs(self.pos[self.gantry] - self.pos[s[1]])     # 0.1 km
        dt = (self.now - s[2]) & 0xFFFFFFFF
        if dt == 0 or dt >= 0x80000000:                        # same time or earlier
            return dist > 0
        # speed km/h = dist*0.1 / (dt/3600000) = dist*360000/dt > VMAX
        if dist * 360000 == self.vmax * dt:
            self.cov["clone speed boundary (exactly vmax)"] += 1
        return dist * 360000 > self.vmax * dt

    @staticmethod
    def _class_ok(tagc, phys):
        if tagc == 4:
            return phys == 1              # taxi: an ordinary 2-axle car
        if tagc == 5:
            return phys in (2, 3)         # bus
        return tagc == phys


# ---------------------------------------------------------------------------
# Scenario generation
# ---------------------------------------------------------------------------

def make_epc(rng, cls):
    e = bytearray(rng.getrandbits(8) for _ in range(12))
    e[0] = (e[0] & 0xF8) | cls
    return bytes(e)


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROM_HEX = "application/firmware/out/lane/firmware.hex"


def load_rom(path=None):
    """The lane firmware image as 32-bit words (the firmware Makefile's
    firmware.hex), or None."""
    path = path or os.path.join(ROOT, ROM_HEX)
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return [int(l, 16) for l in fh.read().split()]


class Scenario:
    """An ordered stimulus: ('B', bytes) send then idle for the host's
    inter-frame gap, ('N', bytes) send with no gap after, ('G', value) set pins
    3:0 then settle, ('W', cycles) idle. Also records the ground truth."""

    def __init__(self):
        self.ev = []
        self.truth = []

    def send(self, b, gap=True):
        self.ev.append(("B" if gap else "N", bytes(b)))

    def pins(self, v):
        self.ev.append(("G", v & 0xF))

    def wait(self, cycles):
        self.ev.append(("W", int(cycles)))

    def run(self, rom=None):
        """Timing rules the firmware meets (tb_app enforces them): the gap after
        a 'B' is shorter than the parser's inter-byte timeout; a pin change's
        settle and a 'W' are longer than it and than the exit hold-off. So a
        half-received frame is cut off during a settle or wait - after a car
        arrives (the arrival is handled at once), but before a leaving car is
        decided (the decision waits for the line to go quiet)."""
        m = LaneModel(rom if rom is not None else load_rom())
        for kind, v in self.ev:
            if kind in "BN":
                for b in v:
                    m.rx_byte(b)
            elif kind == "G":
                if m.gp & 1 and not v & 1:
                    m.line_idle()
                    m.gpio(v)
                else:
                    m.gpio(v)
                    m.line_idle()
            else:
                m.line_idle()
        return m

    def timed_events(self):
        """The events as the testbench must play them. The parser's inter-byte
        timeout is counted in main-loop iterations, whose length varies, so
        the host's inter-frame gap (2 byte-times) is not reliably shorter than
        it. Wherever a line leaves a frame half-received and bytes follow, the
        line is sent with no gap ('N'), making "the frame continues" certain on
        the chip as it is in the model; only a settle or a wait cuts it off."""
        m = LaneModel(load_rom())
        ev = []
        for i, (kind, v) in enumerate(self.ev):
            if kind in "BN":
                for b in v:
                    m.rx_byte(b)
                nxt = self.ev[i + 1][0] if i + 1 < len(self.ev) else "E"
                ev.append(("N" if kind == "N" or (m.st != 0 and nxt in "BN") else "B", v))
            else:
                if kind == "G":
                    if m.gp & 1 and not v & 1:
                        m.line_idle()
                        m.gpio(v)
                    else:
                        m.gpio(v)
                        m.line_idle()
                else:
                    m.line_idle()
                ev.append((kind, v))
        return ev

    def write(self, stim_path, exp_path):
        m = self.run()
        with open(stim_path, "w") as f:
            for kind, v in self.timed_events():
                if kind in "BN":
                    for i in range(0, len(v), 96):       # the testbench reads <= 100 bytes a line
                        last = i + 96 >= len(v)
                        f.write("%s %s\n" % (kind if last else "N", v[i:i + 96].hex()))
                elif kind == "G":
                    f.write("G %x\n" % v)
                else:
                    f.write("W %d\n" % v)
            f.write("E\n")
        with open(exp_path, "w") as f:
            recs = [bytes(m.out[i:i + 8]) for i in range(0, len(m.out), 8)]
            vp = iter(m.vehicle_pins)
            for r in recs:
                f.write("R %s %02x\n" % (r.hex(), next(vp) if r[0] == 0x56 else 0xFF))
            f.write("E\n")
        return m


CODE_FOR = {1: 0, 2: 1, 3: 2, 0: 3}


def f_params(rssi_min=0, guard=GUARD_MS, dedup=DEDUP_MS, vmax=VMAX_KMH, hold=64, timeout=48):
    return frame(0x50, struct.pack("<BHHHBH", rssi_min, guard, dedup, vmax, hold, timeout))


def f_key(key):
    return frame(0x4B, bytes(key))


def f_identify():
    return frame(0x49, b"")


# The demonstration key the toll back end loads (anything 16 bytes works; the
# replay page and the host tool verify 'A' records with it).
DEMO_KEY = b"RVBL-2 lane key!"
ATTEST_WAIT = 70000     # cycles to leave after 'I': the measurement takes ~61k (tb_app reports it)


def build_scenario(seed, n_vehicles, auth=True):
    """Seeded mixed traffic exercising every decision path and edge case. With
    auth, the lane runs keyed (every 'V' followed by its 'A'), measures its
    ROM first, and filters reads below an RSSI floor of 25."""
    rng = random.Random(seed)
    sc = Scenario()
    t = 100000
    if auth:
        sc.send(f_identify())
        sc.wait(ATTEST_WAIT)
        sc.send(f_key(DEMO_KEY))
        sc.send(f_params(rssi_min=25))
    sc.send(f_config(1, 0, DEFAULT_FARES))
    for g, p in ((1, 0), (2, 400), (3, 1250)):        # gantries at 0, 40.0, 125.0 km
        sc.send(f_gantry(g, p))
    hot = [make_epc(rng, 1), make_epc(rng, 2)]
    for e in hot:
        sc.send(f_hot_add(e, 1))
    sc.send(f_hot_add(make_epc(rng, 1), 2))
    sc.send(f_hot_del(make_epc(rng, 3)))               # delete of an absent tag: no effect
    sc.send(f_time(t))
    prev_epc = None
    kinds = ["normal"] * 10 + ["notag", "moto", "mismatch", "hotlist", "clone", "badcrc",
                                "tailgate", "adjacent", "garbage", "taxi", "bus", "multi",
                                "early", "late"]
    for i in range(n_vehicles):
        kind = rng.choice(kinds)
        phys = rng.choice([1, 1, 1, 1, 2, 3])
        cls = phys
        epc = make_epc(rng, cls)
        present = rng.randint(250, 700)
        t += rng.randint(400, 1500)
        sc.send(f_time(t))
        reads = []                                     # (offset_ms, epc, rssi, stored_override)
        n_reads = rng.randint(2, 6)
        if kind == "moto":
            phys, epc, n_reads = 0, None, 0
        elif kind == "notag":
            epc, n_reads = None, 0
        elif kind == "mismatch":
            epc = make_epc(rng, 1)
            phys = 3
        elif kind == "hotlist":
            epc = rng.choice(hot)
            phys = epc[0] & 7
        elif kind == "clone":
            sc.send(f_sighting(epc, 3, t - 60000))    # seen 125 km away one minute ago
        elif kind == "taxi":
            epc, phys = make_epc(rng, 4), 1
        elif kind == "bus":
            epc, phys = make_epc(rng, 5), rng.choice([2, 3])
        elif kind == "tailgate" and prev_epc is not None:
            reads.append((present // 2, prev_epc, 90, None))   # previous car's tag leaks in
        if epc is not None:
            for k in range(n_reads):
                off = rng.randint(0, present)
                if kind == "early" and k == 0:
                    off = -rng.randint(50, GUARD_MS - 50)      # read before P0 rises
                reads.append((off, epc, rng.randint(40, 120), None))
            if kind == "badcrc":
                reads.append((present // 3, epc, 99, gen2_crc(PC_96, epc) ^ 0x0100))
            if kind == "multi":                                  # adjacent car, fewer reads
                reads.append((present // 4, make_epc(rng, 1), 30, None))
        if kind == "adjacent":
            sc.send(f_read(t - GUARD_MS - 200, make_epc(rng, 1), 20))  # too early: orphan
        if kind == "garbage":
            sc.send(bytes([0xA5, 0x52, 0x40, 0x11]) + bytes(rng.getrandbits(8) for _ in range(6)))
            bad = bytearray(f_time(t))
            bad[4] ^= 0x10                                        # corrupt a whole frame
            sc.send(bad)
        reads.sort(key=lambda r: r[0])
        code = CODE_FOR[phys]
        before = [r for r in reads if r[0] < 0]
        during = [r for r in reads if r[0] >= 0]
        for off, e, rssi, st in before:
            sc.send(f_read(t + off, e, rssi, stored=st))
        sc.pins(1 | code << 1)
        for off, e, rssi, st in during:
            sc.send(f_read(t + off, e, rssi, stored=st))
        t += present
        sc.send(f_time(t))
        sc.pins(0)
        if kind == "late" and epc is not None:
            sc.send(f_read(t + 50, epc, 50))                     # after exit: next car's guard
        prev_epc = epc if epc is not None else prev_epc
        sc.truth.append(kind)
        if rng.random() < 0.05:
            sc.pins(0x8)                                          # lane-closed switch
            sc.pins(0x9 | code << 1)
            t += 300
            sc.send(f_time(t))
            sc.pins(0x8)
            sc.pins(0x0)
    sc.send(f_query())
    return sc


def directed_scenario():
    """Short, hand-written cases with boundary values, in a fixed order."""
    sc = Scenario()
    rng = random.Random(7)
    car = make_epc(rng, 1)
    lorry_tag_car = make_epc(rng, 1)
    sc.send(f_config(1, 0, DEFAULT_FARES))
    sc.send(f_gantry(1, 0))
    sc.send(f_gantry(2, 100))                         # 10.0 km away
    sc.send(f_time(10000))
    # 1 plain charged car
    sc.pins(1); sc.send(f_read(10010, car, 80)); sc.send(f_time(10400)); sc.pins(0)
    # 2 same tag within DEDUP_MS - 1 in a new vehicle: excluded -> NO_TAG
    sc.send(f_time(10400 + DEDUP_MS - 1))
    sc.pins(1); sc.send(f_read(10400 + DEDUP_MS - 1, car, 80)); sc.pins(0)
    # 3 exactly DEDUP_MS later: charged again (strict less-than)
    sc.send(f_time(10400 + 2 * DEDUP_MS))
    sc.pins(1); sc.send(f_read(10400 + 2 * DEDUP_MS, car, 80)); sc.pins(0)
    # 4 guard boundary: read exactly GUARD_MS before P0 rises is kept
    t = 30000
    early = make_epc(rng, 2)
    sc.send(f_read(t - GUARD_MS, early, 70)); sc.send(f_time(t))
    sc.pins(1 | 1 << 1); sc.pins(0)
    # 5 one ms beyond the guard is dropped -> NO_TAG
    t = 40000
    late = make_epc(rng, 2)
    sc.send(f_read(t - GUARD_MS - 1, late, 70)); sc.send(f_time(t))
    sc.pins(1 | 1 << 1); sc.pins(0)
    # 6 clone speed boundary: 10.0 km in exactly 144 s = 250 km/h -> not a clone
    t = 200000
    c1 = make_epc(rng, 1)
    sc.send(f_sighting(c1, 2, t - 144000)); sc.send(f_time(t))
    sc.pins(1); sc.send(f_read(t, c1, 60)); sc.pins(0)
    # 7 one ms faster -> clone
    t = 400000
    c2 = make_epc(rng, 1)
    sc.send(f_sighting(c2, 2, t - 143999)); sc.send(f_time(t))
    sc.pins(1); sc.send(f_read(t, c2, 60)); sc.pins(0)
    # 8 lorry (class 3) with a class-1 tag -> mismatch, charged at class 3
    sc.send(f_time(500000))
    sc.pins(1 | 2 << 1); sc.send(f_read(500000, lorry_tag_car, 60)); sc.pins(0)
    # 9 hotlist add then delete: first hit, then charged
    h = make_epc(rng, 1)
    sc.send(f_hot_add(h)); sc.send(f_time(600000))
    sc.pins(1); sc.send(f_read(600000, h, 60)); sc.pins(0)
    sc.send(f_hot_del(h)); sc.send(f_time(700000))
    sc.pins(1); sc.send(f_read(700000, h, 60)); sc.pins(0)
    # 10 tie-break: equal read counts, higher RSSI wins
    a, b = make_epc(rng, 1), make_epc(rng, 2)
    sc.send(f_time(800000))
    sc.pins(1); sc.send(f_read(800000, a, 50)); sc.send(f_read(800001, b, 51)); sc.pins(0)
    # 11 lane closed by config, then reopened
    sc.send(f_config(1, 1, DEFAULT_FARES)); sc.send(f_time(900000))
    sc.pins(1); sc.send(f_read(900000, make_epc(rng, 1), 60)); sc.pins(0)
    sc.send(f_config(1, 0, DEFAULT_FARES))
    # 12 frames the parser must reject: bad CRC, len > 32, stray SOFs
    bad = bytearray(f_time(900001)); bad[-1] ^= 1
    sc.send(bad)
    sc.send(bytes([0xA5, 0x54, 0x21]))
    sc.send(bytes([0xA5, 0xA5, 0xA5]))
    sc.send(f_time(950000))                           # parser recovered?
    # 13 motorcycle, no tag -> free; motorcycle with a class-0 tag -> charged 0
    sc.pins(1 | 3 << 1); sc.pins(0)
    sc.pins(1 | 3 << 1); sc.send(f_read(950001, make_epc(rng, 0), 60)); sc.pins(0)
    # 14 a corrupted tag CRC alone -> NO_TAG, bad_tag counted
    x = make_epc(rng, 1)
    sc.pins(1); sc.send(f_read(960000, x, 60, stored=gen2_crc(PC_96, x) ^ 1)); sc.pins(0)
    # 15 hotlist overflow region: 70 adds (table 64, probe window 8) then query
    for k in range(70):
        sc.send(f_hot_add(make_epc(rng, 1)))
    sc.send(f_query())
    directed_v3(sc, rng)
    return sc


def directed_v3(sc, rng):
    """Protocol v3 boundaries, appended to the directed scenario."""
    # 16 RSSI floor 60: a read at 59 is the adjacent lane's (NO_TAG); at 60 it counts
    sc.send(f_params(rssi_min=60))
    t = 1000000
    sc.send(f_time(t))
    sc.pins(1); sc.send(f_read(t, make_epc(rng, 1), 59)); sc.pins(0)
    sc.pins(1); sc.send(f_read(t + 1, make_epc(rng, 1), 60)); sc.pins(0)
    # 17 guard 100 ms: kept at exactly 100 before arrival, dropped at 101
    sc.send(f_params(guard=100, dedup=1000, vmax=120))
    t = 1100000
    sc.send(f_read(t - 100, make_epc(rng, 1), 70)); sc.send(f_time(t)); sc.pins(1); sc.pins(0)
    t = 1200000
    sc.send(f_read(t - 101, make_epc(rng, 1), 70)); sc.send(f_time(t)); sc.pins(1); sc.pins(0)
    # 18 dedup 1000 ms: same tag 999 ms later excluded (so not re-stamped),
    #    exactly 1000 ms after the charge charged again
    car = make_epc(rng, 1)
    t = 1300000
    sc.send(f_time(t)); sc.pins(1); sc.send(f_read(t, car, 80)); sc.pins(0)
    sc.send(f_time(t + 999)); sc.pins(1); sc.send(f_read(t + 999, car, 80)); sc.pins(0)
    sc.send(f_time(t + 1000)); sc.pins(1); sc.send(f_read(t + 1000, car, 80)); sc.pins(0)
    # 18b table limits: ten distinct tags before a car (8 remembered, oldest
    #     dropped), then six distinct tags during it (4 tracked)
    t = 1400000
    many = [make_epc(rng, 1) for _ in range(16)]
    for k in range(10):
        sc.send(f_read(t - 10 + k, many[k], 40 + k))
    sc.send(f_time(t)); sc.pins(1)
    for k in range(10, 16):
        sc.send(f_read(t + k, many[k], 90))
    sc.pins(0)
    # 19 vmax 120 km/h: 10.0 km in 300 s = 120 exactly (not a clone), 299.999 s is
    for dt, tt in ((300000, 1500000), (299999, 1900000)):
        c = make_epc(rng, 1)
        sc.send(f_sighting(c, 2, tt - dt)); sc.send(f_time(tt))
        sc.pins(1); sc.send(f_read(tt, c, 70)); sc.pins(0)
    sc.send(f_params())                                   # back to the defaults
    # 20 rejected frames, one 'E' per burst: unknown type (3) then wrong length
    #    (4) -> one 'E'; a good frame re-arms; bad CRC (1); len > 32 (2)
    sc.send(frame(0x7A, b"\x01\x02"))
    sc.send(frame(0x54, b"\x01\x02\x03"))
    sc.send(f_time(2000000))
    bad = bytearray(f_query()); bad[-2] ^= 0x40
    sc.send(bad)
    sc.send(f_time(2000001))
    sc.send(bytes([0xA5, 0x51, 0x40]))
    # 21 a frame cut off mid-way while a car is present, then another as it
    #    leaves: each dropped at the inter-byte timeout ('E' 5), and the leaving
    #    car still decided
    sc.send(f_time(2000002))
    sc.pins(1)
    sc.send(f_read(2000002, make_epc(rng, 1), 70)[:9])  # arrival already handled; cut off
    sc.wait(30000)                                      # ... and dropped at the timeout
    sc.send(f_read(2000003, make_epc(rng, 1), 70))
    sc.send(f_time(2000004)[:5])                        # re-armed by the read; cut off
    sc.pins(0)
    # 22 authenticated records: key on -> 'V' + 'A' (counter 0, 1); key off -> 'V'
    sc.send(f_key(DEMO_KEY))
    for k in range(2):
        tt = 2100000 + 10000 * k
        sc.send(f_time(tt)); sc.pins(1); sc.send(f_read(tt, make_epc(rng, 1), 70)); sc.pins(0)
    sc.send(f_key(b""))
    sc.pins(1); sc.pins(0)
    sc.send(f_key(bytes(range(16))))                    # a second key restarts the counter
    sc.pins(1 | 3 << 1); sc.pins(0)
    # 23 the chip measures its own ROM
    sc.send(f_identify())
    sc.wait(ATTEST_WAIT)
    sc.send(f_query())


def fuzz_scenario(seed, n_vehicles):
    """Hostile line: random bytes, stray SOFs, frames with flipped bits, wrong
    lengths and unknown types, cut-off frames, interleaved with real traffic.
    Differential: the chip must match the model byte for byte."""
    rng = random.Random(seed)
    sc = Scenario()
    sc.send(f_key(DEMO_KEY))
    sc.send(f_params(rssi_min=20))
    sc.send(f_config(1, 0, DEFAULT_FARES))
    sc.send(f_gantry(2, 300))
    t = 500000
    good = [make_epc(rng, rng.choice([1, 2, 3])) for _ in range(6)]
    sc.send(f_hot_add(good[0]))

    def noise():
        k = rng.randrange(8)
        if k == 0:                                         # raw bytes, SOFs likely
            return bytes(rng.choice([0xA5, rng.getrandbits(8)]) for _ in range(rng.randint(1, 12)))
        if k == 1:                                         # a real frame, one bit flipped
            f = bytearray(rng.choice([f_time(t), f_query(), f_read(t, rng.choice(good), 50)]))
            f[rng.randrange(1, len(f))] ^= 1 << rng.randrange(8)
            return bytes(f)
        if k == 2:                                         # unknown type
            return frame(rng.choice([0x00, 0x7A, 0xFF, 0x55]), bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 8))))
        if k == 3:                                         # known type, wrong length
            return frame(rng.choice([0x52, 0x54, 0x43, 0x50, 0x4B]), bytes(rng.randint(1, 3)))
        if k == 4:                                         # length over 32
            return bytes([0xA5, rng.getrandbits(8), rng.randint(33, 255)])
        if k == 5:                                         # SOF storm then a good frame
            return bytes([0xA5] * rng.randint(1, 5)) + f_time(t)
        return b""

    for i in range(n_vehicles):
        t += rng.randint(500, 3000)
        sc.send(f_time(t))
        for _ in range(rng.randint(0, 3)):
            n = noise()
            if n:
                sc.send(n)
        phys = rng.choice([1, 1, 2, 3, 0])
        sc.pins(1 | CODE_FOR[phys] << 1)
        epc = rng.choice(good) if rng.random() < 0.8 else None
        for _ in range(rng.randint(0, 4)):
            if epc is not None:
                sc.send(f_read(t + rng.randint(0, 300), epc, rng.randint(10, 120)))
            if rng.random() < 0.4:
                n = noise()
                if n:
                    sc.send(n)
        if rng.random() < 0.2:                             # cut off as the car leaves
            sc.send(f_read(t + 301, rng.choice(good), 90)[:rng.randint(1, 20)])
        t += 400
        sc.send(f_time(t))
        sc.pins(0)
        sc.truth.append("fuzz")
    sc.send(f_query())
    return sc


def showcase_scenario(hold=64, attest_wait=ATTEST_WAIT):
    """The demonstration run for the video, the platform and the F2: the chip
    measures its ROM, the toll back end loads a key, parameters, a stolen car
    and a sighting; then seven vehicles, one per outcome, each 'V' with its
    'A'; a corrupted frame and its 'E'; and the stats. `hold` (the exit
    hold-off) and the wait after 'I' change only the timing, never the output:
    the fast platform run uses a shorter hold-off to fit its time window."""
    sc = Scenario()
    rng = random.Random(3)
    car, lorry_tag, stolen, cloned, taxi, far = (make_epc(rng, 1), make_epc(rng, 1),
                                                 make_epc(rng, 1), make_epc(rng, 2),
                                                 make_epc(rng, 4), make_epc(rng, 1))
    sc.send(f_identify())
    sc.wait(attest_wait)
    sc.send(f_key(DEMO_KEY))
    sc.send(f_params(rssi_min=30, hold=hold))
    sc.send(f_config(1, 0, DEFAULT_FARES))
    sc.send(f_gantry(2, 400))                            # gantry 2: 40.0 km away
    sc.send(f_hot_add(stolen))
    sc.send(f_sighting(cloned, 2, 100000))               # seen there 30 s ago
    sc.send(f_time(130000))
    sc.pins(1); sc.send(f_read(130001, car, 90)); sc.send(f_read(130002, car, 95)); sc.pins(0)
    sc.pins(1 | 2 << 1); sc.send(f_read(131000, lorry_tag, 70)); sc.pins(0)
    sc.pins(1); sc.send(f_read(132000, stolen, 80)); sc.pins(0)
    sc.pins(1 | 1 << 1); sc.send(f_read(133000, cloned, 80)); sc.pins(0)
    sc.pins(1); sc.send(f_read(134000, taxi, 85)); sc.pins(0)
    sc.pins(1); sc.send(f_read(135000, far, 20)); sc.pins(0)   # adjacent lane: below the floor
    sc.pins(1 | 3 << 1); sc.pins(0)                            # motorcycle
    bad = bytearray(f_time(136000)); bad[5] ^= 0x04
    sc.send(bad)                                               # line noise -> 'E'
    sc.send(f_query())
    return sc


def smoke_scenario():
    """Six vehicles, one of each main outcome: short enough to run through the
    whole F2 wrapper in simulation (stage4-aws/tb/tb_cl.sv) and on the platform."""
    sc = Scenario()
    rng = random.Random(11)
    car, lorry_tag, stolen, cloned = (make_epc(rng, 1), make_epc(rng, 1),
                                      make_epc(rng, 1), make_epc(rng, 2))
    sc.send(f_gantry(2, 400))
    sc.send(f_hot_add(stolen))
    sc.send(f_sighting(cloned, 2, 100000))           # 40 km away, 30 s before
    sc.send(f_time(130000))
    sc.pins(1); sc.send(f_read(130001, car, 90)); sc.send(f_read(130002, car, 95)); sc.pins(0)
    sc.pins(1 | 2 << 1); sc.send(f_read(131000, lorry_tag, 70)); sc.pins(0)
    sc.pins(1); sc.send(f_read(132000, stolen, 80)); sc.pins(0)
    sc.pins(1 | 1 << 1); sc.send(f_read(133000, cloned, 80)); sc.pins(0)
    sc.pins(1); sc.pins(0)                            # no tag
    sc.pins(1 | 3 << 1); sc.pins(0)                   # motorcycle
    return sc


def _showcase_tags():
    rng = random.Random(3)
    return [make_epc(rng, c) for c in (1, 1, 1, 2, 4, 1)]


def platform_scenarios(hold=8, attest_wait=50000):
    """The demo, cut into three runs that each fit the ChipInventor simulator's
    time window (about 260,000 cycles of a light design there; this chip at
    921,600 bps manages about 110,000 in the same time). Each starts from
    reset: key and parameters first, so every run's 'A' counter starts at 0."""
    car, lorry_tag, stolen, cloned, taxi, far = _showcase_tags()

    def head(sc):
        sc.send(f_key(DEMO_KEY))
        sc.send(f_params(rssi_min=30, hold=hold))

    a = Scenario()                       # charged, class mismatch, the next lane's read, a line error, stats
    head(a)
    a.pins(1); a.send(f_read(130001, car, 90)); a.send(f_read(130002, car, 95)); a.pins(0)
    a.pins(1 | 2 << 1); a.send(f_read(131000, lorry_tag, 70)); a.pins(0)
    a.pins(1); a.send(f_read(135000, far, 20)); a.pins(0)
    bad = bytearray(f_time(136000)); bad[5] ^= 0x04
    a.send(bad)
    a.send(f_query())
    b = Scenario()                       # a stolen car and a cloned tag
    head(b)
    b.send(f_gantry(2, 400))             # gantry 2, 40.0 km away
    b.send(f_hot_add(stolen))
    b.send(f_sighting(cloned, 2, 100000))
    b.pins(1); b.send(f_read(132000, stolen, 80)); b.pins(0)
    b.pins(1 | 1 << 1); b.send(f_read(133000, cloned, 80)); b.pins(0)
    c = Scenario()                       # the chip measures its ROM; a taxi
    c.send(f_identify())
    c.wait(attest_wait)
    head(c)
    c.pins(1); c.send(f_read(134000, taxi, 85)); c.pins(0)
    return [("lane-a", a), ("lane-b", b), ("identity", c)]


def emu_tokens(values, prefix):
    """Bytes as the organisers' emu options: as many 4-byte values as fit,
    then a 2-byte and a 1-byte one. emu sends (-t) and compares (-r) a
    multi-byte value least-significant byte first, so bytes b0 b1 b2 b3 are
    the value 0xb3b2b1b0."""
    tok, i = [], 0
    for n in (4, 2, 1):
        while len(values) - i >= n:
            v = int.from_bytes(bytes(values[i:i + n]), "little")
            tok += ["-%s%d" % (prefix, n), "0x%0*X" % (2 * n, v)]
            i += n
    return tok


def emu_commands():
    """One ./emu command line per application outcome, for the organisers'
    unmodified emulator (and for application/emulator-preview, which plays
    the same lines on the chip in simulation). Each line is one emulator run:
    emu resets the processor, so every line starts from power-up. Frames go
    out with -t4/-t2/-t1, the vehicle sensors are driven with -i, and the
    chip's 8-byte record is checked with two -r4 and its lamps with -o.

    Pins (the emulator's -d 0xF0): P0 vehicle present, P2:P1 class from the
    sensors (0 car, 1 van, 2 lorry, 3 motorcycle), P3 lane closed; P4 charged,
    P5 camera, P6 alarm, P7 lane closed. No 'P' frame here sets the frame
    timeout, so it stays off: emu sends one byte per AXI access, about 0.1 s
    apart. Returns [(title, [tokens])]."""
    rng = random.Random(2026)
    car, lorry_tag, taxi = make_epc(rng, 1), make_epc(rng, 1), make_epc(rng, 4)
    stolen, cloned, bad, far = (make_epc(rng, 1) for _ in range(4))
    t = 30000                                   # the read's time stamp, ms
    V = lambda epc, rssi=90, stored=None: [f_read(t, epc, rssi, stored=stored)]
    cases = [
        ("valid tag, class matches -> CHARGED RM 2.50, P4 on", [], 1, V(car)),
        ("car tag on a lorry -> CLASS MISMATCH, charged at the lorry fare, P4+P5",
         [], 1 | 2 << 1, V(lorry_tag)),
        ("taxi tag -> CHARGED at the taxi fare RM 1.30", [], 1, V(taxi)),
        ("no tag read -> NO TAG, camera P5", [], 1, []),
        ("motorcycle, no tag -> FREE, no lamp", [], 1 | 3 << 1, []),
        ("stolen car on the hotlist -> HOTLIST, camera + alarm P5+P6",
         [f_hot_add(stolen)], 1, V(stolen)),
        ("cloned tag: seen 40 km away 30 s ago -> CLONE, camera + alarm",
         [f_gantry(2, 400), f_sighting(cloned, 2, 0)], 1, V(cloned)),
        ("radio-corrupted tag (bad Gen2 CRC) -> NO TAG, camera",
         [], 1, V(bad, stored=gen2_crc(PC_96, bad) ^ 0x0100)),
        ("adjacent lane's weak read below the RSSI floor -> NO TAG",
         [f_params(rssi_min=30, timeout=0)], 1, V(far, rssi=20)),
        ("lane closed (P3) -> LANE CLOSED, P7 stays on while closed",
         [], 1 | 1 << 3, V(car)),
    ]
    out = []
    for title, pre, pins, reads in cases:
        sc = Scenario()
        for f in pre:
            sc.send(f)
        sc.pins(pins)                           # the vehicle arrives
        for f in reads:
            sc.send(f)
        sc.pins(pins & 0x8)                     # and leaves (the lane stays closed if it was)
        m = sc.run()
        tok = ["-d", "0xF0"]
        for kind, v in sc.ev:
            tok += ["-i", "0x%02X" % v] if kind == "G" else emu_tokens(list(v), "t")
        tok += emu_tokens(list(m.out), "r") + ["-o", "0x%02X" % m.pins]
        out.append((title, tok))
    # the chip measures its own ROM: size and CRC, compared with the build
    sc = Scenario()
    sc.send(f_identify())
    m = sc.run()
    out.append(("identify: the chip reads its own ROM and reports its size and CRC",
                ["-d", "0xF0"] + emu_tokens(list(f_identify()), "t") + emu_tokens(list(m.out), "r")))
    return out


def write_host_files(scens, root):
    """stage4-aws/host/rvbl2_scen.h (built-in scenarios for the host tool) and
    stage4-aws/host/rvbl2_f2.c: the tool as ONE file, header inlined, for pasting
    into the F2 console."""
    lines = ["/* rvbl2_scen.h - GENERATED by application/testbench/lane_model.py; do not edit.",
             " * Events: 'G',1,pins | 'B',len,bytes... | 'W',4,cycles u32 (idle).",
             " * Expected: 8-byte records. */",
             "#include <stdint.h>"]
    for name, sc in scens:
        m = sc.run()
        ev = []
        for kind, v in sc.ev:
            if kind == "G":
                ev += [ord("G"), 1, v]
            elif kind == "W":
                ev += [ord("W"), 4] + list(struct.pack("<I", v))
            else:
                ev += [ord("B"), len(v)] + list(v)
        vp = [x >> 4 for x in m.vehicle_pins]
        for tag, data in (("ev", ev), ("exp", list(m.out)), ("vpins", vp)):
            lines.append("static const uint8_t scen_%s_%s[%d] = {" % (name, tag, len(data)))
            for i in range(0, len(data), 16):
                lines.append("    " + ", ".join("0x%02x" % b for b in data[i:i + 16]) + ",")
            lines.append("};")
    hdr = "\n".join(lines) + "\n"
    hdir = os.path.join(root, "stage4-aws", "host")
    if not os.path.isfile(os.path.join(hdir, "rvbl2.c")):
        return                          # the Stage 4 host tool is not in this tree
    with open(os.path.join(hdir, "rvbl2_scen.h"), "w", newline="\n") as f:
        f.write(hdr)
    src = open(os.path.join(hdir, "rvbl2.c"), encoding="utf-8").read()
    inc = '#include "rvbl2_scen.h"   /* generated by application/testbench/lane_model.py; inlined in rvbl2_f2.c */\n'
    assert src.count(inc) == 1
    with open(os.path.join(hdir, "rvbl2_f2.c"), "w", newline="\n") as f:
        f.write("/* rvbl2_f2.c - GENERATED: stage4-aws/host/rvbl2.c with rvbl2_scen.h inlined. */\n"
                + src.replace(inc, hdr))


# Every bin the combined scenarios must reach: each outcome, each rejection,
# each table limit and each parameter boundary. The run fails if one is 0.
REQUIRED_BINS = STATUS_NAMES + [
    "E1", "E2", "E3", "E4", "E5", "E suppressed",
    "tag CRC bad", "read below RSSI floor", "pending reads full", "tags per vehicle full",
    "several tags in one vehicle", "tie broken by RSSI",
    "read kept by the guard", "guard boundary (kept)", "read dropped by the guard",
    "tag excluded: charged here moments ago", "dedup boundary (charged again)",
    "clone speed boundary (exactly vmax)",
    "hotlist add", "hotlist slot reused", "hotlist probe window full", "sighting evicted",
    "parameters set", "key loaded", "key cleared", "record authenticated", "identify",
]


def scenarios(seed=2026, vehicles=120, fuzz_vehicles=60):
    return [("smoke", smoke_scenario()), ("directed", directed_scenario()),
            ("random", build_scenario(seed, vehicles)), ("fuzz", fuzz_scenario(seed + 1, fuzz_vehicles)),
            ("showcase", showcase_scenario())]


if __name__ == "__main__":
    import argparse
    import os
    ap = argparse.ArgumentParser(description="write lane scenarios + expected output")
    ap.add_argument("--out", default="build/lane")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--vehicles", type=int, default=120)
    ap.add_argument("--soak", type=int, default=0,
                    help="also write soak.{stim,exp}: this many vehicles, keyed (RUN_LONG)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if load_rom() is None:
        raise SystemExit("application/firmware/out/lane/firmware.hex missing: run make in application/firmware first "
                         "('I' reports the ROM's CRC, so the model needs the image)")
    total = collections.Counter()
    scen = scenarios(a.seed, a.vehicles)
    if a.soak:
        scen.append(("soak", build_scenario(a.seed + 7, a.soak)))
    for name, sc in scen:
        m = sc.write(os.path.join(a.out, name + ".stim"), os.path.join(a.out, name + ".exp"))
        total.update(m.cov)
        kinds = collections.Counter(chr(m.out[i]) for i in range(0, len(m.out), 8))
        print("%-9s %4d vehicles, %4d stimulus events, %5d output bytes  records %s"
              % (name, m.vehicles, len(sc.ev), len(m.out),
                 " ".join("%s:%d" % kv for kv in sorted(kinds.items()))))
    missing = [b for b in REQUIRED_BINS if not total[b]]
    print("coverage: %d of %d required bins hit%s"
          % (len(REQUIRED_BINS) - len(missing), len(REQUIRED_BINS),
             "" if not missing else "; MISSING: " + ", ".join(missing)))
    with open(os.path.join(a.out, "coverage.txt"), "w", newline="\n") as f:
        for b in REQUIRED_BINS:
            f.write("%6d  %s\n" % (total[b], b))
    if missing:
        raise SystemExit(1)
    root = ROOT
    write_host_files((("smoke", smoke_scenario()), ("directed", directed_scenario()),
                      ("showcase", showcase_scenario())), root)
    demos = emu_commands()
    emu_file = os.path.join(ROOT, "application", "emulator-preview", "emu_commands.txt")
    with open(emu_file, "w", newline="\n") as f:
        f.write("# ./emu command lines for the lane controller, one emulator run each.\n"
                "# GENERATED by application/testbench/lane_model.py (the expected -r and -o\n"
                "# values are the golden model's). application/emulator-preview plays them\n"
                "# on the chip in simulation.\n")
        for title, tok in demos:
            f.write("\n# %s\n./emu %s\n" % (title, " ".join(tok)))
    print("wrote %s (%d ./emu command lines)" % (os.path.relpath(emu_file, ROOT), len(demos)))
    # the same lines for stage4-aws/tb/tb_cl.sv (T9), one byte per option
    with open(os.path.join(a.out, "emu_demos.tok"), "w", newline="\n") as f:
        for title, tok in demos:
            for opt, val in zip(tok[0::2], tok[1::2]):
                key, v = opt.lstrip("-"), int(val, 0)
                n = int(key[1]) if len(key) == 2 else 1
                for k in range(n):
                    f.write("%s %02x\n" % (key[0], (v >> (8 * k)) & 0xFF))
            f.write("E 0\n")
        f.write("Z 0\n")
