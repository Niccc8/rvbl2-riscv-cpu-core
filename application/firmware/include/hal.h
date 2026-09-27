/*
 * hal.h - a small hardware abstraction layer for RVBL-2 firmware: blocking
 * UART byte and word I/O, GPIO helpers and CRC-16 over a buffer.
 *
 * Multi-byte values travel little-endian (least significant byte first).
 * [ASSUMPTION - confirm] that this is the order the organisers' emulator uses
 * for -t2/-t4/-r2/-r4: read emu.c on the F2 instance.
 */
#ifndef HAL_H
#define HAL_H

#include <stdint.h>
#include <stddef.h>
#include "rvbl2.h"

void     uart_putc(uint8_t c);
uint8_t  uart_getc(void);             /* blocks until a byte arrives */
int      uart_try_getc(uint8_t *c);   /* 1 and *c if a byte was pending, else 0 */
void     uart_puts(const char *s);
void     uart_put_hex32(uint32_t v);
void     uart_put_dec(uint32_t v);
void     uart_write_u16(uint16_t v);
void     uart_write_u32(uint32_t v);
uint16_t uart_read_u16(void);
uint32_t uart_read_u32(void);

static inline void     gpio_set_dir(uint32_t out_mask) { GPIO_DATADIR = out_mask; }
static inline void     gpio_write(uint32_t v)          { GPIO_DATAOUT = v; }
static inline uint32_t gpio_read(void)                 { return GPIO_DATAIN; }

/* CRC-16/CCITT-FALSE over a buffer, using the Xicrc instructions. */
uint16_t crc16_ccitt(uint16_t seed, const uint8_t *buf, size_t len);

/* Chaskey-12 MAC (Mouha 2015; ISO/IEC 29192-6:2019), little-endian words.
 * chaskey12_subkeys derives K1 = 2K and K2 = 4K in GF(2^128);
 * chaskey12_round is one round of the permutation (the MAC runs twelve);
 * chaskey12_mac writes the first taglen (<= 16) bytes of the tag of m. */
void chaskey12_subkeys(uint32_t k1[4], uint32_t k2[4], const uint32_t k[4]);
void chaskey12_round(uint32_t v[4]);
void chaskey12_mac(uint8_t *tag, uint32_t taglen, const uint8_t *m, uint32_t len,
                   const uint32_t k[4], const uint32_t k1[4], const uint32_t k2[4]);

#endif /* HAL_H */
