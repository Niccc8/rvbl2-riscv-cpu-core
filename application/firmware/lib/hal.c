/*
 * hal.c - RVBL-2 hardware abstraction layer, plus the four C-library memory
 * routines GCC may call implicitly (struct copies, zeroing) in a -nostdlib
 * build.
 */
#include "hal.h"

void uart_putc(uint8_t c)
{
    while (!(UART_CONTROL & UART_TXDONE))
        ;
    UART_TXDATA = c;
    /* TRANSMIT, and RXDONE written as 1 so a pending received byte survives. */
    UART_CONTROL = UART_TRANSMIT | UART_RXDONE;
}

int uart_try_getc(uint8_t *c)
{
    if (!(UART_CONTROL & UART_RXDONE))
        return 0;
    *c = (uint8_t)UART_RXDATA;
    UART_CONTROL = 0;           /* clear RXDONE; TRANSMIT = 0 does nothing */
    return 1;
}

uint8_t uart_getc(void)
{
    uint8_t c;
    while (!uart_try_getc(&c))
        ;
    return c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc((uint8_t)*s++);
}

void uart_put_hex32(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4)
        uart_putc("0123456789abcdef"[(v >> i) & 0xF]);
}

void uart_put_dec(uint32_t v)
{
    char buf[10];
    int n = 0;
    do {
        buf[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        uart_putc((uint8_t)buf[--n]);
}

void uart_write_u16(uint16_t v)
{
    uart_putc((uint8_t)v);
    uart_putc((uint8_t)(v >> 8));
}

void uart_write_u32(uint32_t v)
{
    for (int i = 0; i < 32; i += 8)
        uart_putc((uint8_t)(v >> i));
}

uint16_t uart_read_u16(void)
{
    uint16_t lo = uart_getc();
    return (uint16_t)(lo | ((uint16_t)uart_getc() << 8));
}

uint32_t uart_read_u32(void)
{
    uint32_t v = 0;
    for (int i = 0; i < 32; i += 8)
        v |= (uint32_t)uart_getc() << i;
    return v;
}

uint16_t crc16_ccitt(uint16_t seed, const uint8_t *buf, size_t len)
{
    uint32_t crc = seed;
    while (len--)
        crc = xicrc_b(crc, *buf++);
    return (uint16_t)crc;
}

/* ---- Chaskey-12 ---------------------------------------------------------
 * Follows the reference implementation (Nicky Mouha, chaskey12.c, CC0); the
 * selftest checks it against that code's test vectors on the RTL. */
#define ROTL(x, b) (((x) << (b)) | ((x) >> (32 - (b))))

void chaskey12_round(uint32_t v[4])
{
    v[0] += v[1]; v[1] = ROTL(v[1], 5);  v[1] ^= v[0]; v[0] = ROTL(v[0], 16);
    v[2] += v[3]; v[3] = ROTL(v[3], 8);  v[3] ^= v[2];
    v[0] += v[3]; v[3] = ROTL(v[3], 13); v[3] ^= v[0];
    v[2] += v[1]; v[1] = ROTL(v[1], 7);  v[1] ^= v[2]; v[2] = ROTL(v[2], 16);
}

static void times2(uint32_t out[4], const uint32_t in[4])
{
    out[0] = (in[0] << 1) ^ ((in[3] >> 31) ? 0x87u : 0u);
    out[1] = (in[1] << 1) | (in[0] >> 31);
    out[2] = (in[2] << 1) | (in[1] >> 31);
    out[3] = (in[3] << 1) | (in[2] >> 31);
}

void chaskey12_subkeys(uint32_t k1[4], uint32_t k2[4], const uint32_t k[4])
{
    times2(k1, k);
    times2(k2, k1);
}

static uint32_t le32(const uint8_t *p)
{
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

void chaskey12_mac(uint8_t *tag, uint32_t taglen, const uint8_t *m, uint32_t len,
                   const uint32_t k[4], const uint32_t k1[4], const uint32_t k2[4])
{
    uint32_t v[4] = {k[0], k[1], k[2], k[3]};
    uint32_t full = len ? (len - 1) >> 4 : 0;          /* blocks before the last */
    for (uint32_t b = 0; b < full; b++, m += 16) {
        for (int i = 0; i < 4; i++)
            v[i] ^= le32(m + 4 * i);
        for (int r = 0; r < 12; r++)
            chaskey12_round(v);
    }
    uint32_t rest = len - 16 * full;
    uint8_t lb[16];
    const uint32_t *l;
    for (uint32_t i = 0; i < 16; i++)
        lb[i] = i < rest ? m[i] : (i == rest ? 0x01 : 0);
    l = (len && rest == 16) ? k1 : k2;                /* complete last block: K1 */
    for (int i = 0; i < 4; i++)
        v[i] ^= le32(lb + 4 * i) ^ l[i];
    for (int r = 0; r < 12; r++)
        chaskey12_round(v);
    for (int i = 0; i < 4; i++)
        v[i] ^= l[i];
    for (uint32_t i = 0; i < taglen && i < 16; i++)
        tag[i] = (uint8_t)(v[i >> 2] >> (8 * (i & 3)));
}

/* ---- freestanding C library subset ------------------------------------ */

void *memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;
    if (d < s) {
        while (n--)
            *d++ = *s++;
    } else {
        while (n--)
            d[n] = s[n];
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    uint8_t *d = dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y)
            return *x - *y;
    return 0;
}
