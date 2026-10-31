#!/usr/bin/env python3
"""
Diff two commit traces (RTL vs reference model).

Each line is "<pc> <instr>[ x<rd>=<value>]" for one retired instruction.
On the first mismatch, prints the instructions leading up to it so the bug
can be located in the disassembly. Exits 0 on match, 1 on mismatch.

    compare.py rtl_trace ref_trace
"""
import sys


def main():
    rtl = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    ref = [l.strip() for l in open(sys.argv[2]) if l.strip()]
    for n, (a, b) in enumerate(zip(rtl, ref)):
        if a != b:
            print(f"MISMATCH at instruction #{n}")
            for prev in ref[max(0, n - 5):n]:
                print(f"       {prev}")
            print(f"  rtl: {a}")
            print(f"  ref: {b}")
            sys.exit(1)
    if len(rtl) != len(ref):
        print(f"LENGTH MISMATCH: rtl retired {len(rtl)}, ref retired {len(ref)}")
        print(f"  last rtl: {rtl[-1] if rtl else '-'}")
        print(f"  last ref: {ref[-1] if ref else '-'}")
        sys.exit(1)
    print(f"MATCH: {len(rtl)} instructions")


if __name__ == "__main__":
    main()
