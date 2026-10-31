#!/usr/bin/env python3
"""
Random RV32I(M) program generator for RTL-vs-reference co-simulation.

Programs are straight-line code with forward-only control flow, so they always
terminate. A deliberately small pool of 8 registers makes almost every
instruction depend on one of the last few, which stresses exactly the parts of
a pipeline that are easy to get wrong:

  - forwarding from MEM and WB (back-to-back ALU dependencies)
  - load-use stalls (loads followed by consumers, including branches)
  - branches on freshly computed / loaded values
  - JAL/JALR with link registers that are immediately reused
  - x0 as a source and as a destination
  - corner-case values (0, -1, INT_MIN, shift amounts >= 32, ...)

All memory traffic goes to a 256-byte scratch buffer, which is checksummed at
the end so stores are checked too.

    rand_test.py <seed> <out.S> [--n 400] [--m]
"""
import argparse
import random

POOL = ["x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12"]   # hot registers
BASE = "x31"      # scratch-buffer base pointer (never written by random code)
TMP = "x30"       # temp for JALR targets and setup

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
M_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]

INTERESTING = [0, 1, -1, 2, 0x7FFFFFFF, -0x80000000, 0x80000000,
               31, 32, 33, 0xFF, 0xFFFF, 0x8000, 0x80]


def gen(seed, n, m_ext):
    rnd = random.Random(seed)
    r = lambda: rnd.choice(POOL)
    rs = lambda: "x0" if rnd.random() < 0.1 else r()     # sometimes read x0
    rd_any = lambda: "x0" if rnd.random() < 0.05 else r()  # sometimes write x0
    fwd_label = lambda i: f"L{min(n, i + rnd.randint(1, 6))}"

    def body(i):
        if rnd.random() < 0.06:          # re-inject corner-case values mid-stream
            return f"li {r()}, {rnd.choice(INTERESTING) & 0xFFFFFFFF}"
        k = rnd.random()
        if k < 0.25:
            ops = M_OPS if (m_ext and rnd.random() < 0.3) else R_OPS
            return f"{rnd.choice(ops)} {rd_any()}, {rs()}, {rs()}"
        if k < 0.42:
            return f"{rnd.choice(I_OPS)} {rd_any()}, {rs()}, {rnd.randint(-2048, 2047)}"
        if k < 0.48:
            return f"{rnd.choice(SH_OPS)} {r()}, {rs()}, {rnd.randint(0, 31)}"
        if k < 0.51:
            return f"lui {r()}, {rnd.randint(0, 0xFFFFF)}"
        if k < 0.53:
            return f"auipc {r()}, {rnd.randint(0, 0xFFFFF)}"
        if k < 0.66:
            op, sz = rnd.choice(LOADS)
            return f"{op} {rd_any()}, {rnd.randrange(0, 256, sz)}({BASE})"
        if k < 0.76:
            op, sz = rnd.choice(STORES)
            return f"{op} {rs()}, {rnd.randrange(0, 256, sz)}({BASE})"
        if k < 0.90:
            return f"{rnd.choice(BR_OPS)} {rs()}, {rs()}, {fwd_label(i)}"
        if k < 0.95:
            return f"jal {rd_any()}, {fwd_label(i)}"
        odd = rnd.choice([0, 1])         # JALR must clear bit 0 of the target
        return f"la {TMP}, {fwd_label(i)}\n    jalr {rd_any()}, {odd}({TMP})"

    out = ["    .text", "    .globl main", "main:", f"    la {BASE}, scratch"]
    for reg in POOL:
        v = rnd.choice(INTERESTING) if rnd.random() < 0.4 else rnd.getrandbits(32)
        out.append(f"    li {reg}, {v & 0xFFFFFFFF}")
    for off in range(0, 256, 4):
        out.append(f"    li {TMP}, {rnd.getrandbits(32)}\n    sw {TMP}, {off}({BASE})")

    for i in range(n):
        out.append(f"L{i}:\n    {body(i)}")
    out.append(f"L{n}:")

    # Fold the scratch buffer into x10 so every store is observed in the trace
    for off in range(0, 256, 4):
        out.append(f"    lw {TMP}, {off}({BASE})\n    add x10, x10, {TMP}")
    out.append("    li a0, 0\n    ret")
    out.append("\n    .bss\n    .balign 4\nscratch: .space 256")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seed", type=int)
    ap.add_argument("out")
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--m", action="store_true", help="include M-extension instructions")
    a = ap.parse_args()
    open(a.out, "w").write(gen(a.seed, a.n, a.m))


if __name__ == "__main__":
    main()
