/*
 * divmod.c - 32-bit division and remainder for the compiler.
 *
 * The core has no divider (RV32I + Zmmul: multiply only), so C's / and % are
 * compiled into calls to these four routines. They normally come from libgcc;
 * here they are part of the firmware, so the image links with -nostdlib and
 * no library, exactly as the organisers' Firmware Builder links it, and the
 * delivered assembly is the complete program.
 *
 * Restoring shift-and-subtract: one quotient bit per step, at most 32 steps.
 * Division by zero returns what the RISC-V M extension defines: quotient all
 * ones (-1), remainder the dividend.
 */
#include <stdint.h>

static uint32_t udivmod(uint32_t n, uint32_t d, uint32_t *rem)
{
    uint32_t q = 0, r = 0;
    if (d == 0) {
        *rem = n;
        return 0xFFFFFFFFu;
    }
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= 1u << i;
        }
    }
    *rem = r;
    return q;
}

uint32_t __udivsi3(uint32_t n, uint32_t d)
{
    uint32_t r;
    return udivmod(n, d, &r);
}

uint32_t __umodsi3(uint32_t n, uint32_t d)
{
    uint32_t r;
    udivmod(n, d, &r);
    return r;
}

/* Signed: divide the magnitudes; the quotient is negative when the signs
 * differ, the remainder takes the dividend's sign (C rounds toward zero). */
int32_t __divsi3(int32_t n, int32_t d)
{
    uint32_t r, q;
    if (d == 0)
        return -1;
    q = udivmod(n < 0 ? 0u - (uint32_t)n : (uint32_t)n, d < 0 ? 0u - (uint32_t)d : (uint32_t)d, &r);
    return ((n < 0) != (d < 0)) ? (int32_t)(0u - q) : (int32_t)q;
}

int32_t __modsi3(int32_t n, int32_t d)
{
    uint32_t r;
    if (d == 0)
        return n;
    udivmod(n < 0 ? 0u - (uint32_t)n : (uint32_t)n, d < 0 ? 0u - (uint32_t)d : (uint32_t)d, &r);
    return n < 0 ? (int32_t)(0u - r) : (int32_t)r;
}
