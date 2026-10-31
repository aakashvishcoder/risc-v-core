# Exception test kernels.
#
# trap_entry records each trap (mcause, mepc, mtval, mstatus) in trap_info and
# returns to mepc + 4 - skipping the faulting instruction - or, if
# trap_info.resume is set, there instead (for faults where mepc + 4 is not a
# useful place to go, like a fetch from a bad address). It only touches t0-t2,
# saved through mscratch, so the kernels can check that the faulting
# instruction left every other register alone.
#
# Each kernel returns a0 = address of the instruction expected to trap and
# a1 = the destination register of that instruction afterwards (preloaded with
# 0x5555; a trapping instruction must not write it).

    .data
    .balign 4
    .globl trap_info
trap_info:                 # struct trap_info in main.c
    .word 0, 0             # saved t1, t2
    .word 0                # 8:  mcause
    .word 0                # 12: mepc
    .word 0                # 16: mtval
    .word 0                # 20: mstatus seen by the handler
    .word 0                # 24: traps taken
    .word 0                # 28: resume address (0: mepc + 4)

    .text
    .balign 4
    .globl trap_entry
trap_entry:
    csrrw t0, mscratch, t0     # t0 = &trap_info, mscratch = interrupted t0
    sw   t1, 0(t0)
    sw   t2, 4(t0)
    csrr t1, mcause
    sw   t1, 8(t0)
    csrr t1, mepc
    sw   t1, 12(t0)
    csrr t1, mtval
    sw   t1, 16(t0)
    csrr t1, mstatus
    sw   t1, 20(t0)
    lw   t1, 24(t0)
    addi t1, t1, 1
    sw   t1, 24(t0)
    lw   t2, 28(t0)
    bnez t2, 1f
    csrr t2, mepc
    addi t2, t2, 4
1:  csrw mepc, t2
    sw   zero, 28(t0)
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    csrrw t0, mscratch, t0     # restore t0; mscratch = &trap_info again
    mret

# Kernel body: a0 = pc of the instruction at label 1, a1 = 0x5555
.macro KERNEL name
    .globl \name
    .balign 4
\name:
.endm
.macro PRE
    li   a1, 0x5555
    la   a0, 1f
.endm

KERNEL k_ecall
    PRE
1:  ecall
    ret

KERNEL k_ebreak
    PRE
1:  ebreak
    ret

KERNEL k_illegal_zero          # all-zero word
    PRE
1:  .word 0x00000000
    ret

KERNEL k_illegal_ones          # all-ones word
    PRE
1:  .word 0xffffffff
    ret

KERNEL k_illegal_sub_sll       # funct7 0x20 on SLL: not an instruction
    PRE
1:  .word 0x40b595b3           # "sub" encoding with funct3 = 1, rd = a1
    ret

KERNEL k_illegal_csr_missing   # read of a CSR that doesn't exist
    PRE
1:  csrr a1, 0x7c0
    ret

KERNEL k_illegal_csr_ro        # write to the read-only cycle CSR
    PRE
1:  csrrw a1, cycle, a2
    ret

KERNEL k_illegal_mret_like     # SYSTEM funct3 0 with an unknown funct12
    PRE
1:  .word 0x20200073
    ret

KERNEL k_illegal_fence_ok      # FENCE is legal: no trap expected
    PRE
1:  fence
    ret

KERNEL k_lw_mis                # a0 = address
    mv   a2, a0
    PRE
1:  lw   a1, 0(a2)
    ret

KERNEL k_lh_mis
    mv   a2, a0
    PRE
1:  lh   a1, 0(a2)
    ret

KERNEL k_lhu_mis
    mv   a2, a0
    PRE
1:  lhu  a1, 0(a2)
    ret

KERNEL k_sw_mis                # a0 = address, value 0xdeadbeef
    mv   a2, a0
    li   a3, 0xdeadbeef
    PRE
1:  sw   a3, 0(a2)
    ret

KERNEL k_sh_mis
    mv   a2, a0
    li   a3, 0x4141            # "AA" if it ever reached the UART
    PRE
1:  sh   a3, 0(a2)
    ret

KERNEL k_sb                    # byte store: never misaligned
    mv   a2, a0
    li   a3, 0x5a
    PRE
1:  sb   a3, 0(a2)
    ret

# A misaligned load right behind a load it depends on (load-use stall into a
# trap), and a misaligned store right behind a divide (EX held for 33 cycles
# with the store waiting in ID)
KERNEL k_loaduse_mis           # a0 = address of a word holding a misaligned address
    mv   a2, a0
    li   a1, 0x5555
    la   a0, 1f
    lw   a3, 0(a2)
1:  lw   a1, 0(a3)
    ret

KERNEL k_div_then_sw_mis       # a0 = misaligned address
    mv   a2, a0
    li   a3, 1000
    li   a4, 7
    li   a1, 0x5555
    la   a0, 1f
    div  a5, a3, a4
1:  sw   a5, 0(a2)
    mv   a1, a5                # 142: the divide must still have completed
    ret

KERNEL k_lw_fault              # a0 = unmapped address
    mv   a2, a0
    PRE
1:  lw   a1, 0(a2)
    ret

KERNEL k_sw_fault
    mv   a2, a0
    li   a3, 0x41
    PRE
1:  sw   a3, 0(a2)
    ret

# Fetch from a0 (outside RAM): the fault is taken with mepc = mtval = a0.
# The handler resumes at label 2.
KERNEL k_fetch_fault
    mv   a2, a0
    la   t0, 2f
    la   t1, trap_info
    sw   t0, 28(t1)
    li   a1, 0x5555
    la   a0, 1f
1:  jalr a1, 0(a2)             # links (retires), then the target faults
2:  mv   a0, a2
    ret

# jalr to a target with bit 1 set: the jalr traps and must not link
KERNEL k_jalr_mis
    la   a2, 2f
    addi a2, a2, 2
    PRE
1:  jalr a1, 0(a2)
2:  ret

# jal / taken branch to pc + 6 and pc - 6 (hand-encoded: assemblers refuse)
KERNEL k_jal_mis_fwd
    PRE
1:  .word 0x006005ef           # jal a1, .+6
    ret

KERNEL k_jal_mis_back
    PRE
1:  .word 0xffbff5ef           # jal a1, .-6
    ret

KERNEL k_beq_mis_fwd           # forward: predicted not taken, redirected from EX
    PRE
1:  .word 0x00000363           # beq x0, x0, .+6
    ret

KERNEL k_beq_mis_back          # backward: predicted taken in decode, then traps
    PRE
1:  .word 0xfe000de3           # beq x0, x0, .-6
    ret

KERNEL k_bne_mis_nottaken      # not taken: the misaligned target doesn't matter
    PRE
1:  .word 0x00001363           # bne x0, x0, .+6
    ret
