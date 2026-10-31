// ---------------------------------------------------------------------------
// rv_soc: core + 64 KiB dual-port RAM + memory-mapped I/O
//
// Memory map
//   0x0000_0000 - 0x0000_FFFF  RAM (code + data + stack)
//   0x1000_0000  UART_DATA  W  : transmit byte (dropped if UART busy)
//   0x1000_0004  UART_STAT  R  : bit0 = transmitter busy
//   0x1000_0008  SIM_EXIT   W  : end simulation with exit code (testbench)
//   0x1000_000C  LEDS       RW : LED outputs
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
  parameter int    IBTB_BITS    = 4
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

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_we;
  logic        dmem_re;

  rv_core #(.EARLY_JAL(EARLY_JAL != 0), .BPRED(BPRED), .BHT_BITS(BHT_BITS), .GHR_BITS(GHR_BITS), .RAS_DEPTH(RAS_DEPTH), .IBTB_BITS(IBTB_BITS)) u_core (
    .clk, .rst,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_wdata, .dmem_we, .dmem_re, .dmem_rdata,
    .commit_valid, .commit_pc, .commit_instr,
    .commit_rd_we, .commit_rd, .commit_rd_val,
    .halted
  );

  wire sel_ram = (dmem_addr[31:28] == 4'h0);
  wire sel_io  = (dmem_addr[31:28] == 4'h1);

  logic [31:0] ram_rdata;
  rv_ram #(.WORDS(MEM_WORDS), .INIT(MEM_INIT)) u_ram (
    .clk,
    .a_addr  (imem_addr[AW+1:2]),
    .a_rdata (imem_rdata),
    .b_addr  (dmem_addr[AW+1:2]),
    .b_we    (sel_ram ? dmem_we : 4'b0),
    .b_wdata (dmem_wdata),
    .b_rdata (ram_rdata)
  );

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
