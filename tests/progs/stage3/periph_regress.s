# periph_regress.s - Stage 3 peripheral register semantics, exercised by the
# core itself through real loads and stores (spec §10.2, S5).
#
# Self-checking: every check stores (actual XOR expected) to the next DMEM word
# from 0x10010000, so a pass is 0. After the last check the program writes
# DONE_MARK to the next word and parks in a self-loop. The testbench requires
# every word before the marker to be 0 and the marker to be at word NUM_CHECKS.
#
# Test harness assumptions (tb_periph_soc.v):
#   * GPIO pins 7:4 are driven by the testbench with 0b1010; pins 3:0 are
#     outputs here, and nothing else drives them.
#   * tx_o is looped back to rx_i.
#
# Check pattern, four instructions:  li t4, EXPECTED / xor t3, t5, t4 /
#                                    sw t3, 0(s2) / addi s2, s2, 4

.equ GPIO_BASE,   0xF0000000
.equ UART_BASE,   0xF1000000
.equ SIG_BASE,    0x10010000
.equ DONE_MARK,   0x600DC0DE

.equ TRANSMIT,    0x1
.equ RXDONE,      0x2
.equ TXDONE,      0x4

_start:
    la   s0, GPIO_BASE
    la   s1, UART_BASE
    la   s2, SIG_BASE

    # ---------------- GPIO ----------------------------------------------------
    # 1  DATAOUT resets to 0
    lw   t5, 0(s0)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 2  DATADIR resets to 0 (all inputs)
    lw   t5, 8(s0)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 3  DATAOUT read-back; reserved bits read 0
    li   t0, -1
    sw   t0, 0(s0)
    lw   t5, 0(s0)
    li   t4, 0xFF
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 4  DATADIR = 0x0F: pins 3:0 outputs, 7:4 inputs
    li   t0, 0x0F
    sw   t0, 8(s0)
    lw   t5, 8(s0)
    li   t4, 0x0F
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 5  DATAIN: inputs 7:4 = 1010 from the testbench, outputs read 0
    lw   t5, 4(s0)
    li   t4, 0xA0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 6  DATAIN is read-only: a store to it changes nothing
    sw   t0, 4(s0)
    lw   t5, 8(s0)
    li   t4, 0x0F
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 7  offset 0xC reads 0 and ignores writes
    sw   t0, 12(s0)
    lw   t5, 12(s0)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 8  sb to DATAOUT+1 (byte lane 1) changes nothing
    li   t0, 0x5A
    sb   t0, 1(s0)
    lw   t5, 0(s0)
    li   t4, 0xFF
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 9  sb to DATAOUT+0 (lane 0) writes
    sb   t0, 0(s0)
    lw   t5, 0(s0)
    li   t4, 0x5A
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 10 misaligned sw (the LSU gives bw = 0000) writes nothing
    li   t0, 0x33
    sw   t0, 2(s0)
    lw   t5, 0(s0)
    li   t4, 0x5A
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 11 no aliasing: 0xF0000010 is not a register (write ignored, reads 0)
    li   t1, 0xF0000010
    sw   t0, 0(t1)
    lw   t5, 0(t1)
    lw   t6, 0(s0)
    xor  t5, t5, t6          # 0 ^ 0x5A if nothing aliased
    li   t4, 0x5A
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 12 an empty slot reads 0
    li   t1, 0xF2000000
    lw   t5, 0(t1)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4

    # ---------------- UART (tx_o looped back to rx_i) --------------------------
    # 13 CONTROL resets to TXDONE only
    lw   t5, 8(s1)
    li   t4, TXDONE
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 14 TXDATA read-back
    li   t0, 0x55
    sw   t0, 0(s1)
    lw   t5, 0(s1)
    li   t4, 0x55
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 15 TRANSMIT: reads back 0, TXDONE clears as the frame starts
    li   t0, TRANSMIT
    sw   t0, 8(s1)
    lw   t5, 8(s1)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
wait_tx1:
    lw   t0, 8(s1)
    andi t0, t0, TXDONE
    beq  t0, zero, wait_tx1
    # 16 the looped-back byte arrived
    lw   t5, 4(s1)
    li   t4, 0x55
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 17 writing 1 to RXDONE has no effect (TRANSMIT 0 in the same word)
    li   t0, RXDONE
    sw   t0, 8(s1)
    lw   t5, 8(s1)
    li   t4, 0x6
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 18 writing 0x3 starts a frame and keeps RXDONE
    li   t0, 0xA3
    sw   t0, 0(s1)
    li   t0, 0x3
    sw   t0, 8(s1)
    lw   t5, 8(s1)
    li   t4, RXDONE
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
wait_tx2:
    lw   t0, 8(s1)
    andi t0, t0, TXDONE
    beq  t0, zero, wait_tx2
    # 19 overrun: RXDONE was still set, the new byte overwrote RXDATA
    lw   t5, 4(s1)
    li   t4, 0xA3
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 20 sb zero to CONTROL+1 (lane 1) does not clear RXDONE
    sb   zero, 9(s1)
    lw   t5, 8(s1)
    li   t4, 0x6
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 21 sb zero to CONTROL (lane 0) clears it
    sb   zero, 8(s1)
    lw   t5, 8(s1)
    li   t4, TXDONE
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 22 a misaligned sw to CONTROL (bw = 0000) cannot start a frame
    li   t0, TRANSMIT
    sw   t0, 10(s1)
    lw   t5, 8(s1)
    li   t4, TXDONE
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 23 RXDATA is read-only
    sw   t0, 4(s1)
    lw   t5, 4(s1)
    li   t4, 0xA3
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4
    # 24 offset 0xC reads 0
    lw   t5, 12(s1)
    li   t4, 0
    xor  t3, t5, t4
    sw   t3, 0(s2)
    addi s2, s2, 4

    # ---------------- Done ----------------------------------------------------
    li   t0, DONE_MARK
    sw   t0, 0(s2)
done:
    j    done
