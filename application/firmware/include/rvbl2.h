/*
 * rvbl2.h - the RVBL-2 memory map, peripheral registers and Xicrc intrinsics
 * for C firmware built with GCC (-march=rv32i_zmmul -mabi=ilp32).
 *
 * Memory map (docs/ARCH_SPEC.md §5.1, docs/GPIO_UART_INTEGRATION.md):
 *   IMEM   0x00400000  code, constants and .data initial values (read only)
 *   DMEM   0x10010000  8 kB: .data, .bss, stack
 *   GPIO   0xF0000000  slot 0
 *   UART   0xF1000000  slot 1
 *
 * Every peripheral field lives in byte lane 0, so byte, halfword and word
 * accesses all work; the helpers below use word accesses throughout.
 */
#ifndef RVBL2_H
#define RVBL2_H

#include <stdint.h>

#define RVBL2_IMEM_BASE 0x00400000u
#define RVBL2_DMEM_BASE 0x10010000u
#define RVBL2_DMEM_SIZE 0x00002000u

#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

/* GPIO "PIN Controller" (8 pins). DATADIR bit n: 0 = input, 1 = output.
 * DATAIN reads 0 for a pin configured as output (spec §5.3). */
#define GPIO_BASE    0xF0000000u
#define GPIO_DATAOUT REG32(GPIO_BASE + 0x0)
#define GPIO_DATAIN  REG32(GPIO_BASE + 0x4)
#define GPIO_DATADIR REG32(GPIO_BASE + 0x8)

/* UART "Serial Controller", 8-N-1. A frame is sent only when TRANSMIT is
 * written. RXDONE is write-0-to-clear: writing CONTROL with bit 1 = 0 clears
 * a pending received byte, so a transmit must write TRANSMIT | RXDONE. */
#define UART_BASE    0xF1000000u
#define UART_TXDATA  REG32(UART_BASE + 0x0)
#define UART_RXDATA  REG32(UART_BASE + 0x4)
#define UART_CONTROL REG32(UART_BASE + 0x8)
#define UART_TRANSMIT 0x1u
#define UART_RXDONE   0x2u
#define UART_TXDONE   0x4u

/* Xicrc: CRC-16/CCITT-FALSE (poly 0x1021, MSB first, no reflection, no final
 * XOR) folded over 8, 16 or 32 data bits in one instruction. rs1 = data,
 * rs2 = running CRC. Encoding: opcode 0x33, funct7 0x40, funct3 0/1/2. With
 * seed 0xFFFF this is the CCSDS frame check (CRC-16/IBM-3740); with seed 0 it
 * is CRC-16/XMODEM. */
static inline uint32_t xicrc_b(uint32_t crc, uint32_t data)
{
    uint32_t r;
    __asm__ volatile (".insn r 0x33, 0, 0x40, %0, %1, %2" : "=r"(r) : "r"(data), "r"(crc));
    return r;
}
static inline uint32_t xicrc_h(uint32_t crc, uint32_t data)
{
    uint32_t r;
    __asm__ volatile (".insn r 0x33, 1, 0x40, %0, %1, %2" : "=r"(r) : "r"(data), "r"(crc));
    return r;
}
static inline uint32_t xicrc_w(uint32_t crc, uint32_t data)
{
    uint32_t r;
    __asm__ volatile (".insn r 0x33, 2, 0x40, %0, %1, %2" : "=r"(r) : "r"(data), "r"(crc));
    return r;
}

/* ECALL pulses the core's sys_event_o for one cycle and continues (it is not
 * a trap: the core has no CSRs). Testbenches use it as an end-of-test mark. */
static inline void rvbl2_event(void) { __asm__ volatile ("ecall"); }

#endif /* RVBL2_H */
