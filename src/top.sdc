create_clock -name clk_50 -period 20 -waveform {0 10} [get_ports {clk}]
create_clock -name clk_5x -period 2.685 [get_pins {u_pll/pll/CLKOUT0}]
create_clock -name clk_pixel -period 13.426 [get_pins {u_div/CLKOUT}]
create_clock -name clk_iq_fast -period 2.963 [get_pins {u_pll/pll/CLKOUT1}]
create_clock -name clk_iq -period 11.852 [get_pins {u_div_iq/CLKOUT}]
// The activity and vote counts cross to the pixel domain for display only.
set_false_path -from [get_clocks {clk_iq}] -to [get_clocks {clk_pixel}]
// The scope line RAM is written in the IQ domain and read for display.
set_false_path -from [get_clocks {clk_pixel}] -to [get_clocks {clk_iq}]
