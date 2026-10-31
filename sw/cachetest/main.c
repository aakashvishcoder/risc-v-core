// Directed cache test: exact miss and writeback counts derived from the
// cache geometry (mcache CSR), plus a data-integrity check that forces dirty
// lines out and back in. Passes trivially on a core without caches.
#include "rt.h"

#define CSRR(name) ({ uint32_t v_; __asm__ volatile("csrr %0, " #name : "=r"(v_)); v_; })

uint32_t c_seq(uintptr_t r0, uintptr_t r1, uint32_t lines);
uint32_t c_reread(uintptr_t r0, uintptr_t r1, uint32_t lines);
uint32_t c_dirty(uintptr_t r0, uintptr_t r1, uintptr_t r2, uint32_t lines);
uint32_t c_conflict(uintptr_t r0, uint32_t lines, uintptr_t base, uint32_t span,
                    uint32_t k, uint32_t rounds);
uint32_t ic_measure(uint32_t passes);

// 32 KB, aligned so every region below starts on a set boundary
static uint32_t buf[8192] __attribute__((aligned(16384)));

static int fails;
static void check(const char *name, uint32_t r, uint32_t misses, uint32_t wbs) {
  uint32_t m = r & 0xFFFF, w = r >> 16;
  int ok = (m == misses && w == wbs);
  printf_("  %-34s misses %5u (expect %5u)  writebacks %5u (expect %5u)  %s\n", name, m,
          misses, w, wbs, ok ? "ok" : "FAIL");
  fails += !ok;
}

int main(void) {
  uint32_t mc = CSRR(0xFC1);
  if (!(mc & 1)) {
    printf_("cachetest: no caches, skipped\ncachetest: 0 failures\n");
    return 0;
  }
  uint32_t ic_lines = 1u << ((mc >> 4) & 0xF);
  uint32_t dc_sets_log2 = (mc >> 8) & 0xF;
  uint32_t ways = 1u << ((mc >> 12) & 0xF);
  int has_dcache = dc_sets_log2 != 0;
  printf_("cachetest: I-cache %u lines; D-cache %s", ic_lines, has_dcache ? "" : "none");
  if (has_dcache) printf_("%u sets x %u ways", 1u << dc_sets_log2, ways);
  printf_("; memory latency %u\n", mc >> 16);

  // ---- instruction cache: a 16-line loop
  uint32_t passes = 4;
  ic_measure(1);                                   // warm up
  uint32_t im = ic_measure(passes);
  uint32_t expect_im = ic_lines >= 16 ? 0 : 16 * passes;   // fits, or thrashes every line
  printf_("  %-34s misses %5u (expect %5u)  %s\n", "I: 256-byte loop, 4 warm passes", im,
          expect_im, im == expect_im ? "ok" : "FAIL");
  fails += im != expect_im;

  if (has_dcache) {
    uint32_t sets = 1u << dc_sets_log2;
    uint32_t lines = sets * ways;                  // lines in the cache
    uint32_t size = lines * 16;                    // bytes
    uint32_t span = sets * 16;                     // one way: addresses this far apart share a set
    if (4 * size > sizeof buf) {
      printf_("  D-cache larger than the test buffer allows, skipped\n");
    } else {
      uintptr_t r0 = (uintptr_t)buf, r1 = r0 + size, r2 = r1 + size, r3 = r2 + size;
      check("D: read 1 cache-size, clean", c_seq(r0, r1, lines), lines, 0);
      check("D: re-read the same region", c_reread(r0, r1, lines), 0, 0);
      check("D: read over dirty lines", c_dirty(r0, r1, r2, lines), lines, lines);
      check("D: k = ways addresses in one set", c_conflict(r0, lines, r3, span, ways, 50),
            ways, 0);
      check("D: k = ways+1 addresses in one set", c_conflict(r0, lines, r3, span, ways + 1, 50),
            (ways + 1) * 50, 0);

      // Data integrity: 2 cache-sizes of writes, then read back
      uint32_t n = 2 * size / 4;
      for (uint32_t i = 0; i < n; i++) buf[i] = i * 2654435761u + 7;
      uint32_t bad = 0;
      for (uint32_t i = 0; i < n; i++) bad += buf[i] != i * 2654435761u + 7;
      // byte and halfword stores into lines that get evicted and refilled
      uint8_t *b8 = (uint8_t *)buf;
      for (uint32_t i = 0; i < 2 * size; i += 5) b8[i] = (uint8_t)(i * 3);
      for (uint32_t i = 0; i < 2 * size; i += 5) bad += b8[i] != (uint8_t)(i * 3);
      printf_("  %-34s %u mismatches  %s\n", "D: write/read back 2 cache-sizes", bad,
              bad ? "FAIL" : "ok");
      fails += bad != 0;
    }
  }
  printf_("cachetest: %d failures\n", fails);
  return fails;
}
