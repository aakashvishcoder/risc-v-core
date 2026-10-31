# Kernels with exactly known performance-event counts.
#
# Each kernel is   void kN(uint32_t delta[6])
# It snapshots cycle + hpmcounter3..7, runs a loop, snapshots again, and writes
# the six differences to delta[]:
#   [0] cycles  [1] load-use stalls  [2] flush cycles
#   [3] branches  [4] taken branches  [5] jumps
#
# Snapshots read the counters in the same order at the start and the end, so
# each counter is sampled the same distance from its own reads and the
# per-counter offsets cancel.

#define N 100

.macro SNAP base
    csrr s2, cycle
    csrr s3, hpmcounter3
    csrr s4, hpmcounter4
    csrr s5, hpmcounter5
    csrr s6, hpmcounter6
    csrr s7, hpmcounter7
.endm

.macro DIFF
    csrr t0, cycle
    sub  t0, t0, s2
    sw   t0, 0(a0)
    csrr t0, hpmcounter3
    sub  t0, t0, s3
    sw   t0, 4(a0)
    csrr t0, hpmcounter4
    sub  t0, t0, s4
    sw   t0, 8(a0)
    csrr t0, hpmcounter5
    sub  t0, t0, s5
    sw   t0, 12(a0)
    csrr t0, hpmcounter6
    sub  t0, t0, s6
    sw   t0, 16(a0)
    csrr t0, hpmcounter7
    sub  t0, t0, s7
    sw   t0, 20(a0)
.endm

.macro PROLOGUE
    addi sp, sp, -32
    sw   s2, 0(sp)
    sw   s3, 4(sp)
    sw   s4, 8(sp)
    sw   s5, 12(sp)
    sw   s6, 16(sp)
    sw   s7, 20(sp)
    sw   ra, 24(sp)
.endm

.macro EPILOGUE
    lw   s2, 0(sp)
    lw   s3, 4(sp)
    lw   s4, 8(sp)
    lw   s5, 12(sp)
    lw   s6, 16(sp)
    lw   s7, 20(sp)
    lw   ra, 24(sp)
    addi sp, sp, 32
    ret
.endm

    .text

# k1: load immediately consumed + counted loop.
# Expect: load-use N, branches N, taken N-1, flush N-1, jumps 0.
    .globl k1
k1:
    PROLOGUE
    la   t1, scratch
    li   t3, N
    SNAP
1:  lw   t2, 0(t1)
    add  t4, t2, t2          # uses t2 right after the load -> 1 stall
    addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

# k2: same loop with one independent instruction between load and use.
# Expect: load-use 0 (forwarding from WB covers it), branches N, taken N-1.
    .globl k2
k2:
    PROLOGUE
    la   t1, scratch
    li   t3, N
    SNAP
1:  lw   t2, 0(t1)
    addi t3, t3, -1          # independent filler
    add  t4, t2, t2          # load result now comes from WB: no stall
    bnez t3, 1b
    DIFF
    EPILOGUE

# k3: load feeding the *second* source operand, and a load feeding a store's
# data (a store reads rs2 in EX too, so this must stall as well).
# Expect: load-use 2N, branches N, taken N-1.
    .globl k3
k3:
    PROLOGUE
    la   t1, scratch
    li   t3, N
    SNAP
1:  lw   t2, 0(t1)
    add  t4, t3, t2          # rs2 dependence -> stall
    lw   t5, 4(t1)
    sw   t5, 8(t1)           # store data dependence -> stall
    addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

# k4: call / return in a loop.
# Expect: jumps 2N (jal + jalr), branches N, taken N-1, flush 2N + N-1.
    .globl k4
k4:
    PROLOGUE
    li   t3, N
    SNAP
1:  jal  ra, leaf
    addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

leaf:
    addi t6, t6, 1
    ret

# k5: load into x0 followed by a use of x0 - x0 is never a real dependence.
# Expect: load-use 0.
    .globl k5
k5:
    PROLOGUE
    la   t1, scratch
    li   t3, N
    SNAP
1:  lw   x0, 0(t1)
    add  t4, x0, x0
    addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

    .bss
    .balign 4
scratch: .space 16
