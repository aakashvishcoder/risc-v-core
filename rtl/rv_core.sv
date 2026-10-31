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
// ---------------------------------------------------------------------------
module rv_core #(
  parameter logic [31:0] RESET_PC  = 32'h0000_0000,
  parameter bit          EARLY_JAL = 1'b1,    // resolve JAL in decode (0-cycle penalty)
  parameter int          BPRED     = 3,       // 0 not-taken, 1 BTFN, 2 bimodal, 3 gshare
  parameter int          BHT_BITS  = 8,       // log2(branch history table entries)
  parameter int          GHR_BITS  = 8,       // gshare global history length
  parameter int          RAS_DEPTH = 8        // return-address stack entries (0 = none)
) (
  input  logic        clk,
  input  logic        rst,

  // Instruction memory (sync read: rdata is valid the cycle after addr)
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,

  // Data memory (sync read)
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_we,
  output logic        dmem_re,
  input  logic [31:0] dmem_rdata,

  // Retirement port (for tracing / verification)
  output logic        commit_valid,
  output logic [31:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic        commit_rd_we,
  output logic [4:0]  commit_rd,
  output logic [31:0] commit_rd_val,

  output logic        halted     // ECALL / EBREAK / illegal instruction retired
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
    logic [1:0] wb_sel;
    logic       trap;
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
    ctrl_t       c;
  } idex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_we;
    logic        is_load;
    logic [2:0]  funct3;
    logic [1:0]  addr_lo;
    logic [31:0] result;
    logic        trap;
  } exmem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_we;
    logic [31:0] value;
    logic        trap;
  } memwb_t;

  idex_t  ex;
  exmem_t mem;
  memwb_t wb;

  logic [63:0] cycle_ctr, instret_ctr;
  logic        halt_fetch;   // a trapping instruction has entered EX

  // -------------------------------------------------------------------------
  // IF / ID
  // -------------------------------------------------------------------------
  logic [31:0] pc_d;         // PC of the instruction on imem_rdata
  logic        valid_d;

  wire [31:0] instr_d = valid_d ? imem_rdata : INSTR_NOP;
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
        c_d.trap = (f3_d != 3'b000);
      end
      OP_BRANCH: begin
        c_d.uses_rs1 = 1; c_d.uses_rs2 = 1; c_d.is_branch = 1; imm_d = imm_b;
        c_d.trap = (f3_d == 3'b010) || (f3_d == 3'b011);
      end
      OP_LOAD: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.b_imm = 1; c_d.is_load = 1;
        c_d.trap = (f3_d == 3'b011) || (f3_d == 3'b110) || (f3_d == 3'b111);
      end
      OP_STORE: begin
        c_d.uses_rs1 = 1; c_d.uses_rs2 = 1; c_d.b_imm = 1; c_d.is_store = 1; imm_d = imm_s;
        c_d.trap = (f3_d[2] == 1'b1) || (f3_d == 3'b011);
      end
      OP_IMM: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.b_imm = 1;
        // Only shifts use instr[30] as an op bit for immediates
        c_d.alu_op = {(f3_d == 3'b101) & instr_d[30], f3_d};
        if (f3_d == 3'b001) c_d.trap = (f7_d != 7'b0);
        if (f3_d == 3'b101) c_d.trap = (f7_d != 7'b0) && (f7_d != 7'b0100000);
      end
      OP_REG: begin
        c_d.reg_we = 1; c_d.uses_rs1 = 1; c_d.uses_rs2 = 1;
        c_d.alu_op = {instr_d[30], f3_d};
        c_d.trap = !((f7_d == 7'b0) ||
                     (f7_d == 7'b0100000 && (f3_d == 3'b000 || f3_d == 3'b101)));
      end
      OP_FENCE: ; // no caches or reordering: NOP
      OP_SYSTEM: begin
        if (f3_d == 3'b000) begin
          c_d.trap = 1;  // ECALL / EBREAK / xRET: stop the core
        end else if (f3_d[1] && (rs1_d == 5'd0)) begin
          // CSRRS / CSRRC / CSRRSI / CSRRCI with x0 / zimm=0: pure CSR read
          c_d.reg_we = 1; c_d.wb_sel = WB_CSR;
        end else begin
          c_d.trap = 1;  // CSR writes unsupported
        end
      end
      default: c_d.trap = 1;
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

  // Load-use hazard: EX holds a load whose result the ID instruction needs.
  // The load's data only exists at the end of MEM, so forwarding can't help.
  wire load_use = ex.valid && ex.c.is_load && (ex.rd != 5'd0) &&
                  ((c_d.uses_rs1 && rs1_d == ex.rd) || (c_d.uses_rs2 && rs2_d == ex.rd));

  // -------------------------------------------------------------------------
  // EX
  // -------------------------------------------------------------------------
  // Forwarding: youngest producer wins (MEM before WB). A load in MEM can't
  // forward (its data isn't ready until the end of MEM) - load_use covers it.
  function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] v);
    if (r != 5'd0 && mem.valid && mem.reg_we && !mem.is_load && mem.rd == r)
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
  // wasn't already followed in decode redirect too.
  wire br_mispredict = ex.valid && ex.c.is_branch && (br_cond != ex.pred_taken);
  wire [31:0] jalr_actual = (a_fwd + ex.imm) & ~32'd1;
  wire jmp_redirect  = ex.valid && ((ex.c.is_jal && !EARLY_JAL) ||
                                    (ex.c.is_jalr && !(ex.jalr_pred && ex.jalr_target == jalr_actual)));
  wire redirect_ex   = br_mispredict || jmp_redirect;

  logic [31:0] target_ex;
  always_comb begin
    if (ex.c.is_jalr)                     target_ex = jalr_actual;
    else if (ex.c.is_branch && !br_cond)  target_ex = ex.pc + 32'd4;  // predicted taken, wasn't
    else                                  target_ex = ex.pc + ex.imm;
  end

  // Train the branch history table and shift the outcome into the history
  always_ff @(posedge clk) begin
    if (rst) begin
      ghr <= '0;
    end else if (BPRED >= 2 && !halted && ex.valid && ex.c.is_branch) begin
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
  //   7  jumps                     JAL + JALR
  //   8  branch mispredictions     (redirects caused by a conditional branch)
  //   9  jump redirects from EX    (jumps not followed in decode, or followed
  //                                 to the wrong target)
  // Every flush is one or the other, so event 4 == event 8 + event 9, and
  //   cycles = instret + load-use stalls + flush cycles + pipeline fill.
  // -------------------------------------------------------------------------
  localparam int NHPM = 7;               // hpmcounter3 .. hpmcounter9
  logic [NHPM-1:0] perf_ev;
  logic [63:0]     hpm [NHPM];

  assign perf_ev[0] = valid_d && load_use && !redirect_ex && !halt_fetch;
  assign perf_ev[1] = redirect_ex;
  assign perf_ev[2] = ex.valid && ex.c.is_branch;
  assign perf_ev[3] = ex.valid && ex.c.is_branch && br_cond;
  assign perf_ev[4] = ex.valid && (ex.c.is_jal || ex.c.is_jalr);
  assign perf_ev[5] = br_mispredict;
  assign perf_ev[6] = jmp_redirect;

  // Read-only configuration register in the custom machine CSR space, so
  // software (tests, benchmarks) can tell which features this build has.
  //   [0]     JAL resolved in decode
  //   [3:1]   branch predictor: 0 not-taken, 1 BTFN, 2 bimodal, 3 gshare
  //   [11:4]  return-address stack depth (0 = none)
  //   [15:12] log2(indirect jump target buffer entries) (0 = none)
  localparam logic [11:0] CSR_MCONFIG = 12'hFC0;
  wire [31:0] mconfig = {20'b0, 8'(RAS_DEPTH), 3'(BPRED), EARLY_JAL};

  // CSR reads (read-only counters)
  logic [31:0] csr_val;
  always_comb begin
    unique case (ex.instr[31:20])
      12'hC00, 12'hC01, 12'hB00: csr_val = cycle_ctr[31:0];
      12'hC80, 12'hC81, 12'hB80: csr_val = cycle_ctr[63:32];
      12'hC02, 12'hB02:          csr_val = instret_ctr[31:0];
      12'hC82, 12'hB82:          csr_val = instret_ctr[63:32];
      12'h301:                   csr_val = 32'h4000_0100;  // misa: RV32I
      CSR_MCONFIG:               csr_val = mconfig;
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

  logic [31:0] ex_result;
  always_comb begin
    unique case (ex.c.wb_sel)
      WB_PC4:  ex_result = ex.pc + 32'd4;
      WB_CSR:  ex_result = csr_val;
      default: ex_result = alu_y;
    endcase
  end

  // Data memory request (address = ALU result for loads/stores)
  wire [1:0] byte_off = alu_y[1:0];
  always_comb begin
    dmem_addr  = {alu_y[31:2], 2'b00};
    dmem_re    = ex.valid && ex.c.is_load;
    dmem_wdata = b_fwd << {byte_off, 3'b000};
    dmem_we    = 4'b0000;
    if (ex.valid && ex.c.is_store) begin
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

  wire        jalr_pred_d   = ras_pop;
  wire [31:0] jalr_target_d = ras[ras_top];

  // Decode-stage redirect: follow a JAL, a branch predicted taken, or a
  // return predicted by the return-address stack
  wire        redirect_id = (EARLY_JAL && c_d.is_jal) || pred_taken_d || jalr_pred_d;
  wire [31:0] target_id   = jalr_pred_d ? jalr_target_d
                                        : pc_d + (c_d.is_jal ? imm_j : imm_b);

  wire stall_d = load_use || halt_fetch;
  logic [31:0] fetch_pc;
  always_comb begin
    if (redirect_ex)              fetch_pc = target_ex;  // EX outranks ID: ID may be wrong-path
    else if (!valid_d || stall_d) fetch_pc = pc_d;       // re-read same word
    else if (redirect_id)         fetch_pc = target_id;
    else                          fetch_pc = pc_d + 32'd4;
  end
  assign imem_addr = fetch_pc;

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
  wire [31:0] mem_value = mem.is_load ? load_val : mem.result;

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
      halt_fetch  <= 1'b0;
      halted      <= 1'b0;
      ras_top     <= '0;
      cycle_ctr   <= '0;
      instret_ctr <= '0;
      for (int k = 0; k < NHPM; k++) hpm[k] <= '0;
    end else if (!halted) begin
      cycle_ctr <= cycle_ctr + 64'd1;
      if (wb.valid) instret_ctr <= instret_ctr + 64'd1;
      for (int k = 0; k < NHPM; k++)
        if (perf_ev[k]) hpm[k] <= hpm[k] + 64'd1;

      // IF -> ID
      pc_d    <= fetch_pc;
      valid_d <= 1'b1;

      // Return-address stack: update as the instruction leaves ID for EX
      if (valid_d && !stall_d && !redirect_ex) begin
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
      if (redirect_ex || stall_d || !valid_d) begin
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
        ex.c          <= c_d;
        if (c_d.trap) halt_fetch <= 1'b1;
      end

      // EX -> MEM
      mem.valid   <= ex.valid;
      mem.pc      <= ex.pc;
      mem.instr   <= ex.instr;
      mem.rd      <= ex.rd;
      mem.reg_we  <= ex.valid && ex.c.reg_we;
      mem.is_load <= ex.valid && ex.c.is_load;
      mem.funct3  <= f3_e;
      mem.addr_lo <= byte_off;
      mem.result  <= ex_result;
      mem.trap    <= ex.valid && ex.c.trap;

      // MEM -> WB
      wb.valid  <= mem.valid;
      wb.pc     <= mem.pc;
      wb.instr  <= mem.instr;
      wb.rd     <= mem.rd;
      wb.reg_we <= mem.reg_we;
      wb.value  <= mem_value;
      wb.trap   <= mem.trap;

      if (wb.valid && wb.trap) halted <= 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // Retirement
  // -------------------------------------------------------------------------
  assign commit_valid  = wb.valid && !halted;
  assign commit_pc     = wb.pc;
  assign commit_instr  = wb.instr;
  assign commit_rd_we  = wb.reg_we && (wb.rd != 5'd0);
  assign commit_rd     = wb.rd;
  assign commit_rd_val = wb.value;

endmodule
