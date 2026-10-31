// Cold-cache check: the very first data loads after reset read code as data
// (crt0 starts with li x1, 0 = 0x00000093 and li x3, 0 = 0x00000193). This
// program has almost no data, so these loads hit sets the data cache has
// never filled - a cache that hits on a line it never filled (e.g. by
// ignoring the valid bit) returns garbage here. Larger programs can't test
// this: startup code clearing .bss fills every set first.
#include "rt.h"

int main(void) {
  uint32_t w0 = *(volatile uint32_t *)0;
  uint32_t w1 = *(volatile uint32_t *)4;
  int ok = (w0 == 0x00000093) && (w1 == 0x00000193);
  printf_("coldload: %08x %08x %s\n", w0, w1, ok ? "ok" : "FAIL");
  printf_("coldload: %d failures\n", !ok);
  return !ok;
}
