#!/bin/bash
# Build and run the IQ system simulation with Verilator (5.x, --timing).
#   ./sim/run_sim.sh          NTSC on both receivers
#   ./sim/run_sim.sh pal      receiver B sends PAL
# Output frames are written as frame_NNN.ppm into build/run[_pal]/.
set -e
mkdir -p ${BUILD:-build}
cd "$(dirname "$0")/.."
DEF=""; SUF=""; B=${BUILD:-build}
if [ "$1" == "pal" ]; then DEF="-DPAL_B_SRC"; SUF="_pal"; fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT $DEF --top-module tb -Mdir $B/obj$SUF \
  sim/tb_iq.v sim/iq_src.v sim/sdram_model.v \
  src/c5vrx_core_iq.v src/iq_os_rx.v src/iq_phase_lut.v src/fm_demod.v src/link_rx.v \
  src/cvbs_decode_fm.v src/chan_buf.v src/sdram_fb.v src/display.v src/tmds_enc.v src/button.v \
  -j 4 > $B/verilator$SUF.log 2>&1 || { tail -30 $B/verilator$SUF.log; exit 1; }
mkdir -p $B/run$SUF
cd $B/run$SUF
$B/obj$SUF/Vtb +stop_ms=${STOP_MS:-235}
