# Modified C5VRX-5 firmware for the FPGA link

`c5vrx5-v5.0.387-fpga-link.patch` modifies
[C5VRX](https://github.com/Twotoz/C5VRX) by Twotoz and the C5VRX
contributors, release `c5vrx5-v5.0.387` (commit `2f1a1252`), so that the
Tang Dock's buttons can step the band and channel and the FPGA can show the
channel on screen. It is **not an official C5VRX release** and is not
endorsed by its authors. Visit the
[official C5VRX website](https://twotoz.github.io/C5VRX/) for the original
project and its Discord invite. C5VRX and this patch are GPL-3.0-only.

What the patch changes (files `main/console.c`, `main/transport.c`,
`main/CMakeLists.txt`):

- UART1, 115200 8N1, on XIAO **D4 = GPIO23 (TX)** and **D5 = GPIO24 (RX)**,
  the two DAC LSB pins, which are no longer driven. The C5's own analog
  video output therefore no longer works; the FPGA takes the MODEM_DIAG
  IQ and does not need it.
- Only the keys `b` (next band), `c` (next channel), `s` (scan) and `?`
  (report now) are accepted on this UART; nothing on it can reboot,
  calibrate or change saved settings. The receiver answers
  `CH <name> <MHz>` + CR LF on every channel change and once a second.
- The sync flywheel stays off whatever is saved, because it drives the
  output enables and pin muxes of all six DAC pins.

The FPGA side works with the official firmware too; only the buttons and
the channel display need this patch.

## Build and flash

ESP-IDF **v6.0.2** (C5VRX checks the PHY library of exactly this version):

```sh
git clone https://github.com/Twotoz/C5VRX
cd C5VRX
git checkout c5vrx5-v5.0.387
git am /path/to/c5-fpga-hdmi/firmware/c5vrx5-v5.0.387-fpga-link.patch
idf.py set-target esp32c5
idf.py build
idf.py -p <XIAO COM port> flash
```

Saved C5VRX settings (NVS) are kept. To go back, flash an official
release from the C5VRX web flasher.
