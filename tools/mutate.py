#!/usr/bin/env python3
"""
Mutation testing: does the test suite actually catch pipeline bugs?

Each mutant is one realistic hardware bug (a missing forwarding path, a
missing stall, a predictor that never trains, ...) injected into a *copy* of
rtl/. The copy is built into its own Verilator model (default configuration)
and checked two ways:
  - random co-simulation seeds (RV32IM) catch functional bugs (wrong results)
  - sw/mext checks spec-defined multiply/divide results directly
  - perftest catches performance bugs: the design still computes the right
    answers, so co-simulation can't see them, but event counts are off
  - sw/cachetest checks exact miss/writeback counts and data integrity, and
    sw/coldload checks the first loads into a cold data cache
A mutant is "killed" if any check fails. A surviving mutant means a hole in
the tests (or an equivalent mutant that doesn't change behavior). Mutants of
the memory system are built with caches in front of slow main memory.

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

CACHED = "CACHES=1"   # build setting for memory-system mutants

# (name, file, original text, mutated text[, build settings])
MUTANTS = [
    ("no MEM->EX forwarding", "rv_core.sv",
     "if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && !mem.is_mul && mem.rd == r)",
     "if (1'b0)"),
    ("no WB->EX forwarding", "rv_core.sv",
     "if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)",
     "if (1'b0)"),
    ("forwarding priority reversed (WB before MEM)", "rv_core.sv",
     """    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && !mem.is_mul && mem.rd == r)
      return mem.result;
    if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)
      return wb.value;""",
     """    if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)
      return wb.value;
    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && !mem.is_mul && mem.rd == r)
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
     "if (redirect_ex || stall_d || !valid_i) begin",
     "if (stall_d || !valid_i) begin"),
    ("JALR keeps bit 0", "rv_core.sv",
     "wire [31:0] jalr_actual = (a_fwd + ex.imm) & ~32'd1;",
     "wire [31:0] jalr_actual = (a_fwd + ex.imm);"),
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
    # --- branch prediction: functional ---
    ("wrongly-taken branch resumes at target, not pc+4", "rv_core.sv",
     "    else if (ex.c.is_branch && !br_cond)  target_ex = ex.pc + 32'd4;  // predicted taken, wasn't\n",
     ""),
    ("prediction not passed to EX", "rv_core.sv",
     "ex.pred_taken <= pred_taken_d;",
     "ex.pred_taken <= 1'b0;"),
    ("EX trusts predicted JALR target", "rv_core.sv",
     "(ex.c.is_jalr && !(ex.jalr_pred && ex.jalr_target == jalr_actual))",
     "(ex.c.is_jalr && !ex.jalr_pred)"),
    ("decode redirect ignores a stall", "rv_core.sv",
     """    else if (!valid_i || stall_d) fetch_pc = pc_d;       // re-read same word
    else if (redirect_id)         fetch_pc = target_id;""",
     """    else if (redirect_id)         fetch_pc = target_id;
    else if (!valid_i || stall_d) fetch_pc = pc_d;"""),
    ("decode redirect outranks EX redirect", "rv_core.sv",
     """    if (redirect_ex)              fetch_pc = target_ex;  // EX outranks ID: ID may be wrong-path
    else if (!valid_i || stall_d) fetch_pc = pc_d;       // re-read same word
    else if (redirect_id)         fetch_pc = target_id;""",
     """    if (redirect_id && valid_i && !stall_d) fetch_pc = target_id;
    else if (redirect_ex)         fetch_pc = target_ex;
    else if (!valid_i || stall_d) fetch_pc = pc_d;"""),
    ("decode drops JAL", "rv_core.sv",
     "wire        redirect_id = (EARLY_JAL && c_d.is_jal) ||",
     "wire        redirect_id = (1'b0 && c_d.is_jal) ||"),
    # --- branch prediction: performance only ---
    ("branch history table never trained up", "rv_core.sv",
     "if (br_cond && bht[ex.bht_idx] != 2'b11)",
     "if (1'b0 && br_cond && bht[ex.bht_idx] != 2'b11)"),
    ("gshare history never updated", "rv_core.sv",
     "ghr <= {ghr[GHR_BITS-2:0], br_cond};",
     "ghr <= ghr;"),
    ("return-address stack never pops", "rv_core.sv",
     "wire ras_pop  = (RAS_DEPTH > 0) && c_d.is_jalr",
     "wire ras_pop  = 1'b0 && (RAS_DEPTH > 0) && c_d.is_jalr"),
    ("return-address stack pushes pc, not pc+4", "rv_core.sv",
     "ras[ras_inc] <= pc_d + 32'd4;",
     "ras[ras_inc] <= pc_d;"),
    # --- M extension: functional ---
    ("no multiply-use stall", "rv_core.sv",
     "wire mul_use  = ex.valid && ex.c.is_mul  && ex_dep;",
     "wire mul_use  = 1'b0 && ex.valid && ex.c.is_mul  && ex_dep;"),
    ("MULHSU treats rs2 as signed", "rv_core.sv",
     "wire b_signed = (f3_e[1:0] == 2'b01);",
     "wire b_signed = (f3_e[1:0] != 2'b11);"),
    ("MULH* return the low word", "rv_core.sv",
     "wire [31:0]        mul_val = (mem.funct3[1:0] == 2'b00) ? product[31:0] : product[63:32];",
     "wire [31:0]        mul_val = product[31:0];"),
    ("divide doesn't hold EX", "rv_core.sv",
     "wire div_stall   = div_pending && !(div_issued && div_done);",
     "wire div_stall   = 1'b0;"),
    ("no MEM bubbles while dividing", "rv_core.sv",
     "mem.valid   <= ex_live && !ex_stall;",
     "mem.valid   <= ex_live;"),
    ("divide by zero returns 0", "rv_divider.sv",
     "result = want_rem ? dividend : 32'hFFFF_FFFF;",
     "result = want_rem ? dividend : 32'h0;"),
    ("REM takes the divisor's sign", "rv_divider.sv",
     "neg_r    <= is_signed && a[31];",
     "neg_r    <= is_signed && b[31];"),
    # --- M extension: performance only ---
    ("divide by zero runs all 32 iterations", "rv_divider.sv",
     """      busy     <= (b != 32'b0);
      done     <= (b == 32'b0);   // divide by zero: result is ready now""",
     """      busy     <= 1'b1;
      done     <= 1'b0;"""),
    # --- caches: functional ---
    ("D-cache dirty bit never set", "rv_dcache.sv",
     "if (store_hit) dirty[hit_way][idx] <= 1'b1;",
     "", CACHED),
    ("D-cache writes back to the missing address", "rv_dcache.sv",
     "assign mem_addr  = (state == WRITEBACK) ? {tags[victim][idx], idx, 4'b0} : {addr[31:4], 4'b0};",
     "assign mem_addr  = {addr[31:4], 4'b0};", CACHED),
    ("D-cache hit ignores the valid bit", "rv_dcache.sv",
     "hit_w[w] = valid[w][idx] && (tags[w][idx] == tag);",
     "hit_w[w] = (tags[w][idx] == tag);", CACHED),
    ("D-cache refills over a dirty victim", "rv_dcache.sv",
     "state  <= (valid[lru_way][idx] && dirty[lru_way][idx]) ? WRITEBACK : FILL;",
     "state  <= FILL;", CACHED),
    ("D-cache store hit writes way 0", "rv_dcache.sv",
     "end else if (store_hit && hit_way == WB_'(w)) begin",
     "end else if (store_hit && w == 0) begin", CACHED),
    ("D-cache load word from the wrong way", "rv_dcache.sv",
     "assign rdata = data_q[way_q][32*off_q +: 32];",
     "assign rdata = data_q[hit_way][32*off_q +: 32];", CACHED),
    ("I-cache hit ignores the tag", "rv_icache.sv",
     "assign hit   = valid_q && (tag_q == pc_id[31:IB+4]);",
     "assign hit   = valid_q;", CACHED),
    ("I-cache miss still decoded", "rv_core.sv",
     "wire        valid_i = valid_d && !fetch_miss;",
     "wire        valid_i = valid_d;", CACHED),
    ("EX operands not refreshed during a stall", "rv_core.sv",
     """        ex.rs1_val <= a_fwd;
        ex.rs2_val <= b_fwd;""",
     "", CACHED),
    # --- caches: performance only ---
    ("D-cache LRU never updated", "rv_dcache.sv",
     "if (WAYS > 1 && req && hit) lru[idx] <= !hit_way[0];",
     "", CACHED),
    ("load-use also counted during a cache stall", "rv_core.sv",
     "assign perf_ev[0] = valid_i && load_use && !redirect_ex && !ex_stall;",
     "assign perf_ev[0] = valid_i && load_use && !redirect_ex;", CACHED),
]

