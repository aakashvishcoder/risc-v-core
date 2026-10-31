// Dual-port synchronous RAM, written to infer a Xilinx true dual-port block RAM.
//   Port A: instruction fetch (read only)
//   Port B: data (read/write, byte enables, read-first)
module rv_ram #(
  parameter int    WORDS = 16384,          // 64 KiB
  parameter string INIT  = ""
) (
  input  logic                     clk,
  input  logic [$clog2(WORDS)-1:0] a_addr,
  output logic [31:0]              a_rdata,
  input  logic [$clog2(WORDS)-1:0] b_addr,
  input  logic [3:0]               b_we,
  input  logic [31:0]              b_wdata,
  output logic [31:0]              b_rdata
);
  (* ram_style = "block" *) logic [31:0] mem [WORDS];

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

  always_ff @(posedge clk) a_rdata <= mem[a_addr];

  always_ff @(posedge clk) begin
    for (int i = 0; i < 4; i++)
      if (b_we[i]) mem[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
    b_rdata <= mem[b_addr];
  end
endmodule
