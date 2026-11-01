#!/usr/bin/env python3
"""
Run the official RISC-V architecture tests (riscv-arch-test 2.7.4: RV32I, M,
Zifencei and the machine-mode privilege tests) on the RTL.

Each test is assembled with this target's model_test.h, run on the Verilator
model, and the signature it prints over the UART is compared word for word
with the reference signature shipped with the test suite (produced by the
suite's reference simulator, not by anything in this repository). Every test
is also co-simulated against tools/iss.py.

    compliance/run.py [--sim <Vrv_soc>] [--suite I] [--only add-01]

The default simulator is the standard core built with 4 MB of RAM
(sim/obj_act; the jump/branch tests are up to 2 MB of code), made on demand.
Pass --sim with a build that has the same MEM_WORDS to test another
configuration.

The test suite is cloned into build/riscv-arch-test on first use (or point
ACT_DIR at a checkout of tag 2.7.4).
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.join(ROOT, "compliance")
TAG = "2.7.4"
SUITES = ["I", "M", "Zifencei", "privilege"]
ISA = "RV32IMZicsr_Zifencei"
# Platform facts the tests' RVTEST_CASE conditions ask about
PLATFORM = {"hw_data_misaligned_support": "False"}
RAM_KB = 4096


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, errors="replace", **kw)


def reference_assumes_c(src):
    """In 2.7.4 each test has one reference signature. For tests whose first
    case is for a core with compressed instructions (a jump to pc+2 is legal
    there, and traps without C), that signature was generated with C, so it
    can't be compared on a core without C."""
    m = re.search(r'RVTEST_CASE\(\s*0\s*,\s*"([^"]*)"', open(src).read())
    return m is not None and "regex(.*I.*C.*)" in m.group(1)


def test_defines(src):
    """The RVTEST_CASE whose conditions this core meets, as -D flags
    (riscof normally does this)."""
    for m in re.finditer(r'RVTEST_CASE\(\s*\d+\s*,\s*"([^"]*)"', open(src).read()):
        ok, defs = True, []
        for part in m.group(1).split(";"):
            part = part.strip().lstrip("/").strip()
            if part.startswith("check "):
                key, _, val = part[6:].partition(":=")
                key, val = key.strip(), val.strip()
                if key == "ISA":
                    rx = re.fullmatch(r"regex\((.*)\)", val).group(1)
                    ok &= re.match(rx, ISA) is not None
                else:
                    ok &= PLATFORM.get(key) == val
            elif part.startswith("def "):
                defs.append("-D" + part[4:].strip())
        if ok:
            return defs
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim")
    ap.add_argument("--suite", action="append")
    ap.add_argument("--only")
    ap.add_argument("--no-cosim", action="store_true")
    args = ap.parse_args()

    act = os.environ.get("ACT_DIR") or os.path.join(ROOT, "build", "riscv-arch-test")
    if not os.path.isdir(act):
        r = sh(f"git clone -q -c advice.detachedHead=false --depth 1 --branch {TAG} "
               f"https://github.com/riscv-non-isa/riscv-arch-test.git {act}")
        if r.returncode:
            sys.exit(f"could not clone riscv-arch-test: {r.stderr}")
    suite_dir = os.path.join(act, "riscv-test-suite", "rv32i_m")
    env_dir = os.path.join(act, "riscv-test-suite", "env")
    work = os.path.join(ROOT, "build", "compliance")
    os.makedirs(work, exist_ok=True)
    if not args.sim:
        r = sh(f"make -s -C {ROOT}/sim OBJ=obj_act MEM_WORDS={RAM_KB * 256}")
        if r.returncode:
            sys.exit(f"could not build the simulator: {r.stdout}{r.stderr}")
        args.sim = os.path.join(ROOT, "sim/obj_act/Vrv_soc")

    total = fails = noref = 0
    for suite in args.suite or SUITES:
        srcdir = os.path.join(suite_dir, suite, "src")
        for f in sorted(os.listdir(srcdir)):
            name = f[:-2]
            if args.only and args.only not in name:
                continue
            src = os.path.join(srcdir, f)
            ref = os.path.join(suite_dir, suite, "references", name + ".reference_output")
            defs = test_defines(src)
            if defs is None:
                print(f"  skip  {suite}/{name}: no test case applies to this core")
                continue
            total += 1
            elf, hexf = os.path.join(work, name + ".elf"), os.path.join(work, name + ".hex")
            b = sh(f"clang --target=riscv32-unknown-elf -march=rv32im_zicsr_zifencei -mabi=ilp32 "
                   f"-mno-relax -nostdlib -static -DXLEN=32 {' '.join(defs)} "
                   f"-I{env_dir} -I{HERE} -T{HERE}/link.ld -fuse-ld=lld {src} -o {elf} && "
                   f"llvm-objcopy -O binary {elf} {elf}.bin && "
                   f"python3 {ROOT}/tools/bin2hex.py {elf}.bin {hexf}")
            if b.returncode:
                print(f"  FAIL  {suite}/{name}: build failed\n{b.stderr[-2000:]}")
                fails += 1
                continue
            r = sh(f"{args.sim} +firmware={hexf} +max_cycles=2000000 +trace={work}/{name}.rtl")
            got = r.stdout.split()
            want = open(ref).read().split()
            no_ref = reference_assumes_c(src)
            sig_ok = r.returncode == 0 and (got == want or (no_ref and len(got) == len(want)))
            note = "reference signature is for a core with C: co-simulated only" if no_ref else ""
            if not sig_ok:
                bad = next((i for i, (a, b2) in enumerate(zip(got, want)) if a != b2),
                           min(len(got), len(want)))
                note = (f"signature word {bad}: got {got[bad] if bad < len(got) else '-'}, "
                        f"expected {want[bad] if bad < len(want) else '-'} "
                        f"({len(got)}/{len(want)} words, exit {r.returncode})")
            cos_ok = True
            if sig_ok and not args.no_cosim:
                c = sh(f"PYTHONDONTWRITEBYTECODE=1 python3 {ROOT}/tools/iss.py {hexf} --m --ram-kb {RAM_KB} "
                       f"--trace {work}/{name}.ref --sync {work}/{name}.rtl && "
                       f"python3 {ROOT}/tools/compare.py {work}/{name}.rtl {work}/{name}.ref")
                cos_ok = c.returncode == 0
                if not cos_ok:
                    note = "signature matches, but RTL and reference model disagree: " + \
                           c.stdout.strip().replace("\n", " | ")[:300]
            ok = sig_ok and cos_ok
            fails += not ok
            noref += ok and no_ref
            print(f"  {'pass' if ok else 'FAIL'}  {suite}/{name:24} {len(want):4} words  {note}")
    print(f"compliance: {total - fails}/{total} tests passed "
          f"({total - fails - noref} against the reference signature, {noref} co-simulated only)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
