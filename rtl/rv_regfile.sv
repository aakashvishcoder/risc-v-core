// 32 x 32 register file, 2 async read ports, 1 write port.
// Write-through: a read of the register being written this cycle returns the
// new value, so WB -> ID needs no extra forwarding path.
module rv_regfile (
  input  logic        clk,
  input  logic [4:0]  ra1,
  input  logic [4:0]  ra2,
  output logic [31:0] rd1,
  output logic [31:0] rd2,
  input  logic        we,
  input  logic [4:0]  wa,
  input  logic [31:0] wd
);
  logic [31:0] regs [32];

  initial for (int i = 0; i < 32; i++) regs[i] = 32'b0;

  always_ff @(posedge clk)
    if (we && wa != 5'd0) regs[wa] <= wd;

  assign rd1 = (ra1 == 5'd0) ? 32'b0 : (we && wa == ra1) ? wd : regs[ra1];
  assign rd2 = (ra2 == 5'd0) ? 32'b0 : (we && wa == ra2) ? wd : regs[ra2];
endmodule
