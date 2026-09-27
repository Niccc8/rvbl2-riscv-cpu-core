/*
 * lane - free-flow toll lane controller for RVBL-2 (the Stage 3 application).
 *
 * The chip is the lane controller at one lane of a barrier-free gantry: it
 * takes UHF RFID tag reads and back-end commands over the UART, vehicle
 * presence, class and lane state on GPIO, and decides for every vehicle -
 * charge it, photograph it, raise an alarm - emitting an 8-byte record sealed
 * with CRC-16 and, once the toll back end has loaded a key, authenticated with
 * Chaskey-12 (ISO/IEC 29192-6). application/testbench/lane_model.py is the
 * executable specification: this file must produce byte-for-byte its output
 * stream and pin states, which application/testbench/tb_app.v checks. The
 * protocol is in application/PROTOCOL.md.
 *
 * The main loop never blocks: bytes are parsed as they arrive, the pins are
 * polled every iteration, output drains through a transmit queue one byte
 * per TXDONE, and the two long computations - the record MAC and the ROM
 * measurement - run as background jobs a slice per iteration. The UART holds
 * a single received byte, so nothing here may keep the loop away from it for
 * a byte-time; tb_app measures the longest wait.
 */
#include <stdint.h>
#include "hal.h"

#define PROTO      3
#define SOF        0xA5
#define MAX_LEN    32
#define PENDING    8
#define VTAGS      4
#define HOT_SLOTS  64
#define SEEN_SLOTS 64
#define PROBES     8
#define TXQ        128
#define MAC_ROUNDS_PER_STEP 4
#define ATTEST_WORDS_PER_STEP 64

enum { ST_CHARGED, ST_NO_TAG, ST_MISMATCH, ST_HOTLIST, ST_CLONE, ST_FREE, ST_CLOSED };

typedef struct { uint32_t w[3]; } epc_t;

static const uint8_t code_to_class[4] = {1, 2, 3, 0};

/* configuration: 'C', 'G', 'P' */
static uint32_t gantry = 1, closed_cfg;
static uint16_t fares[6] = {0, 250, 500, 750, 130, 380};
static uint16_t pos[8];
static uint32_t rssi_min, guard_ms = 500, dedup_ms = 3000, vmax_kmh = 250;
/* Exit hold-off, in main-loop iterations: a car's decision waits until the
 * UART has been quiet this long after it left, so reads still in flight - a
 * reader reporting late, or a host that queued the frame before lowering P0 -
 * are counted. An idle iteration is ~170 cycles, so 64 is ~10,900 cycles: 2.5
 * byte-times at 50 MHz, 4.1 at 30.3 MHz. The next car arriving decides the
 * previous one at once. */
static uint32_t hold = 64;
/* Frame timeout, in main-loop iterations of silence (~170 cycles each): a
 * half-received frame is dropped after it, as 'E' reason 5. 0 = never, the
 * default, because the organisers' emulator sends one byte per AXI access,
 * about 0.1 s apart - a timeout would cut every frame it sends. A host that
 * streams its bytes switches it on with 'P' (48: ~3 byte-times at 30.3 MHz,
 * longer than the 2-byte-time gap between frames). */
static uint32_t frame_timeout;

/* state */
static uint32_t now, seq, vehicles, bad_tag, bad_frame, hot_n, tx_drops;
static uint32_t pins, gp, code, active;
static uint32_t fin_pending, fin_hold, fin_closed;
static uint32_t err_armed = 1, idle;

/* Tables live in .noinit (not zeroed at boot, see link.ld); an entry is only
   ever read when its count or flag, which are zeroed, says it is valid. */
#define NOINIT __attribute__((section(".noinit")))
static NOINIT struct { epc_t e; uint32_t t; uint8_t rssi; } pend[PENDING];
static uint32_t pend_n;
static NOINIT struct { epc_t e; uint32_t count, rssi; } vt[VTAGS];
static uint32_t vt_n;

static NOINIT epc_t hot[HOT_SLOTS];
static uint8_t hot_state[HOT_SLOTS];            /* 0 empty, 1 used, 2 tombstone */
static NOINIT struct { epc_t e; uint32_t t; uint32_t g; } seen[SEEN_SLOTS];
static uint8_t seen_used[SEEN_SLOTS];

