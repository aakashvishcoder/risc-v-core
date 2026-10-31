// 8N1 UART transmitter. CLKS_PER_BIT = f_clk / baud (e.g. 50 MHz / 115200 = 434).
module uart_tx #(
  parameter int CLKS_PER_BIT = 434
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       start,
  input  logic [7:0] data,
  output logic       busy,
  output logic       tx
);
  logic [9:0]  shreg;      // {stop, data[7:0], start}
  logic [3:0]  bits_left;
  logic [$clog2(CLKS_PER_BIT+1)-1:0] ctr;

  assign busy = (bits_left != 0);

  always_ff @(posedge clk) begin
    if (rst) begin
      tx        <= 1'b1;
      bits_left <= '0;
      ctr       <= '0;
      shreg     <= '1;
    end else if (!busy) begin
      tx <= 1'b1;
      if (start) begin
        shreg     <= {1'b1, data, 1'b0};
        bits_left <= 4'd10;
        ctr       <= '0;
      end
    end else begin
      tx <= shreg[0];
      if (ctr == CLKS_PER_BIT - 1) begin
        ctr       <= '0;
        shreg     <= {1'b1, shreg[9:1]};
        bits_left <= bits_left - 4'd1;
      end else begin
        ctr <= ctr + 1'b1;
      end
    end
  end
endmodule
