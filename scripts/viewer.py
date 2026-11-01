"""Live viewer and control panel for the FPGA's HDMI output (through a UVC
capture device) and its UART settings.

    py -3.13 scripts/viewer.py [--device "C8 USB3.0 Video"] [--port COM4] [--set first=14,act=736]
    py -3.13 scripts/viewer.py --list-devices

Window:
    video (scales with the window; F11 or View > Fullscreen, Esc leaves),
    control panel (every FPGA setting as buttons), live status (the FPGA's
    'T' packet, read once a second) and a status bar.
    Device menu: the capture device (DirectShow video input). Without
    --device it takes "C8 USB3.0 Video" if present, else the first one.
    Port menu: the FPGA UART. "Auto" takes the Dock debugger's second
    channel (FTDI 0403:6010, serial number ending in B), else COM4.
    Both reconnect by themselves when the board or the capture device is
    unplugged and comes back.

Keys (sent to the FPGA as they are; the panel sends the same keys):
    P picture   W waveform monitor
    u / d first active line -/+ 1      h / l picture start -/+ 0.2 us
    f field offset direction           c colour on/off      v V sign
    a / z colour saturation +/- 0.25x  [ / ] hue -/+ 11.25 degrees
    m FM demodulator mode 0..3 (0 adjacent, 1 fast PLL, 2 PLL, 3 slow PLL)
    A picture 4:3 (black pillars, power-up) / 16:9 stretch
    g output genlock: off (power-up, SDRAM field store) / porch lines /
      pixel clock (both genlock modes bypass the SDRAM)
    K SDRAM read timing test   k invert the SDRAM clock and test
    s save a snapshot now (captures/snap_<time>.png)         q quit
    r start / stop recording a video (captures/rec_<time>.mp4)

The panel shows the FPGA's own settings: the viewer reads them back with
'R' when the UART opens, after every key it sends and once a second. With
a bitstream older than 'R' it falls back to tracking what it sent
(power-up values at start, or --set; "Read settings" then resets them).

The viewer keeps the UART open, so other tools go through it. It saves
captures/live.png once a second and executes lines appended to
captures/viewer_cmd.txt, logging to captures/viewer_log.txt:
    key <chars>            send characters to the FPGA
    cap <C|S|B|G> <path>   logic-analyser capture (as scripts/iqla.py)
    snap <path>            save the current frame
    rec start [path]       record the picture to an H.264 mp4 (30 fps)
    rec stop               finish the recording
    fm <0..3>              set the FM demodulator mode (from the tracked one)
    defaults               read the settings back ('R'; power-up values if unsupported)
    status                 FPGA status packet ('T'), logged
    device <name>          switch the capture device
    port <name|auto>       switch the UART port
"""
import argparse
import os
import queue
import struct
import subprocess
import sys
import threading
import time
import tkinter as tk
import zlib
from tkinter import ttk

import serial
from serial.tools import list_ports

try:
    from PIL import Image, ImageTk          # scaling the picture; without it, 1:1 only
except ImportError:
    Image = ImageTk = None

W, H = 1280, 720
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
CAP_DIR = os.path.join(ROOT, "captures")
CMD_FILE = os.path.join(CAP_DIR, "viewer_cmd.txt")
LOG_FILE = os.path.join(CAP_DIR, "viewer_log.txt")
KEYS = "PWudhlfcvaz[]mAgKk"
DEFAULT_DEVICE = "C8 USB3.0 Video"
DEFAULT_PORT = "COM4"
IQ_HZ = 84_375_000          # FPGA IQ clock; the 'T' pixel clock meter counts per 2^20 of them
DEFAULTS = {"mode": "P", "first": 16, "act": 752, "f": 1, "c": 1, "v": 1, "sat": 4, "hue": 0, "fm": 1,
            "ar43": 1, "gl": 1}   # as in src/top.v
GL_ORDER = [1, 2, 0]        # 'g' steps off -> porch lines -> pixel clock -> off
GL_NAMES = {0: "pixel clock (no SDRAM)", 1: "off (SDRAM)", 2: "porch lines (no SDRAM)"}
FM_NAMES = ("adjacent", "PLL fast", "PLL", "PLL slow")


