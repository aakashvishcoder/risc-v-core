// Directed exception test: every exception the core implements, checked for
// the right mcause / mepc / mtval, for leaving the destination register and
// memory untouched, and for the mstatus MIE/MPIE stack and mret. Also checks
// CSR write masks and the counter CSRs (writable, inhibitable).
#include "rt.h"

#define CSRR(csr) ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define CSRW(csr, v) __asm__ volatile("csrw " #csr ", %0" :: "r"(v))

struct trap_info {
  uint32_t save[2], cause, epc, tval, status, count, resume;
};
extern volatile struct trap_info trap_info;
void trap_entry(void);

typedef uint64_t (*kernel0)(void);
typedef uint64_t (*kernel1)(uint32_t);
uint64_t k_ecall(void), k_ebreak(void), k_illegal_zero(void), k_illegal_ones(void),
    k_illegal_sub_sll(void), k_illegal_csr_missing(void), k_illegal_csr_ro(void),
    k_illegal_mret_like(void), k_illegal_fence_ok(void), k_jalr_mis(void), k_jal_mis_fwd(void),
    k_jal_mis_back(void), k_beq_mis_fwd(void), k_beq_mis_back(void), k_bne_mis_nottaken(void);
uint64_t k_lw_mis(uint32_t), k_lh_mis(uint32_t), k_lhu_mis(uint32_t), k_sw_mis(uint32_t),
    k_sh_mis(uint32_t), k_sb(uint32_t), k_loaduse_mis(uint32_t), k_div_then_sw_mis(uint32_t),
    k_lw_fault(uint32_t), k_sw_fault(uint32_t), k_fetch_fault(uint32_t);

static volatile uint32_t buf[4] = {0x11111111, 0x22222222, 0x33333333, 0x44444444};
static int fails;
static uint32_t last_count;

static uint32_t traps_since_last(void) {
  uint32_t n = trap_info.count - last_count;
  last_count = trap_info.count;
  return n;
}

static void ok(const char *name, int pass) {
  printf_("  %-38s %s\n", name, pass ? "ok" : "FAIL");
  fails += !pass;
}

// Run a kernel; expect exactly one trap with this cause and mtval at the
// address the kernel reports, and its destination register untouched
static void expect(const char *name, uint64_t r, uint32_t cause, uint32_t tval, uint32_t rd_after) {
  uint32_t pc = (uint32_t)r, rd = (uint32_t)(r >> 32);
  uint32_t traps = traps_since_last();
  int pass = traps == 1 && trap_info.cause == cause && trap_info.epc == pc &&
             trap_info.tval == tval && rd == rd_after;
  printf_("  %-38s cause %2u  mepc %08x  mtval %08x  rd %08x  %s\n", name, trap_info.cause,
          trap_info.epc, trap_info.tval, rd, pass ? "ok" : "FAIL");
  if (!pass)
    printf_("    expected %u trap(s)=1, cause %u, mepc %08x, mtval %08x, rd %08x (got %u traps)\n",
            1, cause, pc, tval, rd_after, traps);
  fails += !pass;
}

static void expect_none(const char *name, uint64_t r, uint32_t rd_after) {
  uint32_t rd = (uint32_t)(r >> 32);
  int pass = traps_since_last() == 0 && rd == rd_after;
  printf_("  %-38s no trap, rd %08x  %s\n", name, rd, pass ? "ok" : "FAIL");
  fails += !pass;
}

