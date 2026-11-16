# Test app (viewer) manual — v0.3.1

[日本語](VIEWER.ja.md)

`scripts/viewer.py` is a Windows app that shows the FPGA's HDMI output on
the PC and changes the FPGA's settings with buttons. The picture comes in
through a UVC capture device; the settings go out over the UART of the
Dock's USB debugger.

The receiver works without it; use it to change settings or to look at
how the picture is received. In v0.3.1 the FPGA saves its settings in its
flash, so once they are set it starts with them without the app.

## What you need

| Item | Notes |
|---|---|
| Windows PC | tested on Windows 11 |
| HDMI capture device (UVC) | 720p input; development used one that shows up as "C8 USB3.0 Video" |
| USB-C cable to the Dock | the Dock's USB debugger (the port used for programming); its second COM port is the FPGA UART (1 Mbaud) |
| Python 3 | from [python.org](https://www.python.org/) (comes with tkinter and the `py` launcher) |
| numpy, pyserial, Pillow | `py -3 -m pip install numpy pyserial pillow` |
| ffmpeg | on the PATH; recording needs a build with libx264 (e.g. from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/)) |

Without a capture device the UART part (settings, status) still works and
the picture area says "no picture"; you can watch an HDMI monitor and use
the app as a remote control.

## Starting

