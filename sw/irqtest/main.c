// Directed interrupt test: timer, software and external interrupts through
// the CLINT and the external-interrupt test hook; enables (mstatus.MIE and
// mie), priority, deferral while in a handler, direct and vectored mtvec,
// wfi, and precise interrupts under load (a busy loop interrupted thousands
// of times must compute exactly what it computes undisturbed).
#include "rt.h"

#define CSRR(csr) ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define CSRW(csr, v) __asm__ volatile("csrw " #csr ", %0" :: "r"(v) : "memory")
#define CSRS(csr, v) __asm__ volatile("csrs " #csr ", %0" :: "r"(v) : "memory")
#define CSRC(csr, v) __asm__ volatile("csrc " #csr ", %0" :: "r"(v) : "memory")

#define CLINT_MSIP     (*(volatile uint32_t *)0x02000000u)
#define CLINT_CMP_LO   (*(volatile uint32_t *)0x02004000u)
#define CLINT_CMP_HI   (*(volatile uint32_t *)0x02004004u)
#define CLINT_TIME_LO  (*(volatile uint32_t *)0x0200BFF8u)
#define CLINT_TIME_HI  (*(volatile uint32_t *)0x0200BFFCu)
#define EXT_IRQ        (*(volatile uint32_t *)0x10000010u)

#define MSTATUS_MIE 0x8u
#define MSIP_BIT    (1u << 3)
#define MTIP_BIT    (1u << 7)
#define MEIP_BIT    (1u << 11)
#define IRQ(code)   (0x80000000u | (code))

void trap_direct(void);
void vec_table(void);
uint32_t busy_loop(uint32_t *buf, uint32_t n);

// ---- what the handler saw --------------------------------------------------
#define LOGN 16
static volatile uint32_t log_cause[LOGN], log_vec[LOGN], log_time[LOGN];
static volatile uint32_t nlog, ntraps;
static volatile uint32_t period;      // timer: re-arm this far ahead (0 = disarm)
static volatile uint32_t raise_ext_in_soft;

static void timer_disarm(void) { CLINT_CMP_HI = 0xFFFFFFFFu; }
static void timer_at(uint32_t t) {   // the low word of mtime never wraps in these runs
  CLINT_CMP_HI = 0xFFFFFFFFu;        // no spurious match while the halves change
  CLINT_CMP_LO = t;
  CLINT_CMP_HI = 0;
}

void trap_c(uint32_t cause, uint32_t epc, uint32_t vec) {
  ntraps++;
  if (nlog < LOGN) {
    log_cause[nlog] = cause;
    log_vec[nlog] = vec;
    log_time[nlog] = CLINT_TIME_LO;
    nlog++;
  }
  if (cause == IRQ(7)) {
    if (period) timer_at(CLINT_TIME_LO + period);   // from now: always leaves time to progress
    else timer_disarm();
  } else if (cause == IRQ(3)) {
    CLINT_MSIP = 0;
    if (raise_ext_in_soft) EXT_IRQ = 1;     // pending, but MIE is 0 in here
  } else if (cause == IRQ(11)) {
    EXT_IRQ = 0;
  } else if (!(cause & 0x80000000u)) {
    CSRW(mepc, epc + 4);                    // exception: skip the instruction
  }
}

static int fails;
static void ok(const char *name, int pass) {
  printf_("  %-46s %s\n", name, pass ? "ok" : "FAIL");
  fails += !pass;
}
static void reset_log(void) { nlog = 0; }

static int spin_until(volatile uint32_t *p, uint32_t value, uint32_t limit) {
  for (uint32_t i = 0; i < limit; i++)
    if (*p >= value) return 1;
  return 0;
}

