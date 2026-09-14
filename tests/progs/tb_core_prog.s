# tb_core integration test program - exercises one representative
# instruction from each major class. DMEM base 0x10010000 is built with a
# single LUI (its low 12 bits are already zero, so LUI alone suffices).
    lui   x20, 0x10010      # x20 = 0x10010000 (DMEM base pointer)

    addi  x1, x0, 5         # x1 = 5
    addi  x2, x0, 10        # x2 = 10
    add   x3, x1, x2        # x3 = 15
    sub   x4, x2, x1        # x4 = 5
    and   x5, x1, x2        # x5 = 0
    or    x6, x1, x2        # x6 = 15
    xor   x7, x1, x2        # x7 = 15
    slli  x8, x1, 2         # x8 = 20
    srli  x9, x2, 1         # x9 = 5
    slt   x10, x1, x2       # x10 = 1
    sltu  x11, x1, x2       # x11 = 1
    addi  x12, x0, -1       # x12 = 0xFFFFFFFF
    sra   x13, x12, x1      # x13 = 0xFFFFFFFF (arith shift of -1 is still -1)
    lui   x14, 0x12345      # x14 = 0x12345000
    mul   x16, x1, x2       # x16 = 50
    mulh  x17, x1, x2       # x17 = 0
    crcb  x18, x1, x0       # x18 = CRC16-CCITT-FALSE(seed=0, byte=5)
                            # rs1 = data, rs2 = running CRC - the operand order
                            # the official validation firmware uses.

    sw    x3, 0(x20)        # DMEM[0x10010000] = 15
    lw    x21, 0(x20)       # x21 = 15 (load back)
    sb    x1, 4(x20)        # DMEM byte @0x10010004 = 5
    lbu   x22, 4(x20)       # x22 = 5 (zero-extended)

    addi  x23, x0, 0        # x23 = 0 (branch-not-taken marker)
    beq   x1, x2, skip1     # not taken (5 != 10)
    addi  x23, x0, 1        # x23 = 1 (executed, branch not taken)
skip1:
    addi  x24, x0, 0
    beq   x1, x1, skip2     # taken (5 == 5)
    addi  x24, x0, 99       # skipped
skip2:
    addi  x24, x24, 2       # x24 = 2 (only reached if branch was taken correctly)

    jal   x25, jtarget       # x25 = return addr (link), jump to jtarget
    addi  x26, x0, 77        # must be SKIPPED by the jump
jtarget:
    addi  x27, x0, 42        # x27 = 42, proves jump landed correctly

    auipc x28, 0             # x28 = address of this instruction

    ecall                    # completion marker (sys_event_o pulse)
