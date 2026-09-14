# tb_soc test program: a small loop (sum 1..5), JALR indirect call, a
# load-from-IMEM constant (critical §7.4 timing case: IMEM has no output
# register, so a load's oe_o/address must stay asserted through WriteBack),
# and FENCE/illegal no-ops that must not disturb architectural state.
    lui   x20, 0x10010       # x20 = DMEM base 0x10010000

    # ---- loop: sum = 1+2+3+4+5 = 15, using back-to-back dependent adds ----
    addi  x1, x0, 0           # x1 = sum accumulator
    addi  x2, x0, 1           # x2 = loop counter
    addi  x3, x0, 6           # x3 = loop bound (exclusive)
loop:
    add   x1, x1, x2          # sum += counter  (reads x1 the immediately-preceding instruction wrote)
    addi  x2, x2, 1           # counter++
    blt   x2, x3, loop        # loop while counter < 6
    sw    x1, 0(x20)          # DMEM[0] = 15 (store the loop result)

    # ---- FENCE / illegal must be pure no-ops (architectural state unchanged) ----
    addi  x4, x0, 0x55        # x4 = 0x55 (sentinel before the no-ops)
    fence
    .word 0xFFFFFFFF          # not a valid encoding of anything -> illegal no-op
    addi  x5, x4, 0            # x5 should still read x4 = 0x55 (no corruption occurred)

    # ---- JALR indirect call ----
    lui   x10, 0x00400        # x10 = 0x00400000 (IMEM base, used as a jump-table base)
    addi  x10, x10, callee    # x10 = address of `callee` (small positive offset, fits in imm12)
    jalr  x6, 0(x10)          # x6 = return address, jump to callee
    addi  x7, x0, 0xAA        # must be skipped by the call... no wait, callee returns HERE via jalr back
    j     after_call
callee:
    addi  x8, x0, 0x33         # proves the indirect jump landed correctly
    jalr  x0, 0(x6)            # return to caller (x0 discards the new link)
after_call:
    addi  x9, x0, 0x99         # proves control flow rejoined correctly after the call

    # ---- load-from-IMEM constant: critical §7.4 timing case ----
    auipc x11, 0                # x11 = address of THIS auipc instruction
    lw    x12, 12(x11)          # load the .word constant (auipc,lw,j = 12 bytes ahead)
    j     const_skip
    .word 0xCAFEBABE            # the constant being loaded (lands exactly 12 bytes after auipc)
const_skip:
    addi  x13, x0, 1            # reached only if control flow is still sane after the IMEM load

    ecall
