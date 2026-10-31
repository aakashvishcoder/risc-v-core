// ---------------------------------------------------------------------------
// rv_dcache: direct-mapped, write-back, write-allocate data cache.
// 16-byte lines, SETS entries.
//
// Timing matches the block RAM it replaces. In EX the access address picks
// a line: tag/valid/dirty are read asynchronously (small, LUT RAM) to decide
// hit or miss in the same cycle, and the data line is read synchronously
// (block RAM) so a load's word is ready in MEM.
//   hit, load : word comes out in MEM, as before
//   hit, store: the bytes are written into the line and it's marked dirty;
//               main memory isn't touched
//   miss      : `stall` holds the access in EX. If the line being replaced
//               is dirty it's written back first; then the missing line is
//               fetched, and the access retries and hits.
// The access can't change while it waits (EX is held), so the victim's data
// and address stay put for the writeback.
// ---------------------------------------------------------------------------
module rv_dcache #(
  parameter int SETS = 64                   // 64 x 16 B = 1 KiB
) (
  input  logic         clk,
  input  logic         rst,
  // Core side (EX stage)
  input  logic         req,                 // load or store to RAM in EX
  input  logic [31:0]  addr,
  input  logic [3:0]   we,                  // byte enables within the word (stores)
  input  logic [31:0]  wdata,               // already shifted into its byte lanes
  output logic         stall,
  output logic [31:0]  rdata,               // load word, in MEM (cycle after EX)
  // Main memory side
  output logic         mem_req,
  output logic         mem_we,
  output logic [31:0]  mem_addr,
  output logic [127:0] mem_wdata,
  input  logic         mem_done,
  input  logic [127:0] mem_rdata,
  // Events (one pulse each)
  output logic         miss_ev,
  output logic         wb_ev
);
  localparam int IB = $clog2(SETS);
  localparam int TW = 32 - 4 - IB;

  logic [127:0]  data  [SETS];
  logic [TW-1:0] tags  [SETS];
  logic          valid [SETS];
  logic          dirty [SETS];

  wire [IB-1:0] idx     = addr[IB+3:4];
  wire [TW-1:0] tag     = addr[31:IB+4];
  wire          hit     = valid[idx] && (tags[idx] == tag);

  typedef enum logic [1:0] {IDLE, WRITEBACK, FILL} state_t;
  state_t state;

  assign stall = req && !hit;               // also covers WRITEBACK/FILL: tag not there yet

  wire        store_hit = req && hit && (we != 4'b0);
  wire [15:0] line_we   = 16'(we) << (4 * addr[3:2]);
  wire        fill_done = (state == FILL) && mem_done;

  // Data array: one port, read every cycle at the EX address
  logic [127:0] data_q;
  logic [1:0]   off_q;
  always_ff @(posedge clk) begin
    data_q <= data[idx];
    off_q  <= addr[3:2];
    if (fill_done) begin
      data[idx] <= mem_rdata;
    end else if (store_hit) begin
      for (int b = 0; b < 16; b++)
        if (line_we[b]) data[idx][8*b +: 8] <= wdata[8*(b%4) +: 8];
    end
  end
  assign rdata = data_q[32*off_q +: 32];

  // Tags, valid and dirty bits, and the miss state machine
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      for (int i = 0; i < SETS; i++) begin
        valid[i] <= 1'b0;
        dirty[i] <= 1'b0;
      end
    end else begin
      unique case (state)
        IDLE:      if (req && !hit) state <= (valid[idx] && dirty[idx]) ? WRITEBACK : FILL;
        WRITEBACK: if (mem_done) state <= FILL;
        FILL:      if (mem_done) begin
                     state      <= IDLE;
                     tags[idx]  <= tag;
                     valid[idx] <= 1'b1;
                     dirty[idx] <= 1'b0;
                   end
        default:   state <= IDLE;
      endcase
      if (store_hit) dirty[idx] <= 1'b1;
    end
  end

  assign mem_req   = (state == WRITEBACK) || (state == FILL);
  assign mem_we    = (state == WRITEBACK);
  assign mem_addr  = (state == WRITEBACK) ? {tags[idx], idx, 4'b0} : {addr[31:4], 4'b0};
  assign mem_wdata = data_q;                // the victim line, read while EX waits

  assign miss_ev = (state == IDLE) && req && !hit;
  assign wb_ev   = miss_ev && valid[idx] && dirty[idx];
endmodule
