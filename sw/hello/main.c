#include "rt.h"

int main(void) {
  uint32_t c0 = rdcycle(), i0 = rdinstret();
  puts_("Hello from risc-v-core!\n");
  uint32_t c1 = rdcycle(), i1 = rdinstret();
  printf_("printing that took %u cycles, %u instructions\n", c1 - c0, i1 - i0);
  LEDS = 0xA5;
  return 0;
}
