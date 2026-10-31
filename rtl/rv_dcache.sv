// ---------------------------------------------------------------------------
// rv_dcache: set-associative (1 or 2 ways), write-back, write-allocate data
// cache with LRU replacement. 16-byte lines, SETS sets.
//
// Timing matches the block RAM it replaces. In EX the access address picks
// a set: every way's tag/valid/dirty is read asynchronously (small, LUT RAM)
// to decide hit or miss in the same cycle, and every way's data line is read
// synchronously (one block RAM per way); MEM selects the word from the way
// that hit.
//   hit, load : word comes out in MEM, as before
//   hit, store: the bytes are written into the line and it's marked dirty;
//               main memory isn't touched
//   miss      : `stall` holds the access in EX. The victim is the set's least
//               recently used way; if it's dirty it's written back first. Then
//               the missing line is fetched into it, and the access retries
//               and hits.
// The access can't change while it waits (EX is held), so the victim's data
// and address stay put for the writeback.
// ---------------------------------------------------------------------------
module rv_dcache #(
  parameter int SETS = 64,                  // 64 sets
  parameter int WAYS = 1                    // 1 (direct-mapped) or 2
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
  localparam int WB_ = 1;                   // way-index width (1 bit covers 1 or 2 ways)

  logic [127:0]  data  [WAYS][SETS];
  logic [TW-1:0] tags  [WAYS][SETS];
  logic          valid [WAYS][SETS];
  logic          dirty [WAYS][SETS];
  logic          lru   [SETS];              // way to replace next (2 ways)

  wire [IB-1:0] idx = addr[IB+3:4];
  wire [TW-1:0] tag = addr[31:IB+4];

  // Lookup
  logic [WAYS-1:0] hit_w;
  logic            hit;
  logic [WB_-1:0]  hit_way;
  always_comb begin
    hit = 1'b0;
    hit_way = '0;
    for (int w = 0; w < WAYS; w++) begin
      hit_w[w] = valid[w][idx] && (tags[w][idx] == tag);
      if (hit_w[w]) begin
        hit = 1'b1;
        hit_way = WB_'(w);
      end
    end
  end

  typedef enum logic [1:0] {IDLE, WRITEBACK, FILL} state_t;
  state_t        state;
  logic [WB_-1:0] victim;                   // way chosen when the miss started
  wire  [WB_-1:0] lru_way = (WAYS > 1) ? WB_'(lru[idx]) : '0;

  assign stall = req && !hit;               // also covers WRITEBACK/FILL: tag not there yet

  wire        store_hit = req && hit && (we != 4'b0);
  wire [15:0] line_we   = 16'(we) << (4 * addr[3:2]);
  wire        fill_done = (state == FILL) && mem_done;

  // Data arrays: one port per way, read every cycle at the EX address
  logic [127:0]   data_q [WAYS];
  logic [1:0]     off_q;
  logic [WB_-1:0] way_q;
  always_ff @(posedge clk) begin
    off_q <= addr[3:2];
    way_q <= hit_way;
    for (int w = 0; w < WAYS; w++) begin
      data_q[w] <= data[w][idx];
      if (fill_done && victim == WB_'(w)) begin
        data[w][idx] <= mem_rdata;
      end else if (store_hit && hit_way == WB_'(w)) begin
        for (int b = 0; b < 16; b++)
          if (line_we[b]) data[w][idx][8*b +: 8] <= wdata[8*(b%4) +: 8];
      end
    end
  end
  assign rdata = data_q[way_q][32*off_q +: 32];

  // Tags, valid/dirty bits, LRU, and the miss state machine
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      for (int i = 0; i < SETS; i++) begin
        lru[i] <= 1'b0;
        for (int w = 0; w < WAYS; w++) begin
          valid[w][i] <= 1'b0;
          dirty[w][i] <= 1'b0;
        end
      end
    end else begin
      unique case (state)
        IDLE:      if (req && !hit) begin
                     victim <= lru_way;
                     state  <= (valid[lru_way][idx] && dirty[lru_way][idx]) ? WRITEBACK : FILL;
                   end
        WRITEBACK: if (mem_done) state <= FILL;
        FILL:      if (mem_done) begin
                     state              <= IDLE;
                     tags[victim][idx]  <= tag;
                     valid[victim][idx] <= 1'b1;
                     dirty[victim][idx] <= 1'b0;
                   end
        default:   state <= IDLE;
      endcase
      if (store_hit) dirty[hit_way][idx] <= 1'b1;
      // Every access that hits makes the other way the least recently used
      if (WAYS > 1 && req && hit) lru[idx] <= !hit_way[0];
    end
  end

  assign mem_req   = (state == WRITEBACK) || (state == FILL);
  assign mem_we    = (state == WRITEBACK);
  assign mem_addr  = (state == WRITEBACK) ? {tags[victim][idx], idx, 4'b0} : {addr[31:4], 4'b0};
  assign mem_wdata = data_q[victim];        // the victim line, read while EX waits

  assign miss_ev = (state == IDLE) && req && !hit;
  assign wb_ev   = miss_ev && valid[lru_way][idx] && dirty[lru_way][idx];

`ifdef SIMULATION
  initial if (WAYS != 1 && WAYS != 2) $fatal(1, "rv_dcache: WAYS must be 1 or 2");
`endif
endmodule
