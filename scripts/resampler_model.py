"""Bit-level model of src/iq_resampler.v.

    py -3.13 scripts/resampler_model.py captures/c5_vtx.bin

Feeds the model with 675 MS/s windows made from a 270 MS/s capture
(nearest sample, so edges are only as sharp as the 270 MS/s data), then
FM-demodulates the symbols with scripts/demod.py and reports sync spacing.
"""
import sys

import numpy as np

import demod


def resampler(words):
    """words: (N, 8) uint8. Returns symbols and early/late vote counts."""
    pos, acc, prev_sym, pending = 0, 0, 0, 0
    prv = np.zeros(8, np.uint8)
    out, early_n, late_n = [], 0, 0
    for w in words:
        buf = np.concatenate([prv, w])
        if pos < 512:
            s = int(buf[8 + (pos >> 6)])
            e = int(buf[(pos + 242) >> 6])
            moved = s != prev_sym
            early = moved and e == s
            late = moved and not early and e == prev_sym
            acc += -1 if early else (1 if late else 0)
            early_n += early
            late_n += late
            corr = 0
            if acc == 8:
                corr, acc = 1, 0
            elif acc == -8:
                corr, acc = -1, 0
            out.append(s)
            prev_sym = s
            pos = pos + 28 + pending     # the step lands one symbol later
            pending = corr
        else:
            pos -= 512
        prv = w
    return np.array(out, np.uint8), early_n, late_n


def main():
    s270 = demod.load(sys.argv[1])
    n675 = int(len(s270) * 2.5) // 8 * 8
    s675 = s270[np.minimum((np.arange(n675) * 0.4).astype(int), len(s270) - 1)]
    sym, early_n, late_n = resampler(s675.reshape(-1, 8))
    dur = n675 / 675e6
    print(f"{len(sym)} symbols in {dur * 1e6:.1f} us = {len(sym) / dur / 1e6:.4f} MS/s, "
          f"votes early {early_n} late {late_n}")
    q = (sym & 15).astype(np.int16)
    i = (sym >> 4).astype(np.int16)
    z = (np.where(i & 8, i - 16, i) + 0.5) + 1j * (np.where(q & 8, q - 16, q) + 0.5)
    v = demod.fm(z)
    print(f"|z| mean {abs(z).mean():.2f} std {abs(z).std():.2f}")
    thr = (np.percentile(v, 2) + np.median(v)) / 2
    e = np.diff((v < thr).astype(np.int8))
    starts = np.nonzero(e == 1)[0]
    ends = np.nonzero(e == -1)[0]
    pulses = [a for a in starts for b in ends[ends > a][:1] if (b - a) / 80 > 3]
    print("sync spacing us:", np.round(np.diff(pulses) / 80, 2).tolist())


if __name__ == "__main__":
    main()