Double-click `viewer.bat` at the top of the repository (or of the
release's source zip). It checks the requirements first and stops with a
message if something is missing.

From a prompt:

```powershell
py -3 scripts\viewer.py
py -3 scripts\viewer.py --device "C8 USB3.0 Video" --port COM4
py -3 scripts\viewer.py --list-devices      # list the capture devices
```

| Argument | Meaning |
|---|---|
| `--device NAME` | capture device; default "C8 USB3.0 Video" if present, else the first video device |
| `--port COMn` | FPGA UART; default (`auto`) finds the Dock debugger's second channel, else COM4 |
| `--list-devices` | print the video device names and exit |
| `--set first=14,act=736` | only for old bitstreams without `R`: tells the app what the FPGA already has (not needed from v0.3.0) |

`viewer.bat` passes the same arguments on (`viewer.bat --port COM5`).

## Window

```
┌ Device  Port  View ───────────────────────────────────────────┐
│                                         │ Display             │
│                                         │ Genlock             │
│            HDMI picture                 │ FM demodulator      │
│      (scales with the window)           │ Colour              │
│                                         │ Picture position    │
│                                         │ SDRAM / capture     │
│                                         │ Live status         │
├─────────────────────────────────────────┴─────────────────────┤
│ UART COM4 open | capture C8 USB3.0 Video 30.0 fps | settings … │
└────────────────────────────────────────────────────────────────┘
```

- **Picture**: the capture device at 1280×720, scaled to the window.
- **Control panel** (right): the FPGA settings as buttons (table below).
- **Status bar** (bottom): UART state, capture device and fps, recording
  time, and the current settings. `settings from FPGA` means read back
  from the FPGA; `tracked` means guessed from what the app sent.

### Menus

| Menu | |
|---|---|
| Device | choose the capture device; Refresh list |
| Port | choose the UART; Auto finds the Dock debugger; Refresh list |
| View > Fullscreen (F11) | full screen; Esc leaves |
| View > Control panel | show / hide the panel |
| View > Live status | read the status once a second or not |

When the board or the capture device is unplugged and plugged back in,
the app reconnects by itself (the capture is retried every 3 s).

## Control panel

Each button sends one character to the FPGA; typing the same character
in the window does the same. The panel shows the values read back from
the FPGA (`R`) after every key and once a second.

| Group | Item | Key | |
|---|---|---|---|
| Display | Picture / Waveform | `P` / `W` | picture / waveform monitor of one demodulated line. Not saved; always Picture at power-up |
| | 4:3 / 16:9 stretch | `A` | 4:3 with black pillars (power-up) / stretched to 16:9 |
| Genlock | Off — SDRAM field store (HDZero) | `g` | fixed output clock through the SDRAM (power-up); use this for HDZero goggles |
| | Porch lines — no SDRAM | `g` | output follows the input by changing the front porch line length; no SDRAM |
| | Pixel clock — no SDRAM | `g` | output follows the input by phase-stepping the pixel clock; no SDRAM |
| FM demodulator | 0 adjacent … 3 PLL slow | `m` | FM demodulator (3 at power-up) |
| Colour | Colour | `c` | colour on / off |
| | V invert | `v` | V sign; try it when the hue is far off |
| | Saturation − / + | `z` / `a` | 0.25× steps |
| | Hue − / + | `[` / `]` | 11.25° steps |
| Picture position | First line − / + | `u` / `d` | first displayed line: vertical position |
| | Start − / + | `h` / `l` | horizontal position, 0.2 µs steps |
| | Field offset flip | `f` | direction of the interlace field offset; flip it when thin horizontal lines or text bob up and down |
| SDRAM / capture | Timing test (K) | `K` | SDRAM read timing test; result in Live status, SDRAM |
| | Invert clock + test (k) | `k` | invert the SDRAM clock, then test |
| | Snapshot (s) | `s` | save the picture as PNG (not sent to the FPGA) |
| | Record (r) | `r` | start / stop recording (H.264 mp4, 30 fps; not sent to the FPGA) |
| | Logic analyser C / S / B / G | `C` `S` `B` `G` | development: raw IQ / symbols / FM output / chroma from the FPGA, saved to a file |
| | Read settings from the FPGA | `R` | read the settings again |

`q` quits (closing a recording first).

The three Genlock buttons send `g` as many times as needed (`g` steps
off → porch lines → pixel clock → off).

**Saved settings**: everything but `P` / `W` is saved in the FPGA's
flash 2 s after the last change and comes back at the next power-up,
also after the bitstream is reprogrammed. The settings stay in the FPGA
when the app is closed.

## Live status

The FPGA status (`T`), read once a second.

| Row | Example | Meaning |
|---|---|---|
| Signal | `OK  lines 253  h …` | green OK with more than 200 lines and 40 fields; red NO SYNC without a VTX |
| Fields | `48/0.8s  synth 0  vsync 48` | fields per 0.8 s (47–48 when fine); synth = fields made up without a vertical sync |
| Levels | `tip … black … gain …` | sync tip and black levels, picture amplitude correction |
| Colour | `locked  burst …  │R│ …` | green locked when locked to the colour burst; killed = shown in black and white |
| Receiver | `F3  5780 MHz` | receiver channel, only with the modified C5 firmware and the receiver link; else no link report |
| Output | `pclk 74.1818 MHz  re-locks 0` | measured HDMI pixel clock and how often the output re-locked |
| SDRAM | `pass  pos …  ckinv …  ok …` | last SDRAM test; FAIL without the SDRAM module (fine in the genlock modes) |

## Common problems

- **Picture stays black**: after programming the FPGA the capture device
  sometimes does not pick up the HDMI again. Switch Waveform → Picture
  once, or replug the capture device's USB.
- **No SDRAM module**: nothing shows at power-up (Genlock Off). Choose
  Genlock Porch lines; it is saved after 2 s, so the board starts in that
  mode from then on. Going back to Off loses the picture again. HDZero
  goggles show white in the genlock modes.
- **UART not connected**: pick the Dock debugger's second COM port in the
  Port menu. Another program (serial terminal, programmer tool) holding
  the port blocks it, and while the app is open other programs cannot
  open it.
- **Programming the FPGA**: works with the app open; the UART drops while
  programming and reconnects by itself.
- **Picture shifted**: Picture position, First line and Start.
- **Wrong colours**: V invert, then Hue. With no colour, check that the
  Colour row says locked.
- **Record saves nothing**: the ffmpeg build has no libx264.

## Files

Everything goes into `captures/` at the top of the repository.

| File | |
|---|---|
| `snap_HHMMSS.png` | snapshot |
| `rec_YYYYMMDD_HHMMSS.mp4` | recording |
| `la_X_HHMMSS.bin` | logic analyser capture (development) |
| `live.png` | current picture, rewritten once a second |
| `viewer_log.txt` | log |
| `viewer_cmd.txt` | remote control from other programs (below) |

## Control from other programs (development)

The app keeps the UART open, so other tools append lines to
`captures/viewer_cmd.txt`; results go to `captures/viewer_log.txt`.

| Command | |
|---|---|
| `key CHARS` | send characters to the FPGA |
| `cap C\|S\|B\|G PATH` | logic analyser capture |
| `snap PATH` | save the current picture |
| `rec start [PATH]` / `rec stop` | start / stop recording |
| `fm 0..3` | set the FM demodulator |
| `defaults` | read the settings again (`R`) |
| `status` | write the status (`T`) to the log |
| `device NAME` / `port NAME\|auto` | switch the capture device / UART |
