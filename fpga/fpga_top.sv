// ---------------------------------------------------------------------------
// fpga_top: the SoC as it goes on the Artix-7 carrier board
//   - single-cycle block RAM (CACHES = 0): 64 KiB = 16 RAMB36, initialised
//     from the program image at configuration time
//   - UART at 115200 baud, 8 LEDs, active-high reset button
//   - reset synchronised to the clock and held for 16 cycles
// Only real pins leave this module, so synthesis trims the simulation-only
// ports (commit trace, SIM_EXIT).
// ---------------------------------------------------------------------------
module fpga_top #(
  parameter int    CLK_HZ   = 100_000_000,
  parameter int    BAUD     = 115_200,
  parameter string FIRMWARE = "firmware.hex"
) (
  input  logic       clk,
  input  logic       btn_rst,
  output logic       uart_txd,
  output logic [7:0] leds
);
  logic [3:0] rst_cnt = '0;
  logic       rst_meta = 1'b1, rst_sync = 1'b1;
  always_ff @(posedge clk) begin
    rst_meta <= btn_rst;
    rst_sync <= rst_meta;
    if (rst_sync)           rst_cnt <= '0;
    else if (rst_cnt != '1) rst_cnt <= rst_cnt + 1'b1;
  end
  wire rst = (rst_cnt != '1);

  rv_soc #(
    .CLKS_PER_BIT (CLK_HZ / BAUD),
    .MEM_INIT     (FIRMWARE),
    .CACHES       (0),
    .TICK_DIV     (1)
  ) u_soc (
    .clk, .rst,
    .uart_txd, .leds,
    .tx_valid (), .tx_byte (), .exit_valid (), .exit_code (),
    .commit_valid (), .commit_pc (), .commit_instr (), .commit_rd_we (),
    .commit_rd (), .commit_rd_val (), .commit_trap (), .commit_cause (), .commit_tval ()
  );
endmodule
