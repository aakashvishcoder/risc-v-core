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

    # Clear .bss
    la   t0, _bss_start
    la   t1, _bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

    # exit(main's return value), then halt
    li   t0, 0x10000008
    sw   a0, 0(t0)
    ebreak
3:  j    3b
