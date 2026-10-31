#!/usr/bin/env python3
"""
RV32I(M) instruction-set simulator used as the golden reference model.

Executes one instruction at a time with no notion of pipelining, and emits the
same commit trace format as the Verilator testbench:

    <pc> <instr>[ x<rd>=<value>]

so the two can be diffed line by line (tools/compare.py).

Usage: iss.py prog.hex [--trace out.txt] [--max N] [--m] [--csr-sync rtl_trace]
"""
import argparse
import sys

MASK = 0xFFFFFFFF


def sx(v, bits):
    """Sign-extend the low `bits` bits of v."""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Trap(Exception):
    pass


class ISS:
    def __init__(self, image_words, mem_bytes=64 * 1024, m_ext=False):
        self.mem = bytearray(mem_bytes)
        for i, w in enumerate(image_words):
            self.mem[4 * i:4 * i + 4] = w.to_bytes(4, "little")
        self.x = [0] * 32
        self.pc = 0
        self.m_ext = m_ext
        self.instret = 0
        self.out = []
        self.leds = 0
        self.exit_code = None
        self.csr_sync = {}   # instret index -> CSR value observed by the RTL

    # ---- memory (mirrors the rv_soc memory map) ---------------------------
    def load(self, addr, size):
        if addr >> 28 == 1:
            off = addr & 0xFF
            if off == 0x04:
                return 0                      # UART never busy in simulation
            if off == 0x0C:
                return self.leds
            return 0
        a = addr & (len(self.mem) - 1)
        return int.from_bytes(self.mem[a:a + size], "little")

    def store(self, addr, size, val):
        if addr >> 28 == 1:
            off = addr & 0xFC
            lane = (val << (8 * (addr & 3))) & MASK   # sub-word stores use their byte lane
            if off == 0x00:
                self.out.append(lane & 0xFF)
            elif off == 0x08:
                self.exit_code = lane
            elif off == 0x0C:
                self.leds = lane & 0xFF
            return
        a = addr & (len(self.mem) - 1)
        self.mem[a:a + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    # ---- execution ---------------------------------------------------------
    def step(self):
        pc = self.pc
        ins = int.from_bytes(self.mem[pc:pc + 4], "little")
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

        npc = (pc + 4) & MASK
        wval = None

        if op == 0x37:                                   # LUI
            wval = imm_u
        elif op == 0x17:                                 # AUIPC
            wval = (pc + imm_u) & MASK
        elif op == 0x6F:                                 # JAL
            wval = npc
            npc = (pc + imm_j) & MASK
        elif op == 0x67:                                 # JALR
            if f3 != 0:
                raise Trap("illegal")
            wval = npc
            npc = (a + imm_i) & MASK & ~1
        elif op == 0x63:                                 # BRANCH
            sa, sb = sx(a, 32), sx(b, 32)
            conds = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}
            if f3 not in conds:
                raise Trap("illegal")
            if conds[f3]:
                npc = (pc + imm_b) & MASK
        elif op == 0x03:                                 # LOAD
            addr = (a + imm_i) & MASK
            if f3 == 0:   wval = sx(self.load(addr, 1), 8) & MASK
            elif f3 == 1: wval = sx(self.load(addr, 2), 16) & MASK
            elif f3 == 2: wval = self.load(addr, 4)
            elif f3 == 4: wval = self.load(addr, 1)
            elif f3 == 5: wval = self.load(addr, 2)
            else: raise Trap("illegal")
        elif op == 0x23:                                 # STORE
            addr = (a + imm_s) & MASK
            if f3 > 2:
                raise Trap("illegal")
            self.store(addr, 1 << f3, b)
        elif op in (0x13, 0x33):                         # OP-IMM / OP
            if op == 0x33 and f7 == 1:
                if not self.m_ext:
                    raise Trap("illegal")
                wval = self.muldiv(f3, a, b)
            else:
                if op == 0x13:
                    b = imm_i & MASK
                    if f3 == 1 and f7 != 0:
                        raise Trap("illegal")
                    if f3 == 5 and f7 not in (0, 0x20):
                        raise Trap("illegal")
                    alt = f3 == 5 and (f7 & 0x20)
                else:
                    if f7 not in (0, 0x20) or (f7 == 0x20 and f3 not in (0, 5)):
                        raise Trap("illegal")
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
            if f3 == 0 or not (f3 & 2) or rs1 != 0:
                raise Trap("ecall/ebreak/unsupported")
            # Counter CSRs depend on pipeline timing, which this model doesn't
            # have: take the value the RTL saw (co-simulation sync), else 0.
            wval = self.csr_sync.get(self.instret, 0)
        else:
            raise Trap("illegal")

        self.instret += 1
        if wval is not None and rd != 0:
            self.x[rd] = wval & MASK
            line = f"{pc:08x} {ins:08x} x{rd}={self.x[rd]:08x}"
        else:
            line = f"{pc:08x} {ins:08x}"
        self.pc = npc
        return line

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hex")
    ap.add_argument("--trace")
    ap.add_argument("--max", type=int, default=50_000_000)
    ap.add_argument("--m", action="store_true", help="enable M extension")
    ap.add_argument("--csr-sync", help="RTL trace to take CSR read values from")
    args = ap.parse_args()

    sim = ISS(read_hex(args.hex), m_ext=args.m)
    if args.csr_sync:
        for i, line in enumerate(open(args.csr_sync)):
            p = line.split()
            if len(p) == 3 and (int(p[1], 16) & 0x7F) == 0x73:
                sim.csr_sync[i] = int(p[2].split("=")[1], 16)

    tf = open(args.trace, "w") if args.trace else None
    why = "timeout"
    try:
        while sim.instret < args.max:
            line = sim.step()
            if tf:
                tf.write(line + "\n")
            if sim.exit_code is not None:
                why = "exit"
                break
    except Trap as e:
        why = f"trap ({e})"
        if tf:  # the trapping instruction still retires in the RTL
            ins = int.from_bytes(sim.mem[sim.pc:sim.pc + 4], "little")
            tf.write(f"{sim.pc:08x} {ins:08x}\n")
    if tf:
        tf.close()
    sys.stdout.write(bytes(sim.out).decode(errors="replace"))
    print(f"[iss] stop: {why} code={sim.exit_code} retired={sim.instret}", file=sys.stderr)
    sys.exit(sim.exit_code if sim.exit_code is not None else 2)


if __name__ == "__main__":
    main()