def list_video_devices():
    """DirectShow video input names, as ffmpeg lists them."""
    try:
        out = subprocess.run(["ffmpeg", "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
                             capture_output=True, timeout=15).stderr.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return []
    names = []
    for line in out.splitlines():
        if line.rstrip().endswith("(video)") and '"' in line:
            names.append(line.split('"')[1])
    return names


def find_uart_port():
    """The Dock debugger's UART: FTDI 0403:6010 channel B (serial number ends in B)."""
    ftdi = [p for p in list_ports.comports() if p.vid == 0x0403 and p.pid == 0x6010]
    for p in ftdi:
        if (p.serial_number or "").endswith("B"):
            return p.device
    return ftdi[-1].device if ftdi else None


def decode_status(data):
    """40-byte 'T' reply -> dict of named values (see src/top.v la_status)."""
    w = struct.unpack("<16H", data[8:])
    sgn = lambda v: v - 0x4000 if v & 0x2000 else v      # 14-bit signed
    st = w[13]
    cnt = 921_894 + ((w[15] - 921_894 + 0x8000) & 0xFFFF) - 0x8000   # low 16 bits of ~921,894
    return {
        "real_lines": w[0],
        "channel": bytes([w[1] >> 8, w[1] & 255]).decode("ascii", "replace") if w[1] >> 8 else "--",
        "par1_fields": w[2] >> 5, "lvl_n": w[2] & 31,
        "out_jumps": w[3],
        "tip_f": sgn(w[4]), "black_f": sgn(w[5]),
        "freq_mhz": w[6],
        "vsync_det": w[7], "gain": w[8], "h": w[9], "synth_fields": w[10], "fields": w[11],
        "burst": w[12] & 0x7fff, "colour_lock": bool(w[12] & 0x8000),
        "sdram": st, "sd_pass": st >> 15, "sd_ckinv": (st >> 14) & 1, "sd_pos": (st >> 11) & 7,
        "sd_dist": (st >> 8) & 3, "sd_ok": st & 255,
        "r_mag": w[14],
        "pclk_mhz": cnt * IQ_HZ / (1 << 20) / 1e6,
    }


def decode_settings(data):
    """16-byte 'R' reply -> viewer settings dict (layout in src/top.v `settings`)."""
    b = data[8:16]
    return {"mode": "P" if b[0] & 1 else "W", "ar43": (b[0] >> 1) & 1, "gl": (b[0] >> 2) & 3,
            "fm": (b[0] >> 4) & 3, "c": (b[0] >> 6) & 1, "v": b[0] >> 7,
            "sat": b[1] & 15, "f": (b[1] >> 4) & 1, "hue": b[2] & 31, "first": b[3],
            "act": (b[4] | b[5] << 8) & 0x1FFF}


def status_line(s):
    return (f"real_lines={s['real_lines']} channel={s['channel']} par1_fields|lvl_n={s['par1_fields']}|{s['lvl_n']} "
            f"out_jumps={s['out_jumps']} tip_f={s['tip_f']} black_f={s['black_f']} freq_mhz={s['freq_mhz']} "
            f"vsync_det/0.8s={s['vsync_det']} gain={s['gain']} h/0.8s={s['h']} synth_fields/0.8s={s['synth_fields']} "
            f"fields/0.8s={s['fields']} burst|B|/16={s['burst']} colour={'on' if s['colour_lock'] else 'KILLED'} "
            f"sdram={s['sdram']:#06x}(pass={s['sd_pass']} ckinv={s['sd_ckinv']} pos={s['sd_pos']} "
            f"dist={s['sd_dist']} ok={s['sd_ok']:08b}) |R|={s['r_mag']} pclk={s['pclk_mhz']:.4f}MHz")


def write_png(path, rgb, w=W, h=H):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 1))
                + chunk(b"IEND", b""))
    os.replace(tmp, path)