int main(void) {
  CSRW(mscratch, (uint32_t)&trap_info);
  CSRW(mtvec, (uint32_t)trap_entry);
  uint32_t b = (uint32_t)buf;
  const uint32_t KEEP = 0x5555;

  printf_("traptest: exceptions\n");
  expect("ecall", k_ecall(), 11, 0, KEEP);
  {
    uint64_t r;
    r = k_ebreak();              expect("ebreak (mtval = pc)", r, 3, (uint32_t)r, KEEP);
    r = k_illegal_zero();        expect("illegal: 0x00000000", r, 2, 0x00000000, KEEP);
    r = k_illegal_ones();        expect("illegal: 0xffffffff", r, 2, 0xffffffff, KEEP);
    r = k_illegal_sub_sll();     expect("illegal: funct7 0x20 on sll", r, 2, 0x40b595b3, KEEP);
    r = k_illegal_csr_missing(); expect("illegal: unimplemented CSR", r, 2, 0x7c0025f3, KEEP);
    r = k_illegal_csr_ro();      expect("illegal: write to cycle", r, 2, 0xc00615f3, KEEP);
    r = k_illegal_mret_like();   expect("illegal: unknown SYSTEM funct12", r, 2, 0x20200073, KEEP);

    r = k_lw_mis(b + 2);         expect("lw  misaligned (+2)", r, 4, b + 2, KEEP);
    r = k_lw_mis(b + 1);         expect("lw  misaligned (+1)", r, 4, b + 1, KEEP);
    r = k_lh_mis(b + 1);         expect("lh  misaligned (+1)", r, 4, b + 1, KEEP);
    r = k_lhu_mis(b + 3);        expect("lhu misaligned (+3)", r, 4, b + 3, KEEP);
    r = k_sw_mis(b + 6);         expect("sw  misaligned (+6)", r, 6, b + 6, KEEP);
    r = k_sh_mis(b + 1);         expect("sh  misaligned (+1)", r, 6, b + 1, KEEP);
    r = k_sh_mis(0x10000001);    expect("sh  misaligned to UART_DATA+1", r, 6, 0x10000001, KEEP);
    ok("misaligned stores left memory alone",
       buf[0] == 0x11111111 && buf[1] == 0x22222222 && buf[2] == 0x33333333);

    static volatile uint32_t ptr;
    ptr = b + 2;
    r = k_loaduse_mis((uint32_t)&ptr);  expect("lw misaligned after load-use stall", r, 4, b + 2, KEEP);
    r = k_div_then_sw_mis(b + 2);       expect("sw misaligned behind a divide", r, 6, b + 2, 142);
    ok("... and it left memory alone", buf[0] == 0x11111111);

    r = k_lw_fault(0x40000000);  expect("lw  access fault (0x40000000)", r, 5, 0x40000000, KEEP);
    r = k_lw_fault(0x10000100);  expect("lw  access fault (past I/O page)", r, 5, 0x10000100, KEEP);
    r = k_lw_fault(0x00010000);  expect("lw  access fault (just past RAM)", r, 5, 0x00010000, KEEP);
    r = k_sw_fault(0x80000000);  expect("sw  access fault (0x80000000)", r, 7, 0x80000000, KEEP);
    r = k_sw_fault(0x10000108);  expect("sw  access fault (I/O alias)", r, 7, 0x10000108, KEEP);

    // Fetch faults: mepc = mtval = the bad address; the jalr itself retired
    // and linked (the kernel returns the fault address and the link)
    const uint32_t bad[] = {0x20000000, 0x00010000, 0x10000000};
    for (int i = 0; i < 3; i++) {
      r = k_fetch_fault(bad[i]);
      uint32_t link = (uint32_t)(r >> 32);
      expect(i == 0 ? "fetch access fault (0x20000000)"
             : i == 1 ? "fetch access fault (just past RAM)"
                      : "fetch access fault (I/O)",
             r, 1, bad[i], link);
      ok("... the jalr linked", link != KEEP && link < 0x10000 && (link & 3) == 0);
    }

    // Misaligned jump targets: the jump traps, mtval = target, no link
    r = k_jalr_mis();     expect("jalr to target+2", r, 0, (uint32_t)r + 6, KEEP);
    r = k_jal_mis_fwd();  expect("jal  .+6", r, 0, (uint32_t)r + 6, KEEP);
    r = k_jal_mis_back(); expect("jal  .-6", r, 0, (uint32_t)r - 6, KEEP);
    r = k_beq_mis_fwd();  expect("beq  .+6 (taken, predicted not)", r, 0, (uint32_t)r + 6, KEEP);
    r = k_beq_mis_back(); expect("beq  .-6 (taken, predicted taken)", r, 0, (uint32_t)r - 6, KEEP);
    r = k_beq_mis_back(); expect("beq  .-6 again (trained)", r, 0, (uint32_t)r - 6, KEEP);

    expect_none("bne .+6 not taken", k_bne_mis_nottaken(), KEEP);
    expect_none("fence", k_illegal_fence_ok(), KEEP);
    expect_none("sb at +1 (bytes never misalign)", k_sb(b + 1), KEEP);
    ok("... and the byte landed", buf[0] == 0x11115a11);
  }

  printf_("traptest: mstatus stack and mret\n");
  CSRW(mstatus, 0x8);                                  // MIE = 1
  k_ecall();
  ok("one trap; handler saw MIE=0 MPIE=1 MPP=11",
     traps_since_last() == 1 && trap_info.status == 0x1880);
  ok("mret restored MIE=1 MPIE=1", CSRR(mstatus) == 0x1888);
  CSRW(mstatus, 0);
  ok("mstatus cleared", CSRR(mstatus) == 0x1800);

  printf_("traptest: CSRs\n");
  uint32_t ones = 0xFFFFFFFF;
  CSRW(mstatus, ones); ok("mstatus write mask", CSRR(mstatus) == 0x1888); CSRW(mstatus, 0);
  CSRW(mie, ones);     ok("mie write mask", CSRR(mie) == 0x888);        CSRW(mie, 0);
  CSRW(mepc, ones);    ok("mepc [1:0] = 0", CSRR(mepc) == 0xFFFFFFFC);
  uint32_t tv = CSRR(mtvec);
  CSRW(mtvec, ones);   ok("mtvec modes 0/1 only", CSRR(mtvec) == 0xFFFFFFFD);
  CSRW(mtvec, tv);
  CSRW(mcause, 0x8000000B); ok("mcause read/write", CSRR(mcause) == 0x8000000B);
  CSRW(mtval, 0x12345678);  ok("mtval read/write", CSRR(mtval) == 0x12345678);
  uint32_t old;
  __asm__ volatile("csrrsi %0, mtval, 0x7" : "=r"(old));
  ok("csrrsi returns old, sets bits", old == 0x12345678 && CSRR(mtval) == 0x1234567F);
  __asm__ volatile("csrrci %0, mtval, 0xF" : "=r"(old));
  ok("csrrci clears bits", old == 0x1234567F && CSRR(mtval) == 0x12345670);
  ok("mhartid reads 0", CSRR(mhartid) == 0);
  uint32_t misa = CSRR(misa);
  ok("misa says RV32I or RV32IM", misa == 0x40001100 || misa == 0x40000100);

  // Counters: writable, and frozen by mcountinhibit
  CSRW(mcycle, 1000);
  uint32_t c = CSRR(mcycle);
  ok("mcycle writable", c >= 1000 && c < 1200);   // (an I-cache miss can intervene)
  CSRW(mcountinhibit, 0x5);                            // freeze cycle + instret
  uint32_t c1 = CSRR(mcycle), i1 = CSRR(minstret);
  __asm__ volatile("nop; nop; nop; nop");
  uint32_t c2 = CSRR(mcycle), i2 = CSRR(minstret);
  CSRW(mcountinhibit, 0);
  ok("mcountinhibit freezes mcycle/minstret", c1 == c2 && i1 == i2);
  CSRW(mcountinhibit, ones);
  uint32_t inh = CSRR(mcountinhibit);
  CSRW(mcountinhibit, 0);
  ok("mcountinhibit reads back (bit 1 is 0)", inh == 0xFFFFFFFD);
  c1 = CSRR(mcycle);
  c2 = CSRR(mcycle);
  ok("counting again", c2 > c1);

  printf_("traptest: %d failures\n", fails);
  return fails;
}
