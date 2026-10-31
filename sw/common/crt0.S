    .section .text.start
    .globl _start
_start:
    # Zero the registers so every run starts from the same state
    li   x1, 0
    li   x3, 0
    li   x4, 0
    li   x5, 0
    li   x6, 0
    li   x7, 0
    li   x8, 0
    li   x9, 0
    li   x10, 0
    la   sp, _stack_top

    # Until the program installs its own, any trap ends the run (see below)
    la   t0, _default_trap
    csrw mtvec, t0

    # Clear .bss
    la   t0, _bss_start
    la   t1, _bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

    # exit(main's return value)
    li   t0, 0x10000008
    sw   a0, 0(t0)
3:  j    3b

    # Default trap handler: a trap the program didn't expect ends the run with
    # exit code 0x100 | mcause for an exception, 0x200 | cause for an interrupt
    .balign 4
_default_trap:
    csrr t0, mcause
    bltz t0, 1f
    ori  t0, t0, 0x100
    j    2f
1:  andi t0, t0, 0xff
    ori  t0, t0, 0x200
2:  li   t1, 0x10000008
    sw   t0, 0(t1)
4:  j    4b
