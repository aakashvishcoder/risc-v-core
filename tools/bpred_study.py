#!/usr/bin/env python3
"""
Trace-driven branch predictor study.

Replays the conditional branches and jumps from a commit trace through
software models of several predictors and estimates CPI for each, using this
pipeline's penalties:

  - conditional branch: resolves in EX, so a misprediction costs 1 cycle
  - JAL: always taken with a target known from the encoding; costs 1 cycle if
    resolved in EX, 0 if the pipeline redirects from ID
  - JALR: target comes from a register; costs 1 cycle unless predicted
    (a return-address stack catches returns)

A "predicted taken" branch only avoids the penalty if the redirect happens in
ID, where the target (pc + imm) is computable from the instruction, so every
scheme below assumes taken predictions redirect from ID at no cost.

The model is calibrated against the real run: the RTL testbench log next to
the trace (<trace>.log) gives the measured cycle count, from which the
load-use stall cycles are recovered, so the baseline row reproduces the
measured CPI and the other rows are what-if estimates on the same run. The
trace must come from the baseline configuration (no prediction, JAL in EX),
which `make study` builds.

Jump models: a return-address stack (same push/pop rules as the RTL) and an
indirect jump target buffer (direct-mapped by pc, remembers each JALR's last
target) for JALRs the stack doesn't predict.

    bpred_study.py out/coremark_1iter.rtl
"""
import argparse
import os
import re


def parse(path):
    """Yield (pc, instr, next_pc) for each retired instruction."""
    rows = []
    for line in open(path):
        p = line.split()
        rows.append((int(p[0], 16), int(p[1], 16)))
    for (pc, ins), (npc, _) in zip(rows, rows[1:]):
        yield pc, ins, npc


def b_imm(ins):
    imm = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | \
          (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1)
    return imm - (1 << 13) if imm >> 12 else imm


class Bimodal:
    def __init__(self, bits):
        self.bits, self.t = bits, [1] * (1 << bits)      # weakly not-taken
    def idx(self, pc):
        return (pc >> 2) & ((1 << self.bits) - 1)
    def predict(self, pc):
        return self.t[self.idx(pc)] >= 2
    def update(self, pc, taken):
        i = self.idx(pc)
        self.t[i] = min(3, self.t[i] + 1) if taken else max(0, self.t[i] - 1)


class Gshare(Bimodal):
    def __init__(self, bits, hist_bits):
        super().__init__(bits)
        self.h, self.hb = 0, hist_bits
    def idx(self, pc):
        return ((pc >> 2) ^ self.h) & ((1 << self.bits) - 1)
    def update(self, pc, taken):
        super().update(pc, taken)
        self.h = ((self.h << 1) | taken) & ((1 << self.hb) - 1)


