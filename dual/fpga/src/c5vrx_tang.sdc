// 50 MHz board clock; the PLL outputs (375, 150 MHz) are derived from it by
// the Gowin timing analyser.
create_clock -name clk50 -period 20 -waveform {0 10} [get_ports {clk50}]
// 75 MHz system / pixel clock from CLKDIV (375 / 5); the analyser does not
// derive CLKDIV outputs by itself.
create_clock -name clk_sys -period 13.333 -waveform {0 6.667} [get_pins {u_div/CLKOUT}]
// 150 MHz CVBS oversampling clock, named so the crossing below can refer to it.
create_clock -name clk_os -period 6.667 -waveform {0 3.333} [get_pins {u_pll/PLLA_inst/CLKOUT1}]
// clk_os <-> clk_sys only meet in cvbs_os_rx's toggle handshake, which is
// built for asynchronous clocks.
set_false_path -from [get_clocks {clk_os}] -to [get_clocks {clk_sys}]
set_false_path -from [get_clocks {clk_sys}] -to [get_clocks {clk_os}]
