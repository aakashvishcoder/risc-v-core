// ---------------------------------------------------------------------------
// rv_clint: core-local interruptor (the standard SiFive/RISC-V layout, one
// hart), at CLINT_BASE in the SoC's memory map
//   +0x0000  msip       [0] software interrupt pending (machine software IRQ)
//   +0x4000  mtimecmp   low word   } timer interrupt pending while
//   +0x4004  mtimecmp   high word  }   mtime >= mtimecmp (unsigned, 64-bit)
//   +0xBFF8  mtime      low word   } free-running 64-bit timer, one tick every
//   +0xBFFC  mtime      high word  }   TICK_DIV clock cycles; writable
// mtimecmp resets to all ones, so nothing fires until software arms it. Reads
// are registered (one cycle, like the RAM). Sub-word writes update only the
// bytes they enable.
// ---------------------------------------------------------------------------
module rv_clint #(
  parameter int TICK_DIV = 1                // clock cycles per mtime tick
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        sel,                  // access is in the CLINT's 64 KiB
  input  logic [15:0] addr,
  input  logic [3:0]  we,
  input  logic [31:0] wdata,                // already in its byte lanes
  output logic [31:0] rdata,                // cycle after the read
  output logic        irq_timer,
  output logic        irq_soft
);
  logic [63:0] mtime, mtimecmp;
  logic        msip;

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [3:0] be,
                                        input logic [31:0] d);
    for (int i = 0; i < 4; i++) if (be[i]) old[8*i +: 8] = d[8*i +: 8];
    return old;
  endfunction

  wire [15:0] a = {addr[15:2], 2'b00};
  wire wr = sel && (we != 4'b0);

  // Tick prescaler
  localparam int PW = (TICK_DIV > 1) ? $clog2(TICK_DIV) : 1;
  logic [PW-1:0] pre;
  wire tick = (TICK_DIV <= 1) || (pre == PW'(TICK_DIV - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      mtime    <= '0;
      mtimecmp <= '1;
      msip     <= 1'b0;
      pre      <= '0;
    end else begin
      if (TICK_DIV > 1) pre <= tick ? '0 : pre + 1'b1;
      // A write to mtime wins over the tick in the same cycle
      if (wr && a == 16'hBFF8)      mtime <= {mtime[63:32], merge(mtime[31:0], we, wdata)};
      else if (wr && a == 16'hBFFC) mtime <= {merge(mtime[63:32], we, wdata), mtime[31:0]};
      else if (tick)                mtime <= mtime + 64'd1;
      if (wr && a == 16'h4000) mtimecmp[31:0]  <= merge(mtimecmp[31:0], we, wdata);
      if (wr && a == 16'h4004) mtimecmp[63:32] <= merge(mtimecmp[63:32], we, wdata);
      if (wr && a == 16'h0000 && we[0]) msip <= wdata[0];
    end
  end

  always_ff @(posedge clk) begin
    unique case (a)
      16'h0000: rdata <= {31'b0, msip};
      16'h4000: rdata <= mtimecmp[31:0];
      16'h4004: rdata <= mtimecmp[63:32];
      16'hBFF8: rdata <= mtime[31:0];
      16'hBFFC: rdata <= mtime[63:32];
      default:  rdata <= 32'b0;
    endcase
  end

  assign irq_timer = (mtime >= mtimecmp);
  assign irq_soft  = msip;
endmodule
