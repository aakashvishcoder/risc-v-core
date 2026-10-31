# Trap entry for irqtest: save the caller-saved registers, call
#   void trap_c(uint32_t mcause, uint32_t mepc, uint32_t vector)
# and return with mret. `vector` says how we got here: -1 through the direct
# entry (mtvec mode 0), or the slot number of the vector table (mode 1).
# trap_c may change mepc (exceptions skip the faulting instruction).

.macro SAVE_AND_CALL vec
    addi sp, sp, -64
    sw   ra, 0(sp)
    sw   t0, 4(sp)
    sw   t1, 8(sp)
    sw   t2, 12(sp)
    sw   t3, 16(sp)
    sw   t4, 20(sp)
    sw   t5, 24(sp)
    sw   t6, 28(sp)
    sw   a0, 32(sp)
    sw   a1, 36(sp)
    sw   a2, 40(sp)
    sw   a3, 44(sp)
    sw   a4, 48(sp)
    sw   a5, 52(sp)
    sw   a6, 56(sp)
    sw   a7, 60(sp)
    csrr a0, mcause
    csrr a1, mepc
    li   a2, \vec
    call trap_c
    lw   ra, 0(sp)
    lw   t0, 4(sp)
    lw   t1, 8(sp)
    lw   t2, 12(sp)
    lw   t3, 16(sp)
    lw   t4, 20(sp)
    lw   t5, 24(sp)
    lw   t6, 28(sp)
    lw   a0, 32(sp)
    lw   a1, 36(sp)
    lw   a2, 40(sp)
    lw   a3, 44(sp)
    lw   a4, 48(sp)
    lw   a5, 52(sp)
    lw   a6, 56(sp)
    lw   a7, 60(sp)
    addi sp, sp, 64
    mret
.endm

    .text
    .balign 4
    .globl trap_direct
trap_direct:
    SAVE_AND_CALL -1

# Vector table (mtvec = vec_table | 1): exceptions use slot 0, interrupt
# cause N uses slot N. Each slot is one jump.
    .balign 64
    .globl vec_table
vec_table:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    j    vec_\n
    .endr

    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
vec_\n:
    SAVE_AND_CALL \n
    .endr

# A loop that keeps the whole pipeline busy - loads, stores, multiplies,
# divides, branches, calls - so interrupts land on every kind of instruction
# and in every kind of stall. Returns a checksum that must not depend on
# where (or how often) it was interrupted.
#   uint32_t busy_loop(uint32_t *buf, uint32_t n)      buf: 64 words
    .globl busy_loop
busy_loop:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    li   t0, 0x9e3779b9        # running hash
    li   t1, 0                 # i
1:  andi t2, t1, 63
    slli t2, t2, 2
    add  t2, a0, t2
    lw   t3, 0(t2)             # load ...
    add  t3, t3, t0            # ... used immediately (load-use)
    mul  t4, t3, t1            # multiply ...
    xor  t0, t0, t4            # ... used immediately (multiply-use)
    ori  t5, t1, 1
    divu t6, t0, t5            # 33-cycle divide
    add  t0, t0, t6
    sw   t0, 0(t2)             # store back
    andi t5, t1, 3
    bnez t5, 2f                # data-dependent branch
    jal  ra, mix               # call/return
2:  addi t1, t1, 1
    bltu t1, a1, 1b
    mv   a0, t0
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret
mix:
    slli s0, t0, 7
    srli s1, t0, 25
    or   t0, s0, s1
    rem  s0, t0, t5            # t5 = 0 here: remainder by zero
    add  t0, t0, s0
    ret
