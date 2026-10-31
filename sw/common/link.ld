OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > RAM

  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM

  .data : { *(.data .data.* .sdata .sdata.*) } > RAM

  .bss (NOLOAD) : {
    . = ALIGN(4);
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM

  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
