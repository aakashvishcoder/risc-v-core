// ---------------------------------------------------------------------------
// rv_mainmem: slow main memory model, one 16-byte line per access.
//
// Stands in for off-chip memory (DRAM, or the board's SPI flash read in
// execute-in-place mode) behind the caches. Behavioral: meant for simulation
// and for studying the memory hierarchy, not for synthesis.
//
// Protocol: hold `req` (with we/wstrb/addr/wdata) until `done` pulses. The access
// starts on the first cycle `req` is seen and `done` arrives LATENCY+1
// cycles later, with `rdata` valid for reads in the same cycle.
// ---------------------------------------------------------------------------
module rv_mainmem #(
  parameter int    WORDS   = 16384,       // 64 KiB
  parameter int    LATENCY = 20,
  parameter string INIT    = ""
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         req,
  input  logic         we,
  input  logic [15:0]  wstrb,             // byte enables within the line (writes)
  input  logic [31:0]  addr,              // byte address; low 4 bits ignored
  input  logic [127:0] wdata,
  output logic         done,
  output logic [127:0] rdata
);
  localparam int AW = $clog2(WORDS);
  logic [31:0] mem [WORDS];

`ifdef SIMULATION
  string fw;
  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'b0;
    if ($value$plusargs("firmware=%s", fw)) $readmemh(fw, mem);
    else if (INIT != "")                     $readmemh(INIT, mem);
  end
`else
  initial if (INIT != "") $readmemh(INIT, mem);
`endif

  logic        busy;
  logic [15:0] count;
  wire  [AW-1:0] base = {addr[AW+1:4], 2'b00};

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
    end else if (!busy) begin
      // Don't restart in the cycle `done` is high: the requester only drops
      // `req` the cycle after it sees `done`.
      if (req && !done) begin
        busy  <= 1'b1;
        count <= 16'(LATENCY);
      end
    end else if (count != 0) begin
      count <= count - 1'b1;
    end else begin
      busy <= 1'b0;
      done <= 1'b1;
      for (int w = 0; w < 4; w++) begin
        for (int b = 0; b < 4; b++)
          if (we && wstrb[4*w + b]) mem[base + AW'(w)][8*b +: 8] <= wdata[32*w + 8*b +: 8];
        rdata[32*w +: 32] <= mem[base + AW'(w)];
      end
    end
  end
endmodule
