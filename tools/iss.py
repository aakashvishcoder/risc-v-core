#!/usr/bin/env python3
"""
RV32IM + Zicsr machine-mode instruction-set simulator, used as the golden
reference model.

Executes one instruction at a time with no notion of pipelining, and emits the
same commit trace format as the Verilator testbench, so the two can be diffed
line by line (tools/compare.py):

    <pc> <instr>[ x<rd>=<value>]               one retired instruction
    trap <mcause> pc=<mepc> tval=<mtval>        a trap was taken

Traps follow the RISC-V privileged spec (machine mode only): exceptions for
illegal instructions, ecall/ebreak, misaligned load/store addresses and jump
targets, and access faults outside the memory map; interrupts from the timer,
software and external sources; mret; direct and vectored mtvec.

Co-simulation sync (--sync <rtl trace>): some values depend on pipeline timing,
which this model doesn't have, so it takes them from the RTL trace:
  - reads of the counter CSRs, mip, and the build-configuration CSRs
  - loads from the CLINT (mtime and friends)
  - *when* interrupts arrive: the RTL trace says where each interrupt was
    taken, and the model takes the same interrupt at the same point - after
    checking that it was enabled there (mstatus.MIE and its mie bit); an
    interrupt taken while disabled shows up as a mismatching trace line
Everything else (all other CSRs, every exception) the model computes itself.

Usage: iss.py prog.hex [--trace out.txt] [--max N] [--m] [--sync rtl_trace]
                      [--mem-trace mem.txt]
"""
import argparse
import sys

MASK = 0xFFFFFFFF

# Memory map (rv_soc.sv)
RAM_SIZE = 64 * 1024
CLINT_BASE, CLINT_SIZE = 0x0200_0000, 0x1_0000
IO_BASE, IO_SIZE = 0x1000_0000, 0x100

# Exception causes
CAUSE_MISALIGNED_FETCH = 0
CAUSE_FETCH_FAULT = 1
CAUSE_ILLEGAL = 2
CAUSE_BREAKPOINT = 3
CAUSE_MISALIGNED_LOAD = 4
CAUSE_LOAD_FAULT = 5
CAUSE_MISALIGNED_STORE = 6
CAUSE_STORE_FAULT = 7
CAUSE_ECALL_M = 11
INTERRUPT = 0x8000_0000

# CSR numbers
MSTATUS, MISA, MIE, MTVEC, MCOUNTINHIBIT = 0x300, 0x301, 0x304, 0x305, 0x320
MSCRATCH, MEPC, MCAUSE, MTVAL, MIP = 0x340, 0x341, 0x342, 0x343, 0x344
MSTATUS_MIE, MSTATUS_MPIE, MSTATUS_MPP = 1 << 3, 1 << 7, 3 << 11
MIE_MASK = (1 << 3) | (1 << 7) | (1 << 11)          # MSIE, MTIE, MEIE
MCOUNTINHIBIT_MASK = 0xFFFF_FFFD                     # bit 1 (time) is hardwired 0


def sx(v, bits):
    """Sign-extend the low `bits` bits of v."""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def counter_csr(n):
    """mcycle/minstret/mhpmcounterN and their user-mode read-only shadows."""
    lo = n & 0x1F
    return (n & 0xF60) in (0xB00, 0xB80, 0xC00, 0xC80) and lo != 1 or n in (0xC01, 0xC81)


def timing_csr(n):
    """CSRs whose value depends on the hardware's timing or build: synced."""
    return counter_csr(n) or n in (MIP, MISA, 0xFC0, 0xFC1)


def csr_exists(n):
    return (counter_csr(n) or
            n in (MSTATUS, MISA, MIE, MTVEC, MCOUNTINHIBIT, MSCRATCH, MEPC, MCAUSE, MTVAL,
                  MIP, 0xF11, 0xF12, 0xF13, 0xF14, 0xFC0, 0xFC1))


class Exc(Exception):
    """A synchronous exception raised while executing an instruction."""
    def __init__(self, cause, tval=0):
        super().__init__(cause)
        self.cause, self.tval = cause, tval & MASK