/* ---- input --------------------------------------------------------------
 * The UART holds one received byte, and the next one overwrites it a
 * byte-time later (2,630 cycles at 115,200 bps; 330 at 921,600). Decisions,
 * table lookups and the MAC take longer than that, so every loop that can run
 * for more than a couple of hundred cycles calls uart_service(), which moves a
 * waiting byte into this ring; the main loop parses from the ring, in order.
 * The worst-case wait for a byte is then the longest stretch between two
 * calls, not the longest piece of work (tb_app measures it). */
#define RXQ 64
static NOINIT uint8_t rxq[RXQ];
static uint32_t rxh, rxt, rx_lost;

static inline __attribute__((always_inline)) void uart_service(void)
{
    if (UART_CONTROL & UART_RXDONE) {
        uint8_t b = (uint8_t)UART_RXDATA;
        UART_CONTROL = 0;                           /* clear RXDONE; TRANSMIT = 0 does nothing */
        if (rxt - rxh < RXQ)
            rxq[rxt++ & (RXQ - 1)] = b;
        else
            rx_lost++;
    }
}

/* ---- output ------------------------------------------------------------ */

static NOINIT uint8_t txq[TXQ];                  /* only [txh, txt) is ever read */
static uint32_t txh, txt;                       /* head (next out), tail */

static void tx_poll(void)
{
    if (txh != txt && (UART_CONTROL & UART_TXDONE)) {
        UART_TXDATA = txq[txh++ & (TXQ - 1)];
        UART_CONTROL = UART_TRANSMIT | UART_RXDONE;   /* keep a pending RX byte */
    }
}

/* A whole record or nothing: a record never tears. */
static void push8(const uint8_t r[8])
{
    if (txt - txh > TXQ - 8) {
        tx_drops++;
        return;
    }
    for (int i = 0; i < 8; i++) {
        txq[txt++ & (TXQ - 1)] = r[i];
        if (i == 3)
            uart_service();
    }
    uart_service();
}

static void seal(uint8_t r[8], uint32_t kind, const uint8_t body[5])
{
    uint32_t crc = xicrc_b(0xFFFF, kind);
    r[0] = (uint8_t)kind;
    for (int i = 0; i < 5; i++) {
        r[1 + i] = body[i];
        crc = xicrc_b(crc, body[i]);
    }
    r[6] = (uint8_t)crc;
    r[7] = (uint8_t)(crc >> 8);
}

/* ---- Chaskey-12 record authentication ------------------------------------
 * Chaskey-12 (Mouha, 2015; ISO/IEC 29192-6:2019): an ARX permutation on four
 * 32-bit words, twelve rounds, built for 32-bit microcontrollers. Each 'V'
 * record is followed by an 'A' record carrying the first 4 bytes of the tag
 * over V[0..5] | gantry | PROTO | counter, one 12-byte (padded) block. The
 * rounds run MAC_ROUNDS_PER_STEP per main-loop iteration; anything that
 * emits a record first completes a pending MAC, so records keep the model's
 * order. The round and the subkeys are the HAL's (lib/hal.c), which
 * selftest checks against the reference test vectors on the RTL. */
static uint32_t kk[4], k2[4], auth_on, auth_ctr;
static uint32_t mv[4], mac_r;                   /* state, rounds left */
static uint8_t mac_rec[8];                       /* the 'V' record being authenticated */

static void mac_finish(void)
{
    uint8_t a[5];
    uint32_t tag = mv[0] ^ k2[0];
    push8(mac_rec);
    uart_service();
    a[0] = mac_rec[1];
    a[1] = (uint8_t)tag;
    a[2] = (uint8_t)(tag >> 8);
    a[3] = (uint8_t)(tag >> 16);
    a[4] = (uint8_t)(tag >> 24);
    uint8_t r[8];
    seal(r, 0x41, a);
    uart_service();
    push8(r);
    auth_ctr++;
}

static void mac_step(uint32_t rounds)
{
    while (rounds-- && mac_r) {
        chaskey12_round(mv);
        uart_service();
        if (--mac_r == 0)
            mac_finish();
    }
}

static void mac_flush(void) { mac_step(12); }

