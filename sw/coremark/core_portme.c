/*
 * CoreMark port for risc-v-core.
 *
 * Timing uses the cycle CSR, so CoreMark's "ticks" are core clock cycles and
 * CoreMark/MHz = iterations * 1e6 / cycles, independent of the clock rate.
 * CLOCK_HZ only scales the seconds CoreMark prints.
 *
 * The timed region also snapshots the hardware performance counters, and
 * portable_fini() prints a CPI stack (where every cycle of the run went) and
 * branch-prediction statistics.
 */
#include "coremark.h"
#include "core_portme.h"

#ifndef CLOCK_HZ
#define CLOCK_HZ 50000000u
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define CSRR(name) ({ ee_u32 v_; __asm__ volatile("csrr %0, " #name : "=r"(v_)); v_; })

/* cycle, instret, hpmcounter3..9 */
#define NCTR 9
static ee_u32 t_start[NCTR], t_stop[NCTR];

static void snapshot(ee_u32 *s) {
  s[0] = CSRR(cycle);
  s[1] = CSRR(instret);
  s[2] = CSRR(hpmcounter3);
  s[3] = CSRR(hpmcounter4);
  s[4] = CSRR(hpmcounter5);
  s[5] = CSRR(hpmcounter6);
  s[6] = CSRR(hpmcounter7);
  s[7] = CSRR(hpmcounter8);
  s[8] = CSRR(hpmcounter9);
}

void start_time(void) { snapshot(t_start); }
void stop_time(void)  { snapshot(t_stop); }
CORE_TICKS get_time(void) { return t_stop[0] - t_start[0]; }
secs_ret time_in_secs(CORE_TICKS ticks) { return ticks / CLOCK_HZ; }

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc; (void)argv;
  p->portable_id = 1;
}

/* a / b as "x.yyy" with 32-bit integer math (no FPU, no 64-bit divide) */
static void print_ratio(const char *label, ee_u32 a, ee_u32 b) {
  ee_u32 whole = a / b, r = a % b, frac = 0;
  for (int i = 0; i < 3; i++) { r *= 10; frac = frac * 10 + r / b; r %= b; }
  ee_printf("%s%u.%u%u%u\n", label, (unsigned)whole, (unsigned)(frac / 100),
            (unsigned)(frac / 10 % 10), (unsigned)(frac % 10));
}

/* part / whole as a percentage with one decimal, by long division so it stays
 * in 32 bits (valid while whole < 429M) */
static void print_pct(const char *label, ee_u32 part, ee_u32 whole) {
  ee_u32 r = part, permille = 0;
  for (int i = 0; i < 3; i++) { r *= 10; permille = permille * 10 + r / whole; r %= whole; }
  if (part >= whole) permille = 1000;
  ee_printf("  %s %u (%u.%u%%)\n", label, (unsigned)part, (unsigned)(permille / 10),
            (unsigned)(permille % 10));
}

void portable_fini(core_portable *p) {
  p->portable_id = 0;
  ee_u32 d[NCTR];
  for (int i = 0; i < NCTR; i++) d[i] = t_stop[i] - t_start[i];
  ee_u32 cycles = d[0], insns = d[1];
  ee_u32 other = cycles - insns - d[2] - d[3];

  ee_printf("\nrisc-v-core: %u iterations, %u cycles, %u instructions\n",
            (unsigned)ITERATIONS, (unsigned)cycles, (unsigned)insns);
  print_ratio("CoreMark/MHz: ", (ee_u32)ITERATIONS * 1000000u, cycles);
  print_ratio("CPI:          ", cycles, insns);
  ee_printf("CPI stack (share of cycles):\n");
  print_pct("retiring             ", insns, cycles);
  print_pct("load-use stalls      ", d[2], cycles);
  print_pct("branch/jump flushes  ", d[3], cycles);
  print_pct("other                ", other, cycles);
  ee_printf("Control flow:\n");
  print_pct("taken branches       ", d[5], d[4]);
  print_pct("mispredicted branches", d[7], d[4]);
  print_pct("redirected jumps     ", d[8], d[6]);
  ee_printf("  branches %u, jumps %u\n", (unsigned)d[4], (unsigned)d[6]);
}
