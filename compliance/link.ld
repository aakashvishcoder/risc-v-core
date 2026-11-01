OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4M }
SECTIONS
{
  .text.init : { *(.text.init) } > RAM
  .text      : { *(.text .text.*) } > RAM
  .data      : { *(.data .data.* .sdata .sdata.*) } > RAM
  .tohost    : { *(.tohost) } > RAM
  .bss       : { *(.bss .bss.* .sbss .sbss.* COMMON) } > RAM
}
