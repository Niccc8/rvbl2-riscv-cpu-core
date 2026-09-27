# GPIO example, Stage 3 Block Guide §1.3.2, transcribed LITERALLY.
#
# Note: its comment says "copy P0 to P1", but it stores the DATAIN word into
# DATAOUT bit for bit, so P1 receives DATAIN[1] - which reads 0 because P1 is an
# output (spec §5.3). Expected behaviour: DATADIR = 0x02 and P1 stays low
# whatever P0 does. gpio_fixed.s adds the missing shift.

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

    /* Write to P1 */
    sw t0, GPIO_DATAOUT(s0)

    j _loop