static void mac_start(const uint8_t v[8])
{
    for (int i = 0; i < 8; i++)
        mac_rec[i] = v[i];
    /* one final block: 12 message bytes, the 0x01 padding byte, zeros; K2 */
    mv[0] = kk[0] ^ k2[0] ^ (v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24);
    mv[1] = kk[1] ^ k2[1] ^ (v[4] | v[5] << 8 | gantry << 16 | (uint32_t)PROTO << 24);
    mv[2] = kk[2] ^ k2[2] ^ auth_ctr;
    mv[3] = kk[3] ^ k2[3] ^ 0x01u;
    mac_r = 12;
}

/* Every record other than the MAC job's own goes through here. */
static void record(uint32_t kind, const uint8_t body[5])
{
    uint8_t r[8];
    mac_flush();
    seal(r, kind, body);
    push8(r);
}

/* ---- ROM measurement ('I') ------------------------------------------------
 * The CRC-16 of the firmware image, word 0 to the end of .data's initial
 * values, one crcw per word. It runs ATTEST_WORDS_PER_STEP words per
 * iteration, so the UART is served throughout. */
extern const uint32_t __rom_end[];
#define ROM_BASE ((const volatile uint32_t *)0x00400000u)

static const volatile uint32_t *att_p;
static uint32_t att_crc, att_busy;

static void att_step(void)
{
    const volatile uint32_t *end = (const volatile uint32_t *)__rom_end;
    const volatile uint32_t *p = att_p;             /* locals, so the loop stays in */
    uint32_t crc = att_crc, n = 0;                   /* registers                    */
    while (n < ATTEST_WORDS_PER_STEP && end - p >= 8) {   /* eight words, then the UART */
        crc = xicrc_w(crc, p[0]); crc = xicrc_w(crc, p[1]);
        crc = xicrc_w(crc, p[2]); crc = xicrc_w(crc, p[3]);
        crc = xicrc_w(crc, p[4]); crc = xicrc_w(crc, p[5]);
        crc = xicrc_w(crc, p[6]); crc = xicrc_w(crc, p[7]);
        p += 8;
        n += 8;
        uart_service();
    }
    while (n < ATTEST_WORDS_PER_STEP && p != end) {      /* the image's last few words */
        crc = xicrc_w(crc, *p++);
        n++;
    }
    att_p = p;
    att_crc = crc;
    if (att_p == end) {
        uint32_t words = (uint32_t)(end - ROM_BASE);
        uint8_t body[5] = {PROTO, (uint8_t)words, (uint8_t)(words >> 8),
                           (uint8_t)att_crc, (uint8_t)(att_crc >> 8)};
        att_busy = 0;
        record(0x49, body);
    }
}

/* ---- pins ---------------------------------------------------------------- */

static void set_pins(void) { GPIO_DATAOUT = pins; }

static void update_p7(void)
{
    uint32_t closed = closed_cfg | ((gp >> 3) & 1);
    pins = (pins & 0x70) | (closed << 7);
    set_pins();
}

/* ---- tags -------------------------------------------------------------- */

static int epc_eq(const epc_t *a, const epc_t *b)
{
    return a->w[0] == b->w[0] && a->w[1] == b->w[1] && a->w[2] == b->w[2];
}

static uint32_t epc_hash(const epc_t *e)
{
    uint32_t h = (e->w[0] * 0x9E3779B1u) ^ (e->w[1] * 0x85EBCA77u) ^ (e->w[2] * 0xC2B2AE3Du);
    return (h * 0x27D4EB2Fu) >> 26;
}

static int hot_find(const epc_t *e)
{
    uint32_t h = epc_hash(e);
    for (uint32_t i = 0; i < PROBES; i++) {
        uint32_t k = (h + i) & (HOT_SLOTS - 1);
        uart_service();
        if (hot_state[k] == 0)
            return -1;
        if (hot_state[k] == 1 && epc_eq(&hot[k], e))
            return (int)k;
    }
    return -1;
}

static void hot_add(const epc_t *e)
{
    if (hot_find(e) >= 0)
        return;
    uint32_t h = epc_hash(e);
    for (uint32_t i = 0; i < PROBES; i++) {
        uint32_t k = (h + i) & (HOT_SLOTS - 1);
        uart_service();
        if (hot_state[k] != 1) {
            hot[k] = *e;
            hot_state[k] = 1;
            hot_n++;
            return;
        }
    }
}

static void hot_del(const epc_t *e)
{
    int k = hot_find(e);
    if (k >= 0) {
        hot_state[k] = 2;
        hot_n--;
    }
}

