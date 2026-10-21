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
    """words: (N, 8) uint8. Returns symbols and early/late vote counts.
    Clock-by-clock like the RTL: the detector sees the symbol emitted the
    clock before, and its step lands at the next emit after that."""
    pos, acc, prev_sym = 0, 0, 0
    up = dn = 0
    h1, s1, e1 = False, 0, 0
    prv = np.zeros(8, np.uint8)
    out, early_n, late_n = [], 0, 0
    for w in words:
        buf = np.concatenate([prv, w])
        # detector stage (registered values from the previous clock)
        new_up = new_dn = 0
        if h1:
            moved = s1 != prev_sym
            early = moved and e1 == s1
            late = moved and not early and e1 == prev_sym
            early_n += early
            late_n += late
            acc += -1 if early else (1 if late else 0)
            if acc == 8:
                new_up, acc = 1, 0
            elif acc == -8:
                new_dn, acc = 1, 0
            prev_sym = s1
        # emit stage
        h1 = pos < 512
        if h1:
            s1 = int(buf[8 + (pos >> 6)])
            e1 = int(buf[(pos + 242) >> 6])
            out.append(s1)
            pos = pos + 28 + up - dn
            up, dn = 0, 0
        else:
            pos -= 512
        up |= new_up
        dn |= new_dn
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
