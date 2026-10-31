// Minimal freestanding runtime: UART output, a tiny printf, and the libgcc
// helpers that clang emits calls to on RV32I (no hardware multiply/divide).
#include <stdarg.h>
#include "rt.h"

void putchar_(char c) {
  while (UART_STAT & 1) { }
  UART_DATA = (uint8_t)c;
}

void puts_(const char *s) {
  while (*s) putchar_(*s++);
}

static void print_uint(uint32_t v, unsigned base, int width, char pad) {
  char buf[12];
  int n = 0;
  do {
    unsigned d = v % base;
    buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    v /= base;
  } while (v);
  while (n < width) { putchar_(pad); width--; }
  while (n) putchar_(buf[--n]);
}

void printf_(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  for (; *fmt; fmt++) {
    if (*fmt != '%') { putchar_(*fmt); continue; }
    fmt++;
    char pad = ' ';
    int width = 0, left = 0;
    if (*fmt == '-') { left = 1; fmt++; }
    if (*fmt == '0') { pad = '0'; fmt++; }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    switch (*fmt) {
      case 'd': {
        int32_t v = va_arg(ap, int32_t);
        if (v < 0) { putchar_('-'); v = -v; if (width) width--; }
        print_uint((uint32_t)v, 10, width, pad);
        break;
      }
      case 'u': print_uint(va_arg(ap, uint32_t), 10, width, pad); break;
      case 'x': print_uint(va_arg(ap, uint32_t), 16, width, pad); break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        int len = 0;
        while (s[len]) len++;
        if (!left) for (int k = len; k < width; k++) putchar_(' ');
        puts_(s);
        if (left)  for (int k = len; k < width; k++) putchar_(' ');
        break;
      }
      case 'c': putchar_((char)va_arg(ap, int)); break;
      case '%': putchar_('%'); break;
      default: break;
    }
  }
  va_end(ap);
}

void *memcpy(void *dst, const void *src, size_t n) {
  uint8_t *d = dst;
  const uint8_t *s = src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  uint8_t *d = dst;
  while (n--) *d++ = (uint8_t)c;
  return dst;
}

// ---- libgcc integer helpers (only used when the core lacks the M extension)
#ifndef HAVE_M_EXT
uint32_t __mulsi3(uint32_t a, uint32_t b) {
  uint32_t r = 0;
  while (b) {
    if (b & 1) r += a;
    a <<= 1;
    b >>= 1;
  }
  return r;
}

static uint32_t udivmod(uint32_t n, uint32_t d, uint32_t *rem) {
  if (d == 0) { *rem = n; return 0xFFFFFFFFu; }
  uint32_t q = 0, r = 0;
  for (int i = 31; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) { r -= d; q |= 1u << i; }
  }
  *rem = r;
  return q;
}

uint32_t __udivsi3(uint32_t n, uint32_t d) { uint32_t r; return udivmod(n, d, &r); }
uint32_t __umodsi3(uint32_t n, uint32_t d) { uint32_t r; udivmod(n, d, &r); return r; }

int32_t __divsi3(int32_t n, int32_t d) {
  int neg = (n < 0) ^ (d < 0);
  uint32_t r;
  uint32_t q = udivmod(n < 0 ? -(uint32_t)n : (uint32_t)n,
                       d < 0 ? -(uint32_t)d : (uint32_t)d, &r);
  return neg ? -(int32_t)q : (int32_t)q;
}

int32_t __modsi3(int32_t n, int32_t d) {
  uint32_t r;
  udivmod(n < 0 ? -(uint32_t)n : (uint32_t)n,
          d < 0 ? -(uint32_t)d : (uint32_t)d, &r);
  return n < 0 ? -(int32_t)r : (int32_t)r;
}
#endif