static int seen_get(const epc_t *e)
{
    uint32_t h = epc_hash(e);
    for (uint32_t i = 0; i < PROBES; i++) {
        uint32_t k = (h + i) & (SEEN_SLOTS - 1);
        uart_service();
        if (!seen_used[k])
            return -1;
        if (epc_eq(&seen[k].e, e))
            return (int)k;
    }
    return -1;
}

static void seen_put(const epc_t *e, uint32_t g, uint32_t t)
{
    uint32_t h = epc_hash(e), victim = 0, vtime = 0;
    int have = 0;
    for (uint32_t i = 0; i < PROBES; i++) {
        uint32_t k = (h + i) & (SEEN_SLOTS - 1);
        uart_service();
        if (!seen_used[k] || epc_eq(&seen[k].e, e)) {
            victim = k;
            goto put;
        }
        if (!have || seen[k].t < vtime) {
            victim = k;
            vtime = seen[k].t;
            have = 1;
        }
    }
put:
    seen[victim].e = *e;
    seen[victim].g = g;
    seen[victim].t = t;
    seen_used[victim] = 1;
}

static void vt_add(const epc_t *e, uint32_t rssi)
{
    uart_service();
    for (uint32_t i = 0; i < vt_n; i++)
        if (epc_eq(&vt[i].e, e)) {
            vt[i].count++;
            if (rssi > vt[i].rssi)
                vt[i].rssi = rssi;
            return;
        }
    if (vt_n < VTAGS) {
        vt[vt_n].e = *e;
        vt[vt_n].count = 1;
        vt[vt_n].rssi = rssi;
        vt_n++;
    }
}

/* ---- decisions --------------------------------------------------------- */

static int too_fast(uint32_t g_other, uint32_t t_other)
{
    int32_t d = (int32_t)pos[gantry] - (int32_t)pos[g_other];
    uint32_t dist = (uint32_t)(d < 0 ? -d : d);          /* 0.1 km */
    uint32_t dt = now - t_other;
    if (dt == 0 || dt >= 0x80000000u)
        return dist > 0;
    /* km/h = dist*0.1 / (dt/3.6e6) = dist*360000/dt; compare without dividing */
    return (uint64_t)dist * 360000u > (uint64_t)vmax_kmh * dt;
}

static int class_ok(uint32_t tagc, uint32_t phys)
{
    if (tagc == 4)
        return phys == 1;                               /* taxi */
    if (tagc == 5)
        return phys == 2 || phys == 3;                  /* bus */
    return tagc == phys;
}

static void finalize(void)
{
    uint32_t phys = code_to_class[code];
    uint32_t closed = fin_closed;
    int best = -1;
    active = 0;
    fin_pending = 0;

    for (uint32_t i = 0; i < vt_n; i++) {
        uart_service();
        int s = seen_get(&vt[i].e);
        if (s >= 0 && seen[s].g == gantry && (int64_t)now - (int64_t)seen[s].t < (int64_t)dedup_ms)
            continue;                                   /* charged here moments ago */
        if (best < 0 || vt[i].count > vt[best].count ||
            (vt[i].count == vt[best].count && vt[i].rssi > vt[best].rssi))
            best = (int)i;
    }

    uint32_t st, tagc = 7, fare = 0;
    if (closed) {
        st = ST_CLOSED;
    } else if (best < 0) {
        st = phys == 0 ? ST_FREE : ST_NO_TAG;
    } else {
        const epc_t *e = &vt[best].e;
        int s = seen_get(e);
        tagc = e->w[0] & 7;
        if (hot_find(e) >= 0)
            st = ST_HOTLIST;
        else if (s >= 0 && seen[s].g != gantry && too_fast(seen[s].g, seen[s].t))
            st = ST_CLONE;
        else if (!class_ok(tagc, phys)) {
            st = ST_MISMATCH;
            fare = fares[phys];
        } else {
            st = ST_CHARGED;
            fare = fares[tagc < 6 ? tagc : phys];
        }
        seen_put(e, gantry, now);
    }

    vehicles++;
    uart_service();
    uint8_t body[5] = {(uint8_t)seq, (uint8_t)st, (uint8_t)(phys << 4 | tagc),
                       (uint8_t)fare, (uint8_t)(fare >> 8)};
    uint8_t v[8];
    mac_flush();
    seal(v, 0x56, body);
    if (auth_on)
        mac_start(v);                               /* 'V' and 'A' leave together */
    else
        push8(v);
    seq = (seq + 1) & 0xFF;

    uint32_t charged = st == ST_CHARGED || st == ST_MISMATCH;
    uint32_t camera = st == ST_NO_TAG || st == ST_MISMATCH || st == ST_HOTLIST || st == ST_CLONE;
    uint32_t alarm = st == ST_HOTLIST || st == ST_CLONE;
    pins = (pins & 0x80) | charged << 4 | camera << 5 | alarm << 6;
    set_pins();
}

