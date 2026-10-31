# Kernels with exactly known performance-event counts.
#
# Each kernel is   void kN(uint32_t delta[10])
# It snapshots cycle + hpmcounter3..11, runs a loop, snapshots again, and
# writes the ten differences to delta[]:
#   [0] cycles  [1] load-use stalls  [2] flush cycles  [3] branches
#   [4] taken branches  [5] jumps  [6] branch mispredicts  [7] jump redirects
#   [8] multiply-use stalls  [9] divider stall cycles
#
# Snapshots read the counters in the same order at the start and the end, so
# each counter is sampled the same distance from its own reads and the
# per-counter offsets cancel.

#define N 100

.macro SNAP
    csrr s2, cycle
    csrr s3, hpmcounter3
    csrr s4, hpmcounter4
    csrr s5, hpmcounter5
    csrr s6, hpmcounter6
    csrr s7, hpmcounter7
    csrr s8, hpmcounter8
    csrr s9, hpmcounter9
    csrr s10, hpmcounter10
    csrr s11, hpmcounter11
.endm

.macro DIFF1 csr, saved, off
    csrr t0, \csr
    sub  t0, t0, \saved
    sw   t0, \off(a0)
.endm

.macro DIFF
    DIFF1 cycle,       s2, 0
    DIFF1 hpmcounter3, s3, 4
    DIFF1 hpmcounter4, s4, 8
    DIFF1 hpmcounter5, s5, 12
    DIFF1 hpmcounter6, s6, 16
    DIFF1 hpmcounter7, s7, 20
    DIFF1 hpmcounter8, s8, 24
    DIFF1 hpmcounter9, s9, 28
    DIFF1 hpmcounter10, s10, 32
    DIFF1 hpmcounter11, s11, 36
.endm

.macro PROLOGUE
    addi sp, sp, -48
    sw   s2, 0(sp)
    sw   s3, 4(sp)
    sw   s4, 8(sp)
    sw   s5, 12(sp)
    sw   s6, 16(sp)
    sw   s7, 20(sp)
    sw   s8, 24(sp)
    sw   s9, 28(sp)
    sw   s10, 32(sp)
    sw   s11, 36(sp)
    sw   ra, 40(sp)
.endm

.macro EPILOGUE
    lw   s2, 0(sp)
    lw   s3, 4(sp)
    lw   s4, 8(sp)
    lw   s5, 12(sp)
    lw   s6, 16(sp)
    lw   s7, 20(sp)
    lw   s8, 24(sp)
    lw   s9, 28(sp)
    lw   s10, 32(sp)
    lw   s11, 36(sp)
    lw   ra, 40(sp)
    addi sp, sp, 48
    ret
.endm

    .text

# k1: load immediately consumed + counted loop (400 instructions).
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

# k2: one independent instruction between load and use (400 instructions).
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

# k3: load feeding rs2, and a load feeding a store's data (600 instructions).
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

# k4: call / return in a loop (500 instructions).
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

# k5: load into x0 followed by a use of x0 (400 instructions).
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

# k6: forward branch that is never taken, inside a loop (400 instructions).
    .globl k6
k6:
    PROLOGUE
    li   t3, N
    SNAP
1:  beq  t3, x0, 2f          # t3 != 0 inside the loop: never taken
    addi t4, t4, 1
2:  addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

# k7: forward branch that alternates taken / not taken (450 instructions).
# Taken when t3 is even (50 of 100 iterations), skipping one instruction.
    .globl k7
k7:
    PROLOGUE
    li   t3, N
    SNAP
1:  andi t0, t3, 1
    beqz t0, 2f
    addi t4, t4, 1
2:  addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

# k8: multiply immediately consumed, then a multiply with a gap (600
# instructions). Encoded with .insn so this file assembles for any -march;
# only called on a core with a multiplier.
    .globl k8
k8:
    PROLOGUE
    li   t3, N
    SNAP
1:  .insn r 0x33, 0, 1, t2, t3, t3    # mul  t2, t3, t3
    add  t4, t2, t2                   # uses the product right away -> 1 stall
    .insn r 0x33, 3, 1, t5, t3, t3    # mulhu t5, t3, t3
    addi t3, t3, -1                   # independent filler
    bnez t5, 2f                       # product now comes from WB: no stall
2:  bnez t3, 1b
    DIFF
    EPILOGUE

# k9: a divide whose result is used right away, and a divide by zero
# (500 instructions). Only called on a core with a divider.
    .globl k9
k9:
    PROLOGUE
    li   t3, N
    li   t4, 1000
    SNAP
1:  .insn r 0x33, 5, 1, t2, t4, t3    # divu t2, t4, t3   (t3 = N..1, never 0)
    add  t5, t2, t2                   # quotient forwarded from MEM: no extra stall
    .insn r 0x33, 7, 1, t6, t4, x0    # remu t6, t4, x0   (divide by zero)
    addi t3, t3, -1
    bnez t3, 1b
    DIFF
    EPILOGUE

    .bss
    .balign 4
scratch: .space 16
