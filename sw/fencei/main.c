// FENCE.I (Zifencei): self-modifying code. A function in a RAM buffer is
// rewritten and called again, 32 times. On the cached memory system each
// rewrite sits in the write-back data cache and the old version is in the
// instruction cache, so FENCE.I has to write the data cache back and
// invalidate the instruction cache, or the old code runs.
#include "rt.h"

static uint32_t code[8] __attribute__((aligned(16)));

static uint32_t addi_a0(int32_t imm) {      // addi a0, x0, imm
  return ((uint32_t)(imm & 0xFFF) << 20) | (10u << 7) | 0x13u;
}

int main(void) {
  int fails = 0;
  for (int i = 0; i < 32; i++) {
    int32_t k = i * 37 - 500;
    code[0] = addi_a0(k);
    code[1] = 0x00008067;                     // ret
    __asm__ volatile("fence.i" ::: "memory");
    int32_t got = ((int32_t (*)(void))code)();
    if (got != k) {
      printf_("  rewrite %d: function returned %d, expected %d\n", i, got, k);
      fails++;
    }
  }
  // Rewrite the instruction right after the FENCE.I: by the time the store
  // executes, that instruction has already been fetched, so FENCE.I must
  // throw it away and fetch it again
  for (int i = 0; i < 8; i++) {
    register int32_t got __asm__("a0");      // the rewritten instruction writes a0
    __asm__ volatile(
        "  la   t0, 1f\n"
        "  sw   %1, 0(t0)\n"
        "  fence.i\n"
        "1: addi %0, x0, -1\n"                  // replaced by addi a0, x0, k
        : "=r"(got) : "r"(addi_a0(i * 3)) : "t0", "memory");
    if (got != i * 3) {
      printf_("  next-instruction rewrite %d: got %d, expected %d\n", i, got, i * 3);
      fails++;
    }
  }
  printf_("fencei: 32 rewrites of a function in RAM, 8 of the next instruction\n"
          "fencei: %d failures\n", fails);
  return fails;
}
