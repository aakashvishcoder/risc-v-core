// Memory-hierarchy benchmark: access patterns CoreMark (2 KB of data) doesn't
// have. Each kernel reports its cycles and the cache counters, and all of them
// fold their data into a checksum that co-simulation verifies.
//
//   stream   sequential reads of a 16 KB array (spatial locality)
//   stride   one read per 64 bytes over 16 KB (no spatial locality)
//   conflict two 4 KB halves exactly 8 KB apart, read alternately: they map
//            to the same sets in any cache of 8 KB or less, so a direct-mapped
//            cache thrashes and a 2-way cache doesn't
//   copy     16 KB -> 16 KB copy (every line is written: dirty evictions)
//   chase    pointer chase over a 4 KB ring (dependent loads, temporal reuse)
#include "rt.h"

#define WORDS 4096                        // 16 KB arrays
static uint32_t a[WORDS] __attribute__((aligned(16)));
static uint32_t b[WORDS] __attribute__((aligned(16)));
static uint32_t ring[1024] __attribute__((aligned(16)));

#define CSRR(name) ({ uint32_t v_; __asm__ volatile("csrr %0, " #name : "=r"(v_)); v_; })

struct snap { uint32_t cyc, ins, ims, dms, dwb; };
static void snap(struct snap *s) {
  s->cyc = CSRR(cycle);
  s->ins = CSRR(instret);
  s->ims = CSRR(hpmcounter14);   // I-cache misses   (0 without caches)
  s->dms = CSRR(hpmcounter15);   // D-cache misses
  s->dwb = CSRR(hpmcounter16);   // D-cache writebacks
}

static uint32_t total_cycles;
static void report(const char *name, struct snap *s0, uint32_t accesses) {
  struct snap s1;
  snap(&s1);
  uint32_t cyc = s1.cyc - s0->cyc;
  total_cycles += cyc;
  printf_("  %-9s %7u cycles  %6u accesses  D-miss %5u  writebacks %5u  I-miss %3u\n",
          name, cyc, accesses, s1.dms - s0->dms, s1.dwb - s0->dwb, s1.ims - s0->ims);
}

int main(void) {
  uint32_t sum = 0;
  struct snap s;

  for (int i = 0; i < WORDS; i++) a[i] = i * 2654435761u;
  for (int i = 0; i < 1024; i++) ring[i] = (i * 389 + 1) % 1024;   // a permutation cycle

  printf_("memstream:\n");
  snap(&s);
  for (int i = 0; i < WORDS; i++) sum += a[i];
  report("stream", &s, WORDS);

  snap(&s);
  for (int i = 0; i < WORDS; i += 16) sum += a[i];
  report("stride", &s, WORDS / 16);

  // a[i] and a[i + 2048] are exactly 8 KB apart
  snap(&s);
  for (int r = 0; r < 4; r++)
    for (int i = 0; i < 1024; i++) sum += a[i] + a[i + 2048];
  report("conflict", &s, 4 * 2048);

  snap(&s);
  for (int i = 0; i < WORDS; i++) b[i] = a[i] ^ i;
  report("copy", &s, 2 * WORDS);

  snap(&s);
  uint32_t p = 0;
  for (int i = 0; i < 4096; i++) p = ring[p];
  sum += p;
  report("chase", &s, 4096);

  for (int i = 0; i < WORDS; i += 7) sum += b[i];
  printf_("memstream: total %u cycles, checksum %08x\n", total_cycles, sum);
  return 0;
}
