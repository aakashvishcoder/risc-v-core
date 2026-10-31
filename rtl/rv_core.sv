`include "rv_defs.svh"

// ---------------------------------------------------------------------------
// rv_core: 5-stage in-order RV32I pipeline
//
//   IF  : PC drives the synchronous instruction BRAM (address = fetch_pc)
//   ID  : BRAM output decoded, register file read, hazard detection
//   EX  : ALU, branch resolution, forwarding, data BRAM address/write
//   MEM : synchronous data BRAM output aligned / sign extended
//   WB  : register file write, retirement
//
// Hazards
//   - Data   : full forwarding from MEM and WB into EX; regfile write-through
//              covers WB -> ID. A load followed by a dependent instruction
//              stalls one cycle (load-use).
//   - Control: branches are predicted in ID (see BPRED) and resolve in EX;
//              a misprediction or a JALR flushes the instruction in ID
//              (1-cycle penalty). JAL's target is pc + imm, known as soon as it's
//              decoded, so with EARLY_JAL decode redirects fetch directly.
//              Because IF is only an address phase, a redirect from ID costs
//              nothing: the next address is chosen in the same cycle.
//
// Memories are synchronous-read (1 cycle), matching Xilinx block RAM. Because
// of that, "IF" is just the address phase: the fetched word appears on
// imem_rdata at the start of ID.
//
// Traps (machine mode only) are precise and are all taken in EX, the one
// place an instruction's fate is decided: every exception is known there
// (decode flags, the load/store address, the jump target), nothing older can
// still fault, and nothing younger has changed any state yet - the only
// younger instruction is in ID, and is flushed. Taking a trap squashes the
// instruction in EX (no register, memory or CSR write), saves mepc/mcause/
// mtval and redirects fetch to mtvec, exactly like a mispredicted branch. A
// marker travels down MEM and WB in the squashed slot so the trap shows up in
// the commit trace in program order.
// ---------------------------------------------------------------------------
module rv_core #(
  parameter logic [31:0] RESET_PC  = 32'h0000_0000,
  parameter bit          EARLY_JAL = 1'b1,    // resolve JAL in decode (0-cycle penalty)
  parameter int          BPRED     = 3,       // 0 not-taken, 1 BTFN, 2 bimodal, 3 gshare
  parameter int          BHT_BITS  = 8,       // log2(branch history table entries)
  parameter int          GHR_BITS  = 8,       // gshare global history length
  parameter int          RAS_DEPTH = 8,       // return-address stack entries (0 = none)
  parameter int          IBTB_BITS = 4,       // log2(indirect jump target buffer entries), 0 = none
  parameter int          M_EXT     = 2,       // 0 none, 1 Zmmul (multiply only), 2 full M
  parameter logic [31:0] MCACHE    = 32'b0,   // cache geometry, reported in the mcache CSR
  parameter int          RAM_BYTES = 65536,   // RAM at address 0; fetches beyond it fault
  // Data addresses outside RAM, the CLINT and the I/O page raise access faults
  parameter logic [31:0] CLINT_BASE = 32'h0200_0000,   // 64 KiB
  parameter logic [31:0] IO_BASE    = 32'h1000_0000    // 256 B
) (
  input  logic        clk,
  input  logic        rst,

  // Instruction memory (sync read: rdata is valid the cycle after addr)
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  input  logic        imem_valid,   // imem_rdata holds the instruction at pc_d (I-cache hit)
  output logic [31:0] imem_pc,      // pc_d: address imem_rdata should belong to
  output logic        imem_lookup,  // ID holds a real fetch (for the I-cache)
  output logic        imem_kill,    // ... which is being flushed this cycle

  // Data memory (sync read)
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_we,
  output logic        dmem_re,
  input  logic [31:0] dmem_rdata,
  input  logic        dmem_stall,   // the access in EX must wait (D-cache miss)

  // Cache events for the performance counters (one pulse each)
  input  logic        ev_icache_miss,
  input  logic        ev_dcache_miss,
  input  logic        ev_dcache_wb,

  // Retirement port (for tracing / verification)
  output logic        commit_valid,
  output logic [31:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic        commit_rd_we,
  output logic [4:0]  commit_rd,
  output logic [31:0] commit_rd_val,
  output logic        commit_trap,   // a trap was taken (in place of a retirement)
  output logic [31:0] commit_cause,  // ... its mcause; commit_pc is mepc
  output logic [31:0] commit_tval
);

  // -------------------------------------------------------------------------
  // Pipeline register types
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic       reg_we;
    logic       uses_rs1;
    logic       uses_rs2;
    logic [1:0] a_sel;
    logic       b_imm;
    logic [3:0] alu_op;
    logic       is_branch;
    logic       is_jal;
    logic       is_jalr;
    logic       is_load;
    logic       is_store;
    logic       is_mul;
    logic       is_div;
    logic [1:0] wb_sel;
    logic       is_csr;       // CSRRW/S/C[I]
    logic       is_ecall;
    logic       is_ebreak;
    logic       is_mret;
    logic       illegal;      // not a valid RV32IM/Zicsr instruction
    logic       fetch_fault;  // fetched from outside RAM
  } ctrl_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic        pred_taken;   // decode predicted taken and already redirected
    logic [BHT_BITS-1:0] bht_idx;  // table entry used for the prediction
    logic        jalr_pred;    // decode already followed a predicted JALR target
    logic [31:0] jalr_target;  // ... and this is the target it followed
    logic        ras_popped;   // the prediction came from the return-address stack
    ctrl_t       c;
  } idex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_we;
    logic        is_load;
    logic        is_mul;
    logic [2:0]  funct3;
    logic [1:0]  addr_lo;
    logic [31:0] result;
    logic [32:0] mul_a;    // sign/zero-extended multiplier operands
    logic [32:0] mul_b;
    logic        trap;     // slot squashed by a trap: pc = mepc
    logic [31:0] cause;
    logic [31:0] tval;
  } exmem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_we;
    logic [31:0] value;
    logic        trap;
    logic [31:0] cause;
    logic [31:0] tval;
  } memwb_t;

  idex_t  ex;
  exmem_t mem;
  memwb_t wb;

  logic [63:0] cycle_ctr, instret_ctr;

  // -------------------------------------------------------------------------
  // IF / ID
  // -------------------------------------------------------------------------
  logic [31:0] pc_d;         // PC of the instruction on imem_rdata
  logic        valid_d;

  // valid_i: ID holds a real instruction. A fetch that missed in the
  // instruction cache is treated exactly like no fetch at all. A fetch from
  // outside RAM doesn't look in memory at all: it becomes a NOP carrying an
  // access fault, which is raised when it reaches EX.
  wire        fetch_fault = (pc_d >= 32'(RAM_BYTES));
  wire        fetch_miss  = valid_d && !imem_valid && !fetch_fault;
  wire        valid_i = valid_d && !fetch_miss;
  wire [31:0] instr_d = (valid_i && !fetch_fault) ? imem_rdata : INSTR_NOP;
  wire [6:0]  opcode  = instr_d[6:0];
  wire [4:0]  rd_d    = instr_d[11:7];
  wire [2:0]  f3_d    = instr_d[14:12];
  wire [4:0]  rs1_d   = instr_d[19:15];
  wire [4:0]  rs2_d   = instr_d[24:20];
  wire [6:0]  f7_d    = instr_d[31:25];

  wire [31:0] imm_i = {{20{instr_d[31]}}, instr_d[31:20]};
  wire [31:0] imm_s = {{20{instr_d[31]}}, instr_d[31:25], instr_d[11:7]};
  wire [31:0] imm_b = {{19{instr_d[31]}}, instr_d[31], instr_d[7], instr_d[30:25], instr_d[11:8], 1'b0};
  wire [31:0] imm_u = {instr_d[31:12], 12'b0};
  wire [31:0] imm_j = {{11{instr_d[31]}}, instr_d[31], instr_d[19:12], instr_d[20], instr_d[30:21], 1'b0};

  ctrl_t       c_d;
  logic [31:0] imm_d;

  always_comb begin
    c_d        = '0;
    c_d.fetch_fault = fetch_fault;
    c_d.a_sel  = A_RS1;
    c_d.wb_sel = WB_ALU;
    c_d.alu_op = ALU_ADD;
    imm_d      = imm_i;

    unique case (opcode)
      OP_LUI: begin
        c_d.reg_we = 1; c_d.a_sel = A_ZERO; c_d.b_imm = 1; imm_d = imm_u;
      end
      OP_AUIPC: begin
        c_d.reg_we = 1; c_d.a_sel = A_PC; c_d.b_imm = 1; imm_d = imm_u;
      end
      OP_JAL: begin
        c_d.reg_we = 1; c_d.wb_sel = WB_PC4; c_d.is_jal = 1; imm_d = imm_j;
      end
      OP_JALR: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.wb_sel = WB_PC4; c_d.is_jalr = 1;
        c_d.illegal = (f3_d != 3'b000);
      end
      OP_BRANCH: begin
        c_d.uses_rs1 = 1; c_d.uses_rs2 = 1; c_d.is_branch = 1; imm_d = imm_b;
        c_d.illegal = (f3_d == 3'b010) || (f3_d == 3'b011);
      end
      OP_LOAD: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.b_imm = 1; c_d.is_load = 1;
        c_d.illegal = (f3_d == 3'b011) || (f3_d == 3'b110) || (f3_d == 3'b111);
      end
      OP_STORE: begin
        c_d.uses_rs1 = 1; c_d.uses_rs2 = 1; c_d.b_imm = 1; c_d.is_store = 1; imm_d = imm_s;
        c_d.illegal = (f3_d[2] == 1'b1) || (f3_d == 3'b011);
      end
      OP_IMM: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.b_imm = 1;
        // Only shifts use instr[30] as an op bit for immediates
        c_d.alu_op = {(f3_d == 3'b101) & instr_d[30], f3_d};
        if (f3_d == 3'b001) c_d.illegal = (f7_d != 7'b0);
        if (f3_d == 3'b101) c_d.illegal = (f7_d != 7'b0) && (f7_d != 7'b0100000);
      end
      OP_REG: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.uses_rs2 = 1;
        c_d.alu_op = {instr_d[30], f3_d};
        if (f7_d == 7'b0000001) begin
          // M extension: MUL/MULH/MULHSU/MULHU (funct3 0-3),
          //              DIV/DIVU/REM/REMU     (funct3 4-7)
          c_d.is_mul = (M_EXT >= 1) && !f3_d[2];
          c_d.is_div = (M_EXT >= 2) &&  f3_d[2];
          c_d.wb_sel = c_d.is_div ? WB_DIV : WB_ALU;
          c_d.illegal = !(c_d.is_mul || c_d.is_div);
        end else begin
          c_d.illegal = !((f7_d == 7'b0) ||
                          (f7_d == 7'b0100000 && (f3_d == 3'b000 || f3_d == 3'b101)));
        end
      end
      OP_FENCE: ; // no caches or reordering: NOP
      OP_SYSTEM: begin
        if (f3_d == 3'b000) begin
          unique case (instr_d)
            32'h0000_0073: c_d.is_ecall  = 1;
            32'h0010_0073: c_d.is_ebreak = 1;
            32'h3020_0073: c_d.is_mret   = 1;
            32'h1050_0073: ;                     // WFI: a hint, executed as a NOP
            default:       c_d.illegal   = 1;
          endcase
        end else if (f3_d == 3'b100) begin
          c_d.illegal = 1;
        end else begin
          // CSRRW/S/C (rs1) and CSRRWI/SI/CI (5-bit zero-extended immediate in
          // the rs1 field). Whether the CSR exists or may be written is checked
          // in EX, where the CSR file is.
          c_d.reg_we = 1; c_d.wb_sel = WB_CSR; c_d.is_csr = 1;
          c_d.uses_rs1 = !f3_d[2];
        end
      end
      default: c_d.illegal = 1;
    endcase
  end

  // Register file
  logic [31:0] rf_rd1, rf_rd2;
  rv_regfile u_rf (
    .clk (clk),
    .ra1 (rs1_d), .ra2 (rs2_d),
    .rd1 (rf_rd1), .rd2 (rf_rd2),
    .we  (wb.valid && wb.reg_we),
    .wa  (wb.rd),
    .wd  (wb.value)
  );

  // Late-result hazard: EX holds a load or a multiply whose result the ID
  // instruction needs. Both produce their result at the end of MEM (load data
  // from the RAM, the product from the MEM-stage multiplier), so forwarding
  // can't help and ID stalls one cycle.
  wire ex_dep   = (ex.rd != 5'd0) &&
                  ((c_d.uses_rs1 && rs1_d == ex.rd) || (c_d.uses_rs2 && rs2_d == ex.rd));
  wire load_use = ex.valid && ex.c.is_load && ex_dep;
  wire mul_use  = ex.valid && ex.c.is_mul  && ex_dep;

  // -------------------------------------------------------------------------
  // EX
  // -------------------------------------------------------------------------
  // Forwarding: youngest producer wins (MEM before WB). A load or multiply in
  // MEM can't forward (its result isn't ready until the end of MEM) - the
  // late-result stall covers it.
  function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] v);
    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && !mem.is_mul && mem.rd == r)
      return mem.result;
    if (r != 5'd0 && wb.valid && wb.reg_we && wb.rd == r)
      return wb.value;
    return v;
  endfunction

  wire [31:0] a_fwd = fwd(ex.rs1, ex.rs1_val);
  wire [31:0] b_fwd = fwd(ex.rs2, ex.rs2_val);

  wire [31:0] op_a = (ex.c.a_sel == A_PC)   ? ex.pc :
                     (ex.c.a_sel == A_ZERO) ? 32'b0 : a_fwd;
  wire [31:0] op_b = ex.c.b_imm ? ex.imm : b_fwd;

  logic [31:0] alu_y;
  rv_alu u_alu (.op(ex.c.alu_op), .a(op_a), .b(op_b), .y(alu_y));

  wire [2:0] f3_e = ex.instr[14:12];
  logic br_cond;
  always_comb begin
    unique case (f3_e)
      3'b000:  br_cond = (a_fwd == b_fwd);
      3'b001:  br_cond = (a_fwd != b_fwd);
      3'b100:  br_cond = ($signed(a_fwd) <  $signed(b_fwd));
      3'b101:  br_cond = ($signed(a_fwd) >= $signed(b_fwd));
      3'b110:  br_cond = (a_fwd <  b_fwd);
      3'b111:  br_cond = (a_fwd >= b_fwd);
      default: br_cond = 1'b0;
    endcase
  end

  // Control-flow resolution. A conditional branch redirects when its outcome
  // differs from the decode-stage prediction (pred_taken); jumps whose target
  // wasn't already followed in decode redirect too, and so does MRET (to
  // mepc). A trap redirects to the trap vector and overrides everything: the
  // instruction in EX doesn't execute (ex_live is low).
  wire ex_live       = ex.valid && !trap_take;
  wire br_mispredict = ex_live && ex.c.is_branch && (br_cond != ex.pred_taken);
  wire [31:0] jalr_actual = (a_fwd + ex.imm) & ~32'd1;
  wire jmp_redirect  = ex_live && ((ex.c.is_jal && !EARLY_JAL) ||
                                   (ex.c.is_jalr && !(ex.jalr_pred && ex.jalr_target == jalr_actual)) ||
                                   ex.c.is_mret);
  wire redirect_ex   = br_mispredict || jmp_redirect || trap_take;

  logic [31:0] target_ex;
  always_comb begin
    if (trap_take)                        target_ex = trap_vector;
    else if (ex.c.is_mret)                target_ex = mepc;
    else if (ex.c.is_jalr)                target_ex = jalr_actual;
    else if (ex.c.is_branch && !br_cond)  target_ex = ex.pc + 32'd4;  // predicted taken, wasn't
    else                                  target_ex = ex.pc + ex.imm;
  end

  // Remember the real target of JALRs the return-address stack didn't predict
  wire [IB_IW-1:0] ib_idx_e = (IBTB_BITS > 0) ? IB_IW'(ex.pc[IBTB_BITS+1:2]) : '0;
  always_ff @(posedge clk) begin
    if (IBTB_BITS > 0 && !rst && ex_live && ex.c.is_jalr && !ex.ras_popped) begin
      ib_valid[ib_idx_e]  <= 1'b1;
      ib_tag[ib_idx_e]    <= ex.pc[31:IBTB_BITS+2];
      ib_target[ib_idx_e] <= jalr_actual;
    end
  end

  // Train the branch history table and shift the outcome into the history
  always_ff @(posedge clk) begin
    if (rst) begin
      ghr <= '0;
    end else if (BPRED >= 2 && ex_live && ex.c.is_branch) begin
      if (br_cond && bht[ex.bht_idx] != 2'b11)       bht[ex.bht_idx] <= bht[ex.bht_idx] + 2'd1;
      else if (!br_cond && bht[ex.bht_idx] != 2'b00) bht[ex.bht_idx] <= bht[ex.bht_idx] - 2'd1;
      ghr <= {ghr[GHR_BITS-2:0], br_cond};
    end
  end

  // -------------------------------------------------------------------------
  // Performance events, counted in hpmcounter3..9 (events are hardwired, so
  // the mhpmevent selectors are not implemented).
  //   3  load-use stall cycles     ID held because EX has a load it depends on
  //   4  flush cycles              cycles lost to a redirect from EX
  //   5  conditional branches      resolved in EX
  //   6  taken conditional branches
  //   7  jumps                     JAL + JALR + MRET
  //   8  branch mispredictions     (redirects caused by a conditional branch)
  //   9  jump redirects from EX    (jumps not followed in decode, or followed
  //                                 to the wrong target)
  //  10  multiply-use stall cycles ID held because EX has a multiply it depends on
  //  11  divider stall cycles      EX busy with a divide
  //  12  I-cache stall cycles      ID empty because its fetch missed
  //  13  D-cache stall cycles      EX waiting for a data-cache miss
  //  14  I-cache misses
  //  15  D-cache misses
  //  16  D-cache dirty writebacks
  //  17  traps taken               exceptions + interrupts
  // Every flush has exactly one cause, so event 4 == events 8 + 9 + 17. A trap
  // also wastes the slot of the instruction it squashes, so
  //   cycles = instret + load-use + multiply-use + divider + I-cache + D-cache
  //            stalls + flushes + traps + fill.
  // -------------------------------------------------------------------------
  localparam int NHPM = 15;              // hpmcounter3 .. hpmcounter17
  logic [NHPM-1:0] perf_ev;
  logic [63:0]     hpm [NHPM];

  // Each lost cycle has exactly one cause: a load waiting in EX on a cache
  // miss is a D-cache stall, not also a load-use stall for the instruction
  // behind it.
  assign perf_ev[0] = valid_i && load_use && !redirect_ex && !ex_stall;
  assign perf_ev[1] = redirect_ex;
  assign perf_ev[2] = ex_live && ex.c.is_branch;
  assign perf_ev[3] = ex_live && ex.c.is_branch && br_cond;
  assign perf_ev[4] = ex_live && (ex.c.is_jal || ex.c.is_jalr || ex.c.is_mret);
  assign perf_ev[5] = br_mispredict;
  assign perf_ev[6] = jmp_redirect;
  assign perf_ev[7] = valid_i && mul_use && !redirect_ex && !ex_stall;
  assign perf_ev[8]  = div_stall;
  assign perf_ev[9]  = fetch_miss && !redirect_ex && !ex_stall;
  assign perf_ev[10] = mem_stall;
  assign perf_ev[11] = ev_icache_miss;
  assign perf_ev[12] = ev_dcache_miss;
  assign perf_ev[13] = ev_dcache_wb;
  assign perf_ev[14] = trap_take;


  // Read-only configuration register in the custom machine CSR space, so
  // software (tests, benchmarks) can tell which features this build has.
  //   [0]     JAL resolved in decode
  //   [3:1]   branch predictor: 0 not-taken, 1 BTFN, 2 bimodal, 3 gshare
  //   [11:4]  return-address stack depth (0 = none)
  //   [15:12] log2(indirect jump target buffer entries) (0 = none)
  //   [19:16] log2(branch history table entries)
  //   [23:20] gshare global history length
  //   [25:24] M extension: 0 none, 1 Zmmul (multiply only), 2 full M
  localparam logic [11:0] CSR_MCONFIG = 12'hFC0;
  // mcache (0xFC1): [0] caches present, [7:4] log2(I-cache lines),
  //   [11:8] log2(D-cache sets), [15:12] log2(D-cache ways),
  //   [31:16] main memory latency. Lines are 16 bytes.
  localparam logic [11:0] CSR_MCACHE  = 12'hFC1;
  wire [31:0] mconfig = {6'b0, 2'(M_EXT), 4'(GHR_BITS), 4'(BHT_BITS), 4'(IBTB_BITS),
                         8'(RAS_DEPTH), 3'(BPRED), EARLY_JAL};

  // -------------------------------------------------------------------------
  // Machine-mode CSRs
  //   mstatus  0x300  MIE [3], MPIE [7]; MPP [12:11] reads 11 (M is the only mode)
  //   misa     0x301  read-only
  //   mie      0x304  MSIE [3], MTIE [7], MEIE [11]
  //   mtvec    0x305  BASE [31:2], MODE [0]: 0 direct, 1 vectored (interrupts
  //                   go to BASE + 4*cause)
  //   mcountinhibit 0x320  freezes cycle [0], instret [2], hpmcounterN [N]
  //   mscratch 0x340, mepc 0x341 ([1:0] = 0), mcause 0x342, mtval 0x343
  //   mip      0x344  read-only: pending interrupts
  //   mcycle, minstret, mhpmcounter3..31 (+h): writable; 17..31 read 0
  //   cycle, time, instret, hpmcounterN (+h): read-only shadows (time = cycle)
  //   mvendorid/marchid/mimpid/mhartid read 0; mconfig, mcache (custom)
  // Accessing any other CSR, or writing a read-only one (0xC00-0xFFF), is an
  // illegal instruction. CSRRS/CSRRC with x0 (or zimm 0) only read.
  // -------------------------------------------------------------------------
  logic        mst_mie, mst_mpie;
  logic [31:0] mie_r, mtvec, mscratch, mepc, mcause, mtval, mcountinhibit;
  wire  [31:0] mip = 32'b0;                       // no interrupt sources yet
  wire  [31:0] mstatus = {19'b0, 2'b11, 3'b0, mst_mpie, 3'b0, mst_mie, 3'b0};

  wire [11:0] csr_addr = ex.instr[31:20];
  // mcycle/minstret/mhpmcounterN (0xB0x/0xB8x, not 0xB01/0xB81) and their
  // read-only shadows (0xC0x/0xC8x)
  wire csr_counter = (csr_addr[11:8] == 4'hB || csr_addr[11:8] == 4'hC) && csr_addr[6:5] == 2'b00 &&
                     (csr_addr[4:0] != 5'd1 || csr_addr[11:8] == 4'hC);
  logic csr_known;
  always_comb begin
    unique case (csr_addr)
      12'h300, 12'h301, 12'h304, 12'h305, 12'h320, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
      12'hF11, 12'hF12, 12'hF13, 12'hF14, CSR_MCONFIG, CSR_MCACHE: csr_known = 1'b1;
      default: csr_known = csr_counter;
    endcase
  end
  wire csr_writes  = ex.c.is_csr && (f3_e[1:0] == 2'b01 || ex.rs1 != 5'd0);
  wire csr_illegal = ex.c.is_csr && (!csr_known || (csr_writes && csr_addr[11:10] == 2'b11));

  logic [31:0] csr_val;
  always_comb begin
    unique case (csr_addr)
      12'hC00, 12'hC01, 12'hB00: csr_val = cycle_ctr[31:0];
      12'hC80, 12'hC81, 12'hB80: csr_val = cycle_ctr[63:32];
      12'hC02, 12'hB02:          csr_val = instret_ctr[31:0];
      12'hC82, 12'hB82:          csr_val = instret_ctr[63:32];
      12'h300:                   csr_val = mstatus;
      12'h301:                   csr_val = (M_EXT >= 2) ? 32'h4000_1100    // misa: RV32IM
                                                    : 32'h4000_0100;   //       RV32I
      12'h304:                   csr_val = mie_r;
      12'h305:                   csr_val = mtvec;
      12'h320:                   csr_val = mcountinhibit;
      12'h340:                   csr_val = mscratch;
      12'h341:                   csr_val = mepc;
      12'h342:                   csr_val = mcause;
      12'h343:                   csr_val = mtval;
      12'h344:                   csr_val = mip;
      CSR_MCONFIG:               csr_val = mconfig;
      CSR_MCACHE:                csr_val = MCACHE;
      default:                   csr_val = 32'b0;          // mhartid etc.
    endcase
    // hpmcounterN / mhpmcounterN (low halves at C0N/B0N, high at C8N/B8N)
    for (int k = 0; k < NHPM; k++) begin
      if (ex.instr[31:20] == (12'hC03 + k[11:0]) || ex.instr[31:20] == (12'hB03 + k[11:0]))
        csr_val = hpm[k][31:0];
      if (ex.instr[31:20] == (12'hC83 + k[11:0]) || ex.instr[31:20] == (12'hB83 + k[11:0]))
        csr_val = hpm[k][63:32];
    end
  end

  // Read-modify-write: CSRRW writes the source, CSRRS sets its bits, CSRRC
  // clears them. The source is rs1, or the zero-extended 5-bit immediate.
  wire [31:0] csr_src = f3_e[2] ? {27'b0, ex.rs1} : a_fwd;
  logic [31:0] csr_new;
  always_comb begin
    unique case (f3_e[1:0])
      2'b01:   csr_new = csr_src;
      2'b10:   csr_new = csr_val | csr_src;
      default: csr_new = csr_val & ~csr_src;
    endcase
  end
  wire csr_we = ex_live && csr_writes;
  function automatic logic csr_wr(input logic [11:0] n);
    return csr_we && csr_addr == n;
  endfunction

  // -------------------------------------------------------------------------
  // Exceptions of the instruction in EX, in priority order
  // -------------------------------------------------------------------------
  wire        is_ls  = ex.c.is_load || ex.c.is_store;
  wire [31:0] ls_addr = alu_y;
  wire ls_misaligned = (f3_e[1:0] == 2'b01 && ls_addr[0]) ||          // half
                       (f3_e[1:0] == 2'b10 && ls_addr[1:0] != 2'b00);  // word
  wire ls_mapped     = (ls_addr < 32'(RAM_BYTES)) ||
                       (ls_addr[31:16] == CLINT_BASE[31:16]) ||
                       (ls_addr[31:8]  == IO_BASE[31:8]);
  // There are no compressed instructions, so a jump or taken branch to an
  // address that isn't word-aligned faults (on the jump itself)
  wire [31:0] jump_target = ex.c.is_jalr ? jalr_actual : ex.pc + ex.imm;
  wire jump_misaligned = (ex.c.is_jal || ex.c.is_jalr || (ex.c.is_branch && br_cond)) &&
                         jump_target[1];

  logic        exc;
  logic [31:0] exc_cause, exc_tval;
  always_comb begin
    exc = 1'b1;
    exc_tval = 32'b0;
    if (ex.c.fetch_fault)                begin exc_cause = 32'd1;  exc_tval = ex.pc; end
    else if (ex.c.illegal || csr_illegal) begin exc_cause = 32'd2;  exc_tval = ex.instr; end
    else if (ex.c.is_ecall)                    exc_cause = 32'd11;
    else if (ex.c.is_ebreak)             begin exc_cause = 32'd3;  exc_tval = ex.pc; end
    else if (jump_misaligned)            begin exc_cause = 32'd0;  exc_tval = jump_target; end
    else if (is_ls && ls_misaligned)     begin exc_cause = ex.c.is_load ? 32'd4 : 32'd6; exc_tval = ls_addr; end
    else if (is_ls && !ls_mapped)        begin exc_cause = ex.c.is_load ? 32'd5 : 32'd7; exc_tval = ls_addr; end
    else begin exc = 1'b0; exc_cause = 32'b0; end
  end

  wire        trap_take   = ex.valid && exc;
  wire [31:0] trap_cause  = exc_cause;
  wire [31:0] trap_tval   = exc_tval;
  wire [31:0] trap_vector = {mtvec[31:2], 2'b00};

  logic [31:0] ex_result;
  always_comb begin
    unique case (ex.c.wb_sel)
      WB_PC4:  ex_result = ex.pc + 32'd4;
      WB_CSR:  ex_result = csr_val;
      WB_DIV:  ex_result = div_result;
      default: ex_result = alu_y;
    endcase
  end

  // Multiplier operands, sign- or zero-extended to 33 bits so one signed
  // 33x33 multiply covers all four variants:
  //   MUL / MULHU: unsigned x unsigned   MULH: signed x signed
  //   MULHSU:      signed x unsigned
  wire a_signed = (f3_e[1:0] == 2'b01) || (f3_e[1:0] == 2'b10);   // MULH, MULHSU
  wire b_signed = (f3_e[1:0] == 2'b01);                           // MULH
  wire [32:0] mul_a_e = {a_signed & a_fwd[31], a_fwd};
  wire [32:0] mul_b_e = {b_signed & b_fwd[31], b_fwd};

  // -------------------------------------------------------------------------
  // Divider: iterative, so a divide holds EX until it's done (33 cycles: one
  // to start, 32 iterations; divide by zero takes one). Everything behind it
  // waits in ID; MEM gets bubbles. The result leaves EX like an ALU result,
  // so a dependent instruction gets it by forwarding with no extra stall.
  // -------------------------------------------------------------------------
  logic        div_issued, div_busy, div_done;
  logic [31:0] div_result;
  wire div_pending = (M_EXT >= 2) && ex_live && ex.c.is_div;
  wire div_start   = div_pending && !div_issued;
  wire div_stall   = div_pending && !(div_issued && div_done);
  // A load or store in EX that misses in the data cache waits there too
  wire mem_stall   = ex_live && is_ls && dmem_stall;
  wire ex_stall    = div_stall || mem_stall;

  generate
    if (M_EXT >= 2) begin : g_div
      rv_divider u_div (
        .clk, .rst,
        .start  (div_start),
        .op     (f3_e[1:0]),
        .a      (a_fwd),
        .b      (b_fwd),
        .busy   (div_busy),
        .done   (div_done),
        .result (div_result)
      );
    end else begin : g_nodiv
      assign div_busy   = 1'b0;
      assign div_done   = 1'b0;
      assign div_result = 32'b0;
    end
  endgenerate

  // Data memory request (address = ALU result for loads/stores)
  wire [1:0] byte_off = alu_y[1:0];
  always_comb begin
    dmem_addr  = {alu_y[31:2], 2'b00};
    dmem_re    = ex_live && ex.c.is_load;      // a faulting access never reaches memory
    dmem_wdata = b_fwd << {byte_off, 3'b000};
    dmem_we    = 4'b0000;
    if (ex_live && ex.c.is_store) begin
      unique case (f3_e[1:0])
        2'b00:   dmem_we = 4'b0001 << byte_off;
        2'b01:   dmem_we = 4'b0011 << byte_off;
        default: dmem_we = 4'b1111;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Fetch PC
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // Branch prediction (decode stage)
  // A branch predicted taken redirects fetch to pc + imm straight from ID, for
  // free; EX checks the real outcome and redirects to the right path if the
  // prediction was wrong (1-cycle penalty either way).
  //   BPRED 0: always not-taken
  //   BPRED 1: static BTFN - backward branches (loops) taken, forward not
  //   BPRED 2: bimodal - 2^BHT_BITS two-bit saturating counters indexed by
  //            pc, read in ID and trained in EX with the real outcome
  //   BPRED 3: gshare - same table, indexed by pc XOR the global history of
  //            the last GHR_BITS branch outcomes, so one branch gets separate
  //            counters for different paths leading to it. The history is
  //            updated in EX with real outcomes (non-speculatively), so a
  //            branch decoded right behind another branch doesn't see that
  //            branch's outcome yet.
  //
  // No repair logic is needed: a branch resolves in EX while the instruction
  // after it is in ID, so nothing past a branch ever executes before the
  // branch is resolved, and the table is only trained by real branches.
  // -------------------------------------------------------------------------
  logic [1:0] bht [2**BHT_BITS];
  initial for (int i = 0; i < 2**BHT_BITS; i++) bht[i] = 2'b01;   // weakly not-taken

  logic [GHR_BITS-1:0] ghr;

  // Fold the history down (or zero-extend it) to the table index width
  function automatic logic [BHT_BITS-1:0] fold_ghr(input logic [GHR_BITS-1:0] h);
    logic [BHT_BITS-1:0] f = '0;
    for (int i = 0; i < GHR_BITS; i++) f[i % BHT_BITS] ^= h[i];
    return f;
  endfunction

  wire [BHT_BITS-1:0] bht_idx_d = (BPRED == 3) ? (pc_d[BHT_BITS+1:2] ^ fold_ghr(ghr))
                                               : pc_d[BHT_BITS+1:2];

  logic pred_taken_d;
  always_comb begin
    unique case (BPRED)
      1:       pred_taken_d = imm_b[31];             // negative offset = backward
      2, 3:    pred_taken_d = bht[bht_idx_d][1];     // counter's MSB
      default: pred_taken_d = 1'b0;
    endcase
    pred_taken_d = pred_taken_d && c_d.is_branch;
  end

  // -------------------------------------------------------------------------
  // Return-address stack (decode stage)
  // Uses the RISC-V hints for which registers are links (x1, x5):
  //   JAL/JALR with rd = link                 push pc+4    (call)
  //   JALR, rs1 = link, rd != link            pop          (return)
  //   JALR, rd and rs1 both links, rd != rs1  pop, then push (coroutine swap)
  // A popped address is a predicted target: decode redirects to it, and EX
  // checks it against the real target. The stack is a circular buffer, so
  // overflow overwrites the oldest entry and deep recursion simply
  // mispredicts. It's updated only when an instruction leaves ID for EX, and
  // everything that reaches EX retires, so it never sees wrong-path calls.
  // -------------------------------------------------------------------------
  localparam int RAS_N = (RAS_DEPTH > 0) ? RAS_DEPTH : 1;
  localparam int RAS_W = (RAS_N > 1) ? $clog2(RAS_N) : 1;
  logic [31:0]      ras [RAS_N];
  logic [RAS_W-1:0] ras_top;               // index of the most recent entry

  wire rd_link  = (rd_d  == 5'd1) || (rd_d  == 5'd5);
  wire rs1_link = (rs1_d == 5'd1) || (rs1_d == 5'd5);
  wire ras_pop  = (RAS_DEPTH > 0) && c_d.is_jalr && rs1_link && !(rd_link && rd_d == rs1_d);
  wire ras_push = (RAS_DEPTH > 0) && (c_d.is_jal || c_d.is_jalr) && rd_link;
  wire [RAS_W-1:0] ras_dec = (ras_top == '0) ? RAS_W'(RAS_N - 1) : ras_top - 1'b1;
  wire [RAS_W-1:0] ras_inc = (ras_top == RAS_W'(RAS_N - 1)) ? '0 : ras_top + 1'b1;

  // -------------------------------------------------------------------------
  // Indirect jump target buffer (decode stage)
  // For JALRs the return-address stack doesn't cover (switch tables, calls
  // through function pointers): a direct-mapped table indexed by pc that
  // remembers each JALR's last target, tagged with the rest of the pc.
  // Written in EX with the real target.
  // -------------------------------------------------------------------------
  localparam int IB_N   = (IBTB_BITS > 0) ? 2**IBTB_BITS : 1;
  localparam int IB_IW  = (IBTB_BITS > 0) ? IBTB_BITS : 1;
  localparam int IB_TW  = 30 - IBTB_BITS;
  logic              ib_valid  [IB_N];
  logic [IB_TW-1:0]  ib_tag    [IB_N];
  logic [31:0]       ib_target [IB_N];
  initial for (int i = 0; i < IB_N; i++) ib_valid[i] = 1'b0;

  wire [IB_IW-1:0] ib_idx_d = (IBTB_BITS > 0) ? IB_IW'(pc_d[IBTB_BITS+1:2]) : '0;
  wire [IB_TW-1:0] ib_tag_d = pc_d[31:IBTB_BITS+2];
  wire ib_hit_d = (IBTB_BITS > 0) && c_d.is_jalr && !ras_pop &&
                  ib_valid[ib_idx_d] && (ib_tag[ib_idx_d] == ib_tag_d);

  wire        jalr_pred_d   = ras_pop || ib_hit_d;
  wire [31:0] jalr_target_d = ras_pop ? ras[ras_top] : ib_target[ib_idx_d];

  // Decode-stage redirect: follow a JAL, a branch predicted taken, or a
  // return predicted by the return-address stack
  wire        redirect_id = (EARLY_JAL && c_d.is_jal) || pred_taken_d || jalr_pred_d;
  wire [31:0] target_id   = jalr_pred_d ? jalr_target_d
                                        : pc_d + (c_d.is_jal ? imm_j : imm_b);

  wire stall_d = load_use || mul_use || ex_stall;
  logic [31:0] fetch_pc;
  always_comb begin
    if (redirect_ex)              fetch_pc = target_ex;  // EX outranks ID: ID may be wrong-path
    else if (!valid_i || stall_d) fetch_pc = pc_d;       // re-read same word
    else if (redirect_id)         fetch_pc = target_id;
    else                          fetch_pc = pc_d + 32'd4;
  end
  assign imem_addr   = fetch_pc;
  assign imem_pc     = pc_d;
  assign imem_lookup = valid_d && !fetch_fault;
  assign imem_kill   = redirect_ex;

  // -------------------------------------------------------------------------
  // MEM: align load data
  // -------------------------------------------------------------------------
  logic [31:0] load_val;
  wire  [31:0] ld_shift = dmem_rdata >> {mem.addr_lo, 3'b000};
  always_comb begin
    unique case (mem.funct3)
      3'b000:  load_val = {{24{ld_shift[7]}},  ld_shift[7:0]};
      3'b001:  load_val = {{16{ld_shift[15]}}, ld_shift[15:0]};
      3'b100:  load_val = {24'b0, ld_shift[7:0]};
      3'b101:  load_val = {16'b0, ld_shift[15:0]};
      default: load_val = dmem_rdata;
    endcase
  end
  // MEM-stage multiply. The operands come straight from the EX/MEM register
  // and the result goes straight into MEM/WB, which matches a DSP48 with
  // input and output registers. MUL takes the low word, MULH* the high word.
  wire signed [65:0] product = $signed(mem.mul_a) * $signed(mem.mul_b);
  wire [31:0]        mul_val = (mem.funct3[1:0] == 2'b00) ? product[31:0] : product[63:32];

  wire [31:0] mem_value = mem.is_load ? load_val :
                          mem.is_mul  ? mul_val  : mem.result;

  // -------------------------------------------------------------------------
  // Pipeline registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      pc_d        <= RESET_PC;
      valid_d     <= 1'b0;
      ex          <= '0;
      mem         <= '0;
      wb          <= '0;
      div_issued  <= 1'b0;
      ras_top     <= '0;
      cycle_ctr   <= '0;
      instret_ctr <= '0;
      for (int k = 0; k < NHPM; k++) hpm[k] <= '0;
      mst_mie       <= 1'b0;
      mst_mpie      <= 1'b0;
      mie_r         <= '0;
      mtvec         <= '0;
      mscratch      <= '0;
      mepc          <= '0;
      mcause        <= '0;
      mtval         <= '0;
      mcountinhibit <= '0;
    end else begin
      // Counters: a CSR write replaces the half it names (and the counter
      // doesn't advance that cycle); otherwise count unless inhibited
      if (csr_wr(12'hB00))             cycle_ctr <= {cycle_ctr[63:32], csr_new};
      else if (csr_wr(12'hB80))        cycle_ctr <= {csr_new, cycle_ctr[31:0]};
      else if (!mcountinhibit[0])      cycle_ctr <= cycle_ctr + 64'd1;
      if (csr_wr(12'hB02))             instret_ctr <= {instret_ctr[63:32], csr_new};
      else if (csr_wr(12'hB82))        instret_ctr <= {csr_new, instret_ctr[31:0]};
      else if (wb.valid && !mcountinhibit[2]) instret_ctr <= instret_ctr + 64'd1;
      for (int k = 0; k < NHPM; k++) begin
        if (csr_wr(12'hB03 + k[11:0]))      hpm[k] <= {hpm[k][63:32], csr_new};
        else if (csr_wr(12'hB83 + k[11:0])) hpm[k] <= {csr_new, hpm[k][31:0]};
        else if (perf_ev[k] && !mcountinhibit[3 + k]) hpm[k] <= hpm[k] + 64'd1;
      end

      // Trap entry, MRET, CSR writes (all from EX)
      if (trap_take) begin
        mepc     <= {ex.pc[31:2], 2'b00};
        mcause   <= trap_cause;
        mtval    <= trap_tval;
        mst_mpie <= mst_mie;
        mst_mie  <= 1'b0;
      end else if (ex_live && ex.c.is_mret) begin
        mst_mie  <= mst_mpie;
        mst_mpie <= 1'b1;
      end else if (csr_we) begin
        unique case (csr_addr)
          12'h300: begin mst_mie <= csr_new[3]; mst_mpie <= csr_new[7]; end
          12'h304: mie_r         <= csr_new & 32'h0000_0888;
          12'h305: mtvec         <= csr_new & ~32'd2;          // modes 0 and 1 only
          12'h320: mcountinhibit <= csr_new & ~32'd2;          // no time counter to inhibit
          12'h340: mscratch      <= csr_new;
          12'h341: mepc          <= {csr_new[31:2], 2'b00};
          12'h342: mcause        <= csr_new;
          12'h343: mtval         <= csr_new;
          default: ;                                           // counters above; misa ignores writes
        endcase
      end

      // IF -> ID
      pc_d    <= fetch_pc;
      valid_d <= 1'b1;

      // Return-address stack: update as the instruction leaves ID for EX
      if (valid_i && !stall_d && !redirect_ex) begin
        if (ras_pop && ras_push) begin
          ras[ras_top] <= pc_d + 32'd4;          // pop then push = replace top
        end else if (ras_push) begin
          ras[ras_inc] <= pc_d + 32'd4;
          ras_top      <= ras_inc;
        end else if (ras_pop) begin
          ras_top      <= ras_dec;
        end
      end

      // ID -> EX
      if (ex_stall) begin
        // EX is busy (dividing, or waiting on a data-cache miss): hold it, and
        // ID holds too, via stall_d. Keep the operands current: the producers
        // it's forwarding from move on and leave the pipeline while EX waits,
        // after which the stale values read in ID would come back.
        ex.rs1_val <= a_fwd;
        ex.rs2_val <= b_fwd;
      end else if (redirect_ex || stall_d || !valid_i) begin
        ex <= '0;  // bubble
      end else begin
        ex.valid   <= 1'b1;
        ex.pc      <= pc_d;
        ex.instr   <= instr_d;
        ex.rd      <= rd_d;
        ex.rs1     <= rs1_d;
        ex.rs2     <= rs2_d;
        ex.rs1_val <= rf_rd1;
        ex.rs2_val <= rf_rd2;
        ex.imm        <= imm_d;
        ex.pred_taken <= pred_taken_d;
        ex.bht_idx    <= bht_idx_d;
        ex.jalr_pred   <= jalr_pred_d;
        ex.jalr_target <= jalr_target_d;
        ex.ras_popped  <= ras_pop;
        ex.c          <= c_d;
      end

      // EX -> MEM
      if (div_start)      div_issued <= 1'b1;
      else if (!ex_stall) div_issued <= 1'b0;

      mem.valid   <= ex_live && !ex_stall;
      mem.pc      <= ex.pc;
      mem.instr   <= ex.instr;
      mem.rd      <= ex.rd;
      mem.reg_we  <= ex_live && !ex_stall && ex.c.reg_we;
      mem.is_load <= ex_live && ex.c.is_load;
      mem.is_mul  <= ex_live && ex.c.is_mul;
      mem.mul_a   <= mul_a_e;
      mem.mul_b   <= mul_b_e;
      mem.funct3  <= f3_e;
      mem.addr_lo <= byte_off;
      mem.result  <= ex_result;
      mem.trap    <= trap_take;
      mem.cause   <= trap_cause;
      mem.tval    <= trap_tval;

      // MEM -> WB
      wb.valid  <= mem.valid;
      wb.pc     <= mem.pc;
      wb.instr  <= mem.instr;
      wb.rd     <= mem.rd;
      wb.reg_we <= mem.reg_we;
      wb.value  <= mem_value;
      wb.trap   <= mem.trap;
      wb.cause  <= mem.cause;
      wb.tval   <= mem.tval;
    end
  end

  // -------------------------------------------------------------------------
  // Retirement
  // -------------------------------------------------------------------------
  assign commit_valid  = wb.valid;
  assign commit_pc     = wb.pc;
  assign commit_instr  = wb.instr;
  assign commit_rd_we  = wb.reg_we && (wb.rd != 5'd0);
  assign commit_rd     = wb.rd;
  assign commit_rd_val = wb.value;
  assign commit_trap   = wb.trap;
  assign commit_cause  = wb.cause;
  assign commit_tval   = wb.tval;

endmodule
