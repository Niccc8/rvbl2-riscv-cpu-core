/*
 * selftest - proves that GCC-built C runs correctly on RVBL-2: every class of
 * code the compiler emits for this target, the C runtime (crt0.S, link.ld)
 * and the HAL. application/testbench/tb_selftest.v runs it on rtl/top.v and checks the UART transcript
 * and the pins.
 *
 * Transcript: "RVBL-2 C selftest\n", one "<group> ok|FAIL" line per group,
 * "READY\n", then the UART exchange with the testbench, then
 * "SELFTEST PASS <checks>\n" or "SELFTEST FAIL <failures>\n".
 */
#include <stdint.h>
#include "hal.h"

static unsigned checks, failures;

static void check(int ok)
{
    checks++;
    if (!ok)
        failures++;
}

static void group(const char *name, unsigned fail_before)
{
    uart_puts(name);
    uart_puts(failures == fail_before ? " ok\n" : " FAIL\n");
}

/* .data with non-zero initial values (copied from IMEM by crt0) */
static volatile uint32_t d_word = 0x1234ABCDu;
static volatile uint8_t d_bytes[5] = {1, 2, 3, 4, 5};
/* .bss (zeroed by crt0) */
static volatile uint32_t b_zero[8];

/* .rodata, read from IMEM by byte, halfword and word loads */
static const char r_text[] = "RVBL-2";
static const int8_t r_s8[4] = {-1, -128, 127, 0};
static const int16_t r_s16[2] = {-2, 0x7FFF};
static const uint16_t r_u16[2] = {0xFFFE, 0x8000};

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static int op_add(int a, int b) { return a + b; }
static int op_sub(int a, int b) { return a - b; }
static int op_xor(int a, int b) { return a ^ b; }
static int (*const r_ops[3])(int, int) = {op_add, op_sub, op_xor};

static int __attribute__((noinline)) dense_switch(volatile int k)
{
    switch (k) {   /* dense enough for a jump table in .rodata */
    case 0: return 11;
    case 1: return 23;
    case 2: return 37;
    case 3: return 41;
    case 4: return 53;
    case 5: return 67;
    case 6: return 71;
    case 7: return 89;
    default: return -1;
    }
}

