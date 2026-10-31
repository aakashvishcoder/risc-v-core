#!/usr/bin/env python3
"""
Mutation testing: does the test suite actually catch pipeline bugs?

Each mutant is one realistic hardware bug (a missing forwarding path, a
missing stall, ...) injected into a *copy* of rtl/. The copy is built into
its own Verilator model and run against random co-simulation seeds. A mutant
is "killed" if at least one seed fails. A surviving mutant means a hole in
the tests (or an equivalent mutant that doesn't change behavior).

The real rtl/ directory is never modified.

    tools/mutate.py [--seeds 20] [--only NAME]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (name, file, original text, mutated text)
MUTANTS = [
    ("no MEM->EX forwarding", "rv_core.sv",
     "if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && mem.rd == r)",
     "if (1'b0)"),
    ("no WB->EX forwarding", "rv_core.sv",
     "if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)",
     "if (1'b0)"),
    ("forwarding priority reversed (WB before MEM)", "rv_core.sv",
     """    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && mem.rd == r)
      return mem.result;
    if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)
      return wb.value;""",
     """    if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)
      return wb.value;
    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && mem.rd == r)
      return mem.result;"""),
    ("forwarding from x0", "rv_core.sv",
     "if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)",
     "if (wb.valid && wb.reg_we && wb.rd == r)"),
    ("no load-use stall", "rv_core.sv",
     "wire load_use = ex.valid && ex.c.is_load",
     "wire load_use = 1'b0 && ex.valid && ex.c.is_load"),
    ("load-use ignores rs2", "rv_core.sv",
     "((c_d.uses_rs1 && rs1_d == ex.rd) || (c_d.uses_rs2 && rs2_d == ex.rd))",
     "(c_d.uses_rs1 && rs1_d == ex.rd)"),
    ("no flush after taken branch", "rv_core.sv",
     "if (redirect_ex || stall_d || !valid_d) begin",
     "if (stall_d || !valid_d) begin"),
    ("JALR keeps bit 0", "rv_core.sv",
     "((a_fwd + ex.imm) & ~32'd1)",
     "(a_fwd + ex.imm)"),
    ("BLTU compares signed", "rv_core.sv",
     "3'b110:  br_cond = (a_fwd <  b_fwd);",
     "3'b110:  br_cond = ($signed(a_fwd) <  $signed(b_fwd));"),
    ("LB zero-extends", "rv_core.sv",
     "3'b000:  load_val = {{24{ld_shift[7]}},  ld_shift[7:0]};",
     "3'b000:  load_val = {24'b0, ld_shift[7:0]};"),
    ("SB writes the wrong byte lane", "rv_core.sv",
     "2'b00:   dmem_we = 4'b0001 << byte_off;",
     "2'b00:   dmem_we = 4'b0001;"),
    ("SRA behaves like SRL", "rv_alu.sv",
     "ALU_SRA:  y = $unsigned($signed(a) >>> b[4:0]);",
     "ALU_SRA:  y = a >> b[4:0];"),
    ("register file not write-through", "rv_regfile.sv",
     "(we && wa == ra1) ? wd : regs[ra1]",
     "regs[ra1]"),
]

RTL_FILES = ["rv_defs.svh", "rv_alu.sv", "rv_regfile.sv", "rv_core.sv",
             "rv_ram.sv", "uart_tx.sv", "rv_soc.sv"]


def run(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--first-seed", type=int, default=1000)
    ap.add_argument("--only")
    args = ap.parse_args()

    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    killed = 0
    mutants = [m for m in MUTANTS if not args.only or args.only in m[0]]
    for name, fname, old, new in mutants:
        os.makedirs(os.path.join(ROOT, "out"), exist_ok=True)
        work = tempfile.mkdtemp(prefix="mut_", dir=os.path.join(ROOT, "out"))
        try:
            rtl = os.path.join(work, "rtl")
            os.makedirs(rtl)
            for f in RTL_FILES:
                shutil.copy(os.path.join(ROOT, "rtl", f), rtl)
            path = os.path.join(rtl, fname)
            src = open(path).read()
            if src.count(old) != 1:
                print(f"  SKIP     {name}: pattern not found exactly once in {fname}")
                continue
            open(path, "w").write(src.replace(old, new))

            obj = os.path.join(work, "obj")
            b = run(f"make -s -C {ROOT}/sim RTL_DIR={rtl} OBJ={obj}")
            if b.returncode != 0:
                print(f"  ERROR    {name}: build failed\n{b.stdout}{b.stderr}")
                continue
            r = run(f"{ROOT}/tools/run_random.sh {args.seeds} {args.first_seed}",
                    env=dict(env, SIM=f"{obj}/Vrv_soc", KEEP_FAILS="0"))
            summary = r.stdout.strip().splitlines()[-1]
            failed = int(summary.split(",")[1].split()[0])
            status = "KILLED" if failed else "SURVIVED"
            killed += bool(failed)
            print(f"  {status:8} {name:46} ({failed}/{args.seeds} seeds fail)")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print(f"{killed}/{len(mutants)} mutants killed")
    sys.exit(0 if killed == len(mutants) else 1)


if __name__ == "__main__":
    main()
