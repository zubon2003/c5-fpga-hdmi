"""Signal-quality log through scripts/viewer.py (which owns the UART).

    py -3.13 scripts/measure.py [--interval 3] [--count 0] [--out captures/measure.csv]

Every interval: an 'S' capture (resampler symbols, ~205 us) and a status
packet. From the symbols:
  cn_db     carrier-to-noise estimate from the IQ envelope moments (M2M4;
            4-bit IQ makes it optimistic at high C/N and coarse below ~3 dB)
  porch_mhz rms of the demodulated video on the back porch (0.5..2.1 us
            after each sync), in MHz of deviation: the picture noise floor
  sync_mhz  sync depth (porch - tip), MHz
  snr_db    20 log10(sync depth * 2.5 / porch rms): video SNR on a
            100 IRE white scale
From the status: real H lines per field, fields per 0.8 s and the colour
killer state (1 colour on, 0 killed).
One CSV line per measurement, also printed.
"""
import argparse
import os
import re
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import fm_model  # noqa: E402
import demod     # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
CAP = os.path.join(ROOT, "captures")
CMD = os.path.join(CAP, "viewer_cmd.txt")
LOG = os.path.join(CAP, "viewer_log.txt")
MHZ = 1024 * fm_model.N / 80.0          # vid units per MHz


def send(line):
    with open(CMD, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def last_log(pattern, after):
    for line in reversed(open(LOG, encoding="utf-8").read().splitlines()):
        if line[:8] >= after and re.search(pattern, line):
            return line
    return ""


def cn_m2m4(z):
    p = np.abs(z - z.mean()) ** 2
    m2, m4 = p.mean(), (p * p).mean()
    s = 2 * m2 * m2 - m4
    if s <= 0:
        return float("nan")
    s = np.sqrt(s)
    n = m2 - s
    return 10 * np.log10(s / n) if n > 0 else float("inf")


def video_stats(sym):
    vid = fm_model.model(sym.astype(np.int64)).astype(float)
    thr = (np.percentile(vid, 2) + np.median(vid)) / 2
    below = vid < thr
    e = np.diff(below.astype(np.int8))
    starts, ends = np.nonzero(e == 1)[0], np.nonzero(e == -1)[0]
    porch, depth = [], []
    for a in starts:
        b = ends[ends > a]
        if not len(b) or not (240 <= b[0] - a < 640):
            continue
        b = b[0]
        if b + 168 >= len(vid):
            continue
        p = vid[b + 40:b + 168]
        tip = vid[a + 40:b - 40].mean()
        porch.append(p.std())
        depth.append(p.mean() - tip)
    if not porch:
        return float("nan"), float("nan"), float("nan"), 0
    pr, dp = float(np.median(porch)), float(np.median(depth))
    snr = 20 * np.log10(dp * 2.5 / pr) if pr > 0 else float("inf")
    return pr / MHZ, dp / MHZ, snr, len(porch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--count", type=int, default=0, help="0 = until Ctrl-C")
    ap.add_argument("--out", default=os.path.join(CAP, "measure.csv"))
    args = ap.parse_args()
    new = not os.path.exists(args.out)
    out = open(args.out, "a", encoding="utf-8")
    if new:
        out.write("time,cn_db,porch_mhz,sync_mhz,snr_db,lines_seen,real_lines,"
                  "fields_per_0.8s,synth_fields_per_0.8s,out_jumps,vsync_det_per_0.8s,colour\n")
    print("time      C/N dB  porch MHz  sync MHz  SNR dB  real lines  fields  synth  jumps  vdet  colour", flush=True)
    n = 0
    while args.count == 0 or n < args.count:
        t0 = time.strftime("%H:%M:%S")
        path = os.path.join(CAP, "measure_sym.bin")
        send("cap S captures/measure_sym.bin")
        time.sleep(2.0)                       # 16 KiB at ~16 kB/s
        send("status")
        time.sleep(0.6)
        st = last_log(r"h/0.8s=", t0)
        rl = re.search(r"real_lines=(\d+)", st)
        fl = re.search(r" fields/0.8s=(\d+)", st)
        sf = re.search(r"synth_fields/0.8s=(\d+)", st)
        oj = re.search(r"out_jumps=(\d+)", st)
        vd = re.search(r"vsync_det/0.8s=(\d+)", st)
        co = re.search(r"colour=(\w+)", st)
        col = (1 if co.group(1) == "on" else 0) if co else -1
        try:
            sym = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
            cn = cn_m2m4(demod.to_iq(sym))
            porch, depth, snr, seen = video_stats(sym)
        except OSError:
            cn = porch = depth = snr = float("nan"); seen = 0
        def g(m):
            return int(m.group(1)) if m else -1
        row = (t0, cn, porch, depth, snr, seen, g(rl), g(fl), g(sf), g(oj), g(vd), col)
        out.write("%s,%.2f,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%d,%d\n" % row)
        out.flush()
        print("%s  %6.1f  %9.3f  %8.2f  %6.1f  %10d  %6d  %5d  %5d  %5d  %6d"
              % (row[0], row[1], row[2], row[3], row[4], row[6], row[7], row[8], row[9], row[10], row[11]), flush=True)
        n += 1
        time.sleep(max(0.0, args.interval - 2.6))


if __name__ == "__main__":
    main()