int main(void) {
  CSRW(mtvec, (uint32_t)trap_direct);
  printf_("irqtest\n");

  // ---- timer ---------------------------------------------------------------
  reset_log();
  CSRW(mie, MTIP_BIT);
  timer_at(CLINT_TIME_LO + 50);              // due soon, but mstatus.MIE is 0
  for (volatile int i = 0; i < 40; i++) {}
  uint32_t pending = CSRR(mip) & MTIP_BIT;
  timer_disarm();
  ok("timer pending in mip but not taken (MIE = 0)", pending && nlog == 0);
  CSRS(mstatus, MSTATUS_MIE);
  // Twice: the first run warms up the caches for the handler (on a cached
  // build its first entry takes cold misses); the second is measured
  uint32_t due = 0;
  int got = 1;
  for (int run = 0; run < 2; run++) {
    reset_log();
    due = CLINT_TIME_LO + 400;
    timer_at(due);
    got &= spin_until(&nlog, 1, 100000);
  }
  ok("timer interrupt taken", got && log_cause[0] == IRQ(7) && log_vec[0] == (uint32_t)-1);
  uint32_t latency = log_time[0] - due;
  printf_("  %-46s %u cycles\n", "  mtime match -> handler reads mtime", latency);
  ok("  ... and not early, nor much later", (int32_t)(log_time[0] - due) >= 0 && latency < 100);
  ok("mip.MTIP clear after the handler re-armed", (CSRR(mip) & MTIP_BIT) == 0);

  // ---- software ------------------------------------------------------------
  reset_log();
  CSRW(mie, MSIP_BIT);
  CLINT_MSIP = 1;
  __asm__ volatile("nop; nop; nop; nop; nop; nop; nop; nop");
  ok("software interrupt taken within 8 instructions", nlog == 1 && log_cause[0] == IRQ(3));
  ok("msip cleared by the handler", CLINT_MSIP == 0);

  // ---- external ------------------------------------------------------------
  reset_log();
  CSRW(mie, MEIP_BIT);
  EXT_IRQ = 1;
  __asm__ volatile("nop; nop; nop; nop; nop; nop; nop; nop");
  ok("external interrupt taken", nlog == 1 && log_cause[0] == IRQ(11));

  // ---- enables and priority ------------------------------------------------
  reset_log();
  CSRC(mstatus, MSTATUS_MIE);
  CSRW(mie, MSIP_BIT | MTIP_BIT | MEIP_BIT);
  CLINT_MSIP = 1;
  EXT_IRQ = 1;
  timer_at(CLINT_TIME_LO);                   // already due
  for (volatile int i = 0; i < 20; i++) {}
  ok("nothing taken while mstatus.MIE = 0", nlog == 0);
  ok("mip shows all three pending", (CSRR(mip) & 0x888) == 0x888);
  CSRW(mie, MSIP_BIT | MEIP_BIT);
  CSRS(mstatus, MSTATUS_MIE);
  for (volatile int i = 0; i < 20; i++) {}
  ok("masked timer not taken, MEI before MSI",
     nlog == 2 && log_cause[0] == IRQ(11) && log_cause[1] == IRQ(3));
  ok("timer still pending in mip", (CSRR(mip) & MTIP_BIT) != 0);
  CSRC(mstatus, MSTATUS_MIE);
  reset_log();
  CLINT_MSIP = 1;
  EXT_IRQ = 1;
  CSRW(mie, MSIP_BIT | MTIP_BIT | MEIP_BIT);
  CSRS(mstatus, MSTATUS_MIE);
  for (volatile int i = 0; i < 20; i++) {}
  ok("priority MEI > MSI > MTI",
     nlog == 3 && log_cause[0] == IRQ(11) && log_cause[1] == IRQ(3) && log_cause[2] == IRQ(7));

  // ---- deferral: an interrupt raised inside a handler waits for mret --------
  reset_log();
  raise_ext_in_soft = 1;
  CLINT_MSIP = 1;
  for (volatile int i = 0; i < 20; i++) {}
  raise_ext_in_soft = 0;
  ok("interrupt raised in a handler is taken after mret",
     nlog == 2 && log_cause[0] == IRQ(3) && log_cause[1] == IRQ(11));

  // ---- vectored mode ---------------------------------------------------------
  reset_log();
  CSRW(mtvec, (uint32_t)vec_table | 1);
  CLINT_MSIP = 1;
  for (volatile int i = 0; i < 10; i++) {}
  EXT_IRQ = 1;
  for (volatile int i = 0; i < 10; i++) {}
  timer_at(CLINT_TIME_LO + 50);
  spin_until(&nlog, 3, 10000);
  __asm__ volatile("ecall");
  ok("vectored: MSI via slot 3, MEI via 11, MTI via 7",
     nlog == 4 && log_vec[0] == 3 && log_vec[1] == 11 && log_vec[2] == 7);
  ok("vectored: exceptions still use the base (slot 0)", log_cause[3] == 11 && log_vec[3] == 0);
  CSRW(mtvec, (uint32_t)trap_direct);

  // ---- wfi -----------------------------------------------------------------
  reset_log();
  timer_at(CLINT_TIME_LO + 200);
  while (nlog == 0) __asm__ volatile("wfi");
  ok("wfi loop woken by the timer", log_cause[0] == IRQ(7));

  // ---- precise interrupts under load --------------------------------------
  static uint32_t buf_a[64], buf_b[64];
  for (int i = 0; i < 64; i++) buf_a[i] = buf_b[i] = (uint32_t)i * 0x01000193u;
  CSRC(mstatus, MSTATUS_MIE);
  uint32_t quiet = busy_loop(buf_a, 2000);
  uint32_t t0 = ntraps;
  period = 97;                               // not a multiple of the loop length
  CSRS(mstatus, MSTATUS_MIE);
  timer_at(CLINT_TIME_LO + period);
  CLINT_MSIP = 1;                            // and one of each other kind on the way in
  EXT_IRQ = 1;
  uint32_t noisy = busy_loop(buf_b, 2000);
  period = 0;
  timer_disarm();
  uint32_t n = ntraps - t0;
  int same = quiet == noisy;
  for (int i = 0; i < 64; i++) same &= buf_a[i] == buf_b[i];
  printf_("  %-46s %u interrupts\n", "busy loop, timer every 97 cycles", n);
  ok("  ... same checksum and memory as undisturbed", same && n > 500);

  CSRC(mstatus, MSTATUS_MIE);
  CSRW(mie, 0);
  printf_("irqtest: %d failures\n", fails);
  return fails;
}
