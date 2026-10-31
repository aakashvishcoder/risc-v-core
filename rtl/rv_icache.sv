// ---------------------------------------------------------------------------
// rv_icache: direct-mapped instruction cache, 16-byte lines.
//
// Timing matches the plain block-RAM fetch it replaces: the fetch address
// (IF) reads the tag, valid bit and data line into registers, and in the
// next cycle (ID) the registered tag is compared with the PC being decoded.
//   hit : the instruction is delivered, exactly as from block RAM
//   miss: `hit` is low, the core treats ID as empty and keeps refetching the
//         same PC; the cache fetches the line from main memory and writes it
//         in, with a bypass so the refetch in that same cycle sees the new line
// While a fill is in flight, other lookups can still hit (hit under miss); a
// second miss waits for the fill to finish. A miss on a fetch the core is
// about to throw away (kill: EX is redirecting) doesn't start a fill.
// ---------------------------------------------------------------------------
module rv_icache #(
  parameter int LINES = 64                  // 64 x 16 B = 1 KiB
) (
  input  logic         clk,
  input  logic         rst,
  input  logic [31:0]  fetch_addr,          // IF: address being fetched
  input  logic [31:0]  pc_id,               // ID: address of the fetch from last cycle
  input  logic         lookup,              // ID holds a real fetch
  input  logic         kill,                // ... which is being flushed this cycle
  output logic         hit,
  output logic [31:0]  instr,

  output logic         mem_req,
  output logic [31:0]  mem_addr,
  input  logic         mem_done,
  input  logic [127:0] mem_rdata,

  output logic         miss_ev              // one pulse per miss (performance counter)
);
  localparam int IB = $clog2(LINES);
  localparam int TW = 32 - 4 - IB;

  logic [127:0]  data  [LINES];
  logic [TW-1:0] tags  [LINES];
  logic [LINES-1:0] valid;                  // packed: resets in one assignment

  wire [IB-1:0] f_idx = fetch_addr[IB+3:4];

  // Fill state
  logic        filling;
  logic [31:0] fill_addr;
  wire  [IB-1:0] fill_idx = fill_addr[IB+3:4];
  wire  fill_we = filling && mem_done;

  // Registered read of the line being fetched, with write bypass
  logic [127:0]  data_q;
  logic [TW-1:0] tag_q;
  logic          valid_q;
  always_ff @(posedge clk) begin
    if (fill_we) begin
      data[fill_idx] <= mem_rdata;
      tags[fill_idx] <= fill_addr[31:IB+4];
    end
    if (fill_we && fill_idx == f_idx) begin
      data_q <= mem_rdata;
      tag_q  <= fill_addr[31:IB+4];
    end else begin
      data_q <= data[f_idx];
      tag_q  <= tags[f_idx];
    end
  end

  // Valid bits: cleared on reset
  always_ff @(posedge clk) begin
    if (rst) begin
      valid   <= '0;
      valid_q <= 1'b0;
    end else begin
      if (fill_we) valid[fill_idx] <= 1'b1;
      valid_q <= (fill_we && fill_idx == f_idx) ? 1'b1 : valid[f_idx];
    end
  end

  assign hit   = valid_q && (tag_q == pc_id[31:IB+4]);
  assign instr = data_q[32*pc_id[3:2] +: 32];

  // Miss handling
  wire start_fill = lookup && !hit && !kill && !filling;
  always_ff @(posedge clk) begin
    if (rst) begin
      filling <= 1'b0;
    end else if (start_fill) begin
      filling   <= 1'b1;
      fill_addr <= {pc_id[31:4], 4'b0};
    end else if (fill_we) begin
      filling <= 1'b0;
    end
  end

  assign mem_req  = filling;
  assign mem_addr = fill_addr;
  assign miss_ev  = start_fill;
endmodule
