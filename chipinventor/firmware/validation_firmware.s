# Confidencial - Propriedade do CPA Wernher von Braun

.macro crcb rd, rs1, rs2
    .insn r 0x33, 0, 0x40, \rd, \rs1, \rs2
.endm

.macro crch rd, rs1, rs2
    .insn r 0x33, 1, 0x40, \rd, \rs1, \rs2
.endm

.macro crcw rd, rs1, rs2
    .insn r 0x33, 2, 0x40, \rd, \rs1, \rs2
.endm

.section .text
.globl _start
_start:

_rv32i_alu_test:

    /* LUId and AUIPC */
    lui t0, 0x12345         /* t0 = 0x12345000 */
    li t1, 0x12345000
    bne t0, t1, _error

    auipc t0, 0x1           /* t0 = PC + 0x1000 */
    beq t0, zero, _error

    /* Arithmetic (ADDI, ADD, SUB) */
    addi t0, zero, 10
    addi t1, t0, -3
    li t2, 7
    bne t1, t2, _error      /* 10 - 3 = 7 */

    add t2, t0, t1          /* 10 + 7 = 17 */
    li t3, 17
    bne t2, t3, _error

    sub t2, t3, t0          /* 17 - 10 = 7 */
    bne t2, t1, _error

    /* Logic (XORI, ORI, ANDI, XOR, OR, AND) */
    li t0, 0x00FF
    xori t1, t0, 0x0F0
    li t2, 0x000F
    bne t1, t2, _error      /* 0x00FF ^ 0x0F0 = 0x000F */

    ori t1, t0, 0x700
    li t2, 0x07FF
    bne t1, t2, _error

    andi t1, t0, 0x0F0
    li t2, 0x00F0
    bne t1, t2, _error

    li t0, 0xAA
    li t1, 0x55
    xor t2, t0, t1          /* 0xAA ^ 0x55 = 0xFF */
    li t3, 0xFF
    bne t2, t3, _error

    or t2, t0, t1           /* 0xAA | 0x55 = 0xFF */
    bne t2, t3, _error

    and t2, t0, t1          /* 0xAA & 0x55 = 0x00 */
    bne t2, zero, _error

    /* Shifts (SLLI, SRLI, SRAI, SLL, SRL, SRA) */
    li t0, 1
    slli t1, t0, 4          /* 1 << 4 = 16 */
    li t2, 16
    bne t1, t2, _error

    srli t1, t2, 2          /* 16 >> 2 = 4 */
    li t3, 4
    bne t1, t3, _error

    li t0, -16              /* 0xFFFFFFF0 */
    srai t1, t0, 2          /* 0xFFFFFFFC (-4) */
    li t2, -4
    bne t1, t2, _error

    /* Test register versions (SLL, SRL, SRA) */
    li t0, 1
    li t1, 4
    sll t2, t0, t1          /* 1 << 4 = 16 */
    li t3, 16
    bne t2, t3, _error

    li t1, 2
    srl t2, t3, t1          /* 16 >> 2 = 4 */
    li t4, 4
    bne t2, t4, _error

    li t0, -16
    sra t2, t0, t1          /* -16 >> 2 = -4 */
    li t4, -4
    bne t2, t4, _error

    /* Comparisons (SLTI, SLTIU, SLT, SLTU) */
    li t0, 10
    slti t1, t0, 20         /* 10 < 20 ? 1 : 0 */
    li t2, 1
    bne t1, t2, _error

    li t0, -10
    sltiu t1, t0, 20        /* -10 (0xFFFFFFF6) < 20 ? unsigned */
    bne t1, zero, _error    

    li t0, 10
    li t1, 20
    slt t2, t0, t1          /* 10 < 20 */
    li t3, 1
    bne t2, t3, _error

    sltu t2, t1, t0         /* 20 < 10 unsigned */
    bne t2, zero, _error

