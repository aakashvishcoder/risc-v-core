`include "rv_defs.svh"

module rv_alu (
  input  logic [3:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);
  always_comb begin
    unique case (op)
      ALU_ADD:  y = a + b;
      ALU_SUB:  y = a - b;
      ALU_SLL:  y = a << b[4:0];
      ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU: y = {31'b0, a < b};
      ALU_XOR:  y = a ^ b;
      ALU_SRL:  y = a >> b[4:0];
      ALU_SRA:  y = $unsigned($signed(a) >>> b[4:0]);
      ALU_OR:   y = a | b;
      ALU_AND:  y = a & b;
      default:  y = 32'b0;
    endcase
  end
endmodule
