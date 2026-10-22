"""Live viewer for the FPGA's HDMI output through a UVC capture device,
with the FPGA's UART settings on the keyboard.

    py -3.13 scripts/viewer.py [--device "C8 USB3.0 Video"] [--port COM4] [--set first=14,act=736]

Window keys (sent to the FPGA as they are):
    P picture   W waveform monitor
    u / d first active line -/+ 1      h / l picture start -/+ 0.2 us
    f field offset direction           c colour on/off      v V sign
    a / z colour saturation +/- 0.25x  [ / ] hue -/+ 11.25 degrees
    m FM demodulator mode 0..3 (0 adjacent, 1 fast PLL, 2 PLL, 3 slow PLL)
    s save a snapshot now (captures/snap_<time>.png)         q quit
    r start / stop recording a video (captures/rec_<time>.mp4)

The viewer keeps the UART open, so other tools go through it. It saves
captures/live.png once a second and executes lines appended to
captures/viewer_cmd.txt, logging to captures/viewer_log.txt:
    key <chars>            send characters to the FPGA
    cap <C|S|B> <path>     logic-analyser capture (as scripts/iqla.py)
    snap <path>            save the current frame
    rec start [path]       record the picture to an H.264 mp4 (30 fps)
    rec stop               finish the recording
    fm <0..3>              set the FM demodulator mode (from the tracked one)
    defaults               forget the tracked settings (after reprogramming)
    status                 sync separator status (FPGA 'T'), logged
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

import serial

W, H = 1280, 720
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
CAP_DIR = os.path.join(ROOT, "captures")
CMD_FILE = os.path.join(CAP_DIR, "viewer_cmd.txt")
LOG_FILE = os.path.join(CAP_DIR, "viewer_log.txt")
KEYS = "PWudhlfcvaz[]m"
DEFAULTS = {"mode": "P", "first": 16, "act": 752, "f": 1, "c": 1, "v": 1, "sat": 4, "hue": 0, "fm": 1}   # as in src/top.v


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
        self.ser = serial.Serial(port, 1_000_000, timeout=3)
        if hasattr(self.ser, "set_buffer_size"):
            self.ser.set_buffer_size(rx_size=1 << 20)
        open(CMD_FILE, "a").close()
        self.cmd_pos = os.path.getsize(CMD_FILE)

        self.ff = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-rtbufsize", "200M",
             "-f", "dshow", "-i", f"video={device}", "-vf", f"scale={W}:{H}",
             "-r", "30", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdout=subprocess.PIPE, bufsize=W * H * 3 * 2)
        threading.Thread(target=self.reader, daemon=True).start()
        threading.Thread(target=self.housekeeping, daemon=True).start()

        self.root = tk.Tk()
        self.root.title("C5 FPGA HDMI viewer")
        self.label = tk.Label(self.root)
        self.label.pack()
        self.bar = tk.Label(self.root, anchor="w", font=("Consolas", 11))
        self.bar.pack(fill="x")
        self.root.bind("<Key>", self.on_key)
        self.root.protocol("WM_DELETE_WINDOW", self.quit)
        self.photo = None
        self.root.after(30, self.redraw)

    def log(self, msg):
        line = time.strftime("%H:%M:%S ") + msg
        print(line, flush=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def reader(self):
        n = W * H * 3
        while self.running:
            buf = self.ff.stdout.read(n)
            if len(buf) < n:
                self.status = "capture stopped"
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

    def send(self, chars):
        with self.ser_lock:
            self.ser.write(chars.encode())
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
        self.log(f"sent {chars!r} -> {self.describe()}")

    def describe(self):
        s = self.settings
        return (f"mode {s['mode']}  first line {s['first']}  start {s['act'] / 80:.2f} us  "
                f"field flip {s['f']}  colour {s['c']}  V inv {s['v']}  sat {s['sat'] / 4:.2f}x  hue {s['hue'] * 11.25:+.1f} deg  "
                f"FM {('adjacent', 'PLL fast', 'PLL', 'PLL slow')[s['fm']]}")

    def capture(self, mode, path):
        with self.ser_lock:
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
        with open(path, "wb") as f:
            f.write(data)
        self.log(f"cap {mode}: {len(data)} of {need} bytes -> {path}")

    def status_cmd(self):
        with self.ser_lock:
            self.ser.reset_input_buffer()
            self.ser.write(b"T")
            data = self.ser.read(40)
        if len(data) != 40 or data[:4] != b"IQLT":
            self.log(f"status: bad reply {data[:8]!r} ({len(data)} bytes)")
            return
        w = struct.unpack("<16H", data[8:])
        sgn = lambda v: v - 0x4000 if v & 0x2000 else v      # 14-bit signed
        names = ["real_lines", "channel", "par1_fields|lvl_n", "out_jumps", "tip_f", "black_f", "freq_mhz", "vsync_det/0.8s",
                 "gain", "h/0.8s", "synth_fields/0.8s", "fields/0.8s", "burst|B|/16", "nco_off", "|R|", "link_bytes|last"]
        vals = list(w)
        vals[1] = (bytes([vals[1] >> 8, vals[1] & 255]).decode("ascii", "replace")
                   if vals[1] >> 8 else "--")         # receiver link: channel name
        for k in (4, 5):
            vals[k] = sgn(vals[k])
        vals[13] = vals[13] - 0x10000 if vals[13] & 0x8000 else vals[13]
        vals[2] = f"{vals[2] >> 5}|{vals[2] & 31}"
        vals[15] = f"{vals[15] >> 8}|{vals[15] & 255:#04x}"
        vals[12] = f"{vals[12] & 0x7fff} colour={'on' if vals[12] & 0x8000 else 'KILLED'}"
        self.log("status " + " ".join(f"{n}={v}" for n, v in zip(names, vals)))

    def snapshot(self, path):
        with self.lock:
            frame = self.frame
        if frame:
            write_png(path, frame)
            return True
        return False

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
                self.settings = dict(DEFAULTS)
                self.log(f"settings reset -> {self.describe()}")
            elif parts[0] == "rec":
                if parts[1] == "start":
                    self.rec_start(os.path.join(ROOT, parts[2]) if len(parts) > 2 else None)
                else:
                    self.rec_stop()
            elif parts[0] == "snap":
                ok = self.snapshot(os.path.join(ROOT, parts[1]))
                self.log(f"snap {parts[1]}: {'ok' if ok else 'no frame yet'}")
            else:
                self.log(f"unknown command: {line}")
        except Exception as e:  # keep the viewer running
            self.log(f"command {line!r} failed: {e}")

    def on_key(self, ev):
        ch = ev.char
        if ch == "q":
            self.quit()
        elif ch == "r":
            if self.rec is None:
                self.rec_start()
            else:
                self.rec_stop()
        elif ch == "s":
            path = os.path.join(CAP_DIR, time.strftime("snap_%H%M%S.png"))
            self.snapshot(path)
            self.log(f"snapshot {path}")
        elif ch and ch in KEYS:
            threading.Thread(target=self.send, args=(ch,), daemon=True).start()

    def redraw(self):
        with self.lock:
            frame, frames = self.frame, self.frames
        if frame is not None:
            ppm = f"P6 {W} {H} 255\n".encode() + frame
            self.photo = tk.PhotoImage(data=ppm, format="PPM")
            self.label.configure(image=self.photo)
        rec = f"   REC {self.rec_frames / 30:.0f} s" if self.rec is not None else ""
        self.bar.configure(text=f" {self.describe()}   frames {frames}   {self.status if frame is None else ''}{rec}"
                                f"   keys: P W u d h l f c v a z [ ] m  s=snapshot r=record q=quit")
        if self.running:
            self.root.after(33, self.redraw)

    def quit(self):
        if self.rec is not None:
            self.rec_stop(wait=True)
        self.running = False
        try:
            self.ff.kill()
        except OSError:
            pass
        self.ser.close()
        self.root.destroy()

    def run(self):
        self.log(f"viewer started: {self.describe()}")
        self.root.mainloop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="C8 USB3.0 Video")
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--set", default="", help="tracked settings the FPGA already has, e.g. first=14,act=736")
    args = ap.parse_args()
    over = {k: (v if k == "mode" else int(v)) for k, v in (kv.split("=") for kv in args.set.split(",") if kv)}
    Viewer(args.device, args.port, over).run()


if __name__ == "__main__":
    sys.exit(main())
