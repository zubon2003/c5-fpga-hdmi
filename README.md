# c5-fpga-hdmi

[日本語の README](README.ja.md)

> **Experimental — close range only.** This has only been seen working with
> the VTX a short distance (about 1 m, on a desk) from the receiver. Range,
> weak-signal behaviour, other VTXs and other channels have not been tested.
> Treat it as a proof of concept, not as a usable FPV receiver.

Analog 5.8 GHz FPV video (FM, NTSC) received by an ESP32-C5 running
[C5VRX](https://github.com/Twotoz/C5VRX), demodulated on a Sipeed
**Tang Primer 25K** FPGA and shown in colour on an HDMI monitor at
**1280×720p, ~60 Hz** (a 4:3 picture, 960×720 with black pillars, or
stretched to 16:9).

The C5VRX-5 firmware already puts the radio's raw 4-bit IQ samples
(MODEM_DIAG Q4/I4) on eight GPIO pins. The FPGA taps those pins in
parallel; the ESP32-C5 firmware is used unmodified and keeps doing the
gain control, AFC and channel selection.

## Origins

- **[fpvdec / 5G8atv-rf-hackrf-decoder](https://github.com/zubon2003/5G8atv-rf-hackrf-decoder)**
  — my HackRF One software receiver for analog FPV video, which this
  project grew out of. It is itself based on
  [famicom-rf-hackrf-decoder](https://github.com/GOROman/famicom-rf-hackrf-decoder)
  by GOROman. Its NTSC decoder and its C5VRX receive-chain emulation
  (`--c5`) were the reference for the processing here; the FPGA design
  itself is newly written HDL.
- **[C5VRX](https://github.com/Twotoz/C5VRX)** by Twotoz and the C5VRX
  contributors — the ESP32-C5 FPV receiver. This project uses its
  MODEM_DIAG IQ GPIO output (lane mapping and pin order, C5VRX-5
  `main/rf.c`), follows its "C5 RF front end plus external DSP logic"
  research (C5VRX-4 `RESEARCH.md`), its sync separator uses the line
  grid idea of the C5VRX-4 sync flywheel (`SYNC_FLYWHEEL.md`), and its
  FM demodulator extends the C5VRX-5 U85Q phase tracker and kp ladder.
  See [Credits](#credits).

## Hardware

| Part | Notes |
|---|---|
| Seeed XIAO ESP32-C5 | running C5VRX-5 (see below) |
| Sipeed Tang Primer 25K + Tang Primer 25K Dock | GW5A-LV25MG121 |
| Sipeed PMOD DVI (HDMI) module | on Dock PMOD **J6** |
| HDMI monitor or capture device | 720p input |
| 9 jumper wires (8 signals + GND), short | XIAO → Dock PMOD **J4** |
| Analog 5.8 GHz VTX (NTSC) | tested on F3 (5780 MHz) |
| Optional: 2 more jumper wires | XIAO D4/D5 → Dock PMOD **J5**, for the Dock buttons (band / channel) and the on-screen channel; needs the modified C5 firmware below |

### C5VRX version

Tested with the official **C5VRX-5 release `c5vrx5-v5.0.332`**
(commit `24da232`), unmodified, flashed from the
[C5VRX web flasher](https://twotoz.github.io/C5VRX/) / GitHub release.
The IQ GPIO mapping below is the one in that version (also identical in
v5.0.322). Later versions may change it; check `RF_IQ_GPIO_NUMS` in
C5VRX's `main/rf.h` (`s_iq_pins` in `main/rf.c` before v5.0.482). Set the
channel on the C5 as usual (BOOT button menu or USB console) and let its
startup calibration finish.

**Official releases from `c5vrx5-v5.0.482` on do not work with this
wiring.** C5VRX PR #263 moved Q sign from D3/GPIO7 to GPIO2 (MTMS) and
I bit 0 from D10/GPIO10 to the user-LED GPIO27, which is not on a pad.
Official releases up to `c5vrx5-v5.0.464` keep the old pins (only
v5.0.332 is tested unmodified here); the modified v5.0.523 in
[firmware/](firmware/README.md) puts both bits back.

### Optional: band / channel buttons on the Dock

To step the band and channel with the Dock's buttons and see the channel
on screen, the C5 needs a modified C5VRX-5 with a UART on its two DAC LSB
pins: [firmware/](firmware/README.md) has the patches (v5.0.523, tested
2026-10-27; the older v5.0.387 one) and the build steps. It is not an
official C5VRX release; the C5's own analog video output is off in it.
Everything else here works with the official firmware up to v5.0.464.

## Wiring (XIAO ESP32-C5 → Tang Primer 25K Dock J4)

Dock PMOD J4 pin numbers as in the Dock schematic: pins 1/2 are +3V3,
pins 3/4 are GND, pins 5..12 are signals (left column even pins, right
column odd pins). Find pin 1 with a meter (+3.3 V) before wiring.

```
   XIAO ESP32-C5                         Tang Primer 25K Dock, PMOD J4
   (top side)                                  ┌─────────┐
   GND  ──────────────────────────────── 3/4  │ 2    1  │  +3V3  (do NOT connect)
   D0   (GPIO1)  ── Q bit 0 ───────────── 5   │ 4    3  │  GND
   D1   (GPIO0)  ── Q bit 1 ───────────── 6   │ 6    5  │
   D2   (GPIO25) ── Q bit 2 ───────────── 7   │ 8    7  │
   D3   (GPIO7)  ── Q sign  ───────────── 8   │ 10   9  │
   D10  (GPIO10) ── I bit 0 ───────────── 9   │ 12  11  │
   (back side JTAG pads)                       └─────────┘
   MTDO (GPIO5)  ── I bit 1 ───────────── 10
   MTDI (GPIO3)  ── I bit 2 ───────────── 11
   MTCK (GPIO4)  ── I sign  ───────────── 12
   MTMS (GPIO2)  ── do NOT connect (driven by official C5VRX-5 firmware)
```

| J4 pin | FPGA ball | `iq[n]` | Signal | XIAO pin | ESP32-C5 GPIO |
|---|---|---|---|---|---|
| 1, 2 | +3V3 | – | not connected | – | – |
| 3 or 4 | GND | – | ground | GND | – |
| 5 | C11 | 0 | Q bit 0 | D0 | 1 |
| 6 | C10 | 1 | Q bit 1 | D1 | 0 |
| 7 | B11 | 2 | Q bit 2 | D2 | 25 |
| 8 | B10 | 3 | Q sign | D3 | 7 |
| 9 | D11 | 4 | I bit 0 | D10 | 10 |
| 10 | D10 | 5 | I bit 1 | MTDO (back pad) | 5 |
| 11 | G11 | 6 | I bit 2 | MTDI (back pad) | 3 |
| 12 | G10 | 7 | I sign | MTCK (back pad) | 4 |

- Do not connect the two 3.3 V supplies together; both boards are powered
  over their own USB. A common ground is required.
- Keep the wires short (under ~10 cm): the IQ bits change at 80 MHz.
- The three I bits on the XIAO's back-side JTAG pads need soldering.
- The PMOD DVI goes on **J6**.

Optional receiver link (modified C5 firmware only), Dock PMOD **J5**
(same pin numbering as J4):

| J5 pin | FPGA ball | Signal | XIAO pin | ESP32-C5 GPIO |
|---|---|---|---|---|
| 5 | L5 | FPGA TX → C5 RX | D5 | 24 |
| 6 | K5 | C5 TX → FPGA RX | D4 | 23 |

Remove the DAC resistors from D4/D5 if the XIAO had the resistor DAC.

## Programming

A prebuilt bitstream is attached to the
[GitHub release](../../releases) (`c5_fpga_hdmi.fs` for the Gowin
Programmer, `c5_fpga_hdmi.bin` for other loaders).

With the Gowin Programmer (Education edition, no licence needed), device
**GW5A-25A / GW5A-LV25MG121NC1/I0**:

```powershell
# SRAM (lost at power-off)
programmer_cli.exe --device GW5A-25A --run 2  --fsFile c5_fpga_hdmi.fs
# external flash (boots at power-on, ~3 minutes)
programmer_cli.exe --device GW5A-25A --run 54 --fsFile c5_fpga_hdmi.fs
```

If the Programmer reports a different ID, your board may be GW5A-25B:
change `set_device` in `scripts/build.tcl` and rebuild.

### Building

Gowin EDA Education 1.9.11.03 (batch mode):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
# output: impl\pnr\c5_fpga_hdmi.fs
```

## Use

Power the XIAO (C5VRX-5 on the VTX channel) and the Dock, plug in HDMI.
With a VTX on, the picture appears within a second; without one the output
free-runs at ~59.9 Hz. The small square at the top right of the picture is
green while horizontal sync is found, red otherwise.

With the receiver link: the Dock key on H11 steps the band, the key on
H10 the channel (R, A, B, E, F, L; 1..8). The new channel name (e.g. `F3`)
appears at the top right for 3 seconds, and once at power-up.

The Dock's USB debugger has a UART (the second COM port, 1 Mbaud). Single
characters change settings at run time (they reset at power-off):

| Key | Action |
|---|---|
| `P` / `W` | picture (default) / waveform monitor of one demodulated line |
| `u` / `d` | first active line −/+ 1 |
| `h` / `l` | picture start −/+ 0.2 µs |
| `f` | field offset direction (interlace) |
| `c` | colour on/off |
| `v` | V sign (hue) |
| `a` / `z` | colour saturation +/− 0.25× |
| `[` / `]` | hue −/+ 11.25° |
| `m` | FM demodulator mode: 0 adjacent, 1 PLL fast (power-up), 2 PLL, 3 PLL slow |
| `A` | picture 4:3 (960×720 with black pillars, power-up) / stretched to 16:9 |
| `T` | status packet (sync, levels, colour lock, receiver channel) |
| `C` `S` `B` `G` | logic-analyser captures (raw IQ, symbols, FM output, chroma) |

`scripts/viewer.py` shows the HDMI output through a UVC capture device,
sends these keys from its window and decodes `T`:

```powershell
py -3 scripts\viewer.py --device "C8 USB3.0 Video" --port COM4
```

Requirements: Python 3 with numpy and pyserial, ffmpeg on the PATH.
`scripts/iqla.py`, `demod.py`, `fm_model.py` and `resampler_model.py` are
the host tools and bit-level models used to verify each stage on the board.

## How it works

```
XIAO ESP32-C5 (C5VRX-5; official, or patched for the link): RF, ADC, gain, AFC
  │ MODEM_DIAG Q4/I4 on 8 GPIOs, ~80 MHz, no clock
  ▼
Tang Primer 25K
  IDES8 input        675 MS/s, 8.4 samples per IQ symbol
  iq_resampler       phase-tracking resampler (byte-wide Alexander detector)
                     → one IQ byte per symbol, ~80 MS/s (C5/Dock crystal
                     offset ~30 ppm tracked)
  fm_demod           amplitude-gated PLL (or adjacent difference), 22-tap boxcar
  video_in           sync separator (hysteresis, pulse widths, flywheel),
                     field / parity, black and white levels from porch and
                     sync depth, 640 pixels per line into a 32-line ring
  chroma             3.58 MHz NCO frequency-locked to the burst, burst
                     reference averaged over lines (hue + ACC), 1.6 µs
                     chroma low-pass, two-line chroma average
  display            240 → 720 lines with vertical interpolation (field 2
                     placed 1.5 rows lower), BT.601 RGB
  video_timing       1280×720, always 750 lines of 1657 pixels; locked to
                     the input field by changing only the five vertical
                     front porch lines (PI loop)
  TMDS / OSER10      → PMOD DVI (J6)
```

Notes from bring-up:

- The C5's GPIO IQ updates at 80 MHz (C5VRX itself captures it at 40 MS/s).
- A frame length that changes from frame to frame (an earlier version
  repeated the last line to wait for the input) worked on a capture card
  but not on an HDMI monitor; changing the length of picture lines sheared
  the picture on the capture card. Only the vertical front porch lines
  change length now.
- Sharp horizontal edges (OSD text) still move by about a line between
  fields: each field is shown on its own (bob). Removing that needs a
  field store, i.e. external SDRAM.
- After reprogramming, the capture card used during development sometimes
  stayed black until the display mode was switched once (`W`, then `P`).

Resources: about 5,000 LUTs, 49 of 56 BSRAM, 15 DSP blocks.

A detailed development log (Japanese) is in
[docs/DEVLOG.ja.md](docs/DEVLOG.ja.md).

## License

GPL-3.0-only — see [LICENSE](LICENSE).

## Credits

This project incorporates/adapts the ESP32-C5 MODEM_DIAG IQ GPIO routing
(Q4/I4 lane mapping and pin order, C5VRX-5 `main/rf.c`) and the
"C5 RF front end plus external DSP logic" architecture research
(C5VRX-4 `legacy/c5vrx4/RESEARCH.md`), and the idea of a PLL line grid
that only accepts sync pulses near its prediction (C5VRX-4 sync flywheel,
`legacy/c5vrx4/SYNC_FLYWHEEL.md`; reimplemented here as the line PLL in
`src/video_in.v`, which times lines and does not rebuild sync pulses), and
the phase-tracker FM demodulator with selectable loop gain (C5VRX-5 U85Q
tracker and kp ladder, `main/u85q.bsasm`, `main/kp_ladder.h` and
`research/README.md`; extended here in `src/fm_demod.v` with a
second-order loop, an amplitude-gated correction and seamless mode
switching, with the signal and channel model of the C5VRX-5 range
simulator `research/sim.py` followed in `research/demod_sim.py`) from
[C5VRX], and `firmware/c5vrx5-v5.0.523-fpga-link.patch` and
`firmware/c5vrx5-v5.0.387-fpga-link.patch` modify C5VRX-5 v5.0.523
(commit `96995500`; `main/console.c`, `main/main.c`, `main/receiver.h`,
`main/rf.h`, `main/transport.c`, `main/CMakeLists.txt`) and v5.0.387
(commit `2f1a1252`; `main/console.c`, `main/transport.c`,
`main/CMakeLists.txt`) for the optional receiver link, from
[C5VRX](https://github.com/Twotoz/C5VRX) by Twotoz and the C5VRX
contributors. Visit the [official C5VRX website](https://twotoz.github.io/C5VRX/)
for the original project and its Discord invite. See the source and
license notices for the applicable terms (C5VRX is GPL-3.0-only); this
derivative is not an official C5VRX release.

- [fpvdec / 5G8atv-rf-hackrf-decoder](https://github.com/zubon2003/5G8atv-rf-hackrf-decoder)
  (GPL-3.0-only), based on GOROman's
  [famicom-rf-hackrf-decoder](https://github.com/GOROman/famicom-rf-hackrf-decoder) (MIT).
- Tang Primer 25K Dock PMOD / HDMI pin locations and PLL settings follow
  Sipeed's [TangPrimer-25K-example](https://github.com/sipeed/TangPrimer-25K-example)
  (`hdmi/svo`, commit 27c1737) and the Dock schematic; the HDL here is newly
  written.
