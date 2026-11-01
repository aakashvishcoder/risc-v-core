# Constraints for fpga_top on the XC7A35T-FGG484.
#
# NOTE: the pin locations below are placeholders on bank 34 (the clock on a
# clock-capable MRCC pin) so the design can be placed, routed and timed. They
# are not yet the carrier board's real pinout, which gets filled in at board
# bring-up. Timing results don't depend on which pins these are.

set_property PACKAGE_PIN R4  [get_ports clk]
set_property PACKAGE_PIN AA1 [get_ports btn_rst]
set_property PACKAGE_PIN AB1 [get_ports uart_txd]
set_property PACKAGE_PIN AA3 [get_ports {leds[0]}]
set_property PACKAGE_PIN AA5 [get_ports {leds[1]}]
set_property PACKAGE_PIN AA6 [get_ports {leds[2]}]
set_property PACKAGE_PIN AA8 [get_ports {leds[3]}]
set_property PACKAGE_PIN AB2 [get_ports {leds[4]}]
set_property PACKAGE_PIN AB3 [get_ports {leds[5]}]
set_property PACKAGE_PIN AB5 [get_ports {leds[6]}]
set_property PACKAGE_PIN AB6 [get_ports {leds[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[7]}]

# The board's system clock is a 50 MHz oscillator (Y1)
create_clock -period 20.000 -name sysclk [get_ports clk]
