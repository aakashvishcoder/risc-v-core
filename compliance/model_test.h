// Target definitions for the RISC-V architecture tests (riscv-arch-test
// 2.7.4) on risc-v-core. Everything lives in RAM at address 0; the branch
// and jump tests need up to 2 MB of code, so the simulator for these tests
// is built with 4 MB of RAM (MEM_WORDS=1048576).
// At the end of a test, the signature region is printed over the UART as one
// 8-digit hex word per line - the reference files' format - and the
// simulation exits through SIM_EXIT.
#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

// Print the signature, then exit with code 0
#define RVMODEL_HALT                                                    \
        la   t0, begin_signature;                                       \
        la   t1, end_signature;                                         \
        li   t2, 0x10000000;           /* UART_DATA */                  \
7771:   bgeu t0, t1, 7774f;                                             \
        lw   t3, 0(t0);                                                 \
        li   t4, 28;                                                    \
7772:   srl  t5, t3, t4;                                                \
        andi t5, t5, 15;                                                \
        addi t6, t5, -10;                                               \
        addi t5, t5, 48;               /* '0'..'9' */                   \
        bltz t6, 7773f;                                                 \
        addi t5, t5, 39;               /* 'a'..'f' */                   \
7773:   sw   t5, 0(t2);                                                 \
        addi t4, t4, -4;                                                \
        bgez t4, 7772b;                                                 \
        li   t5, 10;                                                    \
        sw   t5, 0(t2);                                                 \
        addi t0, t0, 4;                                                 \
        j    7771b;                                                     \
7774:   sw   zero, 8(t2);              /* SIM_EXIT = 0 */               \
7775:   j    7775b;

#define RVMODEL_DATA_BEGIN                                              \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .align 4; .global end_signature; end_signature:                       \
  RVMODEL_DATA_SECTION

#define RVMODEL_BOOT

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// Interrupt sources (CLINT msip, mtimecmp; EXT_IRQ test register)
#define RVMODEL_SET_MSW_INT       li t1, 1; li t2, 0x02000000; sw t1, 0(t2);
#define RVMODEL_CLEAR_MSW_INT     li t2, 0x02000000; sw zero, 0(t2);
#define RVMODEL_CLEAR_MTIMER_INT  li t1, -1; li t2, 0x02004000; sw t1, 4(t2);
#define RVMODEL_CLEAR_MEXT_INT    li t2, 0x10000000; sw zero, 16(t2);

#endif
