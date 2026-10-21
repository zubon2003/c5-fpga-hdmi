"""Capture and analyse IQ from the FPGA logic analyser.

    py -3.13 scripts/iqla.py capture [--mode C|S] [--port COM4] [--out cap.bin]
    py -3.13 scripts/iqla.py analyse cap.bin [--rate 675e6]

Mode C: raw samples of the 8 IQ pins at 675 MS/s (IDES8, 337.5 MHz DDR).
Mode S: the FPGA resampler's output, one byte per ~80 MHz symbol; check it
        with scripts/demod.py --symbols.
One byte per sample, PARLIO data-bit order: Q on bits 0..3 (bit 3 = sign),
I on 4..7 (bit 7 = sign).
"""
import argparse
import struct
import sys
import time

import numpy as np

SAMPLE_RATE = 675e6
BAUD = 1_000_000


def capture(port, out, mode="C"):
    import serial

    with serial.Serial(port, BAUD, timeout=3) as ser:
        if hasattr(ser, "set_buffer_size"):
            ser.set_buffer_size(rx_size=1 << 20)
        ser.reset_input_buffer()
        ser.write(mode.encode())
        hdr = ser.read(8)
        if len(hdr) != 8 or hdr[:3] != b"IQL" or hdr[3:4] != mode.encode():
            sys.exit(f"bad header: {hdr!r} (bitstream loaded? right port?)")
        need = struct.unpack("<I", hdr[4:])[0]
        t0 = time.time()
        data = bytearray()
        while len(data) < need:
            chunk = ser.read(need - len(data))
            if not chunk:
                sys.exit(f"timeout after {len(data)} of {need} bytes")
            data += chunk
        print(f"{need} bytes in {time.time() - t0:.2f} s")
    with open(out, "wb") as f:
        f.write(data)
    print(f"saved {out}")
    return bytes(data)


def nibble_signed(v):
    # Sign bit + three magnitude-order bits, read as two's complement.
    return np.where(v & 8, v.astype(np.int16) - 16, v.astype(np.int16))


def analyse(data, rate=SAMPLE_RATE):
    global SAMPLE_RATE
    SAMPLE_RATE = rate
    s = np.frombuffer(data, dtype=np.uint8)
    n = len(s)
    print(f"{n} samples, {n / SAMPLE_RATE * 1e6:.1f} us at {SAMPLE_RATE / 1e6:.0f} MS/s")

    names = ["Q0", "Q1", "Q2", "Qs", "I0", "I1", "I2", "Is"]
    print("\nper pin: ones ratio, transitions per us")
    for b in range(8):
        bit = (s >> b) & 1
        tr = np.count_nonzero(np.diff(bit))
        print(f"  bit{b} {names[b]}  ones {bit.mean():5.3f}  {tr / (n / SAMPLE_RATE) / 1e6:7.2f} /us")

    change = np.nonzero(np.diff(s.astype(np.int16)))[0] + 1
    if len(change) < 16:
        print("\nalmost no transitions: nothing connected, or the C5 is not streaming")
        return
    runs = np.diff(change)
    print("\nrun length of an unchanged byte (samples of 3.70 ns): count")
    hist = np.bincount(runs, minlength=16)
    for L in range(1, min(len(hist), 40)):
        if hist[L]:
            print(f"  {L:2d} ({L / SAMPLE_RATE * 1e9:5.1f} ns): {hist[L]}")
    print(f"  single-sample runs (possible skew between pins): {hist[1]} of {len(runs)}")

    # Update clock: phase coherence of the transition times over a period scan.
    t = change.astype(np.float64)
    best = []
    for period_ns in np.arange(5.0, 60.0, 0.01):
        p = period_ns * 1e-9 * SAMPLE_RATE
        c = abs(np.exp(2j * np.pi * t / p).mean())
        best.append((c, period_ns))
    best.sort(reverse=True)
    print("\nupdate-period candidates (coherence, period, rate):")
    shown = []
    for c, per in best:
        if all(abs(per - x) > 0.5 for x in shown):
            shown.append(per)
            print(f"  {c:5.3f}  {per:6.2f} ns  {1e3 / per:6.2f} MHz")
        if len(shown) == 5:
            break

    q = nibble_signed(s & 15)
    i = nibble_signed(s >> 4)
    print("\nQ value histogram (-8..7):", np.bincount(q + 8, minlength=16).tolist())
    print("I value histogram (-8..7):", np.bincount(i + 8, minlength=16).tolist())


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--mode", default="C", choices=["C", "S", "B"])
    c.add_argument("--port", default="COM4")
    c.add_argument("--out", default="cap.bin")
    a = sub.add_parser("analyse")
    a.add_argument("file")
    a.add_argument("--rate", type=float, default=SAMPLE_RATE)
    args = ap.parse_args()
    if args.cmd == "capture":
        data = capture(args.port, args.out, args.mode)
        if args.mode == "C":
            analyse(data)
    else:
        with open(args.file, "rb") as f:
            analyse(f.read(), args.rate)


if __name__ == "__main__":
    main()