class ISS:
    def __init__(self, image_words, mem_bytes=RAM_SIZE, m_ext=False):
        self.mem = bytearray(mem_bytes)
        self.ram_size = mem_bytes
        for i, w in enumerate(image_words):
            self.mem[4 * i:4 * i + 4] = w.to_bytes(4, "little")
        self.x = [0] * 32
        self.pc = 0
        self.m_ext = m_ext
        self.instret = 0
        self.out = []
        self.leds = 0
        self.ext_irq = 0
        self.exit_code = None
        self.csr = {MSTATUS: MSTATUS_MPP, MIE: 0, MTVEC: 0, MCOUNTINHIBIT: 0,
                    MSCRATCH: 0, MEPC: 0, MCAUSE: 0, MTVAL: 0}
        self.sync = {}       # retired-instruction index -> value the RTL produced
        self.irqs = {}       # trace line index -> interrupt cause taken there
        self.lines = 0       # trace lines produced so far (retirements + traps)
        self.mtrace = None   # optional file: one line per RAM load/store
        self.log = []        # trap lines produced by the last step()

    # ---- memory (mirrors the rv_soc memory map) ---------------------------
    def region(self, addr):
        if addr < self.ram_size:
            return "ram"
        if CLINT_BASE <= addr < CLINT_BASE + CLINT_SIZE:
            return "clint"
        if IO_BASE <= addr < IO_BASE + IO_SIZE:
            return "io"
        return None

    def load(self, addr, size):
        r = self.region(addr)
        if r is None:
            raise Exc(CAUSE_LOAD_FAULT, addr)
        if r == "clint":     # timer values depend on timing: synced from the RTL
            return self.sync.get(self.instret, 0)
        if r == "io":
            off = addr & 0xFC
            v = {0x0C: self.leds, 0x10: self.ext_irq}.get(off, 0)   # UART never busy
            return v >> (8 * (addr & 3))
        if self.mtrace:
            self.mtrace.write(f"L {addr:08x}\n")
        return int.from_bytes(self.mem[addr:addr + size], "little")

    def store(self, addr, size, val):
        r = self.region(addr)
        if r is None:
            raise Exc(CAUSE_STORE_FAULT, addr)
        if r == "clint":     # mtime/mtimecmp/msip only affect interrupt timing: synced
            return
        if r == "io":
            off = addr & 0xFC
            lane = (val << (8 * (addr & 3))) & MASK   # sub-word stores use their byte lane
            if off == 0x00:
                self.out.append(lane & 0xFF)
            elif off == 0x08:
                self.exit_code = lane
            elif off == 0x0C:
                self.leds = lane & 0xFF
            elif off == 0x10:
                self.ext_irq = lane & 1
            return
        if self.mtrace:
            self.mtrace.write(f"S {addr:08x}\n")
        self.mem[addr:addr + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    # ---- CSRs --------------------------------------------------------------
    def csr_read(self, n):
        if timing_csr(n):
            return self.sync.get(self.instret, 0)
        if n in (0xF11, 0xF12, 0xF13, 0xF14):
            return 0
        return self.csr[n]

    def csr_write(self, n, v):
        v &= MASK
        if counter_csr(n) or n in (MISA, MIP):
            return                                   # values are synced on read
        if n == MSTATUS:
            v = (v & (MSTATUS_MIE | MSTATUS_MPIE)) | MSTATUS_MPP
        elif n == MIE:
            v &= MIE_MASK
        elif n == MTVEC:
            v &= ~2                                  # modes: 0 direct, 1 vectored
        elif n == MEPC:
            v &= ~3
        elif n == MCOUNTINHIBIT:
            v &= MCOUNTINHIBIT_MASK
        self.csr[n] = v

    # ---- traps -------------------------------------------------------------
    def take_trap(self, cause, tval, epc):
        st = self.csr[MSTATUS]
        mie = 1 if st & MSTATUS_MIE else 0
        self.csr[MSTATUS] = (st & ~(MSTATUS_MIE | MSTATUS_MPIE)) | (mie << 7) | MSTATUS_MPP
        self.csr[MEPC] = epc & ~3
        self.csr[MCAUSE] = cause & MASK
        self.csr[MTVAL] = tval & MASK
        base, mode = self.csr[MTVEC] & ~3, self.csr[MTVEC] & 1
        self.pc = base + 4 * (cause & 0x7FFF_FFFF) if (cause & INTERRUPT and mode == 1) else base
        self.log.append(f"trap {cause & MASK:08x} pc={epc & MASK:08x} tval={tval & MASK:08x}")
        self.lines += 1

    # ---- execution ---------------------------------------------------------
    def step(self):
        """Execute one instruction (taking any pending synced interrupt first).
        Returns the trace lines it produced."""
        self.log = []
        if self.lines in self.irqs:
            cause = self.irqs.pop(self.lines)
            code = cause & 0x1F
            if not (self.csr[MSTATUS] & MSTATUS_MIE and self.csr[MIE] >> code & 1):
                self.log.append(f"interrupt {cause:08x} taken while disabled: "
                                f"mstatus={self.csr[MSTATUS]:08x} mie={self.csr[MIE]:08x}")
                self.lines += 1
            self.take_trap(cause, 0, self.pc)
            return self.log
        pc = self.pc
        try:
            if self.region(pc) != "ram":
                raise Exc(CAUSE_FETCH_FAULT, pc)
            ins = int.from_bytes(self.mem[pc:pc + 4], "little")
            wval, rd, npc = self.execute(pc, ins)
        except Exc as e:
            self.take_trap(e.cause, e.tval, pc)
            return self.log
        self.instret += 1
        self.lines += 1
        if wval is not None and rd != 0:
            self.x[rd] = wval & MASK
            line = f"{pc:08x} {ins:08x} x{rd}={self.x[rd]:08x}"
        else:
            line = f"{pc:08x} {ins:08x}"
        self.pc = npc
        return self.log + [line]

    def execute(self, pc, ins):
        op = ins & 0x7F
        rd = (ins >> 7) & 31
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 31
        rs2 = (ins >> 20) & 31
        f7 = ins >> 25
        a, b = self.x[rs1], self.x[rs2]
        imm_i = sx(ins >> 20, 12)
        imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        imm_b = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) |
                   (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) |
                   (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
        illegal = Exc(CAUSE_ILLEGAL, ins)

        npc = (pc + 4) & MASK
        wval = None

        def jump(target):
            target &= MASK
            if target & 3:                           # no compressed instructions
                raise Exc(CAUSE_MISALIGNED_FETCH, target)
            return target

        if op == 0x37:                                   # LUI
            wval = imm_u
        elif op == 0x17:                                 # AUIPC
            wval = (pc + imm_u) & MASK
        elif op == 0x6F:                                 # JAL
            npc = jump(pc + imm_j)
            wval = (pc + 4) & MASK
        elif op == 0x67:                                 # JALR
            if f3 != 0:
                raise illegal
            npc = jump((a + imm_i) & ~1)
            wval = (pc + 4) & MASK
        elif op == 0x63:                                 # BRANCH
            sa, sb = sx(a, 32), sx(b, 32)
            conds = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}
            if f3 not in conds:
                raise illegal
            if conds[f3]:
                npc = jump(pc + imm_b)
        elif op == 0x03:                                 # LOAD
            addr = (a + imm_i) & MASK
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}.get(f3)
            if size is None:
                raise illegal
            if addr & (size - 1):
                raise Exc(CAUSE_MISALIGNED_LOAD, addr)
            v = self.load(addr, size)
            if f3 == 0:   wval = sx(v, 8) & MASK
            elif f3 == 1: wval = sx(v, 16) & MASK
            elif f3 == 4: wval = v & 0xFF
            elif f3 == 5: wval = v & 0xFFFF
            else:         wval = v & MASK
        elif op == 0x23:                                 # STORE
            addr = (a + imm_s) & MASK
            if f3 > 2:
                raise illegal
            size = 1 << f3
            if addr & (size - 1):
                raise Exc(CAUSE_MISALIGNED_STORE, addr)
            self.store(addr, size, b)
        elif op in (0x13, 0x33):                         # OP-IMM / OP
            if op == 0x33 and f7 == 1:
                if not self.m_ext:
                    raise illegal
                wval = self.muldiv(f3, a, b)
            else:
                if op == 0x13:
                    b = imm_i & MASK
                    if f3 == 1 and f7 != 0:
                        raise illegal
                    if f3 == 5 and f7 not in (0, 0x20):
                        raise illegal
                    alt = f3 == 5 and (f7 & 0x20)
                else:
                    if f7 not in (0, 0x20) or (f7 == 0x20 and f3 not in (0, 5)):
                        raise illegal
                    alt = bool(f7 & 0x20)
                sh = b & 31
                if f3 == 0:   wval = (a - b) if alt else (a + b)
                elif f3 == 1: wval = a << sh
                elif f3 == 2: wval = int(sx(a, 32) < sx(b, 32))
                elif f3 == 3: wval = int(a < b)
                elif f3 == 4: wval = a ^ b
                elif f3 == 5: wval = (sx(a, 32) >> sh) if alt else (a >> sh)
                elif f3 == 6: wval = a | b
                elif f3 == 7: wval = a & b
                wval &= MASK
        elif op == 0x0F:                                 # FENCE
            pass
        elif op == 0x73:                                 # SYSTEM
            if f3 == 0:
                if ins == 0x0000_0073:                   # ecall
                    raise Exc(CAUSE_ECALL_M, 0)
                if ins == 0x0010_0073:                   # ebreak
                    raise Exc(CAUSE_BREAKPOINT, pc)
                if ins == 0x3020_0073:                   # mret
                    st = self.csr[MSTATUS]
                    mpie = 1 if st & MSTATUS_MPIE else 0
                    self.csr[MSTATUS] = (st & ~MSTATUS_MIE) | (mpie << 3) | MSTATUS_MPIE
                    npc = self.csr[MEPC]
                elif ins == 0x1050_0073:                 # wfi: a hint, treated as nop
                    pass
                else:
                    raise illegal
            elif f3 == 4:
                raise illegal
            else:                                        # CSRRW/S/C and immediate forms
                n = ins >> 20
                src = rs1 if f3 & 4 else a               # zimm or rs1's value
                writes = (f3 & 3) == 1 or rs1 != 0       # CSRRW always; S/C unless x0/zimm 0
                if not csr_exists(n) or (writes and (n >> 10) == 3):
                    raise illegal                        # missing, or read-only (0xC00+)
                old = self.csr_read(n)
                if writes:
                    kind = f3 & 3
                    new = src if kind == 1 else (old | src) if kind == 2 else (old & ~src)
                    self.csr_write(n, new)
                wval = old
        else:
            raise illegal
        return wval, rd, npc

    @staticmethod
    def muldiv(f3, a, b):
        sa, sb = sx(a, 32), sx(b, 32)
        if f3 == 0: return (a * b) & MASK
        if f3 == 1: return ((sa * sb) >> 32) & MASK
        if f3 == 2: return ((sa * b) >> 32) & MASK
        if f3 == 3: return ((a * b) >> 32) & MASK
        if f3 == 4:
            if b == 0: return MASK
            if sa == -2**31 and sb == -1: return a
            q = abs(sa) // abs(sb)
            return (-q if (sa < 0) != (sb < 0) else q) & MASK
        if f3 == 5: return MASK if b == 0 else a // b
        if f3 == 6:
            if b == 0: return a
            if sa == -2**31 and sb == -1: return 0
            r = abs(sa) % abs(sb)
            return (-r if sa < 0 else r) & MASK
        if f3 == 7: return a if b == 0 else a % b


