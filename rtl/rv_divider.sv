// ---------------------------------------------------------------------------
// rv_divider: iterative radix-2 restoring divider for DIV/DIVU/REM/REMU.
//
// Works on magnitudes and fixes the signs at the end:
//   quotient  is negative when the operand signs differ (truncates toward 0)
//   remainder takes the sign of the dividend
// One quotient bit per cycle: `start` latches the operands, then 32 cycles
// later `done` rises and `result` is valid until the next `start`.
//
// RISC-V defines results instead of traps for the corner cases:
//   x / 0       -> quotient all ones, remainder x  (finishes immediately)
//   INT_MIN / -1 -> quotient INT_MIN, remainder 0  (falls out of the
//                   magnitude arithmetic: |INT_MIN| = 2^31 wraps back)
// ---------------------------------------------------------------------------
module rv_divider (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,      // pulse: latch operands and begin
  input  logic [1:0]  op,         // funct3[1:0]: 00 DIV, 01 DIVU, 10 REM, 11 REMU
  input  logic [31:0] a,          // dividend
  input  logic [31:0] b,          // divisor
  output logic        busy,
  output logic        done,       // result valid (held until the next start)
  output logic [31:0] result
);
  logic [31:0] quot, divisor, dividend;
  logic [32:0] rem;
  logic [5:0]  count;
  logic        neg_q, neg_r, want_rem, by_zero;

  wire is_signed = !op[0];
  wire [31:0] a_abs = (is_signed && a[31]) ? -a : a;
  wire [31:0] b_abs = (is_signed && b[31]) ? -b : b;

  // One restoring step: shift the next dividend bit into the partial
  // remainder, and subtract the divisor if it fits.
  wire [32:0] rem_sh = {rem[31:0], quot[31]};
  wire [32:0] diff   = rem_sh - {1'b0, divisor};
  wire        fits   = !diff[32];

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      done <= 1'b0;
    end else if (start) begin
      want_rem <= op[1];
      dividend <= a;
      by_zero  <= (b == 32'b0);
      neg_q    <= is_signed && (a[31] ^ b[31]);
      neg_r    <= is_signed && a[31];
      quot     <= a_abs;          // dividend bits shift out the top as quotient bits shift in
      divisor  <= b_abs;
      rem      <= '0;
      count    <= 6'd32;
      busy     <= (b != 32'b0);
      done     <= (b == 32'b0);   // divide by zero: result is ready now
    end else if (busy) begin
      rem   <= fits ? diff : rem_sh;
      quot  <= {quot[30:0], fits};
      count <= count - 6'd1;
      if (count == 6'd1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  always_comb begin
    if (by_zero)       result = want_rem ? dividend : 32'hFFFF_FFFF;
    else if (want_rem) result = neg_r ? -rem[31:0] : rem[31:0];
    else               result = neg_q ? -quot : quot;
  end
endmodule
