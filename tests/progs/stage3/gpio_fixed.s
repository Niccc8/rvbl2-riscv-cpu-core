# GPIO example, Stage 3 Block Guide §1.3.2, COMPLETED so it does what its
# comments say: one added instruction (slli) moves P0's level to bit 1, so P1
# follows P0. Everything else is the listing verbatim.

.equ GPIO_BASE,       0xF0000000
.equ GPIO_DATAOUT,    0x0000
.equ GPIO_DATAIN,     0x0004
.equ GPIO_DATADIR,    0x0008

_start:
    la s0, GPIO_BASE

    /* Set P0 as input and P1 as output */
    lw t0, GPIO_DATADIR(s0)
    ori t0, t0, 0x2
    sw t0, GPIO_DATADIR(s0)

_loop:
    /* Read P0 */
    lw t0, GPIO_DATAIN(s0)
    slli t0, t0, 1                    # added: P0 (bit 0) -> P1 (bit 1)

    /* Write to P1 */
    sw t0, GPIO_DATAOUT(s0)

    j _loop
