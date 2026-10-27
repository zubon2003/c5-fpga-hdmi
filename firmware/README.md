# Modified C5VRX-5 firmware for the FPGA link

`c5vrx5-v5.0.523-fpga-link.patch` modifies
[C5VRX](https://github.com/Twotoz/C5VRX) by Twotoz and the C5VRX
contributors, release `c5vrx5-v5.0.523` (commit `96995500`), so that the
Tang Dock's buttons can step the band and channel and the FPGA can show the
channel on screen. It is **not an official C5VRX release** and is not
endorsed by its authors. Visit the
[official C5VRX website](https://twotoz.github.io/C5VRX/) for the original
project and its Discord invite. C5VRX and this patch are GPL-3.0-only.

Tested on 2026-10-27: picture through the FPGA, channel on screen and the
Dock buttons. `c5vrx5-v5.0.387-fpga-link.patch` is the earlier version of
the same link for release `c5vrx5-v5.0.387` (commit `2f1a1252`).

What the v5.0.523 patch changes (files `main/console.c`, `main/main.c`,
`main/receiver.h`, `main/rf.h`, `main/transport.c`, `main/CMakeLists.txt`):

- IQ pins back on the header as in v5.0.387: Q sign on **D3/GPIO7** and
  I bit 0 on **D10/GPIO10**. Official releases from v5.0.482 on (C5VRX
  PR #263) put them on GPIO2 and the user-LED GPIO27 instead, which this
  project's wiring does not reach.
- UART1, 115200 8N1, on XIAO **D4 = GPIO23 (TX)** and **D5 = GPIO24 (RX)**,
  the two DAC LSB pins, which are no longer driven. The C5's own analog
  video output therefore no longer works; the FPGA takes the MODEM_DIAG
  IQ and does not need it.
- Only the keys `b` (next band), `c` (next channel), `s` (scan) and `?`
  (report now) are accepted on this UART; nothing on it can reboot,
  calibrate or change saved settings. The receiver answers
  `CH <name> <MHz>` + CR LF on every channel change and once a second.
- Internal RAM is nearly full on v5.0.523, so the link has no task of its
  own (the console task polls it), keeps only a small RX buffer and starts
  after the receiver tasks. A link task made the boot fail with
  `ESP_ERR_NO_MEM`.

The v5.0.387 patch has the same UART link (with its own task) and also
keeps the sync flywheel off, because there it drives all six DAC pins.
C5VRX removed the flywheel in PR #260.

## Build and flash

ESP-IDF **v6.0.2** (C5VRX checks the PHY library of exactly this version):

```sh
git clone https://github.com/Twotoz/C5VRX
cd C5VRX
git checkout c5vrx5-v5.0.523
git am /path/to/c5-fpga-hdmi/firmware/c5vrx5-v5.0.523-fpga-link.patch
idf.py set-target esp32c5
idf.py build
python tools/flash.py <XIAO COM port>
```

`tools/flash.py` first sends the console download key, so a running
receiver reboots into the ROM loader itself. A plain `idf.py flash` on a
running receiver stops with a pySerial "Write timeout" and leaves the
board hung; then hold BOOT while plugging USB in and flash again.

Saved C5VRX settings (NVS) are kept. To go back, flash an official
release from the C5VRX web flasher.
