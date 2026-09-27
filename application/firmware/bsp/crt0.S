/*
 * crt0.S - start-up code. The core starts at 0x00400000 after reset, which is
 * where the linker script puts the .start section.
 *
 *   1. set the stack pointer to the top of DMEM (the stack grows down);
 *   2. copy .data's initial values from IMEM (where they are stored) to DMEM;
 *   3. clear .bss;
 *   4. call main(); main() never returns (if it does: ECALL, then stop).
 *
 * The symbols (_estack, _sidata, _sdata, _edata, _sbss, _ebss) are the ones
 * the organisers' linker script defines. The core has no interrupts or
 * traps, so there is no vector table. gp is not used: the C code is compiled
 * with -msmall-data-limit=0 -mno-relax, so it has no gp-relative accesses.
 */
    .section .start, "ax"
    .globl _start
_start:
    la      sp, _estack

    la      t0, _sidata             /* .data: copy IMEM -> DMEM */
    la      t1, _sdata
    la      t2, _edata
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b
2:
    la      t1, _sbss               /* .bss: clear */
    la      t2, _ebss
3:  bgeu    t1, t2, 4f
    sw      zero, 0(t1)
    addi    t1, t1, 4
    j       3b
4:
    call    main
    ecall
5:  j       5b