class Viewer:
    def __init__(self, device, port, overrides=None):
        os.makedirs(CAP_DIR, exist_ok=True)
        self.frame = None
        self.frames = 0
        self.lock = threading.Lock()
        self.ser_lock = threading.Lock()
        self.running = True
        self.status = "starting"
        self.settings = dict(DEFAULTS)
        self.settings.update(overrides or {})
        self.rec = None                # encoder process while recording
        self.rec_q = None
        self.rec_path = ""
        self.rec_frames = 0
        self.rec_dropped = 0
        self.stat = None               # last decoded 'T' packet
        self.readback = False          # settings come from the FPGA ('R'), not tracking
        self.stat_time = 0.0
        self.poll_status = True
        open(CMD_FILE, "a").close()
        self.cmd_pos = os.path.getsize(CMD_FILE)

        # UART: opened (and reopened) by the serial watcher
        self.ser = None
        self.port_choice = port or "auto"
        self.port = ""

        # capture: ffmpeg on a DirectShow device, restarted when it stops
        self.ff = None
        self.ff_gen = 0                # capture generation: an old reader stops after a switch
        self.device = ""
        self.capture_retry_at = 0.0
        self.devices = list_video_devices()
        if device is None:
            device = DEFAULT_DEVICE if DEFAULT_DEVICE in self.devices or not self.devices else self.devices[0]
        self.fps = 0.0
        self.fps_mark = (time.time(), 0)

        self.build_ui(device)
        self.start_capture(device)
        threading.Thread(target=self.serial_watch, daemon=True).start()
        threading.Thread(target=self.status_poller, daemon=True).start()
        threading.Thread(target=self.housekeeping, daemon=True).start()

    # ---- window -------------------------------------------------------------

    def build_ui(self, device):
        self.root = tk.Tk()
        self.root.title("C5 FPGA HDMI viewer")
        self.root.geometry("1560x800")
        self.root.minsize(800, 480)
        self.fullscreen = False
        self.photo = None

        # menus
        self.device_var = tk.StringVar(value=device)
        self.port_var = tk.StringVar(value=self.port_choice)
        self.panel_var = tk.BooleanVar(value=True)
        self.poll_var = tk.BooleanVar(value=True)
        menubar = tk.Menu(self.root)
        self.dev_menu = tk.Menu(menubar, tearoff=0)
        self.port_menu = tk.Menu(menubar, tearoff=0)
        view = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Device", menu=self.dev_menu)
        menubar.add_cascade(label="Port", menu=self.port_menu)
        menubar.add_cascade(label="View", menu=view)
        view.add_command(label="Fullscreen (F11)", command=self.toggle_fullscreen)
        view.add_checkbutton(label="Control panel", variable=self.panel_var, command=self.apply_panel)
        view.add_checkbutton(label="Live status (T once a second)", variable=self.poll_var,
                             command=lambda: setattr(self, "poll_status", self.poll_var.get()))
        self.root.config(menu=menubar)
        self.fill_device_menu()
        self.fill_port_menu()

        # status bar at the bottom, then video (expands) and the panel on the right
        self.bar = tk.Label(self.root, anchor="w", font=("Consolas", 10), relief="sunken")
        self.bar.pack(side="bottom", fill="x")
        self.body = tk.Frame(self.root, bg="black")
        self.body.pack(side="top", fill="both", expand=True)
        self.panel = ttk.Frame(self.body, padding=4)
        self.panel.pack(side="right", fill="y")
        self.video = tk.Label(self.body, bg="black", fg="gray70", font=("Segoe UI", 14))
        self.video.pack(side="left", fill="both", expand=True)
        self.build_panel(self.panel)

        self.root.bind("<Key>", self.on_key)
        self.root.bind("<F11>", lambda e: self.toggle_fullscreen())
        self.root.bind("<Escape>", lambda e: self.toggle_fullscreen(False))
        self.root.protocol("WM_DELETE_WINDOW", self.quit)
        self.root.after(30, self.redraw)
        self.root.after(250, self.update_status_panel)

    def build_panel(self, p):
        s = self.settings
        self.v_mode = tk.StringVar(value=s["mode"])
        self.v_ar = tk.IntVar(value=s["ar43"])
        self.v_gl = tk.IntVar(value=s["gl"])
        self.v_fm = tk.IntVar(value=s["fm"])
        self.v_c = tk.IntVar(value=s["c"])
        self.v_v = tk.IntVar(value=s["v"])
        self.v_f = tk.IntVar(value=s["f"])
        self.l_sat = tk.StringVar()
        self.l_hue = tk.StringVar()
        self.l_first = tk.StringVar()
        self.l_act = tk.StringVar()

        def group(title):
            f = ttk.LabelFrame(p, text=title, padding=(6, 2))
            f.pack(fill="x", pady=2)
            return f

        def stepper(parent, row, text, var, minus, plus):
            ttk.Label(parent, text=text).grid(row=row, column=0, sticky="w")
            ttk.Button(parent, text="−", width=3, command=lambda: self.send_async(minus)).grid(row=row, column=1)
            ttk.Label(parent, textvariable=var, width=10, anchor="center").grid(row=row, column=2)
            ttk.Button(parent, text="+", width=3, command=lambda: self.send_async(plus)).grid(row=row, column=3)

        g = group("Display")
        ttk.Radiobutton(g, text="Picture", variable=self.v_mode, value="P",
                        command=lambda: self.send_async("P")).grid(row=0, column=0, sticky="w")
        ttk.Radiobutton(g, text="Waveform", variable=self.v_mode, value="W",
                        command=lambda: self.send_async("W")).grid(row=0, column=1, sticky="w")
        ttk.Radiobutton(g, text="4:3", variable=self.v_ar, value=1,
                        command=lambda: self.set_toggle("ar43", 1, "A")).grid(row=1, column=0, sticky="w")
        ttk.Radiobutton(g, text="16:9 stretch", variable=self.v_ar, value=0,
                        command=lambda: self.set_toggle("ar43", 0, "A")).grid(row=1, column=1, sticky="w")

        g = group("Genlock")
        for i, val in enumerate(GL_ORDER):
            ttk.Radiobutton(g, text={1: "Off — SDRAM field store (HDZero)", 2: "Porch lines — no SDRAM",
                                     0: "Pixel clock — no SDRAM"}[val],
                            variable=self.v_gl, value=val, command=lambda v=val: self.set_genlock(v)
                            ).grid(row=i, column=0, sticky="w")

        g = group("FM demodulator")
        for i, name in enumerate(FM_NAMES):
            ttk.Radiobutton(g, text=f"{i} {name}", variable=self.v_fm, value=i,
                            command=lambda v=i: self.set_fm(v)).grid(row=i // 2, column=i % 2, sticky="w")

        g = group("Colour")
        ttk.Checkbutton(g, text="Colour", variable=self.v_c,
                        command=lambda: self.set_toggle("c", self.v_c.get(), "c")).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(g, text="V invert", variable=self.v_v,
                        command=lambda: self.set_toggle("v", self.v_v.get(), "v")).grid(row=0, column=1, columnspan=3,
                                                                                      sticky="w")
        stepper(g, 1, "Saturation", self.l_sat, "z", "a")
        stepper(g, 2, "Hue", self.l_hue, "[", "]")

        g = group("Picture position")
        stepper(g, 0, "First line", self.l_first, "u", "d")
        stepper(g, 1, "Start", self.l_act, "h", "l")
        ttk.Checkbutton(g, text="Field offset flip", variable=self.v_f,
                        command=lambda: self.set_toggle("f", self.v_f.get(), "f")).grid(row=2, column=0, columnspan=4,
                                                                                      sticky="w")

        g = group("SDRAM / capture")
        ttk.Button(g, text="Timing test (K)", command=lambda: self.send_async("K")).grid(row=0, column=0, sticky="ew")
        ttk.Button(g, text="Invert clock + test (k)", command=lambda: self.send_async("k")).grid(row=0, column=1,
                                                                                               sticky="ew")
        ttk.Button(g, text="Snapshot (s)", command=self.snapshot_now).grid(row=1, column=0, sticky="ew")
        self.rec_btn = ttk.Button(g, text="Record (r)", command=self.toggle_rec)
        self.rec_btn.grid(row=1, column=1, sticky="ew")
        la = ttk.Frame(g)
        la.grid(row=2, column=0, columnspan=2, sticky="ew")
        ttk.Label(la, text="Logic analyser:").pack(side="left")
        for m, tip in (("C", "raw"), ("S", "sym"), ("B", "FM"), ("G", "chr")):
            ttk.Button(la, text=f"{m} {tip}", width=6,
                       command=lambda m=m: threading.Thread(target=self.capture_auto, args=(m,), daemon=True).start()
                       ).pack(side="left")
        ttk.Button(g, text="Read settings from the FPGA",
                   command=lambda: threading.Thread(target=self.reset_defaults, daemon=True).start()
                   ).grid(row=3, column=0, columnspan=2, sticky="ew")

        g = group("Live status")
        self.stat_labels = {}
        rows = [("Signal", "sig"), ("Fields", "fld"), ("Levels", "lvl"), ("Colour", "col"), ("Receiver", "rx"),
                ("Output", "out"), ("SDRAM", "sd")]
        for r, (title, key) in enumerate(rows):
            ttk.Label(g, text=title).grid(row=r, column=0, sticky="nw")
            lab = ttk.Label(g, text="-", font=("Consolas", 9), width=34, anchor="w")
            lab.grid(row=r, column=1, sticky="w")
            self.stat_labels[key] = lab
        self.refresh_controls()

    def refresh_controls(self):
        s = self.settings
        self.v_mode.set(s["mode"])
        self.v_ar.set(s["ar43"])
        self.v_gl.set(s["gl"])
        self.v_fm.set(s["fm"])
        self.v_c.set(s["c"])
        self.v_v.set(s["v"])
        self.v_f.set(s["f"])
        self.l_sat.set(f"{s['sat'] / 4:.2f}x")
        self.l_hue.set(f"{(s['hue'] if s['hue'] < 16 else s['hue'] - 32) * 11.25:+.2f}°")
        self.l_first.set(str(s["first"]))
        self.l_act.set(f"{s['act'] / 80:.2f} µs")

    def apply_panel(self):
        if self.panel_var.get() and not self.fullscreen:
            self.panel.pack(side="right", fill="y", before=self.video)
        else:
            self.panel.pack_forget()

    def toggle_fullscreen(self, on=None):
        self.fullscreen = (not self.fullscreen) if on is None else on
        self.root.attributes("-fullscreen", self.fullscreen)
        if self.fullscreen:
            self.bar.pack_forget()
        else:
            self.bar.pack(side="bottom", fill="x", before=self.body)
        self.apply_panel()

    def fill_device_menu(self):
        m = self.dev_menu
        m.delete(0, "end")
        names = list(self.devices)
        if self.device_var.get() and self.device_var.get() not in names:
            names.append(self.device_var.get())
        for name in names:
            m.add_radiobutton(label=name, variable=self.device_var, value=name,
                              command=lambda n=name: self.start_capture(n))
        if not names:
            m.add_command(label="(no video devices found)", state="disabled")
        m.add_separator()
        m.add_command(label="Refresh list", command=self.refresh_devices)

    def refresh_devices(self):
        self.devices = list_video_devices()
        self.fill_device_menu()
        self.log(f"video devices: {', '.join(self.devices) or 'none'}")

    def fill_port_menu(self):
        m = self.port_menu
        m.delete(0, "end")
        auto = find_uart_port()
        m.add_radiobutton(label=f"Auto ({auto or DEFAULT_PORT})", variable=self.port_var, value="auto",
                          command=lambda: self.select_port("auto"))
        m.add_separator()
        for p in list_ports.comports():
            m.add_radiobutton(label=f"{p.device}  {p.description}", variable=self.port_var, value=p.device,
                              command=lambda d=p.device: self.select_port(d))
        m.add_separator()
        m.add_command(label="Refresh list", command=self.fill_port_menu)

    def log(self, msg):
        line = time.strftime("%H:%M:%S ") + msg
        print(line, flush=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    # ---- UART ---------------------------------------------------------------

    def resolve_port(self):
        if self.port_choice == "auto":
            return find_uart_port() or DEFAULT_PORT
        return self.port_choice

    def select_port(self, choice):
        self.port_choice = choice
        self.port_var.set(choice)
        self.drop_serial(f"switching to {choice}")

    def drop_serial(self, why):
        with self.ser_lock:
            if self.ser is not None:
                try:
                    self.ser.close()
                except serial.SerialException:
                    pass
                self.ser = None
                self.log(f"UART {self.port} closed ({why})")

    def serial_watch(self):
        """Open the UART, and reopen it after it went away."""
        last_err = ""
        while self.running:
            if self.ser is None:
                port = self.resolve_port()
                try:
                    ser = serial.Serial(port, 1_000_000, timeout=3)
                    if hasattr(ser, "set_buffer_size"):
                        ser.set_buffer_size(rx_size=1 << 20)
                    with self.ser_lock:
                        self.ser, self.port = ser, port
                    ok = self.read_settings()
                    self.log(f"UART {port} open, settings "
                             f"{'read from the FPGA' if ok else 'tracked (no R reply: older bitstream?)'}")
                    last_err = ""
                except serial.SerialException as e:
                    self.port = port
                    err = str(e).split(":")[0]
                    if err != last_err:
                        self.log(f"UART {port}: not available, retrying")
                        last_err = err
            time.sleep(2)

    def serial_failed(self, e):
        """Called with ser_lock held: forget the port; serial_watch reopens it."""
        self.log(f"UART {self.port} lost: {e}")
        try:
            self.ser.close()
        except Exception:
            pass
        self.ser = None

    def write_keys(self, chars):
        """Send characters; False if the UART is not open."""
        with self.ser_lock:
            if self.ser is None:
                return False
            try:
                self.ser.write(chars.encode())
                return True
            except serial.SerialException as e:
                self.serial_failed(e)
                return False

    def send(self, chars):
        if not self.write_keys(chars):
            self.log(f"not sent {chars!r}: UART not open")
            self.root.after(0, self.refresh_controls)
            return
        s = self.settings
        for ch in chars:
            if ch in "PW":
                s["mode"] = ch
            elif ch == "u":
                s["first"] = max(0, s["first"] - 1)
            elif ch == "d":
                s["first"] = min(60, s["first"] + 1)
            elif ch == "h":
                s["act"] = max(600, s["act"] - 16) if s["act"] > 600 else s["act"]
            elif ch == "l":
                s["act"] = min(1100, s["act"] + 16) if s["act"] < 1100 else s["act"]
            elif ch in "fcv":
                s[ch] ^= 1
            elif ch == "a":
                s["sat"] = min(15, s["sat"] + 1)
            elif ch == "z":
                s["sat"] = max(0, s["sat"] - 1)
            elif ch == "[":
                s["hue"] = (s["hue"] - 1) % 32
            elif ch == "]":
                s["hue"] = (s["hue"] + 1) % 32
            elif ch == "m":
                s["fm"] = (s["fm"] + 1) % 4
            elif ch == "A":
                s["ar43"] ^= 1
            elif ch == "g":
                s["gl"] = GL_ORDER[(GL_ORDER.index(s["gl"]) + 1) % 3]
        self.read_settings()
        self.log(f"sent {chars!r} -> {self.describe()}")
        self.root.after(0, self.refresh_controls)

    def send_async(self, chars):
        if chars:
            threading.Thread(target=self.send, args=(chars,), daemon=True).start()

    def set_genlock(self, target):
        n = (GL_ORDER.index(target) - GL_ORDER.index(self.settings["gl"])) % 3
        self.send_async("g" * n)

    def set_fm(self, target):
        self.send_async("m" * ((target - self.settings["fm"]) % 4))

    def set_toggle(self, key, want, ch):
        if self.settings[key] != want:
            self.send_async(ch)

    def read_settings(self, blocking=True):
        """Read the FPGA's settings ('R'); False if there is no reply (older bitstream)."""
        data = self.request(b"R", 16, blocking)
        if data is None:
            return False
        if len(data) != 16 or data[:4] != b"IQLR" or data[14] != 1:
            self.readback = False
            return False
        new = decode_settings(data)
        changed = new != {k: self.settings[k] for k in new}
        self.settings.update(new)
        self.readback = True
        if changed:
            self.root.after(0, self.refresh_controls)
        return True

    def reset_defaults(self):
        if self.read_settings():
            self.log(f"settings read back -> {self.describe()}")
        else:
            self.settings = dict(DEFAULTS)
            self.log(f"no settings reply; tracked settings reset -> {self.describe()}")
        self.root.after(0, self.refresh_controls)

    def describe(self):
        s = self.settings
        return (f"mode {s['mode']}  first line {s['first']}  start {s['act'] / 80:.2f} us  "
                f"field flip {s['f']}  colour {s['c']}  V inv {s['v']}  sat {s['sat'] / 4:.2f}x  hue {s['hue'] * 11.25:+.1f} deg  "
                f"FM {FM_NAMES[s['fm']]}  {'4:3' if s['ar43'] else '16:9'}  genlock {GL_NAMES[s['gl']]}")

    def request(self, cmd, n, blocking=True):
        """Send one command byte and read n reply bytes (None if busy / closed)."""
        if not self.ser_lock.acquire(blocking=blocking):
            return None
        try:
            if self.ser is None:
                return None
            self.ser.reset_input_buffer()
            self.ser.write(cmd)
            return self.ser.read(n)
        except serial.SerialException as e:
            self.serial_failed(e)
            return None
        finally:
            self.ser_lock.release()

    def read_status(self, blocking=True):
        data = self.request(b"T", 40, blocking)
        if data is None:
            return None
        if len(data) != 40 or data[:4] != b"IQLT":
            return "bad"
        return decode_status(data)

    def status_cmd(self):
        s = self.read_status()
        if s is None:
            self.log("status: UART not open")
        elif s == "bad":
            self.log("status: bad reply")
        else:
            self.stat, self.stat_time = s, time.time()
            self.log("status " + status_line(s))

    def status_poller(self):
        while self.running:
            time.sleep(1.0)
            if self.poll_status and self.ser is not None:
                s = self.read_status(blocking=False)     # skip while a capture holds the UART
                if isinstance(s, dict):
                    self.stat, self.stat_time = s, time.time()
                    self.read_settings(blocking=False)

    def capture(self, mode, path):
        with self.ser_lock:
            if self.ser is None:
                self.log(f"cap {mode}: UART not open")
                return
            try:
                self.ser.reset_input_buffer()
                self.ser.write(mode.encode())
                hdr = self.ser.read(8)
                if len(hdr) != 8 or hdr[:3] != b"IQL":
                    self.log(f"cap {mode}: bad header {hdr!r}")
                    return
                need = struct.unpack("<I", hdr[4:])[0]
                data = bytearray()
                while len(data) < need:
                    chunk = self.ser.read(need - len(data))
                    if not chunk:
                        break
                    data += chunk
            except serial.SerialException as e:
                self.serial_failed(e)
                return
        with open(path, "wb") as f:
            f.write(data)
        self.log(f"cap {mode}: {len(data)} of {need} bytes -> {path}")

    def capture_auto(self, mode):
        self.capture(mode, os.path.join(CAP_DIR, time.strftime(f"la_{mode}_%H%M%S.bin")))

    # ---- capture device -----------------------------------------------------

    def start_capture(self, device, retry=False):
        """(Re)start ffmpeg on a DirectShow video device."""
        if self.ff is not None:
            try:
                self.ff.kill()
            except OSError:
                pass
        self.ff_gen += 1
        self.capture_retry_at = 0.0
        with self.lock:
            self.frame = None
        self.device = device
        self.device_var.set(device)
        if not retry:
            self.status = f"opening {device}"
        try:
            self.ff = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-rtbufsize", "200M",
                 "-f", "dshow", "-i", f"video={device}", "-vf", f"scale={W}:{H}",
                 "-r", "30", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=W * H * 3 * 2)
        except OSError as e:
            self.ff = None
            self.status = f"ffmpeg: {e}"
            return
        threading.Thread(target=self.reader, args=(self.ff, self.ff_gen), daemon=True).start()
        self.root.title(f"C5 FPGA HDMI viewer - {device}")
        if not retry:
            self.log(f"capture device: {device}")

    def reader(self, ff, gen):
        n = W * H * 3
        while self.running and gen == self.ff_gen:
            buf = ff.stdout.read(n)
            if len(buf) < n:
                if gen == self.ff_gen and self.running:
                    if not self.status.startswith("no picture"):
                        self.log(f"capture: no picture from {self.device}, retrying every 3 s")
                    self.status = f"no picture from {self.device}, retrying"
                    with self.lock:
                        self.frame = None
                    self.capture_retry_at = time.time() + 3.0     # redraw() restarts it
                break
            if gen != self.ff_gen:
                break
            with self.lock:
                self.frame = buf
                self.frames += 1
                q = self.rec_q
            if q is not None:
                try:
                    q.put_nowait(buf)
                except queue.Full:        # encoder behind: drop, never stall the capture
                    self.rec_dropped += 1

    # ---- snapshot / recording ----------------------------------------------

    def snapshot(self, path):
        with self.lock:
            frame = self.frame
        if frame:
            write_png(path, frame)
            return True
        return False

    def snapshot_now(self):
        path = os.path.join(CAP_DIR, time.strftime("snap_%H%M%S.png"))
        ok = self.snapshot(path)
        self.log(f"snapshot {path}" if ok else "snapshot: no picture")

    def toggle_rec(self):
        if self.rec is None:
            self.rec_start()
        else:
            self.rec_stop()

    def rec_start(self, path=None):
        if self.rec is not None:
            self.log(f"rec: already recording {self.rec_path}")
            return
        path = path or os.path.join(CAP_DIR, time.strftime("rec_%Y%m%d_%H%M%S.mp4"))
        proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "30", "-i", "-",
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", path],
            stdin=subprocess.PIPE)
        q = queue.Queue(maxsize=30)
        self.rec, self.rec_path, self.rec_frames, self.rec_dropped = proc, path, 0, 0

        def writer():
            while True:
                buf = q.get()
                if buf is None:
                    break
                try:
                    proc.stdin.write(buf)
                    self.rec_frames += 1
                except OSError:
                    self.log("rec: encoder stopped")
                    break
            try:
                proc.stdin.close()
            except OSError:
                pass
            proc.wait()
            self.log(f"rec: saved {path} ({self.rec_frames} frames, {self.rec_frames / 30:.1f} s, "
                     f"{self.rec_dropped} dropped)")

        self.rec_thread = threading.Thread(target=writer, daemon=True)
        self.rec_thread.start()
        with self.lock:
            self.rec_q = q
        self.log(f"rec: recording {path}")

    def rec_stop(self, wait=False):
        if self.rec is None:
            self.log("rec: not recording")
            return
        with self.lock:
            q, self.rec_q = self.rec_q, None
        q.put(None)
        if wait:
            self.rec_thread.join(timeout=30)
        self.rec = None

    # ---- command file -------------------------------------------------------

    def housekeeping(self):
        last_snap = 0
        while self.running:
            now = time.time()
            if now - last_snap >= 1.0:
                last_snap = now
                self.snapshot(os.path.join(CAP_DIR, "live.png"))
            try:
                size = os.path.getsize(CMD_FILE)
                if size > self.cmd_pos:
                    with open(CMD_FILE, encoding="utf-8") as f:
                        f.seek(self.cmd_pos)
                        lines = f.read().splitlines()
                    self.cmd_pos = size
                    for line in lines:
                        self.run_command(line.strip())
                elif size < self.cmd_pos:
                    self.cmd_pos = size
            except OSError as e:
                self.log(f"command file: {e}")
            time.sleep(0.1)

    def run_command(self, line):
        if not line:
            return
        parts = line.split(maxsplit=2)
        try:
            if parts[0] == "key":
                self.send(parts[1])
            elif parts[0] == "cap":
                self.capture(parts[1], os.path.join(ROOT, parts[2]))
            elif parts[0] == "fm":
                n = (int(parts[1]) - self.settings["fm"]) % 4
                if n:
                    self.send("m" * n)
                else:
                    self.log(f"fm already {parts[1]}")
            elif parts[0] == "status":
                self.status_cmd()
            elif parts[0] == "defaults":
                self.reset_defaults()
            elif parts[0] == "rec":
                if parts[1] == "start":
                    self.rec_start(os.path.join(ROOT, parts[2]) if len(parts) > 2 else None)
                else:
                    self.rec_stop()
            elif parts[0] == "device":
                self.root.after(0, self.start_capture, line.split(maxsplit=1)[1])
            elif parts[0] == "port":
                self.root.after(0, self.select_port, parts[1])
            elif parts[0] == "snap":
                ok = self.snapshot(os.path.join(ROOT, parts[1]))
                self.log(f"snap {parts[1]}: {'ok' if ok else 'no frame yet'}")
            else:
                self.log(f"unknown command: {line}")
        except Exception as e:  # keep the viewer running
            self.log(f"command {line!r} failed: {e}")

    # ---- keys and drawing ---------------------------------------------------

    def on_key(self, ev):
        ch = ev.char
        if ch == "q":
            self.quit()
        elif ch == "r":
            self.toggle_rec()
        elif ch == "s":
            self.snapshot_now()
        elif ch and ch in KEYS:
            self.send_async(ch)

    def fit_size(self):
        bw, bh = max(self.video.winfo_width(), 16), max(self.video.winfo_height(), 9)
        if bw * H > bh * W:
            return bh * W // H, bh
        return bw, bw * H // W

    def redraw(self):
        if self.capture_retry_at and time.time() >= self.capture_retry_at:
            self.capture_retry_at = 0.0
            self.start_capture(self.device, retry=True)
        with self.lock:
            frame, frames = self.frame, self.frames
        now = time.time()
        t0, f0 = self.fps_mark
        if now - t0 >= 1.0:
            self.fps = (frames - f0) / (now - t0)
            self.fps_mark = (now, frames)
        if frame is not None:
            if Image is not None:
                img = Image.frombuffer("RGB", (W, H), frame, "raw", "RGB", 0, 1)
                size = self.fit_size()
                if size != (W, H):
                    img = img.resize(size, Image.BILINEAR)
                self.photo = ImageTk.PhotoImage(img)
            else:
                self.photo = tk.PhotoImage(data=f"P6 {W} {H} 255\n".encode() + frame, format="PPM")
            self.video.configure(image=self.photo, text="")
        else:
            self.photo = None
            self.video.configure(image="", text=self.status)
        uart = f"{self.port} open" if self.ser is not None else f"{self.port or '-'} not connected"
        cap = f"{self.device} {self.fps:4.1f} fps" if frame is not None else f"{self.device}: {self.status}"
        rec = f"   REC {self.rec_frames / 30:.0f} s" if self.rec is not None else ""
        src = "from FPGA" if self.readback else "tracked"
        self.bar.configure(text=f" UART {uart}  |  capture {cap}{rec}  |  settings {src}: {self.describe()}")
        self.rec_btn.configure(text="Stop recording (r)" if self.rec is not None else "Record (r)")
        if self.running:
            self.root.after(33, self.redraw)

    def update_status_panel(self):
        s = self.stat
        lab = self.stat_labels
        if s is None or time.time() - self.stat_time > 3.0:
            why = "UART not connected" if self.ser is None else ("polling off" if not self.poll_status else "no reply")
            for k in lab:
                lab[k].configure(text=why if k == "sig" else "-", foreground="gray50")
        else:
            ok = s["real_lines"] > 200 and s["fields"] > 40
            lab["sig"].configure(text=f"{'OK' if ok else 'NO SYNC'}  lines {s['real_lines']}  h {s['h']}/0.8s",
                                 foreground="green4" if ok else "red3")
            lab["fld"].configure(text=f"{s['fields']}/0.8s  synth {s['synth_fields']}  vsync {s['vsync_det']}",
                                 foreground="black")
            lab["lvl"].configure(text=f"tip {s['tip_f']}  black {s['black_f']}  gain {s['gain']}", foreground="black")
            lab["col"].configure(text=f"{'locked' if s['colour_lock'] else 'killed'}  burst {s['burst']}  |R| {s['r_mag']}",
                                 foreground="green4" if s["colour_lock"] else "darkorange3")
            lab["rx"].configure(text=f"{s['channel']}  {s['freq_mhz']} MHz" if s["freq_mhz"] else "no link report",
                                foreground="black" if s["freq_mhz"] else "gray50")
            lab["out"].configure(text=f"pclk {s['pclk_mhz']:.4f} MHz  re-locks {s['out_jumps']}", foreground="black")
            sd_ok = bool(s["sd_pass"])
            lab["sd"].configure(text=f"{'pass' if sd_ok else 'FAIL'}  pos {s['sd_pos']}  ckinv {s['sd_ckinv']}  "
                                     f"ok {s['sd_ok']:08b}",
                                foreground="green4" if sd_ok else "red3")
        if self.running:
            self.root.after(500, self.update_status_panel)

    def quit(self):
        if self.rec is not None:
            self.rec_stop(wait=True)
        self.running = False
        try:
            if self.ff is not None:
                self.ff.kill()
        except OSError:
            pass
        with self.ser_lock:
            if self.ser is not None:
                self.ser.close()
        self.root.destroy()

    def run(self):
        self.log(f"viewer started: {self.describe()}")
        self.root.mainloop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=None,
                    help=f'DirectShow video device (default "{DEFAULT_DEVICE}" if present, else the first)')
    ap.add_argument("--list-devices", action="store_true", help="print the video devices and exit")
    ap.add_argument("--port", default="auto",
                    help=f"FPGA UART port, or auto (the Dock debugger's channel B, else {DEFAULT_PORT})")
    ap.add_argument("--set", default="", help="tracked settings the FPGA already has, e.g. first=14,act=736")
    args = ap.parse_args()
    if args.list_devices:
        for name in list_video_devices():
            print(name)
        return 0
    over = {k: (v if k == "mode" else int(v)) for k, v in (kv.split("=") for kv in args.set.split(",") if kv)}
    Viewer(args.device, args.port, over).run()


if __name__ == "__main__":
    sys.exit(main())
