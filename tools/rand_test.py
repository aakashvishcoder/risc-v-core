#!/usr/bin/env python3
"""
Random RV32I(M) program generator for RTL-vs-reference co-simulation.

A deliberately small pool of 8 registers makes almost every instruction depend
on one of the last few, which stresses the parts of a pipeline that are easy
to get wrong:

  - forwarding from MEM and WB (back-to-back ALU dependencies)
  - load-use stalls (loads followed by consumers, including branches)
  - branches on freshly computed / loaded values
  - x0 as a source and as a destination
  - corner-case values (0, -1, INT_MIN, shift amounts >= 32, ...)

Control flow is mixed so that branch prediction is exercised in both
directions, including recovery from every kind of misprediction:

  - forward branches and jumps (mostly not taken / taken at random)
  - short counted loops (backward branches, taken then not taken)
  - calls to a leaf function and to a call chain 12 deep, deeper than any
    return-address stack this core is built with
  - "returns" to an address that was never called, which leaves a
    return-address stack holding a wrong prediction
  - indirect jumps whose target alternates between iterations

Every program terminates: forward jumps only move forward, and loops count
down a dedicated register and exit once it is <= 0, so entering a loop body
from outside (with a stale counter) still runs it a bounded number of times.

All memory traffic goes to a 256-byte scratch buffer, which is checksummed at
the end so stores are checked too.

    rand_test.py <seed> <out.S> [--n 400] [--m]
"""
import argparse
import random

POOL = ["x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12"]   # hot registers
# Reserved (never written by random ALU/load code):
RA = "x1"         # return address for calls
JT = "x25"        # indirect-jump temp
SAVED_RA = "x26"  # main's own return address
CALLSTACK = "x27" # spill area for the call chain
CALLS = "x28"     # counts function bodies executed
LOOP = "x29"      # loop counter
TMP = "x30"       # temp for JALR targets and setup
BASE = "x31"      # scratch-buffer base pointer

CHAIN_DEPTH = 12

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

    def data_op(i):
        if rnd.random() < 0.06:          # re-inject corner-case values mid-stream
            return f"li {r()}, {rnd.choice(INTERESTING) & 0xFFFFFFFF}"
        k = rnd.random()
        if k < 0.30:
            ops = M_OPS if (m_ext and rnd.random() < 0.3) else R_OPS
            return f"{rnd.choice(ops)} {rd_any()}, {rs()}, {rs()}"
        if k < 0.50:
            return f"{rnd.choice(I_OPS)} {rd_any()}, {rs()}, {rnd.randint(-2048, 2047)}"
        if k < 0.57:
            return f"{rnd.choice(SH_OPS)} {r()}, {rs()}, {rnd.randint(0, 31)}"
        if k < 0.61:
            return f"lui {r()}, {rnd.randint(0, 0xFFFFF)}"
        if k < 0.63:
            return f"auipc {r()}, {rnd.randint(0, 0xFFFFF)}"
        if k < 0.80:
            op, sz = rnd.choice(LOADS)
            return f"{op} {rd_any()}, {rnd.randrange(0, 256, sz)}({BASE})"
        op, sz = rnd.choice(STORES)
        return f"{op} {rs()}, {rnd.randrange(0, 256, sz)}({BASE})"

    def control_op(i):
        k = rnd.random()
        if k < 0.50:
            return f"{rnd.choice(BR_OPS)} {rs()}, {rs()}, {fwd_label(i)}"
        if k < 0.60:
            return f"jal {rd_any()}, {fwd_label(i)}"
        if k < 0.68:
            odd = rnd.choice([0, 1])     # JALR must clear bit 0 of the target
            return f"la {TMP}, {fwd_label(i)}\n    jalr {rd_any()}, {odd}({TMP})"
        if k < 0.80:
            return f"jal {RA}, F_leaf"
        if k < 0.88:
            start = rnd.randrange(CHAIN_DEPTH)      # enter the chain part-way down
            return f"jal {RA}, F{start}"
        if k < 0.93:
            # A "return" to an address that was never called: a return-address
            # stack predicts the wrong target here and must recover.
            return f"la {RA}, {fwd_label(i)}\n    ret"
        # Indirect jump whose target depends on the loop counter's parity:
        # jumps over one of two adds, so the target alternates per iteration.
        dst = r()
        return (f"andi {JT}, {LOOP}, 1\n    slli {JT}, {JT}, 2\n"
                f"    auipc {TMP}, 0\n    add {JT}, {JT}, {TMP}\n"
                f"    jalr x0, 16({JT})\n"
                f"    addi {dst}, {dst}, 1\n    addi {dst}, {dst}, 2")

    out = ["    .text", "    .globl main", "main:",
           f"    mv {SAVED_RA}, {RA}",
           f"    la {BASE}, scratch",
           f"    la {CALLSTACK}, callstack",
           f"    li {CALLS}, 0",
           f"    li {LOOP}, 0"]
    for reg in POOL:
        v = rnd.choice(INTERESTING) if rnd.random() < 0.4 else rnd.getrandbits(32)
        out.append(f"    li {reg}, {v & 0xFFFFFFFF}")
    for off in range(0, 256, 4):
        out.append(f"    li {TMP}, {rnd.getrandbits(32)}\n    sw {TMP}, {off}({BASE})")

    loop_id, loop_end = 0, None
    for i in range(n):
        out.append(f"L{i}:")
        if loop_end is None and rnd.random() < 0.10:
            out.append(f"    li {LOOP}, {rnd.randint(2, 8)}\nLOOP{loop_id}:")
            loop_end = i + rnd.randint(3, 12)
        out.append("    " + (control_op(i) if rnd.random() < 0.25 else data_op(i)))
        if loop_end is not None and i >= loop_end:
            # count down; exit once <= 0 (also safe if entered with a stale count)
            out.append(f"    addi {LOOP}, {LOOP}, -1\n    blt x0, {LOOP}, LOOP{loop_id}")
            loop_id, loop_end = loop_id + 1, None
    out.append(f"L{n}:")

    # Fold the scratch buffer and the call count into x10 so every store and
    # every call is observed in the trace
    for off in range(0, 256, 4):
        out.append(f"    lw {TMP}, {off}({BASE})\n    add x10, x10, {TMP}")
    out.append(f"    add x10, x10, {CALLS}")
    out.append(f"    mv {RA}, {SAVED_RA}\n    li a0, 0\n    ret")

    # Functions
    out.append(f"\nF_leaf:\n    addi {CALLS}, {CALLS}, 1\n    ret")
    for d in range(CHAIN_DEPTH):
        out.append(f"F{d}:\n    addi {CALLS}, {CALLS}, 1\n"
                   f"    sw {RA}, {4*d}({CALLSTACK})\n"
                   f"    jal {RA}, F{d+1}\n"
                   f"    lw {RA}, {4*d}({CALLSTACK})\n"
                   f"    ret")
    out.append(f"F{CHAIN_DEPTH}:\n    addi {CALLS}, {CALLS}, 1\n    ret")

    out.append("\n    .bss\n    .balign 4\nscratch: .space 256")
    out.append(f"callstack: .space {4 * CHAIN_DEPTH}")
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
