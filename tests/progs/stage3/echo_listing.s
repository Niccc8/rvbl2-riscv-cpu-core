# UART "echo" example, Stage 3 Block Guide §2.3.3, transcribed LITERALLY.
#
# Note: it never sets TRANSMIT (UART_CONTROL_TRANSMIT is defined but unused),
# and §2.2.1 says TXDATA is "only sent upon setting the TRANSMIT bit". Expected
# behaviour: every byte is received and copied into TXDATA, and nothing is
# transmitted - tx_o stays high. echo_fixed.s adds the TRANSMIT write.

.equ UART_BASE,               0xF1000000
.equ UART_TXDATA,             0x0000
.equ UART_RXDATA,             0x0004
.equ UART_CONTROL,            0x0008

.equ UART_CONTROL_TRANSMIT,   0x01
.equ UART_CONTROL_RXDONE,     0x02
.equ UART_CONTROL_TXDONE,     0x04

_start:
    la s0, UART_BASE

_check_rxdone:
    lw t0, UART_CONTROL(s0)
    andi t0, t0, UART_CONTROL_RXDONE
    beq t0, zero, _check_rxdone
    sw zero, UART_CONTROL(s0)

    /* Receive data */
    lw t1, UART_RXDATA(s0)

_check_txdone:
    lw t0, UART_CONTROL(s0)
    andi t0, t0, UART_CONTROL_TXDONE
    beq t0, zero, _check_txdone

    /* Send data */
    sw t1, UART_TXDATA(s0)

    j _check_rxdone
