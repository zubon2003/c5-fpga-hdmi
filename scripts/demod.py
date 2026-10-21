"""Resample a logic-analyser capture to 80 MS/s and FM-demodulate it.

    py -3.13 scripts/demod.py captures/c5_vtx.bin [out.png]            270 MS/s raw
    py -3.13 scripts/demod.py --symbols captures/sym.bin [out.png]     FPGA symbols

For a raw capture this picks one fixed sampling phase over the whole capture
(243 us is short against the ~0.4 ms slip from the ~30 ppm clock offset).
With --symbols the bytes are already one per symbol (iqla.py mode S).
"""
import struct
import sys
import zlib

import numpy as np

FS = 270e6


def load(path):
    return np.frombuffer(open(path, "rb").read(), dtype=np.uint8)


def symbol_period(s):
    ch = np.nonzero(np.diff(s.astype(np.int16)))[0] + 1
    best = max((abs(np.exp(2j * np.pi * ch / p).mean()), p)
               for p in np.linspace(3.37, 3.38, 2001))
    p = best[1]
    edge = np.angle(np.exp(2j * np.pi * ch / p).mean()) % (2 * np.pi) / (2 * np.pi) * p
    return p, edge


def resample(s, p, edge):
    # Sample half a symbol away from the mean transition time.
    start = (edge + p / 2) % p
    idx = np.round(start + np.arange(int((len(s) - 2 - start) / p)) * p).astype(int)
    v = s[idx]
    return to_iq(v)


def fm(z, rate=80e6, lp_mhz=5.0):
    d = np.angle(z[1:] * np.conj(z[:-1])) * rate / (2 * np.pi) / 1e6   # MHz
    taps = int(rate / 1e6 / lp_mhz)          # boxcar, first null at lp_mhz
    return np.convolve(d, np.ones(taps) / taps, mode="same")


def write_png(path, v, w=1600, h=360):
    """Waveform plot without matplotlib: per pixel column the min..max of
    its samples, 10 us grid lines, a 0 MHz line."""
    img = np.full((h, w, 3), 255, np.uint8)
    lo, hi = np.percentile(v, 0.2) - 0.5, np.percentile(v, 99.8) + 0.5

    def ys(x):
        return np.clip(((hi - np.asarray(x)) / (hi - lo) * (h - 1)).astype(int), 0, h - 1)

    per = len(v) / w
    for us in range(0, int(len(v) / 80) + 1, 10):
        img[:, min(w - 1, int(us * 80 / per))] = (225, 225, 225)
    img[ys(0.0), :] = (200, 200, 200)
    for x in range(w):
        a0 = int(x * per)
        seg = v[a0:max(int((x + 1) * per), a0 + 1)]
        top, bot = ys([seg.max(), seg.min()])
        img[top:bot + 1, x] = (20, 90, 160)
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9))
                + chunk(b"IEND", b""))


def to_iq(v):
    q = (v & 15).astype(np.int16)
    i = (v >> 4).astype(np.int16)
    return (np.where(i & 8, i - 16, i) + 0.5) + 1j * (np.where(q & 8, q - 16, q) + 0.5)


def main():
    args = sys.argv[1:]
    symbols = args[0] == "--symbols"
    if symbols:
        args = args[1:]
    s = load(args[0])
    if symbols:
        z = to_iq(s)
        print(f"{len(z)} symbols, |z| mean {abs(z).mean():.2f} std {abs(z).std():.2f}")
    else:
        p, edge = symbol_period(s)
        z = resample(s, p, edge)
        print(f"{len(z)} symbols at {FS / p / 1e6:.4f} MHz, |z| mean {abs(z).mean():.2f} std {abs(z).std():.2f}")
    v = fm(z)
    print(f"demod MHz: p1 {np.percentile(v, 1):.2f}  p50 {np.median(v):.2f}  p99 {np.percentile(v, 99):.2f}")

    # Sync tips: the extreme level held for > 3 us.
    lo, hi = np.percentile(v, 2), np.percentile(v, 98)
    for name, level, cmp in (("low", lo, np.less), ("high", hi, np.greater)):
        thr = (level + np.median(v)) / 2
        e = np.diff(cmp(v, thr).astype(np.int8))
        starts, ends = np.nonzero(e == 1)[0], np.nonzero(e == -1)[0]
        pulses = [(a, b) for a in starts for b in ends[ends > a][:1] if (b - a) / 80 > 3]
        print(f"{name}-side pulses > 3 us (start, width):",
              [(round(a / 80, 2), round((b - a) / 80, 2)) for a, b in pulses])
        if len(pulses) > 1:
            print("  spacing us:", np.round(np.diff([a for a, _ in pulses]) / 80, 2).tolist())

    if len(args) > 1:
        write_png(args[1], v)
        print("saved", args[1])


if __name__ == "__main__":
    main()