RTL_FILES = ["rv_defs.svh", "rv_alu.sv", "rv_divider.sv", "rv_regfile.sv", "rv_core.sv",
             "rv_ram.sv", "rv_mainmem.sv", "rv_icache.sv", "rv_dcache.sv", "uart_tx.sv", "rv_soc.sv"]


def run(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          errors="replace", **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--first-seed", type=int, default=1000)
    ap.add_argument("--only")
    args = ap.parse_args()

    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    for prog in ("perftest", "mext", "cachetest", "coldload"):
        if run(f"make -s -C {ROOT}/sw PROG={prog}").returncode != 0:
            sys.exit(f"could not build {prog}")
    perftest = f"{ROOT}/sw/build/perftest.hex"
    mext = f"{ROOT}/sw/build/mext.hex"
    cachetest = f"{ROOT}/sw/build/cachetest.hex"
    coldload = f"{ROOT}/sw/build/coldload.hex"
    killed = 0
    mutants = [m for m in MUTANTS if not args.only or args.only in m[0]]
    for name, fname, old, new, *cfg in mutants:
        cfg = cfg[0] if cfg else ""
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
            b = run(f"make -s -C {ROOT}/sim RTL_DIR={rtl} OBJ={obj} {cfg}")
            if b.returncode != 0:
                print(f"  ERROR    {name}: build failed\n{b.stdout}{b.stderr}")
                continue
            r = run(f"{ROOT}/tools/run_random.sh {args.seeds} {args.first_seed} --m",
                    env=dict(env, SIM=f"{obj}/Vrv_soc", KEEP_FAILS="0"))
            summary = r.stdout.strip().splitlines()[-1]
            failed = int(summary.split(",")[1].split()[0])
            p = run(f"{obj}/Vrv_soc +firmware={perftest} +max_cycles=2000000")
            perf_fail = p.returncode != 0 or "perftest: 0 failures" not in p.stdout
            m = run(f"{obj}/Vrv_soc +firmware={mext} +max_cycles=2000000")
            mext_fail = m.returncode != 0 or ", 0 failures" not in m.stdout
            c = run(f"{obj}/Vrv_soc +firmware={cachetest} +max_cycles=5000000")
            k = run(f"{obj}/Vrv_soc +firmware={coldload} +max_cycles=1000000")
            cache_fail = (c.returncode != 0 or "cachetest: 0 failures" not in c.stdout or
                          k.returncode != 0 or "coldload: 0 failures" not in k.stdout)
            dead = failed > 0 or perf_fail or mext_fail or cache_fail
            killed += dead
            f = lambda x: "FAIL" if x else "pass"
            print(f"  {'KILLED' if dead else 'SURVIVED':8} {name:46} "
                  f"random {failed:2}/{args.seeds}  perftest {f(perf_fail)}  mext {f(mext_fail)}"
                  f"  cachetest {f(cache_fail)}")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print(f"{killed}/{len(mutants)} mutants killed")
    sys.exit(0 if killed == len(mutants) else 1)


if __name__ == "__main__":
    main()
