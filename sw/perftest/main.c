// Directed test for the hardware performance counters (hpmcounter3..9) and
// the branch predictors.
//
// Each kernel in kernels.S has known event counts. Counts that don't depend
// on the core's configuration (load-use stalls, branches, taken branches,
// jumps) are checked exactly. Misprediction counts depend on which predictor
// this build has (read from the mconfig CSR): they're exact for the
// deterministic schemes and bounded for the dynamic ones, whose tables may
// start warm or cold. With very small tables, unrelated branches share
// counters (destructive aliasing) and no useful bound exists, so misprediction
// counts are only reported. Two identities are checked for every kernel:
//   flush cycles = branch mispredictions + jump redirects
//   cycles       = instructions + load-use + multiply-use + divider stalls
//                  + I-cache + D-cache stalls + flush cycles + constant
// Each kernel runs twice and the second (warm) run is measured, so cold
// instruction-cache misses in the measurement code itself can't skew it. On a
// cached configuration the loops still take data misses; the counts above
// don't change, and the identity accounts for the cache stalls.
#include "rt.h"

#define N 100

enum { CYC, LU, FLUSH, BR, TAKEN, JUMPS, MISP, JREDIR, MU, DIV, ICS, DCS, NEV };
static const char *names[NEV] = {"cycles", "load-use", "flush", "branches", "taken",
                                 "jumps", "mispredicts", "jump redirects", "mul-use",
                                 "divider stalls", "I-cache stalls", "D-cache stalls"};

// Divider latency (rv_divider.sv): one cycle to start plus one per quotient
// bit; divide by zero finishes in the start cycle
#define DIV_CYCLES      33
#define DIV_ZERO_CYCLES 1

void k1(uint32_t d[NEV]);
void k2(uint32_t d[NEV]);
void k3(uint32_t d[NEV]);
void k4(uint32_t d[NEV]);
void k5(uint32_t d[NEV]);
void k6(uint32_t d[NEV]);
void k7(uint32_t d[NEV]);
void k8(uint32_t d[NEV]);
void k9(uint32_t d[NEV]);

// mconfig layout (see rv_core.sv)
struct cfg { int early_jal, bpred, ras_depth, ibtb_bits, bht_bits, ghr_bits, m_ext; };
enum { BP_NOT_TAKEN, BP_BTFN, BP_BIMODAL, BP_GSHARE };
static const char *bp_names[] = {"not-taken", "BTFN", "bimodal", "gshare"};

static struct cfg read_cfg(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, 0xFC0" : "=r"(v));
  struct cfg c = {(int)(v & 1), (int)((v >> 1) & 7), (int)((v >> 4) & 0xFF),
                  (int)((v >> 12) & 0xF), (int)((v >> 16) & 0xF), (int)((v >> 20) & 0xF),
                  (int)((v >> 24) & 0x3)};
  return c;
}

struct range { uint32_t lo, hi; };
#define EXACT(x) ((struct range){(x), (x)})
static struct range radd(struct range a, struct range b) {
  return (struct range){a.lo + b.lo, a.hi + b.hi};
}

// Dynamic predictors with tables this small alias too much to bound
#define MIN_BHT_BITS 6
static int aliasing(const struct cfg *c) {
  return c->bpred >= BP_BIMODAL && c->bht_bits < MIN_BHT_BITS;
}
#define ANY ((struct range){0, 0xFFFFFFFFu / 4})

// Mispredictions of a counted loop's closing branch (taken N-1 times, then not)
static struct range loop_misp(const struct cfg *c) {
  if (aliasing(c)) return ANY;
  switch (c->bpred) {
    case BP_NOT_TAKEN: return EXACT(N - 1);
    case BP_BTFN:      return EXACT(1);                      // only the exit
    case BP_BIMODAL:   return (struct range){1, 3};          // warm-up + exit
    default:           return (struct range){1, 12};         // history warm-up + exit
  }
}

// Mispredictions of a forward branch that is never taken
static struct range never_misp(const struct cfg *c) {
  if (aliasing(c)) return ANY;
  switch (c->bpred) {
    case BP_NOT_TAKEN:
    case BP_BTFN:      return EXACT(0);
    case BP_BIMODAL:   return (struct range){0, 2};
    default:           return (struct range){0, 12};
  }
}

// Mispredictions of a forward branch alternating T/N (taken N/2 times)
static struct range alt_misp(const struct cfg *c) {
  if (aliasing(c)) return ANY;
  switch (c->bpred) {
    case BP_NOT_TAKEN:
    case BP_BTFN:      return EXACT(N / 2);                  // every taken one
    case BP_BIMODAL:   return (struct range){N / 2 - 10, N}; // 2-bit counter can't follow it
    default:           return (struct range){0, 20};         // history learns the pattern
  }
}

// Jump redirects for N calls (JAL) + N returns (JALR)
static struct range call_ret_redirects(const struct cfg *c) {
  struct range jal = EXACT(c->early_jal ? 0 : N);
  // Calls and returns are balanced, so every return pops exactly the address
  // its call pushed, whatever was on the stack before: no misses at all.
  struct range ret = c->ras_depth ? EXACT(0)
                   : c->ibtb_bits ? (struct range){0, 2}
                   : EXACT(N);
  return radd(jal, ret);
}

struct test {
  const char *name;
  void (*fn)(uint32_t *);
  uint32_t insns;
  uint32_t lu, br, taken, jumps, mu, div;   // exact
  struct range misp, jredir;         // configuration dependent
};

