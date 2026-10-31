#!/usr/bin/env python3
"""
Known-answer tests for the reference model (tools/iss.py).

Co-simulation only proves the RTL and the model agree, so the model itself is
checked here against hand-computed results from the RISC-V spec. Each test
assembles a few instructions with a tiny encoder, runs them, and checks
registers / memory.

    python3 tools/test_iss.py
"""
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from iss import ISS, Trap  # noqa: E402

M = 0xFFFFFFFF


# ---- minimal encoder -------------------------------------------------------
def r(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def i(imm, rs1, f3, rd, op=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def s(imm, rs2, rs1, f3, op=0x23):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | op

def b(imm, rs2, rs1, f3, op=0x63):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op

def u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def j(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

def li(rd, v):
    """lui+addi pair that loads any 32-bit value."""
    v &= M
    lo = v & 0xFFF
    hi = ((v + 0x800) >> 12) & 0xFFFFF
    return [u(hi, rd, 0x37), i(lo, rd, 0, rd)]


def run(prog, steps=None, m=False):
    sim = ISS(prog, m_ext=m)
    for _ in range(steps if steps is not None else len(prog)):
        sim.step()
    return sim


TESTS = []
def test(fn):
    TESTS.append(fn)
    return fn


# ---- tests -----------------------------------------------------------------
@test
def li_full_range():
    for v in (0, 1, 0x7FF, 0x800, 0xFFF, 0x12345678, 0x80000000, M):
        assert run(li(5, v)).x[5] == v, hex(v)

@test
def x0_is_hardwired():
    assert run([i(123, 0, 0, 0)]).x[0] == 0

@test
def add_sub_wrap():
    p = li(1, M) + li(2, 1) + [r(0, 2, 1, 0, 3), r(0x20, 1, 2, 0, 4)]
    sim = run(p)
    assert sim.x[3] == 0            # 0xFFFFFFFF + 1 wraps to 0
    assert sim.x[4] == 2            # 1 - (-1)

@test
def shifts():
    p = li(1, 0x80000010) + [i(4, 1, 1, 2),            # slli 4
                             i(4, 1, 5, 3),            # srli 4
                             i(0x400 | 4, 1, 5, 4)]    # srai 4
    sim = run(p)
    assert sim.x[2] == 0x00000100
    assert sim.x[3] == 0x08000001
    assert sim.x[4] == 0xF8000001   # arithmetic shift keeps the sign

@test
def shift_amount_uses_low_5_bits():
    p = li(1, 1) + li(2, 33) + [r(0, 2, 1, 1, 3)]       # sll by 33 == sll by 1
    assert run(p).x[3] == 2

@test
def slt_vs_sltu():
    p = li(1, M) + li(2, 1) + [r(0, 2, 1, 2, 3), r(0, 2, 1, 3, 4)]
    sim = run(p)
    assert sim.x[3] == 1            # -1 < 1 signed
    assert sim.x[4] == 0            # 0xFFFFFFFF > 1 unsigned

@test
def sltiu_sign_extends_immediate():
    # sltiu rd, rs1, -1 compares against 0xFFFFFFFF: true for everything but -1
    p = li(1, 5) + [i(-1, 1, 3, 2)]
    assert run(p).x[2] == 1

@test
def lui_auipc():
    p = [i(0, 0, 0, 0), u(0x12345, 1, 0x37), u(0x1, 2, 0x17)]
    sim = run(p)
    assert sim.x[1] == 0x12345000
    assert sim.x[2] == 8 + 0x1000   # auipc at pc=8

@test
def loads_sign_and_zero_extend():
    p = li(1, 0x200) + li(2, 0x8081F0FF) + [
        s(0, 2, 1, 2),              # sw
        i(0, 1, 0, 3, 0x03),        # lb  -> 0xFFFFFFFF
        i(0, 1, 4, 4, 0x03),        # lbu -> 0xFF
        i(2, 1, 1, 5, 0x03),        # lh  [+2] -> 0xFFFF8081
        i(2, 1, 5, 6, 0x03),        # lhu [+2] -> 0x8081
        i(1, 1, 0, 7, 0x03),        # lb  [+1] -> 0xFFFFFFF0
    ]
    sim = run(p)
    assert sim.x[3] == 0xFFFFFFFF
    assert sim.x[4] == 0xFF
    assert sim.x[5] == 0xFFFF8081
    assert sim.x[6] == 0x8081
    assert sim.x[7] == 0xFFFFFFF0

@test
def subword_stores():
    p = li(1, 0x200) + li(2, 0xAABBCCDD) + [
        s(0, 0, 1, 2),              # sw x0 (clear)
        s(1, 2, 1, 0),              # sb at +1
        s(2, 2, 1, 1),              # sh at +2
        i(0, 1, 2, 3, 0x03),        # lw
    ]
    assert run(p).x[3] == 0xCCDDDD00

@test
def branches_taken_and_not():
    # (funct3, rs1, rs2, taken?). A taken branch skips "addi x10, x10, 1".
    # M = -1 signed / max unsigned, so signed and unsigned compares disagree.
    cases = [
        (0, 5, 5, True),  (0, 5, 6, False),    # beq
        (1, 5, 6, True),  (1, 5, 5, False),    # bne
        (4, M, 1, True),  (4, 1, M, False),    # blt   (-1 < 1)
        (5, 1, M, True),  (5, M, 1, False),    # bge
        (6, 1, M, True),  (6, M, 1, False),    # bltu  (1 < 0xFFFFFFFF)
        (7, M, 1, True),  (7, 1, M, False),    # bgeu
        (5, 7, 7, True),  (7, 7, 7, True),     # bge/bgeu on equal
    ]
    for f3, va, vb, taken in cases:
        p = li(1, va) + li(2, vb) + [b(8, 2, 1, f3), i(1, 10, 0, 10), i(0, 0, 0, 0)]
        got = run(p, steps=6).x[10] == 0
        assert got == taken, f"f3={f3} rs1={va:#x} rs2={vb:#x}: taken={got}"

@test
def backward_branch_loop():
    # x1 = 5; loop: x2 += x1; x1 -= 1; bne x1, x0, loop
    p = [i(5, 0, 0, 1),             # addi x1, x0, 5
         i(0, 0, 0, 2),             # addi x2, x0, 0
         r(0, 1, 2, 0, 2),          # loop: add x2, x2, x1
         i(-1, 1, 0, 1),            #       addi x1, x1, -1
         b(-8, 0, 1, 1)]            #       bne x1, x0, loop
    sim = run(p, steps=2 + 3 * 5)
    assert sim.x[2] == 15 and sim.x[1] == 0

@test
def jal_links_and_jumps():
    sim = run([j(8, 1), i(1, 10, 0, 10), i(0, 0, 0, 0)], steps=1)
    assert sim.x[1] == 4 and sim.pc == 8

@test
def jalr_clears_bit0():
    p = li(5, 0x21) + [i(0, 5, 0, 1, 0x67)]          # jalr x1, 0(x5)
    sim = run(p)
    assert sim.pc == 0x20 and sim.x[1] == 12

@test
def illegal_instructions_trap():
    for ins in (0x00000000, 0xFFFFFFFF, r(1, 2, 1, 0, 3),   # mul without M
                i(0, 0, 2, 0, 0x67),                       # jalr f3=2
                r(0x20, 2, 1, 1, 3)):                      # "sub" with sll funct3
        try:
            run([ins])
        except Trap:
            continue
        raise AssertionError(f"{ins:08x} should trap")

@test
def m_extension_corner_cases():
    def op(f3, va, vb):
        return run(li(1, va) + li(2, vb) + [r(1, 2, 1, f3, 3)], m=True).x[3]
    assert op(4, 7, 0) == M                    # div by zero
    assert op(6, 7, 0) == 7                    # rem by zero
    assert op(4, 0x80000000, M) == 0x80000000  # overflow
    assert op(6, 0x80000000, M) == 0
    assert op(4, (-7) & M, 2) == (-3) & M      # truncates toward zero
    assert op(6, (-7) & M, 2) == M             # remainder takes dividend's sign
    assert op(1, M, M) == 0                    # mulh  -1*-1
    assert op(3, M, M) == 0xFFFFFFFE           # mulhu
    assert op(2, M, M) == M                    # mulhsu


def main():
    fails = 0
    for t in TESTS:
        try:
            t()
            print(f"  pass  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            fails += 1
            print(f"  FAIL  {t.__name__}: {e!r}")
    print(f"{len(TESTS) - fails}/{len(TESTS)} reference-model tests passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
