"""Bit-level model of src/fm_demod.v, and the check against a mode B capture.

    py -3.13 scripts/fm_model.py captures/both.bin

Mode B stores, per symbol, the IQ byte and the FPGA's vid output for the
same clock as a 32-bit word: bits 7..0 IQ byte, bits 31..16 vid (signed).
The model recomputes vid from the bytes and reports the best alignment
and the number of mismatching samples.
"""
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
import gen_phase_lut  # noqa: E402

LUT = np.array([gen_phase_lut.phase(b) for b in range(256)], np.int32)


def model(sym):
    ph = LUT[sym]
    d = (np.diff(ph, prepend=0) + 512) % 1024 - 512          # wrap to signed 10 bits
    c = np.cumsum(d)
    vid = c - np.concatenate([np.zeros(16, np.int64), c[:-16]])
    return vid


def main():
    w = np.frombuffer(open(sys.argv[1], "rb").read(), dtype="<u4")
    sym = (w & 0xFF).astype(np.int64)
    vid_hw = (w >> 16).astype(np.uint16).view(np.int16).astype(np.int64)
    vid_m = model(sym)
    best = None
    for lag in range(0, 8):
        a, b = vid_m[32:len(vid_m) - 8], vid_hw[32 + lag:len(vid_hw) - 8 + lag]
        bad = int(np.count_nonzero(a != b))
        if best is None or bad < best[1]:
            best = (lag, bad, len(a))
    lag, bad, n = best
    print(f"{len(w)} symbols; best lag {lag}: {bad} of {n} samples differ")
    print(f"vid range {vid_hw.min()}..{vid_hw.max()} (1 MHz = 204.8)")


if __name__ == "__main__":
    main()