_rv32i_lsu_test:
    la s0, test_ram
    
    /* Store Words, Halfwords, Bytes (SW, SH, SB) */
    li t1, 0x12345678
    sw t1, 0(s0)            /* Grava 0x12345678 */
    
    li t2, 0xAABB
    sh t2, 4(s0)            /* Grava 0xAABB (com sinal estendido depois) */
    
    li t3, 0xCC
    sb t3, 8(s0)            /* Grava 0xCC (com sinal estendido depois) */

    /* Load Words, Halfwords, Bytes (LW, LH, LHU, LB, LBU) */
    lw t4, 0(s0)
    bne t4, t1, _error      /* Verifica LW = 0x12345678 */

    lh t5, 4(s0)            /* Sign-extended: 0xFFFFAABB */
    li t6, 0xFFFFAABB
    bne t5, t6, _error

    lhu t5, 4(s0)           /* Zero-extended: 0x0000AABB */
    li t6, 0x0000AABB
    bne t5, t6, _error

    lb t5, 8(s0)            /* Sign-extended: 0xFFFFFFCC */
    li t6, 0xFFFFFFCC
    bne t5, t6, _error

    lbu t5, 8(s0)           /* Zero-extended: 0x000000CC */
    li t6, 0x000000CC
    bne t5, t6, _error    

_rv32i_ctrl_test:
    li t0, 5
    li t1, 10
    li t2, 5
    li t3, -10              /* 0xFFFFFFF6 */
    li t4, -10

    /* Equals */
    beq t0, t2, 1f          /* 5 == 5 */
    j _error
1:  
    beq t3, t4, 1f          /* -10 == -10 */
    j _error
1:
    bne t0, t1, 1f          /* 5 != 10 */
    j _error
1:  
    bne t0, t3, 1f          /* 5 != -10 */
    j _error
1:

    /* Signed */
    blt t0, t1, 1f          /* 5 < 10 */
    j _error
1:  
    blt t3, t0, 1f          /* -10 < 5 */
    j _error
1:
    bge t1, t0, 1f          /* 10 >= 5 */
    j _error
1:
    bge t0, t3, 1f          /* 5 >= -10 */
    j _error
1:

    /* Unsigned */
    
    bltu t0, t1, 1f         /* 5 < 10 (unsigned) */
    j _error
1:
    bltu t0, t3, 1f         /* 5 < 0xFFFFFFF6 (unsigned) */
    j _error
1:
    bgeu t1, t0, 1f         /* 10 >= 5 (unsigned) */
    j _error
1:
    bgeu t3, t0, 1f         /* 0xFFFFFFF6 >= 5 (unsigned) */
    j _error
1:

    /* --- Jumps (JAL e JALR) --- */
    jal t5, 2f           
    j _error               
2:
    la t6, 3f               
    jalr zero, t6, 0        
    j _error                
3:

_rv32i_reg_test:
    addi zero, zero, 1
    bne zero, zero, _error

    li x5, 0xDEADBEEF
    addi x6, x5, 0
    addi x7, x6, 0
    addi x31, x7, 0
    
    li t0, 0xDEADBEEF
    bne x31, t0, _error

_rvbl2_mult_test:
    /* Test parameters */
    li a1, 100000
    li a2, 2
    li a3, 4000000000 /* ou -294.967.296 */

    /* Expected results */
    li t0, 200000          /* Result of 100.000 x 2                 */
    li t1, -589934592      /* 0xDCD65000 (8.000.000.000)(31:0)      */
    li t2, -1              /* 0xFFFFFFFF (<negative number>)(63:32) */
    li t3, 1               /* 0x00000001 (8.000.000.000)(63:32)     */

    /* --------------------------------------------------------- */
    /* 1. MUL: Lower part of 32-bit multiply result              */
    /* --------------------------------------------------------- */
    
    /* 100.000 x 2 = 200.000 */
    mul a0, a1, a2
    bne a0, t0, _error

    /* 4.000.000.000 x 2 = 8.000.000.000 (0x00000001_DCD65000) */
    mul a0, a3, a2
    bne a0, t1, _error

    /* --------------------------------------------------------- */
    /* 2. MULH: Higher part of 32-bit multiply result            */
    /* --------------------------------------------------------- */

    /* 100.000 x 2 = 200.000 (fits in 32 bits, so 0) */
    mulh a0, a1, a2
    bne a0, zero, _error

    /* -294.967.296 x 2 = -589.934.592 (0xFFFFFFFF_DCD65000) */
    mulh a0, a3, a2
    bne a0, t2, _error

    /* --------------------------------------------------------- */
    /* 3. MULHU: Higher part of 32-bit unsigned multiply result  */
    /* --------------------------------------------------------- */

    /* 4.000.000.000 x 2 = 8.000.000.000 (0x00000001_DCD65000) */
    mulhu a0, a3, a2
    bne a0, t3, _error
    
    /* --------------------------------------------------------- */
    /* 4. MULHSU: Higher part of 32-bit sig/uns multiply result  */
    /* --------------------------------------------------------- */

    /* -294.967.296 x 2 = -589.934.592 (0xFFFFFFFF_DCD65000). */
    mulhsu a0, a3, a2
    bne a0, t2, _error

    /* 2 x 4.000.000.000 = 8.000.000.000 (0x00000001_DCD65000). */
    mulhsu a0, a2, a3
    bne a0, t3, _error

