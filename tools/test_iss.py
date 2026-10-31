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
from iss import ISS, INTERRUPT  # noqa: E402

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

# ---- traps -----------------------------------------------------------------
def csrrw(rd, csr, rs1):  return i(csr, rs1, 1, rd, 0x73)
def csrrs(rd, csr, rs1):  return i(csr, rs1, 2, rd, 0x73)
def csrrc(rd, csr, rs1):  return i(csr, rs1, 3, rd, 0x73)
def csrrwi(rd, csr, z):   return i(csr, z, 5, rd, 0x73)
def csrrsi(rd, csr, z):   return i(csr, z, 6, rd, 0x73)
ECALL, EBREAK, MRET, WFI = 0x00000073, 0x00100073, 0x30200073, 0x10500073
MSTATUS, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL = \
    0x300, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343
HANDLER = 0x100


def trap_prog(body):
    """Point mtvec at HANDLER, then run `body`. Returns the program image."""
    p = li(31, HANDLER) + [csrrw(0, MTVEC, 31)] + body
    return p + [0] * (HANDLER // 4 - len(p))


def first_trap(body, steps=None):
    """Run until the first trap and return (sim, mcause, mepc, mtval)."""
    sim = ISS(trap_prog(body))
    for _ in range(steps or 64):
        if any(l.startswith("trap") for l in sim.step()):
            return sim, sim.csr[MCAUSE], sim.csr[MEPC], sim.csr[MTVAL]
    raise AssertionError("no trap")


@test
def illegal_instructions_trap():
    for ins in (0x00000000, 0xFFFFFFFF, r(1, 2, 1, 0, 3),   # mul without M
                i(0, 0, 2, 0, 0x67),                       # jalr f3=2
                r(0x20, 2, 1, 1, 3),                       # "sub" with sll funct3
                csrrs(1, 0x7C0, 0),                        # unimplemented CSR
                csrrw(0, 0xC00, 1),                        # write to read-only cycle
                csrrs(0, 0x301 | 0xC00, 1)):               # 0xF01-ish: read-only space
        sim, cause, epc, tval = first_trap([ins])
        assert cause == 2, f"{ins:08x}: mcause {cause}"
        assert epc == 12 and tval == ins, f"{ins:08x}: mepc {epc:#x} mtval {tval:#x}"
        assert sim.pc == HANDLER and sim.instret == 3   # faulting instruction didn't retire

@test
def csr_read_only_access_is_legal():
    # csrrs rd, cycle, x0 reads without writing: legal on a read-only CSR
    sim = run(trap_prog([csrrs(1, 0xC00, 0)]), steps=4)
    assert sim.pc == 16 and sim.csr[MCAUSE] == 0

@test
def ecall_and_ebreak():
    _, cause, epc, tval = first_trap([i(0, 0, 0, 0), ECALL])
    assert (cause, epc, tval) == (11, 16, 0)
    _, cause, epc, tval = first_trap([EBREAK])
    assert (cause, epc, tval) == (3, 12, 12)   # tval = address of the ebreak

@test
def misaligned_loads_and_stores():
    for ins, cause in ((i(1, 0, 2, 1, 0x03), 4),    # lw  from 0x201
                       (i(1, 0, 1, 1, 0x03), 4),    # lh  from 0x201
                       (s(2, 0, 0, 2), 6),          # sw  to   0x202
                       (s(1, 0, 0, 1), 6)):         # sh  to   0x201
        sim, c, epc, tval = first_trap([i(0x200, 0, 0, 0)] + [ins])   # x0 stays 0
        # rs1 = x0: address is just the immediate
        exp = (ins >> 20) if cause == 4 else (((ins >> 25) << 5) | ((ins >> 7) & 31))
        assert c == cause and tval == exp, f"{ins:08x}: cause {c} tval {tval:#x}"
    # byte accesses are never misaligned; aligned halfword is fine
    sim = run(trap_prog([i(1, 0, 0, 1, 0x03), i(2, 0, 1, 1, 0x03)]), steps=5)
    assert sim.csr[MCAUSE] == 0 and sim.pc == 20

@test
def access_faults_outside_the_memory_map():
    _, c, _, tval = first_trap(li(5, 0x40000000) + [i(0, 5, 2, 1, 0x03)])
    assert (c, tval) == (5, 0x40000000)
    _, c, _, tval = first_trap(li(5, 0x10000100) + [s(0, 0, 5, 2)])   # just past IO
    assert (c, tval) == (7, 0x10000100)
    # jumping outside RAM faults on the fetch: mepc = mtval = the bad address
    sim, c, epc, tval = first_trap(li(5, 0x20000000) + [i(0, 5, 0, 1, 0x67)])
    assert (c, epc, tval) == (1, 0x20000000, 0x20000000)
    assert sim.x[1] == 24              # the jalr (at 20) itself retired and linked

@test
def misaligned_jump_target():
    # jalr to an address with bit 1 set: the jump traps, rd is not written
    sim, c, epc, tval = first_trap(li(5, 0x22) + [i(0, 5, 0, 1, 0x67)])
    assert (c, epc, tval) == (0, 20, 0x22) and sim.x[1] == 0
    # taken branch to a misaligned target traps; not-taken does not
    _, c, epc, tval = first_trap([b(6, 0, 0, 0)])          # beq x0,x0,+6
    assert (c, epc, tval) == (0, 12, 18)
    sim = run(trap_prog([b(6, 0, 0, 1), i(0, 0, 0, 0)]), steps=5)   # bne: not taken
    assert sim.csr[MCAUSE] == 0 and sim.pc == 20

@test
def trap_updates_mstatus_and_mret_restores():
    # MIE=1 before the trap: after it MIE=0, MPIE=1; mret brings MIE back
    body = [csrrsi(0, MSTATUS, 8), ECALL]
    p = trap_prog(body)
    p += [csrrs(10, MSTATUS, 0),          # handler: x10 = mstatus in the handler
          csrrs(11, MEPC, 0), i(4, 11, 0, 11), csrrw(0, MEPC, 11),   # mepc += 4
          MRET]
    sim = ISS(p)
    for _ in range(5 + 5):         # 3 setup + csrrsi + ecall, then the handler
        sim.step()
    assert sim.x[10] == (1 << 7) | (3 << 11), hex(sim.x[10])   # MPIE=1, MIE=0, MPP=M
    assert sim.pc == 20                                         # back after the ecall
    assert sim.csr[MSTATUS] == (1 << 3) | (1 << 7) | (3 << 11)

@test
def csr_write_masks():
    p = li(1, M) + [csrrw(0, MSTATUS, 1), csrrw(0, MIE, 1), csrrw(0, MEPC, 1),
                    csrrw(0, MTVEC, 1), csrrw(0, MSCRATCH, 1), csrrw(0, 0x320, 1),
                    csrrs(2, MSTATUS, 0), csrrs(3, MIE, 0), csrrs(4, MEPC, 0),
                    csrrs(5, MTVEC, 0), csrrs(6, MSCRATCH, 0), csrrs(7, 0x320, 0)]
    sim = run(p)
    assert sim.x[2] == 0x1888          # only MIE, MPIE writable; MPP reads 11
    assert sim.x[3] == 0x888           # MSIE, MTIE, MEIE
    assert sim.x[4] == 0xFFFFFFFC      # mepc is 4-byte aligned
    assert sim.x[5] == 0xFFFFFFFD      # mtvec mode 0/1 only
    assert sim.x[6] == M
    assert sim.x[7] == 0xFFFFFFFD      # mcountinhibit.TM hardwired 0

@test
def csr_set_clear_and_old_value():
    p = li(1, 0xF0) + [csrrw(0, MSCRATCH, 1), csrrsi(2, MSCRATCH, 0x0F),
                       csrrc(3, MSCRATCH, 1), csrrs(4, MSCRATCH, 0),
                       csrrwi(5, MSCRATCH, 0x1F), csrrs(6, MSCRATCH, 0)]
    sim = run(p)
    assert (sim.x[2], sim.x[3], sim.x[4], sim.x[5], sim.x[6]) == (0xF0, 0xFF, 0x0F, 0x0F, 0x1F)

@test
def interrupts_direct_and_vectored():
    # An interrupt injected before instruction 4 (the nop) is taken there:
    # mepc = its pc, mtval = 0; in vectored mode it lands at BASE + 4*cause.
    for mode in (0, 1):
        p = li(31, HANDLER | mode) + [csrrw(0, MTVEC, 31), i(0, 0, 0, 0), i(0, 0, 0, 0)]
        p += [0] * (HANDLER // 4 - len(p)) + [i(0, 0, 0, 0)] * 16
        sim = ISS(p)
        sim.csr[MSTATUS] |= 8                         # MIE
        sim.csr[MIE] = 1 << 7                         # MTIE
        sim.irqs[4] = INTERRUPT | 7                   # machine timer, at trace line 4
        lines = []
        for _ in range(6):                            # 4 instrs, the trap, 1 handler instr
            lines += sim.step()
        assert lines[4] == "trap 80000007 pc=00000010 tval=00000000", lines
        assert sim.csr[MEPC] == 16 and sim.csr[MCAUSE] == INTERRUPT | 7
        exp = HANDLER + (4 * 7 if mode else 0) + 4    # handler's first instr executed
        assert sim.pc == exp, (mode, hex(sim.pc))

@test
def interrupt_while_disabled_is_flagged():
    # The model takes interrupts where the RTL trace says, but only if they're
    # enabled: otherwise it emits a line that can never match the RTL's trace
    for mstatus, mie in ((0, 1 << 7), (8, 1 << 3), (0, 0)):
        sim = ISS(trap_prog([i(0, 0, 0, 0)] * 4))
        sim.csr[MSTATUS] |= mstatus
        sim.csr[MIE] = mie
        sim.irqs[1] = INTERRUPT | 7
        lines = sim.step() + sim.step()
        assert lines[1].startswith("interrupt 80000007 taken while disabled"), lines

@test
def interrupt_after_exception_keyed_by_trace_line():
    # An exception at instruction 4 (trace line 3), then an interrupt before the
    # handler's first instruction (trace line 4): the exception comes first
    p = trap_prog([ECALL])
    p += [csrrsi(0, MSTATUS, 8), i(1, 0, 0, 1)] + [0] * 8
    sim = ISS(p)
    sim.csr[MIE] = 1 << 3
    sim.irqs[5] = INTERRUPT | 3              # right after the handler's csrrsi (line 4)
    lines = []
    for _ in range(8):
        lines += sim.step()
    assert lines[3] == "trap 0000000b pc=0000000c tval=00000000", lines
    assert lines[5] == f"trap 80000003 pc={HANDLER + 4:08x} tval=00000000", lines

@test
def wfi_is_a_nop():
    sim = run(trap_prog([WFI, i(1, 0, 0, 1)]), steps=5)
    assert sim.x[1] == 1 and sim.csr[MCAUSE] == 0

@test
def io_stores_use_byte_lane():
    # sb of 0x41 to UART_DATA (offset 0) prints 'A'; ext-IRQ hook at 0x10 latches bit 0
    p = li(5, 0x10000000) + [i(0x41, 0, 0, 1), s(0, 1, 5, 0), i(1, 0, 0, 2), s(0x10, 2, 5, 2),
                             i(0x10, 5, 2, 3, 0x03)]
    sim = run(p)
    assert sim.out == [0x41] and sim.ext_irq == 1 and sim.x[3] == 1


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