/* Bit-serial CRC-16/CCITT-FALSE, the independent reference for Xicrc. */
static uint16_t crc16_soft(uint16_t crc, const uint8_t *p, unsigned n)
{
    while (n--) {
        crc ^= (uint16_t)(*p++ << 8);
        for (int i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

struct pkt { uint32_t a; uint16_t b; uint8_t c[6]; };

int main(void)
{
    unsigned f;
    uart_puts("RVBL-2 C selftest\n");

    f = failures;   /* crt0: .data copied, .bss zeroed */
    check(d_word == 0x1234ABCDu);
    check(d_bytes[0] == 1 && d_bytes[4] == 5);
    for (int i = 0; i < 8; i++)
        check(b_zero[i] == 0);
    group("crt0", f);

    f = failures;   /* loads from IMEM: lb/lbu/lh/lhu/lw with sign extension */
    unsigned sum = 0;
    for (const char *p = r_text; *p; p++)
        sum += (unsigned char)*p;
    check(sum == 'R' + 'V' + 'B' + 'L' + '-' + '2');
    check(r_s8[0] == -1 && r_s8[1] == -128 && r_s8[2] == 127);
    check(r_s16[0] == -2 && r_s16[1] == 32767);
    check(r_u16[0] == 0xFFFE && r_u16[1] == 0x8000);
    group("rodata", f);

    f = failures;   /* sub-word stores and loads in DMEM */
    static volatile union { uint32_t w; uint16_t h[2]; uint8_t b[4]; int8_t sb[4]; int16_t sh[2]; } u;
    u.w = 0;
    u.b[1] = 0x80;
    u.h[1] = 0xBEEF;
    check(u.w == 0xBEEF8000u);
    check(u.sb[1] == -128 && u.sh[1] == (int16_t)0xBEEF);
    group("subword", f);

    f = failures;   /* Zmmul, plus libgcc's RV32I division */
    volatile int32_t sa = -7, sb = 123456789;
    volatile uint32_t ua = 0xFFFFFFFFu, ub = 0xFFFFFFFFu;
    check(sa * sb == -864197523);
    check((int64_t)sa * sb == -864197523LL);
    check((uint64_t)ua * ub == 0xFFFFFFFE00000001ULL);
    check((uint32_t)(((int64_t)sa * (uint64_t)ub) >> 32) == 0xFFFFFFF9u);
    volatile int32_t dx = -1000, dy = 7;
    volatile uint32_t ux = 0xFFFFFFFFu, uy = 10;
    check(dx / dy == -142 && dx % dy == -6);
    check(ux / uy == 429496729u && ux % uy == 5u);
    check((dx >> 3) == -125 && (ux >> 28) == 0xFu);
    group("muldiv", f);

    f = failures;   /* control flow: jump table, function pointers, recursion */
    static const int expect[9] = {11, 23, 37, 41, 53, 67, 71, 89, -1};
    for (int k = 0; k < 9; k++)
        check(dense_switch(k) == expect[k]);
    check(r_ops[0](5, 3) == 8 && r_ops[1](5, 3) == 2 && r_ops[2](5, 3) == 6);
    check(fib(15) == 610);
    group("control", f);

    f = failures;   /* struct copy and zeroing through memcpy/memset */
    struct pkt p1 = {0xCAFEF00Du, 0x1234, {1, 2, 3, 4, 5, 6}}, p2;
    volatile struct pkt *vp = &p2;
    p2 = p1;
    check(vp->a == 0xCAFEF00Du && vp->b == 0x1234 && vp->c[5] == 6);
    for (int i = 0; i < 6; i++) p1.c[i] = 0;
    check(p1.c[0] == 0 && p1.c[5] == 0);
    group("memory", f);

    f = failures;   /* Xicrc against published check values and a soft CRC */
    static const uint8_t cv[9] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    check(crc16_ccitt(0xFFFF, cv, 9) == 0x29B1);   /* CRC-16/CCITT-FALSE check */
    check(crc16_ccitt(0x0000, cv, 9) == 0x31C3);   /* CRC-16/XMODEM check */
    /* CRC-16/EPC-C1G2 (UHF RFID tags, ISO 18000-63): the same CRC, inverted */
    check((crc16_ccitt(0xFFFF, cv, 9) ^ 0xFFFFu) == 0xD64E);
    check(xicrc_h(0xFFFF, 0x3132) == crc16_soft(0xFFFF, cv, 2));
    check(xicrc_w(0xFFFF, 0x31323334) == crc16_soft(0xFFFF, cv, 4));
    uint32_t x = 0x2545F491u;
    for (int i = 0; i < 32; i++) {   /* xorshift32 pseudo-random data */
        uint8_t buf[4];
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        buf[0] = (uint8_t)(x >> 24); buf[1] = (uint8_t)(x >> 16);
        buf[2] = (uint8_t)(x >> 8);  buf[3] = (uint8_t)x;
        check(xicrc_w((uint16_t)i * 0x9E37u, x) == crc16_soft((uint16_t)(i * 0x9E37u), buf, 4));
    }
    group("xicrc", f);

    f = failures;   /* Chaskey-12 against the reference implementation's vectors:
                       key 00 11 .. ff, message = bytes 0 .. len-1, 8-byte tags */
    static const uint8_t ck_key[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                       0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
    static const struct { uint8_t len; uint8_t tag[8]; } ck_vec[6] = {
        { 0, {0xdd, 0x3e, 0x18, 0x49, 0xd6, 0x82, 0x45, 0x55}},
        {12, {0x7a, 0x79, 0x12, 0xc1, 0x99, 0x9e, 0xae, 0x81}},   /* the lane's block size */
        {15, {0x6a, 0x3e, 0xe3, 0xd3, 0x5c, 0x04, 0x33, 0x97}},
        {16, {0xd1, 0x39, 0x70, 0xd7, 0xbe, 0x9b, 0x23, 0x50}},   /* complete block: K1 */
        {17, {0x32, 0xac, 0xd9, 0x14, 0xbf, 0xda, 0x3b, 0xc8}},
        {63, {0xfc, 0x7f, 0x9d, 0xf7, 0x99, 0x1b, 0x87, 0xbc}},
    };
    uint32_t ck[4], ck1[4], ck2[4];
    uint8_t cm[64], ctag[8];
    for (int i = 0; i < 4; i++)
        ck[i] = ck_key[4 * i] | (uint32_t)ck_key[4 * i + 1] << 8 |
                (uint32_t)ck_key[4 * i + 2] << 16 | (uint32_t)ck_key[4 * i + 3] << 24;
    for (int i = 0; i < 64; i++)
        cm[i] = (uint8_t)i;
    chaskey12_subkeys(ck1, ck2, ck);
    for (int v = 0; v < 6; v++) {
        chaskey12_mac(ctag, 8, cm, ck_vec[v].len, ck, ck1, ck2);
        int same = 1;
        for (int i = 0; i < 8; i++)
            same &= ctag[i] == ck_vec[v].tag[i];
        check(same);
    }
    group("chaskey", f);

    f = failures;   /* GPIO: pins 7:4 outputs, pins 3:0 driven by the testbench */
    gpio_set_dir(0xF0);
    gpio_write(0x50);
    uint32_t in = gpio_read();
    check(in == 0x0A);                 /* testbench drives 1010; outputs read 0 */
    gpio_write(in << 4);               /* testbench then expects pins 7:4 = 1010 */
    group("gpio", f);

    uart_puts("READY\n");
    f = failures;   /* UART in: one byte, then a little-endian u32 */
    uint8_t c = uart_getc();
    check(c == 'r');
    uart_putc((uint8_t)(c - 'a' + 'A'));
    uint32_t w = uart_read_u32();
    check(w == 0x12345678u);
    uart_write_u32(w ^ 0xFFFFFFFFu);
    uart_putc('\n');
    group("uart", f);

    if (failures == 0) {
        uart_puts("SELFTEST PASS ");
        uart_put_dec(checks);
    } else {
        uart_puts("SELFTEST FAIL ");
        uart_put_dec(failures);
    }
    uart_putc('\n');
    return 0;
}
