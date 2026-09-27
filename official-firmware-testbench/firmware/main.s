.equ GPIO_BASE,             0xF0000000
.equ GPIO_DATAOUT,          0x0000
.equ GPIO_DATAIN,           0x0004
.equ GPIO_DATADIR,          0x0008

.equ UART_BASE,             0xF1000000
.equ UART_TXDATA,           0x0000
.equ UART_RXDATA,           0x0004
.equ UART_CONTROL,          0x0008

.equ UART_CONTROL_TRANSMIT, 0x01
.equ UART_CONTROL_RXDONE,   0x02
.equ UART_CONTROL_TXDONE,   0x04

_start:
    la s0, GPIO_BASE
    la s1, UART_BASE

    /* Set P7-4 as output and P3-0 as input */
    lw t0, GPIO_DATADIR(s0)
    ori t0, t0, 0xF0
    sw t0, GPIO_DATADIR(s0)
    
_loop:
    /* Read P3-0 */
    lw t0, GPIO_DATAIN(s0)

    /* Move P3-0 value to P7-4 */
    slli t0, t0, 4

    /* Write to P7-4 */
    sw t0, GPIO_DATAOUT(s0)

_check_rxdone:
    lw t0, UART_CONTROL(s1)
    andi t0, t0, UART_CONTROL_RXDONE
    beq t0, zero, _check_rxdone

    /* Clear flag */
    sw zero, UART_CONTROL(s1)

    /* Receive data */
    lw t1, UART_RXDATA(s1)

_check_txdone:
    lw t0, UART_CONTROL(s1)
    andi t0, t0, UART_CONTROL_TXDONE
    beq t0, zero, _check_txdone

    /* Data to send */
    sw t1, UART_TXDATA(s1)

    # Send data
    lw t1, UART_CONTROL(s1)
    ori t1, t1, UART_CONTROL_TRANSMIT
    sw t1, UART_CONTROL(s1)

    j _loop
