#!/usr/bin/env python3
"""
Trace-driven cache study.

Replays a program's instruction fetches (from the commit trace) and its RAM
loads/stores (from the reference model's --mem-trace) through models of
set-associative, LRU, write-back / write-allocate caches, and reports misses
and dirty writebacks for a range of sizes, associativities and line sizes.

With --penalty, it also estimates the stall cycles each configuration would
add, using per-event penalties measured on the RTL (see the README):

    stall = I-misses * I_PEN + D-misses * D_PEN + writebacks * WB_PEN

    cache_study.py <commit trace> <mem trace> [--penalty I_PEN D_PEN WB_PEN]
"""
import argparse


class Cache:
    def __init__(self, size, ways, line):
        self.line = line
        self.sets = size // (line * ways)
        self.ways = ways
        self.tags = [[] for _ in range(self.sets)]   # per set: list of [tag, dirty], MRU first
        self.accesses = self.misses = self.writebacks = 0

    def access(self, addr, write=False):
        self.accesses += 1
        blk = addr // self.line
        s, tag = blk % self.sets, blk // self.sets
        ways = self.tags[s]
        for i, (t, d) in enumerate(ways):
            if t == tag:
                ways.insert(0, [t, d or write])
                del ways[i + 1]
                return True
        self.misses += 1
        if len(ways) == self.ways:
            if ways[-1][1]:
                self.writebacks += 1
            ways.pop()
        ways.insert(0, [tag, write])
        return False


def load(commit, mem):
    pcs = [int(l.split()[0], 16) for l in open(commit) if l.strip()]
    data = []
    for l in open(mem):
        k, a = l.split()
        data.append((k == "S", int(a, 16)))
    return pcs, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("commit")
    ap.add_argument("mem")
    ap.add_argument("--penalty", nargs=3, type=int, metavar=("I", "D", "WB"))
    ap.add_argument("--isizes", default="256,512,1024,2048,4096")
    ap.add_argument("--dsizes", default="256,512,1024,2048,4096,8192")
    a = ap.parse_args()

    pcs, data = load(a.commit, a.mem)
    n = len(pcs)
    loads = sum(1 for w, _ in data if not w)
    print(f"{n} instructions, {loads} loads, {len(data) - loads} stores")

    print(f"\nInstruction cache (16-byte lines)")
    print(f"{'size':>6} {'ways':>4} {'misses':>8} {'miss rate':>9}"
          + (f" {'stall cyc':>10} {'+CPI':>7}" if a.penalty else ""))
    for size in map(int, a.isizes.split(",")):
        for ways in (1, 2):
            c = Cache(size, ways, 16)
            for pc in pcs:
                c.access(pc)
            line = f"{size:>6} {ways:>4} {c.misses:>8} {100*c.misses/c.accesses:>8.2f}%"
            if a.penalty:
                st = c.misses * a.penalty[0]
                line += f" {st:>10} {st/n:>7.4f}"
            print(line)

    print(f"\nData cache (write-back, write-allocate)")
    print(f"{'size':>6} {'ways':>4} {'line':>4} {'misses':>8} {'miss rate':>9} {'writebacks':>10}"
          + (f" {'stall cyc':>10} {'+CPI':>7}" if a.penalty else ""))
    for size in map(int, a.dsizes.split(",")):
        for ways, line in ((1, 16), (2, 16), (4, 16), (1, 32)):
            c = Cache(size, ways, line)
            for w, addr in data:
                c.access(addr, w)
            out = (f"{size:>6} {ways:>4} {line:>4} {c.misses:>8} "
                   f"{100*c.misses/max(1,c.accesses):>8.2f}% {c.writebacks:>10}")
            if a.penalty:
                st = c.misses * a.penalty[1] + c.writebacks * a.penalty[2]
                out += f" {st:>10} {st/n:>7.4f}"
            print(out)


if __name__ == "__main__":
    main()
