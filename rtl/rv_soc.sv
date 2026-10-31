// ---------------------------------------------------------------------------
// rv_soc: core + memory system + memory-mapped I/O
//
// Memory map
//   0x0000_0000 - 0x0000_FFFF  RAM (code + data + stack)
//   0x1000_0000  UART_DATA  W  : transmit byte (dropped if UART busy)
//   0x1000_0004  UART_STAT  R  : bit0 = transmitter busy
//   0x1000_0008  SIM_EXIT   W  : end simulation with exit code (testbench)
//   0x1000_000C  LEDS       RW : LED outputs
//
// Memory system
//   CACHES = 0: the core talks to a dual-port block RAM directly; every access
//               takes one cycle (what fits on the FPGA board's on-chip RAM).
//   CACHES = 1: RAM is a slow main memory (MEM_LATENCY cycles per 16-byte
//               line) behind an instruction cache. The data side goes through
//               main memory uncached (one access per load/store) until the
//               data cache is added. I/O is never cached.
// ---------------------------------------------------------------------------
module rv_soc #(
  parameter int    MEM_WORDS    = 16384,
  parameter int    CLKS_PER_BIT = 434,    // 0 = instantaneous UART (simulation)
  parameter string MEM_INIT     = "",
  parameter int    EARLY_JAL    = 1,       // core configuration: see rv_core.sv
  parameter int    BPRED        = 3,
  parameter int    BHT_BITS     = 8,
  parameter int    GHR_BITS     = 8,
  parameter int    RAS_DEPTH    = 8,
  parameter int    IBTB_BITS    = 4,
  parameter int    M_EXT        = 2,
  parameter int    CACHES       = 0,       // memory system: see above
  parameter int    IC_LINES     = 64,      // I-cache lines (16 B each)
  parameter int    MEM_LATENCY  = 20       // main memory latency (CACHES = 1)
) (
  input  logic        clk,
  input  logic        rst,
  output logic        uart_txd,
  output logic [7:0]  leds,
  output logic        halted,

  // Simulation / debug visibility
  output logic        tx_valid,      // a byte was written to UART_DATA
  output logic [7:0]  tx_byte,
  output logic        exit_valid,
  output logic [31:0] exit_code,
  output logic        commit_valid,
  output logic [31:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic        commit_rd_we,
  output logic [4:0]  commit_rd,
  output logic [31:0] commit_rd_val
);
  localparam int AW = $clog2(MEM_WORDS);
  localparam logic [31:0] MCACHE = (CACHES == 0) ? 32'b0 :
      {16'(MEM_LATENCY), 4'b0, 4'b0, 4'($clog2(IC_LINES)), 4'b0001};

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] imem_pc;
  logic        imem_valid, imem_lookup, imem_kill;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_we;
  logic        dmem_re, dmem_stall;
  logic        ev_icache_miss, ev_dcache_miss, ev_dcache_wb;

  rv_core #(
    .EARLY_JAL (EARLY_JAL != 0), .BPRED (BPRED), .BHT_BITS (BHT_BITS), .GHR_BITS (GHR_BITS),
    .RAS_DEPTH (RAS_DEPTH), .IBTB_BITS (IBTB_BITS), .M_EXT (M_EXT), .MCACHE (MCACHE)
  ) u_core (
    .clk, .rst,
    .imem_addr, .imem_rdata, .imem_pc, .imem_valid, .imem_lookup, .imem_kill,
    .dmem_addr, .dmem_wdata, .dmem_we, .dmem_re, .dmem_rdata, .dmem_stall,
    .ev_icache_miss, .ev_dcache_miss, .ev_dcache_wb,
    .commit_valid, .commit_pc, .commit_instr,
    .commit_rd_we, .commit_rd, .commit_rd_val,
    .halted
  );

  wire sel_ram = (dmem_addr[31:28] == 4'h0);
  wire sel_io  = (dmem_addr[31:28] == 4'h1);
  wire ram_acc = sel_ram && (dmem_re || dmem_we != 4'b0);   // EX has a RAM access

  logic [31:0] ram_rdata;

  generate
    if (CACHES == 0) begin : g_bram
      // ---------------- single-cycle block RAM ----------------
      rv_ram #(.WORDS(MEM_WORDS), .INIT(MEM_INIT)) u_ram (
        .clk,
        .a_addr  (imem_addr[AW+1:2]),
        .a_rdata (imem_rdata),
        .b_addr  (dmem_addr[AW+1:2]),
        .b_we    (sel_ram ? dmem_we : 4'b0),
        .b_wdata (dmem_wdata),
        .b_rdata (ram_rdata)
      );
      assign imem_valid     = 1'b1;
      assign dmem_stall     = 1'b0;
      assign ev_icache_miss = 1'b0;
      assign ev_dcache_miss = 1'b0;
      assign ev_dcache_wb   = 1'b0;

    end else begin : g_cached
      // ---------------- caches + slow main memory ----------------
      logic         ic_req, d_req, mm_req, mm_we, mm_done;
      logic [31:0]  ic_addr, d_addr, mm_addr;
      logic [15:0]  d_wstrb;
      logic [127:0] d_wdata, mm_rdata;

      rv_icache #(.LINES(IC_LINES)) u_icache (
        .clk, .rst,
        .fetch_addr (imem_addr),
        .pc_id      (imem_pc),
        .lookup     (imem_lookup),
        .kill       (imem_kill),
        .hit        (imem_valid),
        .instr      (imem_rdata),
        .mem_req    (ic_req),
        .mem_addr   (ic_addr),
        .mem_done   (mm_done && owner_d == 1'b0),
        .mem_rdata  (mm_rdata),
        .miss_ev    (ev_icache_miss)
      );

      // Uncached data path: each RAM load/store is one main-memory access.
      // EX waits until it's done; a load's word is held for MEM.
      logic        d_done_q;          // access finished; EX may move on
      logic [31:0] d_word_q;
      assign d_req   = ram_acc && !d_done_q;
      assign d_addr  = dmem_addr;
      assign d_wstrb = (dmem_we != 4'b0) ? (16'(dmem_we) << (4 * dmem_addr[3:2])) : 16'b0;
      assign d_wdata = {4{dmem_wdata}};
      always_ff @(posedge clk) begin
        if (rst || d_done_q) d_done_q <= 1'b0;      // one-shot: EX moves on this cycle
        else if (mm_done && owner_d) begin
          d_done_q <= 1'b1;
          d_word_q <= mm_rdata[32*dmem_addr[3:2] +: 32];
        end
      end
      assign dmem_stall     = ram_acc && !d_done_q;
      assign ram_rdata      = d_word_q;
      assign ev_dcache_miss = 1'b0;
      assign ev_dcache_wb   = 1'b0;

      // Arbiter: one main-memory access at a time; the data side (older
      // instruction) wins. The owner is latched when an access starts.
      logic owner_d, mm_busy;
      wire  pick_d = d_req;
      always_ff @(posedge clk) begin
        if (rst)                                begin mm_busy <= 1'b0; owner_d <= 1'b0; end
        else if (!mm_busy && !mm_done && (d_req || ic_req)) begin mm_busy <= 1'b1; owner_d <= pick_d; end
        else if (mm_done)                       mm_busy <= 1'b0;
      end
      wire use_d = mm_busy ? owner_d : pick_d;
      assign mm_req  = mm_busy ? 1'b1 : (d_req || ic_req) && !mm_done;
      assign mm_we   = use_d && (d_wstrb != 16'b0);
      assign mm_addr = use_d ? d_addr : ic_addr;

      rv_mainmem #(.WORDS(MEM_WORDS), .LATENCY(MEM_LATENCY), .INIT(MEM_INIT)) u_mainmem (
        .clk, .rst,
        .req   (mm_req),
        .we    (mm_we),
        .wstrb (use_d ? d_wstrb : 16'b0),
        .addr  (mm_addr),
        .wdata (d_wdata),
        .done  (mm_done),
        .rdata (mm_rdata)
      );
    end
  endgenerate

  // ---------------- I/O ----------------
  logic uart_busy;
  wire  io_wr      = sel_io && (dmem_we != 4'b0);
  wire  wr_uart    = io_wr && dmem_addr[7:0] == 8'h00;
  wire  wr_exit    = io_wr && dmem_addr[7:0] == 8'h08;
  wire  wr_leds    = io_wr && dmem_addr[7:0] == 8'h0C;

  generate
    if (CLKS_PER_BIT == 0) begin : g_sim_uart
      assign uart_busy = 1'b0;
      assign uart_txd  = 1'b1;
    end else begin : g_uart
      uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk, .rst,
        .start (wr_uart),
        .data  (dmem_wdata[7:0]),
        .busy  (uart_busy),
        .tx    (uart_txd)
      );
    end
  endgenerate

  assign tx_valid   = wr_uart && !uart_busy;
  assign tx_byte    = dmem_wdata[7:0];
  assign exit_valid = wr_exit;
  assign exit_code  = dmem_wdata;

  always_ff @(posedge clk)
    if (rst)          leds <= 8'h00;
    else if (wr_leds) leds <= dmem_wdata[7:0];

  // Registered read mux to match the RAM's one-cycle read latency
  logic        rd_io_q;
  logic [31:0] io_rdata_q;
  always_ff @(posedge clk) begin
    rd_io_q <= sel_io;
    unique case (dmem_addr[7:0])
      8'h04:   io_rdata_q <= {31'b0, uart_busy};
      8'h0C:   io_rdata_q <= {24'b0, leds};
      default: io_rdata_q <= 32'b0;
    endcase
  end

  assign dmem_rdata = rd_io_q ? io_rdata_q : ram_rdata;

endmodule
