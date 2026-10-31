// Directed test for the hardware performance counters (hpmcounter3..7).
// Each kernel in kernels.S has exactly known event counts; any difference
// means the counters (or the pipeline's hazard logic) are wrong.
#include "rt.h"

#define N 100

void k1(uint32_t d[6]);
void k2(uint32_t d[6]);
void k3(uint32_t d[6]);
void k4(uint32_t d[6]);
void k5(uint32_t d[6]);

static const char *names[6] = {"cycles", "load-use", "flush", "branches", "taken", "jumps"};

struct test {
  const char *name;
  void (*fn)(uint32_t *);
  int insns_per_iter;      // instructions in the loop body
  uint32_t expect[6];      // cycles entry is checked separately (accounting identity)
};

static const struct test tests[] = {
  {"k1 load-use",          k1, 4, {0, N,     N - 1,           N, N - 1, 0}},
  {"k2 load + gap",        k2, 4, {0, 0,     N - 1,           N, N - 1, 0}},
  {"k3 rs2 / store data",  k3, 6, {0, 2 * N, N - 1,           N, N - 1, 0}},
  {"k4 call / return",     k4, 5, {0, 0,     2 * N + (N - 1), N, N - 1, 2 * N}},
  {"k5 load to x0",        k5, 4, {0, 0,     N - 1,           N, N - 1, 0}},
};

int main(void) {
  int fails = 0;
  for (unsigned t = 0; t < sizeof tests / sizeof tests[0]; t++) {
    uint32_t d[6];
    tests[t].fn(d);
    int ok = 1;
    for (int k = 1; k < 6; k++) {
      if (d[k] != tests[t].expect[k]) {
        printf_("  FAIL %s: %s = %u, expected %u\n", tests[t].name, names[k], d[k],
                tests[t].expect[k]);
        ok = 0;
      }
    }
    // Accounting identity: every cycle either retires an instruction or is
    // lost to a stall or a flush. The loop body retires insns_per_iter * N
    // instructions; the snapshot code in between contributes a small constant.
    uint32_t expected_cycles = tests[t].insns_per_iter * N + d[1] + d[2];
    int32_t slack = (int32_t)(d[0] - expected_cycles);
    printf_("  %-22s cycles=%u = %u insns + %u load-use + %u flush + %d\n", tests[t].name,
            d[0], tests[t].insns_per_iter * N, d[1], d[2], slack);
    if (slack < 0 || slack > 8) {
      printf_("  FAIL %s: cycle accounting off by %d\n", tests[t].name, slack);
      ok = 0;
    }
    fails += !ok;
  }
  printf_("perftest: %d failures\n", fails);
  return fails;
}