int main(void) {
  struct cfg c = read_cfg();
  printf_("perftest: early_jal=%d bpred=%s bht_bits=%d ghr_bits=%d ras=%d ibtb_bits=%d m_ext=%d\n",
          c.early_jal, c.bpred < 4 ? bp_names[c.bpred] : "?", c.bht_bits, c.ghr_bits,
          c.ras_depth, c.ibtb_bits, c.m_ext);
  if (aliasing(&c))
    printf_("  (tables under %d index bits alias: mispredicts reported, not bounded)\n",
            MIN_BHT_BITS);

  struct range none = EXACT(0);
  const struct test tests[] = {
    {"k1 load-use",         k1, 4 * N,          N,     N,     N - 1,           0, 0, 0, loop_misp(&c), none},
    {"k2 load + gap",       k2, 4 * N,          0,     N,     N - 1,           0, 0, 0, loop_misp(&c), none},
    {"k3 rs2 / store data", k3, 6 * N,          2 * N, N,     N - 1,           0, 0, 0, loop_misp(&c), none},
    {"k4 call / return",    k4, 5 * N,          0,     N,     N - 1,           2 * N, 0, 0, loop_misp(&c), call_ret_redirects(&c)},
    {"k5 load to x0",       k5, 4 * N,          0,     N,     N - 1,           0, 0, 0, loop_misp(&c), none},
    {"k6 never taken",      k6, 4 * N,          0,     2 * N, N - 1,           0, 0, 0, radd(loop_misp(&c), never_misp(&c)), none},
    {"k7 alternating",      k7, 5 * N - N / 2,  0,     2 * N, N - 1 + N / 2,   0, 0, 0, radd(loop_misp(&c), alt_misp(&c)), none},
    // two multiplies per iteration, the first one consumed immediately
    {"k8 multiply-use",     k8, 6 * N,          0,     2 * N, N - 1,           0, N, 0, radd(loop_misp(&c), never_misp(&c)), none},
    {"k9 divide",           k9, 5 * N,          0,     N,     N - 1,           0, 0, N * (DIV_CYCLES + DIV_ZERO_CYCLES), loop_misp(&c), none},
  };
  unsigned ntests = sizeof tests / sizeof tests[0];
  if (c.m_ext < 2) ntests--;            // k9 needs a divider
  if (c.m_ext < 1) ntests--;            // k8 needs a multiplier

  int fails = 0;
  int32_t slack0 = 0;
  for (unsigned t = 0; t < ntests; t++) {
    const struct test *T = &tests[t];
    uint32_t d[NEV];
    T->fn(d);                // warm-up
    T->fn(d);
    int ok = 1;

    uint32_t exact[NEV] = {0, T->lu, 0, T->br, T->taken, T->jumps, 0, 0, T->mu, T->div, 0, 0};
    for (int k = LU; k < NEV; k++) {
      if (k == FLUSH || k == MISP || k == JREDIR || k == ICS || k == DCS) continue;
      if (d[k] != exact[k]) {
        printf_("  FAIL %s: %s = %u, expected %u\n", T->name, names[k], d[k], exact[k]);
        ok = 0;
      }
    }
    if (d[MISP] < T->misp.lo || d[MISP] > T->misp.hi) {
      printf_("  FAIL %s: mispredicts = %u, expected %u..%u\n", T->name, d[MISP],
              T->misp.lo, T->misp.hi);
      ok = 0;
    }
    if (d[JREDIR] < T->jredir.lo || d[JREDIR] > T->jredir.hi) {
      printf_("  FAIL %s: jump redirects = %u, expected %u..%u\n", T->name, d[JREDIR],
              T->jredir.lo, T->jredir.hi);
      ok = 0;
    }
    if (d[FLUSH] != d[MISP] + d[JREDIR]) {
      printf_("  FAIL %s: flush %u != mispredicts %u + jump redirects %u\n", T->name,
              d[FLUSH], d[MISP], d[JREDIR]);
      ok = 0;
    }
    // Cycle accounting: the snapshot code adds the same constant to every kernel
    int32_t slack = (int32_t)(d[CYC] - (T->insns + d[LU] + d[MU] + d[DIV] + d[ICS] + d[DCS] +
                                        d[FLUSH]));
    if (t == 0) slack0 = slack;
    printf_("  %-20s cycles=%u = %u insns + %u ld-use + %u mul-use + %u div + %u I$ + %u D$ + %u flush (%u misp + %u jump) + %d\n",
            T->name, d[CYC], T->insns, d[LU], d[MU], d[DIV], d[ICS], d[DCS], d[FLUSH], d[MISP],
            d[JREDIR], slack);
    // The counters are read one after another, not at the same instant, so an
    // instruction-cache miss in the middle of the reads (the measurement code
    // can be evicted by the caller between runs) lands in some counters'
    // windows and not others. Allow exactly that much; everything else must
    // match exactly. (mcountinhibit, once CSR writes exist, would remove this.)
    int32_t dev = slack - slack0;
    if (dev < 0) dev = -dev;
    if ((uint32_t)dev > d[ICS] || slack0 < 0 || slack0 > 16) {
      printf_("  FAIL %s: cycle accounting constant %d differs (expected %d)\n", T->name,
              slack, slack0);
      ok = 0;
    }
    fails += !ok;
  }
  printf_("perftest: %d failures\n", fails);
  return fails;
}