def read_hex(path):
    return [int(l, 16) for l in open(path) if l.strip()]


def load_sync(sim, path):
    """Take timing-dependent values and interrupt arrival points from an RTL
    trace: values of CSR reads in timing_csr(), results of CLINT loads, and
    interrupts (trap lines with the interrupt bit set)."""
    retired = 0
    lineno = 0
    for line in open(path):
        p = line.split()
        if not p:
            continue
        lineno += 1
        if p[0] == "trap":
            cause = int(p[1], 16)
            if cause & INTERRUPT:
                sim.irqs[lineno - 1] = cause
            continue
        if len(p) == 3:
            ins = int(p[1], 16)
            val = int(p[2].split("=")[1], 16)
            op, f3 = ins & 0x7F, (ins >> 12) & 7
            if op == 0x73 and f3 not in (0, 4) and timing_csr(ins >> 20):
                sim.sync[retired] = val
            elif op == 0x03:
                sim.sync.setdefault(retired, val)    # used only if the load hits the CLINT
        retired += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hex")
    ap.add_argument("--trace")
    ap.add_argument("--max", type=int, default=50_000_000)
    ap.add_argument("--m", action="store_true", help="enable M extension")
    ap.add_argument("--sync", "--csr-sync", dest="sync",
                    help="RTL trace to take timing-dependent values and interrupts from")
    ap.add_argument("--mem-trace", help="write every RAM load/store address here")
    ap.add_argument("--ram-kb", type=int, default=RAM_SIZE // 1024,
                    help="RAM size (must match the simulator's MEM_WORDS)")
    args = ap.parse_args()

    sim = ISS(read_hex(args.hex), mem_bytes=args.ram_kb * 1024, m_ext=args.m)
    if args.sync:
        load_sync(sim, args.sync)
    if args.mem_trace:
        sim.mtrace = open(args.mem_trace, "w")
    tf = open(args.trace, "w") if args.trace else None
    why = "timeout"
    traps = 0
    while sim.instret < args.max:
        lines = sim.step()
        if tf:
            tf.write("".join(l + "\n" for l in lines))
        if sim.exit_code is not None:
            why = "exit"
            break
        if len(lines) and lines[-1].startswith("trap"):
            traps += 1
            if traps > 100_000:                      # e.g. a trap loop with no handler
                why = "trap storm"
                break
    if tf:
        tf.close()
    sys.stdout.write(bytes(sim.out).decode(errors="replace"))
    print(f"[iss] stop: {why} code={sim.exit_code} retired={sim.instret}", file=sys.stderr)
    sys.exit(sim.exit_code if sim.exit_code is not None else 2)


if __name__ == "__main__":
    main()