static void on_gpio(uint32_t v)
{
    uint32_t was = gp & 1;
    gp = v;
    if (v & 1)
        code = (v >> 1) & 3;
    if (!was && (v & 1)) {
        if (fin_pending)
            finalize();                                 /* the next car: decide now */
        active = 1;
        vt_n = 0;
        for (uint32_t i = 0; i < pend_n; i++)
            if (now - pend[i].t <= guard_ms)            /* pend[i].t <= now always */
                vt_add(&pend[i].e, pend[i].rssi);
        pend_n = 0;
    } else if (was && !(v & 1)) {
        fin_pending = 1;                                /* decide after the hold-off */
        fin_hold = hold;
        fin_closed = closed_cfg | ((v >> 3) & 1);
    }
    update_p7();
}

/* ---- frames ------------------------------------------------------------ */

static uint32_t rd16(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8; }
static uint32_t rd32(const uint8_t *p) { return rd16(p) | rd16(p + 2) << 16; }

static void get_epc(epc_t *e, const uint8_t *p)
{
    e->w[0] = rd32(p);
    e->w[1] = rd32(p + 4);
    e->w[2] = rd32(p + 8);
}

static void error(uint32_t reason, uint32_t type)
{
    if (bad_frame < 255)
        bad_frame++;
    if (err_armed) {
        uint8_t body[5] = {(uint8_t)reason, (uint8_t)type, (uint8_t)bad_frame, 0, 0};
        record(0x45, body);
        err_armed = 0;
    }
}

static void on_read(const uint8_t *p)
{
    uint32_t t = rd32(p), pc = rd16(p + 4), stored = rd16(p + 18), rssi = p[20];
    epc_t e;
    if (t > now)
        now = t;
    uint32_t crc = xicrc_b(0xFFFF, pc >> 8);
    crc = xicrc_b(crc, pc & 0xFF);
    for (int i = 0; i < 12; i++)
        crc = xicrc_b(crc, p[6 + i]);
    uart_service();
    if ((crc ^ 0xFFFF) != stored) {                     /* CRC-16/EPC-C1G2 */
        if (bad_tag < 255)
            bad_tag++;
        return;
    }
    if (rssi < rssi_min)                                /* the adjacent lane's tag */
        return;
    get_epc(&e, p + 6);
    if (active) {
        vt_add(&e, rssi);
    } else {
        uart_service();
        if (pend_n == PENDING) {                        /* drop the oldest */
            for (uint32_t i = 1; i < PENDING; i++)
                pend[i - 1] = pend[i];
            pend_n--;
        }
        pend[pend_n].e = e;
        pend[pend_n].t = t;
        pend[pend_n].rssi = (uint8_t)rssi;
        pend_n++;
    }
}

/* Payload length each type takes; -1 = unknown type. 'K' takes 16 or 0. */
static int frame_len_ok(uint32_t type, uint32_t n)
{
    switch (type) {
    case 0x52: return n == 21;
    case 0x54: return n == 4;
    case 0x43: return n == 14;
    case 0x47: return n == 3;
    case 0x48: return n == 13;
    case 0x68: return n == 12;
    case 0x53: return n == 17;
    case 0x51: return n == 0;
    case 0x50: return n == 10;
    case 0x4B: return n == 16 || n == 0;
    case 0x49: return n == 0;
    default:   return -1;
    }
}

