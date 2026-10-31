`ifndef RV_DEFS_SVH
`define RV_DEFS_SVH

// Opcodes
localparam logic [6:0] OP_LUI    = 7'b0110111;
localparam logic [6:0] OP_AUIPC  = 7'b0010111;
localparam logic [6:0] OP_JAL    = 7'b1101111;
localparam logic [6:0] OP_JALR   = 7'b1100111;
localparam logic [6:0] OP_BRANCH = 7'b1100011;
localparam logic [6:0] OP_LOAD   = 7'b0000011;
localparam logic [6:0] OP_STORE  = 7'b0100011;
localparam logic [6:0] OP_IMM    = 7'b0010011;
localparam logic [6:0] OP_REG    = 7'b0110011;
localparam logic [6:0] OP_FENCE  = 7'b0001111;
localparam logic [6:0] OP_SYSTEM = 7'b1110011;

// ALU ops: {instr[30], funct3}
localparam logic [3:0] ALU_ADD  = 4'b0000;
localparam logic [3:0] ALU_SUB  = 4'b1000;
localparam logic [3:0] ALU_SLL  = 4'b0001;
localparam logic [3:0] ALU_SLT  = 4'b0010;
localparam logic [3:0] ALU_SLTU = 4'b0011;
localparam logic [3:0] ALU_XOR  = 4'b0100;
localparam logic [3:0] ALU_SRL  = 4'b0101;
localparam logic [3:0] ALU_SRA  = 4'b1101;
localparam logic [3:0] ALU_OR   = 4'b0110;
localparam logic [3:0] ALU_AND  = 4'b0111;

// ALU operand A select
localparam logic [1:0] A_RS1  = 2'd0;
localparam logic [1:0] A_PC   = 2'd1;
localparam logic [1:0] A_ZERO = 2'd2;

// Writeback select
localparam logic [1:0] WB_ALU = 2'd0;
localparam logic [1:0] WB_PC4 = 2'd1;
localparam logic [1:0] WB_CSR = 2'd2;

localparam logic [31:0] INSTR_NOP = 32'h0000_0013;

`endif