_rvbl2_crc_test:
    /* Expected result */
    li a7, 0x1E82

    /* CRC16 (8 bits) */
    li s0, 0xFFFF
    li s1, 0x12
    li s2, 0x34
    li s3, 0x56
    li s4, 0x78
    li s5, 0x90
    li s6, 0xAB
    li s7, 0xCD
    li s8, 0xEF
    crcb s0, s1, s0
    crcb s0, s2, s0
    crcb s0, s3, s0
    crcb s0, s4, s0
    crcb s0, s5, s0
    crcb s0, s6, s0
    crcb s0, s7, s0
    crcb s0, s8, s0

    /* If not equal, go to error handler */
    bne s0, a7, _error

    /* CRC16 (16 bits) */
    li t0, 0xFFFF
    li t1, 0x1234
    li t2, 0x5678
    li t3, 0x90AB
    li t4, 0xCDEF
    crch t0, t1, t0
    crch t0, t2, t0
    crch t0, t3, t0
    crch t0, t4, t0

    /* If not equal, go to error handler */
    bne t0, a7, _error

    /* CRC16 (32 bits) */
    li a0, 0xFFFF
    li a1, 0x12345678
    li a2, 0x90ABCDEF
    crcw a0, a1, a0
    crcw a0, a2, a0

    /* If not equal, go to error handler */
    bne a0, a7, _error

_rvbl2_crc_mem_test:
    /* Load from memory and calculate CRC */
    la t0, crc_data         /* Base address (0x12345678, 0x90ABCDEF) */
    lw t1, 0(t0)            /* t1 = 0x12345678 */
    lw t2, 4(t0)            /* t2 = 0x90ABCDEF */

    li a0, 0xFFFF
    crcw a0, t1, a0
    crcw a0, t2, a0

    li a7, 0x1E82 
    bne a0, a7, _error

_rvbl2_arith_integ_test:
    /* Calculate (A + B) * (A - B) */
    li t0, 20               /* A = 20 */
    li t1, 10               /* B = 10 */
    
    add t2, t0, t1          /* t2 = A + B = 30 */
    sub t3, t0, t1          /* t3 = A - B = 10 */
    
    mul t4, t2, t3          /* t4 = 30 * 10 = 300 */
    
    li t5, 300
    bne t4, t5, _error


_rvbl2_mem_transfer_test:
    /* Copy data from .data to .bss */
    la t0, source_data
    la t1, dest_data
    li t2, 3                /* Counter (3 words) */

copy_loop:
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -1
    bnez t2, copy_loop

    /* Check copied data */
    la t1, dest_data
    lw t3, 0(t1)
    li t4, 0x11111111
    bne t3, t4, _error
    
    lw t3, 8(t1)
    li t4, 0x33333333
    bne t3, t4, _error

all_good:
    li x4, 0x00000000
    j .

_error:
    li x4, 0xFFFFFFFF
    j .


.section .rodata
.align 2
crc_data: .word 0x12345678, 0x90ABCDEF
source_data: .word 0x11111111, 0x22222222, 0x33333333

.section .bss
.align 2
test_ram: .space 16
dest_data: .space 12
