/* Confidencial - Propriedade do CPA Wernher von Braun */

ENTRY(_start);

DMEM_SIZE  = 256;
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