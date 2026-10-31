// Directed M-extension test: results the RISC-V spec defines exactly,
// including the corner cases that are easy to get wrong in hardware.
//   - MULH / MULHSU / MULHU sign handling on the extreme operands
//   - divide by zero and signed overflow (no traps in RISC-V: fixed results)
//   - quotient truncates toward zero; remainder takes the dividend's sign
// Built with MARCH=rv32i_zmmul (multiply only) or rv32im (divide too).
#include "rt.h"

typedef uint32_t (*binop)(uint32_t, uint32_t);
#define OP(name, insn) \
  static uint32_t name(uint32_t a, uint32_t b) { uint32_t r; \
    __asm__ volatile(insn " %0, %1, %2" : "=r"(r) : "r"(a), "r"(b)); return r; }

OP(op_mul, "mul") OP(op_mulh, "mulh") OP(op_mulhsu, "mulhsu") OP(op_mulhu, "mulhu")
#ifdef HAVE_DIV
OP(op_div, "div") OP(op_divu, "divu") OP(op_rem, "rem") OP(op_remu, "remu")
#endif

struct vec { const char *name; binop f; uint32_t a, b, expect; };

#define MIN 0x80000000u
#define NEG1 0xFFFFFFFFu

static const struct vec tests[] = {
  {"mul  low word",        op_mul,    0x12345678, 0x9ABCDEF0, 0x242D2080},
  {"mul  -1 * -1",         op_mul,    NEG1,       NEG1,       1},
  {"mul  wraps",           op_mul,    MIN,        2,          0},
  {"mulh -1 * -1",         op_mulh,   NEG1,       NEG1,       0},
  {"mulh MIN * MIN",       op_mulh,   MIN,        MIN,        0x40000000},
  {"mulh MIN * -1",        op_mulh,   MIN,        NEG1,       0},
  {"mulh -1 * 1",          op_mulh,   NEG1,       1,          NEG1},
  {"mulhu max * max",      op_mulhu,  NEG1,       NEG1,       0xFFFFFFFE},
  {"mulhu MIN * 2",        op_mulhu,  MIN,        2,          1},
  {"mulhsu -1 * max",      op_mulhsu, NEG1,       NEG1,       NEG1},
  {"mulhsu MIN * max",     op_mulhsu, MIN,        NEG1,       MIN},
  {"mulhsu 1 * max",       op_mulhsu, 1,          NEG1,       0},
#ifdef HAVE_DIV
  {"div  by zero",         op_div,    7,          0,          NEG1},
  {"divu by zero",         op_divu,   7,          0,          NEG1},
  {"rem  by zero",         op_rem,    0xFFFFFFF9, 0,          0xFFFFFFF9},
  {"remu by zero",         op_remu,   7,          0,          7},
  {"div  MIN / -1",        op_div,    MIN,        NEG1,       MIN},
  {"rem  MIN / -1",        op_rem,    MIN,        NEG1,       0},
  {"div  -7 / 2",          op_div,    0xFFFFFFF9, 2,          0xFFFFFFFD},
  {"rem  -7 / 2",          op_rem,    0xFFFFFFF9, 2,          NEG1},
  {"div  7 / -2",          op_div,    7,          0xFFFFFFFE, 0xFFFFFFFD},
  {"rem  7 / -2",          op_rem,    7,          0xFFFFFFFE, 1},
  {"div  -7 / -2",         op_div,    0xFFFFFFF9, 0xFFFFFFFE, 3},
  {"rem  -7 / -2",         op_rem,    0xFFFFFFF9, 0xFFFFFFFE, NEG1},
  {"divu max / 3",         op_divu,   NEG1,       3,          0x55555555},
  {"remu max / 7",         op_remu,   NEG1,       7,          3},
  {"divu MIN / max",       op_divu,   MIN,        NEG1,       0},
  {"div  small / big",     op_div,    5,          100,        0},
  {"rem  small / big",     op_rem,    0xFFFFFFFB, 100,        0xFFFFFFFB},
  {"divu x / 1",           op_divu,   0xDEADBEEF, 1,          0xDEADBEEF},
#endif
};

int main(void) {
  int fails = 0;
  unsigned n = sizeof tests / sizeof tests[0];
  for (unsigned i = 0; i < n; i++) {
    uint32_t got = tests[i].f(tests[i].a, tests[i].b);
    if (got != tests[i].expect) {
      printf_("FAIL %s: got %08x, expected %08x\n", tests[i].name, got, tests[i].expect);
      fails++;
    }
  }
  // Back-to-back dependent multiplies: every one waits on the previous result
  uint32_t x = 3;
  for (int i = 0; i < 20; i++) x = op_mul(op_mul(x, 7), x) + 1;
  if (x != 0xfd7479c1) { printf_("FAIL mul chain: %08x\n", x); fails++; }
#ifdef HAVE_DIV
  uint32_t y = 0xFFFFFFFF;
  for (int i = 0; i < 20; i++) y = op_divu(y, 3) + op_remu(y, 7) * 5;
  if (y != 0x11) { printf_("FAIL div chain: %08x\n", y); fails++; }
#endif
  printf_("mext: %u vectors + chains, %d failures\n", n, fails);
  return fails;
}
