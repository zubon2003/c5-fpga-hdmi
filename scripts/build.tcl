# Gowin EDA (Education 1.9.11+) batch build: gw_sh scripts/build.tcl
set_device -name GW5A-25A GW5A-LV25MG121NC1/I0
set_option -top_module top
set_option -output_base_name c5_fpga_hdmi
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
add_file src/top.v
add_file src/pll.v
add_file src/video_timing.v
add_file src/display.v
add_file src/tmds_encoder.v
add_file src/dvi_tx.v
add_file src/uart.v
add_file src/iq_la.v
add_file src/iq_resampler.v
add_file src/fm_demod.v
add_file src/scope_line.v
add_file src/video_in.v
add_file src/chroma.v
add_file src/line_buffer.v
add_file src/top.cst
add_file src/top.sdc
run all