static void on_frame(uint32_t type, const uint8_t *p, uint32_t n)
{
    epc_t e;
    int ok = frame_len_ok(type, n);
    if (ok < 0) {
        error(3, type);
        return;
    }
    if (!ok) {
        error(4, type);
        return;
    }
    err_armed = 1;
    if (type == 0x52) {
        on_read(p);
    } else if (type == 0x54) {
        uint32_t t = rd32(p);
        if (t > now)
            now = t;
    } else if (type == 0x43) {
        gantry = p[0] & 7;
        closed_cfg = p[1] & 1;
        for (int i = 0; i < 6; i++)
            fares[i] = (uint16_t)rd16(p + 2 + 2 * i);
        update_p7();
    } else if (type == 0x47) {
        pos[p[0] & 7] = (uint16_t)rd16(p + 1);
    } else if (type == 0x48) {
        get_epc(&e, p);
        hot_add(&e);
    } else if (type == 0x68) {
        get_epc(&e, p);
        hot_del(&e);
    } else if (type == 0x53) {
        get_epc(&e, p);
        seen_put(&e, p[12] & 7, rd32(p + 13));
    } else if (type == 0x51) {
        uint8_t body[5] = {(uint8_t)vehicles, (uint8_t)(vehicles >> 8), (uint8_t)bad_tag,
                           (uint8_t)bad_frame, (uint8_t)hot_n};
        record(0x51, body);
    } else if (type == 0x50) {
        rssi_min = p[0];
        guard_ms = rd16(p + 1);
        dedup_ms = rd16(p + 3);
        vmax_kmh = rd16(p + 5);
        hold = p[7] ? p[7] : 1;
        frame_timeout = rd16(p + 8);
    } else if (type == 0x4B) {
        mac_flush();                                    /* finish under the old key */
        auth_on = n != 0;
        auth_ctr = 0;
        if (auth_on) {
            uint32_t k1[4];
            for (int i = 0; i < 4; i++)
                kk[i] = rd32(p + 4 * i);
            chaskey12_subkeys(k1, k2, kk);
        }
    } else if (type == 0x49) {
        att_p = ROM_BASE;                               /* (re)start the measurement */
        att_crc = 0xFFFF;
        att_busy = 1;
    }
}

static uint8_t buf[MAX_LEN + 4];
static uint32_t pst, plen, need, pcrc;

static void parse(uint32_t b)
{
    if (pst == 0) {
        if (b == SOF) {
            pst = 1;
            plen = 0;
            pcrc = 0xFFFF;
        }
        return;
    }
    buf[plen++] = (uint8_t)b;
    if (pst == 1) {                                     /* type */
        pcrc = xicrc_b(pcrc, b);
        pst = 2;
    } else if (pst == 2) {                              /* len */
        if (b > MAX_LEN) {
            pst = 0;
            error(2, buf[0]);
        } else {
            pcrc = xicrc_b(pcrc, b);
            need = b + 2;
            pst = b ? 3 : 4;
        }
    } else if (pst == 3) {                              /* payload */
        pcrc = xicrc_b(pcrc, b);
        if (--need == 2)
            pst = 4;
    } else {                                            /* crc, 2 bytes */
        if (--need == 0) {
            pst = 0;
            if (rd16(&buf[plen - 2]) != pcrc)
                error(1, buf[0]);
            else
                on_frame(buf[0], &buf[2], buf[1]);
        }
    }
}

int main(void)
{
    uint8_t c;
    gpio_set_dir(0xF0);
    gp = gpio_read() & 0x0F;
    if (gp & 1)
        code = (gp >> 1) & 3;
    gp &= ~1u;                          /* a car already present is seen rising */
    update_p7();
    for (;;) {
        uart_service();
        uint32_t got = rxh != rxt;
        if (got) {
            c = rxq[rxh++ & (RXQ - 1)];
            idle = 0;
            parse(c);
        } else if (idle < 0xFFFF) {
            idle++;
        }
        if (pst != 0 && frame_timeout && idle == frame_timeout) {   /* frame cut off mid-way */
            pst = 0;
            error(5, plen ? buf[0] : 0);
        }
        uint32_t v = gpio_read() & 0x0F;
        if (v != gp)
            on_gpio(v);
        if (fin_pending) {
            if (got || pst != 0)
                fin_hold = hold;                        /* a frame is still arriving */
            else if (--fin_hold == 0)
                finalize();
        }
        if (mac_r)
            mac_step(MAC_ROUNDS_PER_STEP);
        if (att_busy && !got)
            att_step();
        tx_poll();
    }
}
