"""A/B of the FPGA's FM demodulator modes through scripts/viewer.py.

    py -3.13 scripts/ab_demod.py [--rounds 3] [--caps 10]

For each round and mode 0..3 (set with the viewer's 'fm' command): 'B' captures of the FPGA's own vid output, and
from them the back porch noise, sync depth and video SNR as in
scripts/measure.py (porch rms on a 100 IRE scale). Modes are interleaved
so a changing signal affects them alike. Ends in mode 1 (power-up).
"""
import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import measure  # noqa: E402

CAP = measure.CAP
NAMES = ("adjacent", "PLL fast", "PLL", "PLL slow")


def stats(vid):
    vid = vid.astype(float)
    thr = (np.percentile(vid, 2) + np.median(vid)) / 2
    below = vid < thr
    e = np.diff(below.astype(np.int8))
    starts, ends = np.nonzero(e == 1)[0], np.nonzero(e == -1)[0]
    out = []
    for a in starts:
        b = ends[ends > a]
        if not len(b) or not (240 <= b[0] - a < 640) or b[0] + 168 >= len(vid):
            continue
        b = b[0]
        p = vid[b + 40:b + 168]
        out.append((p.std(), p.mean() - vid[a + 40:b - 40].mean()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--caps", type=int, default=10)
    args = ap.parse_args()
    res = {m: [] for m in range(4)}
    path = os.path.join(CAP, "ab_b.bin")
    for r in range(args.rounds):
        for mode in (0, 1, 2, 3):
            measure.send(f"fm {mode}")
            time.sleep(0.5)
            for _ in range(args.caps):
                measure.send("cap B captures/ab_b.bin")
                time.sleep(1.6)                   # 16 KiB at ~16 kB/s
                w = np.frombuffer(open(path, "rb").read(), dtype="<u4")
                vid = (w >> 16).astype(np.uint16).view(np.int16)
                res[mode] += stats(vid)
        print(f"round {r + 1} done", flush=True)
    measure.send("fm 1")
    print("mode  name       pulses  porch MHz  sync MHz  SNR dB")
    for m in range(4):
        if not res[m]:
            print(f"{m}     {NAMES[m]:<9}  no sync pulses")
            continue
        pr = float(np.median([x[0] for x in res[m]]))
        dp = float(np.median([x[1] for x in res[m]]))
        snr = 20 * np.log10(dp * 2.5 / pr) if pr > 0 else float("inf")
        print(f"{m}     {NAMES[m]:<9}  {len(res[m]):6d}  {pr / measure.MHZ:9.3f}  {dp / measure.MHZ:8.2f}  {snr:6.1f}")


if __name__ == "__main__":
    main()
