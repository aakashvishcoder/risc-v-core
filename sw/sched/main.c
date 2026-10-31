// Preemptive round-robin scheduler demo.
//
// Three tasks, each with its own stack, share the core. The CLINT timer
// interrupts every SLICE cycles; the trap handler (switch.S) saves the running
// task's registers on its stack and resumes the next task. A task that has
// finished gives up the core with ecall.
//
// The same three computations first run back to back with interrupts off, as
// a reference; then they run time-sliced, and every result must match. That
// is the point of precise interrupts: a task can be stopped between any two
// instructions - in a divide's shadow, behind a cache miss, in a branch's
// delay - and resumed hundreds of times without noticing.
#include "rt.h"

#define CSRS(csr, v) __asm__ volatile("csrs " #csr ", %0" :: "r"(v) : "memory")
#define CSRC(csr, v) __asm__ volatile("csrc " #csr ", %0" :: "r"(v) : "memory")
#define CSRW(csr, v) __asm__ volatile("csrw " #csr ", %0" :: "r"(v) : "memory")

#define CLINT_CMP_LO   (*(volatile uint32_t *)0x02004000u)
#define CLINT_CMP_HI   (*(volatile uint32_t *)0x02004004u)
#define CLINT_TIME_LO  (*(volatile uint32_t *)0x0200BFF8u)

#define SLICE   3000          // cycles per time slice
#define NTASKS  3
#define STACK_WORDS 512

void trap_switch(void);
void start_first(uint32_t *sp);

// ---- the work ---------------------------------------------------------------
static uint32_t count_primes(uint32_t limit) {
  uint32_t n = 0;
  for (uint32_t k = 2; k < limit; k++) {
    int prime = 1;
    for (uint32_t d = 2; d * d <= k; d++)
      if (k % d == 0) { prime = 0; break; }
    n += prime;
  }
  return n;
}

static uint32_t collatz_longest(uint32_t limit) {   // start value with the longest chain
  uint32_t best = 1, best_len = 0;
  for (uint32_t s = 1; s < limit; s++) {
    uint32_t x = s, len = 0;
    while (x != 1) { x = (x & 1) ? 3 * x + 1 : x / 2; len++; }
    if (len > best_len) { best_len = len; best = s; }
  }
  return best * 1000 + best_len;
}

static uint32_t sort_checksum(uint32_t n) {        // insertion sort of n pseudo-random words
  static uint32_t v[256];
  uint32_t x = 2463534242u;
  for (uint32_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; v[i] = x; }
  for (uint32_t i = 1; i < n; i++) {
    uint32_t t = v[i], j = i;
    while (j > 0 && v[j - 1] > t) { v[j] = v[j - 1]; j--; }
    v[j] = t;
  }
  uint32_t h = 0;
  for (uint32_t i = 0; i < n; i++) {
    if (i && v[i - 1] > v[i]) return 0;            // not sorted
    h = h * 31 + v[i];
  }
  return h;
}

// ---- tasks ------------------------------------------------------------------
struct task {
  const char *name;
  uint32_t (*fn)(uint32_t);
  uint32_t arg;
  uint32_t *sp;            // saved frame while not running
  uint32_t result, expect;
  uint32_t slices;         // times it was given the core
  int done;
};
static struct task tasks[NTASKS] = {
  {"primes", count_primes, 3000},
  {"collatz", collatz_longest, 600},
  {"sort", sort_checksum, 250},
};
static uint32_t stacks[NTASKS][STACK_WORDS];
static int current;
static uint32_t switches;

// printf from a task: interrupts off so lines don't interleave
static void say(const char *fmt, uint32_t a, uint32_t b) {
  CSRC(mstatus, 8);
  printf_(fmt, a, b);
  CSRS(mstatus, 8);
}

static void task_body(void) {
  struct task *t = &tasks[current];
  say("  [%s] started (slice %u)\n", (uint32_t)t->name, t->slices);
  t->result = t->fn(t->arg);
  say("  [%s] finished: %u\n", (uint32_t)t->name, t->result);
  t->done = 1;
  for (;;) __asm__ volatile("ecall");              // yield forever
}

static void timer_rearm(void) {
  CLINT_CMP_HI = 0xFFFFFFFFu;
  CLINT_CMP_LO = CLINT_TIME_LO + SLICE;
  CLINT_CMP_HI = 0;
}

static void finish(void) {
  CLINT_CMP_HI = 0xFFFFFFFFu;
  int fails = 0;
  printf_("sched: all tasks done after %u context switches\n", switches);
  for (int i = 0; i < NTASKS; i++) {
    int ok = tasks[i].result == tasks[i].expect;
    printf_("  %-8s result %10u  reference %10u  ran in %3u slices  %s\n", tasks[i].name,
            tasks[i].result, tasks[i].expect, tasks[i].slices, ok ? "ok" : "FAIL");
    fails += !ok;
  }
  printf_("sched: %d failures\n", fails);
  SIM_EXIT = fails;
  for (;;) {}
}

// Called by trap_switch with the interrupted task's frame
uint32_t *schedule(uint32_t *sp, uint32_t mcause) {
  tasks[current].sp = sp;
  if (mcause == 11) sp[0] += 4;                    // ecall: resume after it
  else if (mcause == 0x80000007u) timer_rearm();
  else {                                           // anything else is a bug
    printf_("sched: unexpected trap %08x at %08x\n", mcause, sp[0]);
    SIM_EXIT = 0x100 | (mcause & 0xFF);
  }
  int all_done = 1;
  for (int i = 0; i < NTASKS; i++) all_done &= tasks[i].done;
  if (all_done) finish();
  do current = (current + 1) % NTASKS; while (tasks[current].done);
  if (mcause == 11) timer_rearm();                 // a fresh slice for the next task
  tasks[current].slices++;
  switches++;
  return tasks[current].sp;
}

int main(void) {
  printf_("sched: reference run, interrupts off\n");
  for (int i = 0; i < NTASKS; i++) {
    tasks[i].expect = tasks[i].fn(tasks[i].arg);
    printf_("  %-8s %u\n", tasks[i].name, tasks[i].expect);
  }

  // Each task starts as if it had been interrupted just before task_body
  for (int i = 0; i < NTASKS; i++) {
    uint32_t *f = &stacks[i][STACK_WORDS - 32];
    for (int r = 0; r < 32; r++) f[r] = 0;
    f[0] = (uint32_t)task_body;                    // mepc
    tasks[i].sp = f;
  }
  printf_("sched: 3 tasks, timer slice %u cycles\n", SLICE);
  CSRW(mtvec, (uint32_t)trap_switch);
  CSRW(mie, 1u << 7);                              // timer only
  current = 0;
  tasks[0].slices = 1;
  timer_rearm();
  start_first(tasks[0].sp);                        // never returns
  return 1;
}
