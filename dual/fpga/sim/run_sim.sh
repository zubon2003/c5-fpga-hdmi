#!/bin/bash
# Build and run the system simulation with Verilator (5.x, --timing).
#   ./sim/run_sim.sh          NTSC on both receivers
#   ./sim/run_sim.sh pal      receiver B sends PAL
# Output frames are written as frame_NNN.ppm into build/run[_pal]/.
set -e
cd "$(dirname "$0")/.."
DEF=""; SUF=""
if [ "$1" == "pal" ]; then DEF="-DPAL_B_SRC"; SUF="_pal"; fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT $DEF --top-module tb -Mdir build/obj$SUF \
  sim/tb.v sim/c5vrx_src.v sim/sdram_model.v \
  src/c5vrx_core.v src/cvbs_os_rx.v src/cvbs_decode.v src/chan_buf.v \
  src/sdram_fb.v src/display.v src/tmds_enc.v src/button.v -j 4 > build/verilator$SUF.log 2>&1
mkdir -p build/run$SUF
cd build/run$SUF
../obj$SUF/Vtb +stop_ms=235
