# Cache scenarios with exactly known miss and writeback counts.
#
# Each scenario is self-contained: it first "cleans" the data cache by reading
# a cache-sized region R0 twice (the first pass evicts whatever is there,
# writing back dirty lines; afterwards every line holds R0 and is clean), then
# runs its measured pass. The measured pass reads hpmcounter15 (D-cache
# misses) and hpmcounter16 (writebacks) before and after, and nothing else
# touches memory inside it - no stack, no globals.
#
# Return value: misses | (writebacks << 16).
#
# a0..a3 are arguments; t0-t6, a4-a7 are scratch. Lines are 16 bytes.

# read one word per line: base=\b, lines=\n
.macro READ_LINES b, n
    mv   t0, \b
    mv   t1, \n
1:  lw   t2, 0(t0)
    addi t0, t0, 16
    addi t1, t1, -1
    bnez t1, 1b
.endm

# write one word per line: base=\b, lines=\n
.macro WRITE_LINES b, n
    mv   t0, \b
    mv   t1, \n
1:  sw   t1, 0(t0)
    addi t0, t0, 16
    addi t1, t1, -1
    bnez t1, 1b
.endm

.macro BEGIN
    csrr a6, hpmcounter15
    csrr a7, hpmcounter16
.endm

.macro END
    csrr t3, hpmcounter15
    csrr t4, hpmcounter16
    sub  t3, t3, a6
    sub  t4, t4, a7
    slli t4, t4, 16
    or   a0, t3, t4
    ret
.endm

    .text

# seq(R0, R1, lines): measured = read R1 once, from a clean cache holding R0
# expect: misses = lines, writebacks = 0
    .globl c_seq
c_seq:
    READ_LINES a0, a2
    READ_LINES a0, a2
    BEGIN
    READ_LINES a1, a2
    END

# reread(R0, R1, lines): measured = read R1 a second time
# expect: misses = 0 (R1 is exactly one cache's worth)
    .globl c_reread
c_reread:
    READ_LINES a0, a2
    READ_LINES a0, a2
    READ_LINES a1, a2
    BEGIN
    READ_LINES a1, a2
    END

# dirty(R0, R1, R2, lines): dirty every line with R1, then measured = read R2
# expect: misses = lines, writebacks = lines
    .globl c_dirty
c_dirty:
    READ_LINES a0, a3
    READ_LINES a0, a3
    WRITE_LINES a1, a3
    BEGIN
    READ_LINES a2, a3
    END

# conflict(R0, lines, base, span, k, rounds): measured = `rounds` passes over
# k addresses base, base+span, ... (span = one way's size: all in one set)
# expect: k <= ways: k misses (cold only); k = ways+1: k*rounds (LRU thrash)
    .globl c_conflict
c_conflict:
    READ_LINES a0, a1
    READ_LINES a0, a1
    BEGIN
2:  mv   t0, a2
    mv   t1, a4
1:  lw   t2, 0(t0)
    add  t0, t0, a3
    addi t1, t1, -1
    bnez t1, 1b
    addi a5, a5, -1
    bnez a5, 2b
    END

# I-cache: a 256-byte (16-line) loop. ic_loop(passes) runs it `passes` times
# and returns the I-cache misses (hpmcounter14) taken while doing so. The
# caller reads the start count; the end count is read in the loop's last line,
# which is the most recently fetched line when the loop exits.
    .balign 256
    .globl ic_loop
ic_loop:
    .rept 60
    addi x0, x0, 0
    .endr
    addi a0, a0, -1               # line 15: loop control + end read
    bnez a0, ic_loop
    csrr a0, hpmcounter14
    ret

# ic_measure(passes): one warm-up pass, then the start read and the measured
# call from a single 16-byte line, so no fetch miss can land between the
# start read and the loop. The warm-up happens here rather than in the caller
# so that no unrelated code (which could evict loop lines in a direct-mapped
# cache) runs between warming the loop and measuring it.
    .globl ic_measure
ic_measure:
    mv   t6, ra
    mv   t4, a0
    li   a0, 1
    jal  ra, ic_loop              # warm-up pass
    .balign 16
    csrr t5, hpmcounter14
    mv   a0, t4
    jal  ra, ic_loop
    nop
    sub  a0, a0, t5
    jr   t6
