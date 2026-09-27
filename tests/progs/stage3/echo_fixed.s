# UART "echo" example, Stage 3 Block Guide §2.3.3, COMPLETED so it really
# echoes: two added instructions set TRANSMIT after TXDATA is written, as
# §2.2.1 requires. Everything else is the listing verbatim.

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
    li t0, UART_CONTROL_TRANSMIT          # added
    sw t0, UART_CONTROL(s0)               # added: start the frame

    j _check_rxdone
