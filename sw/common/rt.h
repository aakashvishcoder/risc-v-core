#ifndef RT_H
#define RT_H

#include <stdint.h>
#include <stddef.h>

#define UART_DATA (*(volatile uint32_t *)0x10000000u)
#define UART_STAT (*(volatile uint32_t *)0x10000004u)
#define SIM_EXIT  (*(volatile uint32_t *)0x10000008u)
#define LEDS      (*(volatile uint32_t *)0x1000000Cu)

static inline uint32_t rdcycle(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, cycle" : "=r"(v));
  return v;
}

static inline uint32_t rdinstret(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, instret" : "=r"(v));
  return v;
}

void putchar_(char c);
void puts_(const char *s);
void printf_(const char *fmt, ...);

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

#endif