def jalr_misses(jumps, ras_depth, ibtb_bits):
    """Count JALRs whose target isn't correctly predicted."""
    ras, top = [0] * max(1, ras_depth), 0
    ibtb = {}
    miss = 0
    link = (1, 5)
    for kind, pc, rd, rs1, target in jumps:
        pop = ras_depth and kind == "jalr" and rs1 in link and not (rd in link and rd == rs1)
        push = ras_depth and rd in link
        if kind == "jalr":
            if pop:
                pred = ras[top]
            elif ibtb_bits:
                e = ibtb.get((pc >> 2) & ((1 << ibtb_bits) - 1))
                pred = e[1] if e and e[0] == pc else None
            else:
                pred = None
            miss += pred != target
            if ibtb_bits and not pop:
                ibtb[(pc >> 2) & ((1 << ibtb_bits) - 1)] = (pc, target)
        if pop and push:
            ras[top] = pc + 4
        elif push:
            top = (top + 1) % ras_depth
            ras[top] = pc + 4
        elif pop:
            top = (top - 1) % ras_depth
    return miss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    args = ap.parse_args()

    insns = 0
    branches = []          # (pc, taken, backward)
    jumps = []             # (kind, pc, rd, rs1, target)
    jal = jalr = ret = jalr_call = 0
    prev = 0
    for pc, ins, npc in parse(args.trace):
        insns += 1
        op = ins & 0x7F
        rs1, rd = (ins >> 15) & 31, (ins >> 7) & 31
        if op == 0x63:
            branches.append((pc, npc != pc + 4, b_imm(ins) < 0))
        elif op == 0x6F:
            jal += 1
            jumps.append(("jal", pc, rd, 0, npc))
        elif op == 0x67:
            jalr += 1
            jumps.append(("jalr", pc, rd, rs1, npc))
            if rs1 == 1 and rd == 0:                    # ret = jalr x0, 0(ra)
                ret += 1
            elif rd == 1 and (prev & 0x7F) == 0x17:     # call = auipc ra + jalr ra
                jalr_call += 1
        prev = ins
    insns += 1  # last instruction has no successor but still retired

    # Calibrate against the measured run: every cycle is an instruction, a
    # load-use stall, a flush (taken branch or jump), or pipeline fill/drain.
    cycles = None
    log = args.trace + ".log"
    if os.path.exists(log):
        m = re.search(r"cycles=(\d+)", open(log).read())
        cycles = int(m.group(1)) if m else None

    n = len(branches)
    taken = sum(t for _, t, _ in branches)
    back = [t for _, t, b in branches if b]
    fwd = [t for _, t, b in branches if not b]
    print(f"{insns} instructions, {n} conditional branches ({100*taken/n:.1f}% taken), "
          f"{jal} JAL, {jalr} JALR")
    print(f"  JALR breakdown: {jalr_call} calls (auipc+jalr), {ret} returns, "
          f"{jalr - jalr_call - ret} other indirect (e.g. switch tables)")
    print(f"  backward branches: {len(back)} ({100*sum(back)/max(1,len(back)):.1f}% taken)"
          f"   forward: {len(fwd)} ({100*sum(fwd)/max(1,len(fwd)):.1f}% taken)\n")

    def static(fn):
        return sum(fn(b) != t for _, t, b in branches)

    def dynamic(pred):
        miss = 0
        for pc, t, _ in branches:
            miss += pred.predict(pc) != t
            pred.update(pc, t)
        return miss

    gshare = dynamic(Gshare(8, 8))
    schemes = [
        ("predict not-taken, all jumps in EX  (baseline)",     static(lambda b: False), jal + jalr),
        ("predict not-taken, JAL in ID",                         static(lambda b: False), jalr),
        ("static BTFN (backward taken), JAL in ID",              static(lambda b: b), jalr),
        ("bimodal 2-bit, 64 entries, JAL in ID",                 dynamic(Bimodal(6)), jalr),
        ("bimodal 2-bit, 256 entries, JAL in ID",                dynamic(Bimodal(8)), jalr),
        ("bimodal 2-bit, 1024 entries, JAL in ID",               dynamic(Bimodal(10)), jalr),
        ("gshare, 256 entries, 8-bit history, JAL in ID",        dynamic(Gshare(8, 8)), jalr),
        ("gshare, 1024 entries, 10-bit history, JAL in ID",      dynamic(Gshare(10, 10)), jalr),
        ("gshare 256 + return-address stack (8)",                gshare, jalr_misses(jumps, 8, 0)),
        ("gshare 256 + RAS 8 + indirect target buffer (16)",     gshare, jalr_misses(jumps, 8, 4)),
        ("gshare 256 + RAS 8 + indirect target buffer (64)",     gshare, jalr_misses(jumps, 8, 6)),
        ("perfect prediction (upper bound)",                     0, 0),
    ]
    FILL = 4                      # pipeline fill + exit drain in the testbench
    lu = 0
    if cycles is not None:
        lu = cycles - insns - taken - jal - jalr - FILL
        print(f"calibration: measured {cycles} cycles -> {lu} load-use stall cycles\n")
    else:
        print("(no testbench log found: CPI excludes load-use stalls)\n")
    print(f"{'scheme':52} {'mispred':>8} {'jump pen':>8} {'CPI':>6}")
    for name, miss, jpen in schemes:
        cpi = (insns + lu + miss + jpen + (FILL if cycles else 0)) / insns
        print(f"{name:52} {100*miss/n:7.1f}% {jpen:8d} {cpi:6.3f}")


if __name__ == "__main__":
    main()
