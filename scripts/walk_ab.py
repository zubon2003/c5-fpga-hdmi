"""Walk test A/B of two FM demodulator modes through scripts/viewer.py.

    py -3.13 scripts/walk_ab.py [--modes 0,2] [--out captures/walk_ab.csv]

Alternates the modes with the viewer's 'fm' command (absolute, from the
mode the viewer tracks, so keys pressed in the viewer window do not
confuse the labels) and per visit logs one CSV row: C/N from an 'S' capture (mode
independent), the sync status after the mode has run for a while (real
lines per field, fields and synthesised fields per 0.8 s, output
re-acquisitions during the visit) and the video SNR from 'B' captures of
the FPGA's own vid output. Neighbouring rows of the two modes see nearly
the same signal. Ctrl-C to stop; leaves the FPGA in mode 1 (power-up).
"""
import argparse
import os
import re
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import ab_demod  # noqa: E402
import demod     # noqa: E402
import measure   # noqa: E402

CAP = measure.CAP


def status():
    t0 = time.strftime("%H:%M:%S")
    measure.send("status")
    time.sleep(0.6)
    st = measure.last_log(r"h/0.8s=", t0)

    def g(name):
        m = re.search(r"(?<![a-z_])" + re.escape(name) + r"=(\d+)", st)
        return int(m.group(1)) if m else -1
    return g("real_lines"), g("fields/0.8s"), g("synth_fields/0.8s"), g("out_jumps")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="0,2")
    ap.add_argument("--out", default=os.path.join(CAP, "walk_ab.csv"))
    ap.add_argument("--caps", type=int, default=3)
    args = ap.parse_args()
    modes = [int(x) for x in args.modes.split(",")]
    new = not os.path.exists(args.out)
    out = open(args.out, "a", encoding="utf-8")
    if new:
        out.write("time,mode,cn_db,real_lines,fields_per_0.8s,synth_per_0.8s,jumps_in_visit,pulses,porch_mhz,snr_db\n")
    print("time      mode  C/N dB  real  fields  synth  jumps  pulses  porch MHz  SNR dB", flush=True)
    sym_path = os.path.join(CAP, "walk_sym.bin")
    b_path = os.path.join(CAP, "walk_b.bin")
    try:
        while True:
            for mode in modes:
                measure.send(f"fm {mode}")
                t0 = time.strftime("%H:%M:%S")
                j0 = status()[3]
                measure.send("cap S captures/walk_sym.bin")
                time.sleep(1.5)
                try:
                    sym = np.frombuffer(open(sym_path, "rb").read(), dtype=np.uint8)
                    cn = measure.cn_m2m4(demod.to_iq(sym))
                except OSError:
                    cn = float("nan")
                pulses = []
                for _ in range(args.caps):
                    measure.send("cap B captures/walk_b.bin")
                    time.sleep(1.6)
                    w = np.frombuffer(open(b_path, "rb").read(), dtype="<u4")
                    pulses += ab_demod.stats((w >> 16).astype(np.uint16).view(np.int16))
                rl, fl, sf, j1 = status()
                if pulses:
                    pr = float(np.median([x[0] for x in pulses]))
                    dp = float(np.median([x[1] for x in pulses]))
                    snr = 20 * np.log10(dp * 2.5 / pr) if pr > 0 else float("inf")
                    pr /= measure.MHZ
                else:
                    pr = snr = float("nan")
                row = (t0, mode, cn, rl, fl, sf, j1 - j0 if j0 >= 0 and j1 >= 0 else -1, len(pulses), pr, snr)
                out.write("%s,%d,%.2f,%d,%d,%d,%d,%d,%.3f,%.2f\n" % row)
                out.flush()
                print("%s  %4d  %6.1f  %4d  %6d  %5d  %5d  %6d  %9.3f  %6.1f" % row, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        measure.send("fm 1")


if __name__ == "__main__":
    main()
