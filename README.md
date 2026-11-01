# c5-fpga-hdmi

[日本語の README](README.ja.md)

> **Experimental — close range only.** This has only been seen working with
> the VTX a short distance (about 1 m, on a desk) from the receiver. Range,
> weak-signal behaviour, other VTXs and other channels have not been tested.
> Treat it as a proof of concept, not as a usable FPV receiver.

Analog 5.8 GHz FPV video (FM, NTSC) received by an ESP32-C5 running
[C5VRX](https://github.com/Twotoz/C5VRX), demodulated on a Sipeed
**Tang Primer 25K** FPGA and shown in colour on an HDMI monitor at
**1280×720p, 59.94 Hz** (CEA 720p frame timing; a 4:3 picture, 960×720 with
black pillars, or stretched to 16:9). An SDRAM field store lets the HDMI
output run on a fixed pixel clock, which HDZero goggles need; with genlock
on, the output follows the input with about 1 ms of latency and no SDRAM.

The C5VRX-5 firmware already puts the radio's raw 4-bit IQ samples
(MODEM_DIAG Q4/I4) on eight GPIO pins. The FPGA taps those pins in
parallel; the ESP32-C5 firmware keeps doing the gain control, AFC and
channel selection. Official releases up to v5.0.464 work unmodified;
later ones moved two IQ pins, and [firmware/](firmware/README.md) has a
patched v5.0.523 (see [C5VRX version](#c5vrx-version)).

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
| Sipeed PMOD DVI (HDMI) module | on Dock PMOD **J5** (middle) |
| Sipeed Tang SDRAM module (32 MB, 16 bit) | on the Dock's 40-pin header **J3**; field store (`src/sdram_fb.v`), needed for genlock off (power-up, HDZero) |
| HDMI monitor or capture device | 720p input |
| 9 jumper wires (8 signals + GND), short | XIAO → Dock PMOD **J4** |
| Analog 5.8 GHz VTX (NTSC) | tested on F3 (5780 MHz) |
| Optional: USB-A plug (breakout) + 3 wires | XIAO D4/D5 → Dock USB-A host port **J13**, for the Dock buttons (band / channel) and the on-screen channel; needs the modified C5 firmware below |

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
- The PMOD DVI goes on **J5** (the middle PMOD; J6 until 2026-11-01).

The SDRAM module plugs into the Dock's 40-pin header J3 (pins as in
Sipeed's TangPrimer-25K-example `nestang-25k`). With genlock off (the
power-up setting, needed for HDZero goggles) every picture goes through
it. With genlock on (`g`) the SDRAM is bypassed, so the board can also be
used without the module: the picture appears after `g` is pressed.

Optional receiver link (modified C5 firmware only), through the Dock's
USB-A host port **J13** (a USB-A plug breakout; the port's D+ / D- go to
FPGA balls L6 / K6 through 0 Ω, with 15 kΩ to GND on both; the link is a
plain 115200 baud UART on those wires, not USB):

| USB-A pin | FPGA ball | Signal | XIAO pin | ESP32-C5 GPIO |
|---|---|---|---|---|
| 2 (D−) | K6 | C5 TX → FPGA RX | D4 | 23 |
| 3 (D+) | L6 | FPGA TX → C5 RX | D5 | 24 |
| 4 (GND) | – | ground | GND | – |
| 1 (VBUS) | – | Dock +5 V | not connected | – |

Leave VBUS unconnected while the XIAO is powered from its own USB (its
5V pin is that USB's VBUS). Remove the DAC resistors from D4/D5 if the
XIAO had the resistor DAC. Tested 2026-11-01: the channel reports arrive
(`E1 5705`); the first build had D+ / D− the other way round and got
nothing.

## Programming

Prebuilt bitstreams are attached to the
[GitHub releases](../../releases) (`c5_fpga_hdmi.fs` for the Gowin
Programmer, `c5_fpga_hdmi.bin` for other loaders). Releases up to v0.2.0
are the earlier design: no SDRAM, PMOD DVI on J6, receiver link on J5.

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
The HDMI output is always 1280×720 at 59.94 Hz (59.945); with a VTX on, the picture
appears within a second, without one the picture area shows noise. The
small square at the top right of the picture is green while horizontal
sync is found, red otherwise.

Latency: with genlock off (power-up), the HDMI output runs on its own
clock and shows fields from the SDRAM field store. The added delay is
between about 0.5 ms and one field (16.7 ms), about 8 ms on average; it
drifts slowly as the output and the input clocks differ, and steps back
by one field every few minutes (one field is dropped or shown twice).
The genlock modes (`g`) lock the output to the input and bypass the SDRAM:
the display reads the lines straight from a 24-line ring, about 0.2 ms
behind the input at the top of the picture and about 1 ms at the bottom
(computed, not measured). HDZero goggles cannot follow the timing changes
genlock makes.

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
| `g` | output genlock, in turn: off (power-up; fixed 74.18 MHz pixel clock, SDRAM field store) → porch lines → pixel clock (PLL phase steps) → off. Both genlock modes bypass the SDRAM (low latency, no module needed) |
| `K` | SDRAM read timing test (result in `T` word 13) |
| `k` | invert the SDRAM clock, then run the test |
| `T` | status packet (sync, levels, colour lock, receiver channel, SDRAM status, pixel clock meter) |
| `R` | read back the settings above (`IQLR`, 8 bytes; layout in `src/top.v`, `settings`) |
| `C` `S` `B` `G` | logic-analyser captures (raw IQ, symbols, FM output, chroma) |

`scripts/viewer.py` is the PC test app: it shows the HDMI output through
a UVC capture device and controls the FPGA over the UART.

- **Picture**: scales with the window; F11 (or View > Fullscreen) for full
  screen, Esc to leave.
- **Control panel**: every setting above as buttons (display mode, 4:3 /
  16:9, genlock mode, FM demodulator, colour, hue, saturation, picture
  position, SDRAM test, snapshot, recording, logic-analyser captures).
  The panel shows the FPGA's own settings, read back with `R` when the
  UART opens, after every key and once a second (with an older bitstream
  without `R` it tracks what it sent).
- **Live status**: the `T` packet once a second (sync, fields, levels,
  colour lock, receiver channel, pixel clock, SDRAM test result).
- **Device** menu: the capture device (default "C8 USB3.0 Video" if
  present, else the first; `--device`, `--list-devices`).
- **Port** menu: the UART (Auto = the Dock debugger's second COM port,
  found by its FTDI serial number; `--port`).
- The capture and the UART reconnect by themselves when the board or the
  capture device is unplugged and comes back.
- Keyboard: the keys above, plus `s` snapshot, `r` record, `q` quit.

Double-click `viewer.bat` in the repository root to start it (it checks
the requirements first and passes any arguments on), or:

```powershell
py -3 scripts\viewer.py
py -3 scripts\viewer.py --device "C8 USB3.0 Video" --port COM4
```

Requirements: Python 3 with numpy, pyserial and Pillow, ffmpeg on the PATH.
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
                     sync depth, 640 pixels per line into an 8-line ring
  sdram_fb           field store in the SDRAM module: 4 field buffers;
                     input ring → SDRAM → 8-line output ring, so the
                     output does not have to follow the input (genlock
                     off); with genlock on, video_in writes the output
                     ring directly as a 24-line ring (SDRAM bypass)
  chroma             3.58 MHz NCO frequency-locked to the burst, burst
                     reference averaged over lines (hue + ACC), 1.6 µs
                     chroma low-pass, two-line chroma average
  display            240 → 720 lines with vertical interpolation (field 2
                     placed 1.5 rows lower), BT.601 RGB
  video_timing       CEA 1280×720p timing, 1650 × 750 at 74.1818 MHz
                     (59.945 Hz; two PLLs in a row), free-running by default; the
                     optional genlock moves the pixel clock (PI loop
                     driving dynamic phase steps of the second PLL) or the
                     porch line lengths
  TMDS / OSER10      → PMOD DVI (J5)
```

Notes from bring-up:

- The C5's GPIO IQ updates at 80 MHz (C5VRX itself captures it at 40 MS/s).
- A frame length that changes from frame to frame (an earlier version
  repeated the last line to wait for the input) worked on a capture card
  but not on an HDMI monitor; changing the length of picture lines sheared
  the picture on the capture card. Changing only the vertical front porch
  lines suited monitors and the capture card, but HDZero goggles (HDMI in)
  showed white and re-synced on every change, even BASE ± 1 for whole
  frames. Moving the pixel clock instead (1/8-VCO-period PLL phase steps,
  112.3 ps now; this needs an integer output divider, with the fractional
  3.625 used before the phase wrapped after three VCO periods and the
  steps did not change the frequency) also turned the goggles white. So
  the output now runs on a fixed clock and the SDRAM field store takes up
  the difference (genlock off at power-up).
- HDZero goggles from firmware 9.6.0-rc1 show black for a non-standard
  1631 × 750 frame at 73.33 MHz (the earlier timing), hence the standard
  1650 × 750 frame (at 74.1818 MHz, 81 ppm above the CEA 74.1758 MHz). A
  fractional PLL multiplier gave no picture at all, so two PLLs with integer
  multipliers run in a row (`src/pll.v`).
- Sharp horizontal edges (OSD text) still move by about a line between
  fields: each field is shown on its own (bob). The field store keeps the
  previous fields, but combining two fields (weave) is not done yet.
- After reprogramming, the capture card used during development sometimes
  stayed black until the display mode was switched once (`W`, then `P`).

Resources: about 5,000 LUTs (7,900 logic cells with ALUs), 41 of 56 BSRAM,
72 % of the DSP blocks, 2 of 6 PLLs.

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
- Tang Primer 25K Dock PMOD / HDMI / SDRAM pin locations and PLL settings
  follow Sipeed's [TangPrimer-25K-example](https://github.com/sipeed/TangPrimer-25K-example)
  (`hdmi/svo` and `nestang-25k`, commit 27c1737) and the Dock schematic; the
  HDL here is newly written.
