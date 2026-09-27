/* custom.ld - memory layout of the lane-controller firmware.
 *
 * This is the organisers' Firmware Builder linker script
 * (tools/rvbl-firmware-builder/bsp/custom.ld) with three additions, each
 * marked "RVBL-2:" below:
 *   1. DMEM_SIZE is our chip's 8 kB of data memory (the builder's default is
 *      256 bytes; the firmware's tables need about 3 kB).
 *   2. A .noinit section for big tables that start-up does not clear (each
 *      table has a small counter in .bss that says which entries are valid).
 *      Clearing 2.5 kB would keep the core away from its one-byte UART
 *      receiver for thousands of cycles after reset.
 *   3. __rom_end: the end of the ROM image (code, constants and .data's
 *      initial values). The firmware's 'I' command measures its own ROM up
 *      to here.
 * Everything else - addresses, section order, symbol names - is unchanged.
 */

ENTRY(_start);

DMEM_SIZE  = 8192;              /* RVBL-2: the chip's DMEM (builder default: 256) */
STACK_SIZE = DEFINED(__stack_size__) ? __stack_size__ : DMEM_SIZE / 2;

MEMORY
{
    FLASH (rx) : ORIGIN = 0x00400000, LENGTH = 16M
    SRAM (rwx) : ORIGIN = 0x10010000, LENGTH = DMEM_SIZE
}

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        *(.start)
        *(.text)
        *(.text*)
        *(.rodata)
        *(.rodata*)
    } > FLASH

    .data : ALIGN(4)
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data)
        *(.data*)

        *(.sdata)
        *(.sdata*)
        . = ALIGN(4);
        _edata = .;
    } > SRAM AT > FLASH

    _sidata = LOADADDR(.data);
    __rom_end = _sidata + SIZEOF(.data);    /* RVBL-2: end of the ROM image */

    .bss :
    {
        . = ALIGN(4);
        _sbss = .;
        __bss_start__ = _sbss;
        *(.bss)
        *(.bss*)
        *(.sbss)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
        __bss_end__ = _ebss;
    } > SRAM

    /* RVBL-2: tables that start-up does not clear */
    .noinit (NOLOAD) :
    {
        . = ALIGN(4);
        *(.noinit)
        *(.noinit*)
        . = ALIGN(4);
    } > SRAM

  . = ALIGN(16);
  _stack_top   = ORIGIN(SRAM) + LENGTH(SRAM);
  _stack_limit = _stack_top - STACK_SIZE;

  .stack _stack_limit :
  {
    . = ALIGN(8);
    _stack_base = .;
    . += STACK_SIZE;
  } > SRAM

  PROVIDE(_estack = _stack_top);
}
