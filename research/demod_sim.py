"""FM demodulator study for the FPGA receiver (host simulation).

    py -3.13 research/demod_sim.py [--dev 0.78] [--filter 10] [--seeds 2]

Signal and channel follow the C5VRX-5 range simulator
(research/sim.py of C5VRX by Twotoz and the C5VRX contributors,
https://github.com/Twotoz/C5VRX): blanking at the -1.0 MHz AFC porch
target, 6.7 MHz sync-to-white at deviation 1.0, the C5 analog channel
(5th-order Butterworth, ~20 MHz complex) with C/N measured in it, an
optional narrower 4th-order filter (the C5VRX-5 receive profile), gain to
rms radius 4.2 and 4-bit quantisation. Differences here: NTSC lines only
(no vertical interval), and the FPGA's ~80 MS/s IQ is kept at 80 MS/s.

Every demodulator gives a phase step per sample that goes through the
same 22-sample boxcar as src/fm_demod.v; the luma SINAD is measured
against the noise-free source through that boxcar (least-squares lag,
gain and offset, picture region only). Synthetic numbers, not measured
range: 1 dB of C/N is 1.12x the free-space distance.

--p64 <C5VRX>/main/p64_tables.h adds the C5's own demodulator, U80P64-R1
(C5VRX-5 v5.0.523, read from that checkout, not copied here): one update
per pair of 40 MS/s samples (every 4th symbol here), token = the 16-sector
phase of the pair's first sample (the table's bits 12..15 at the IQ
address), then code and next state from the (state, token) word; codes
0..63 span -6..+9 MHz. Its 20 MS/s codes are held for 4 symbols and go
through the same boxcar.
"""
import argparse
import os
import re
import sys

import numpy as np
from numba import njit
from scipy import signal as sg

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import gen_phase_lut  # noqa: E402

F = 80e6
DEV_PP = 6.7e6
PORCH_HZ = -1.0e6
LINE = 5084.44                      # NTSC line at 80 MHz
FSC = 3579545.4545
N_BOX = 22
CHAN = sg.butter(5, 10e6, fs=F, output="sos")
LUT10 = np.array([gen_phase_lut.phase(b) for b in range(256)], np.int64)
LUT = LUT10.astype(np.float64) * (2 * np.pi / 1024)


def raster(seed, lines=120):
    """NTSC lines: sync, burst, textured picture with colour. Returns IRE
    at 80 MS/s and a region mask (1 picture, 2 sync, 3 burst)."""
    rng = np.random.default_rng(seed)
    n = int(LINE * lines)
    ire = np.zeros(n)
    region = np.zeros(n, np.uint8)
    for k in range(lines):
        s = int(round(k * LINE))
        e = int(round((k + 1) * LINE))
        ire[s:s + 376] = -40
        region[s:s + 376] = 2
        bs = s + 424
        t = np.arange(bs, bs + 200) / F
        ire[bs:bs + 200] = 20 * np.sin(2 * np.pi * FSC * t + np.pi)
        region[bs:bs + 200] = 3
        a, b = s + 872, e - 120
        x = np.arange(b - a)
        knots = np.arange(0, len(x) + 16, 16)
        pic = np.interp(x, knots, rng.uniform(7.5, 100, len(knots)))
        pic += 10 * np.sin(2 * np.pi * FSC * (x + a) / F + rng.uniform(0, 2 * np.pi))
        ire[a:b] = pic
        region[a:b] = 1
    return sg.lfilter(sg.firwin(81, 4.5e6, fs=F), 1, ire), region


def make_case(seed, cnr_db, dev, filter_mhz, rms=4.2, offset_hz=0.0):
    rng = np.random.default_rng(seed)
    ire, region = raster(seed + 7)
    freq = PORCH_HZ + offset_hz + dev * ire / 140 * DEV_PP
    z = sg.sosfilt(CHAN, np.exp(2j * np.pi * np.cumsum(freq) / F))
    z /= np.sqrt(np.mean(abs(z) ** 2))
    nz = sg.sosfilt(CHAN, (rng.normal(size=len(z)) + 1j * rng.normal(size=len(z))) / np.sqrt(2))
    nz /= np.sqrt(np.mean(abs(nz) ** 2))
    r = 10 ** (cnr_db / 10)
    y = (z * np.sqrt(r) + nz) / np.sqrt(1 + r)
    if filter_mhz:
        y = sg.sosfilt(sg.butter(4, filter_mhz * 1e6 / 2, fs=F, output="sos"), y)
    y *= rms / np.sqrt(np.mean(abs(y) ** 2))
    i = np.clip(np.floor(y.real), -8, 7).astype(np.int64)
    q = np.clip(np.floor(y.imag), -8, 7).astype(np.int64)
    sym = (((i & 15) << 4) | (q & 15)).astype(np.int64)
    return sym, ire, region


def cells(sym):
    """Phase (rad, from the FPGA LUT) and squared radius of the cell centre."""
    q = sym & 15
    i = sym >> 4
    fi = np.where(i & 8, i - 16, i) + 0.5
    fq = np.where(q & 8, q - 16, q) + 0.5
    return LUT[sym], fi * fi + fq * fq


@njit(cache=True)
def wrap(x):
    return (x + np.pi) % (2 * np.pi) - np.pi


@njit(cache=True)
def d_adjacent(ph):
    out = np.zeros(len(ph))
    for n in range(1, len(ph)):
        out[n] = wrap(ph[n] - ph[n - 1])
    return out


@njit(cache=True)
def d_weighted(ph, p2, norm_mode):
    """Amplitude-weighted phase step over the boxcar: weight |z_n||z_n-1|.
    norm_mode 0: exact division by the boxcar weight sum; 1: by a slow
    average of the weight (no per-sample divide)."""
    n = len(ph)
    w = np.zeros(n)
    wd = np.zeros(n)
    for k in range(1, n):
        w[k] = np.sqrt(p2[k] * p2[k - 1])
        wd[k] = w[k] * wrap(ph[k] - ph[k - 1])
    out = np.zeros(n)
    sw = 0.0
    swd = 0.0
    avg = 0.0
    for k in range(n):
        sw += w[k]
        swd += wd[k]
        if k >= N_BOX:
            sw -= w[k - N_BOX]
            swd -= wd[k - N_BOX]
        avg += (w[k] - avg) / 4096.0
        if norm_mode == 0:
            out[k] = swd / sw if sw > 0 else 0.0
        else:
            out[k] = swd / (N_BOX * avg) if avg > 0 else 0.0
    return out


@njit(cache=True)
def d_tracker(ph, p2, kp, ki, amp):
    """Phase tracker: theta follows the measured phase. ki = 0 is the
    first-order (U85Q-like) tracker, ki > 0 a second-order PLL that also
    tracks the frequency. amp: scale the correction by min(1, |z|^2 / mean)
    so samples near the origin barely move the loop. Output: the phase
    step per sample (theta_n - theta_n-1)."""
    n = len(ph)
    out = np.zeros(n)
    th = ph[0]
    om = 0.0
    avg = 1.0
    for k in range(1, n):
        avg += (p2[k] - avg) / 4096.0
        g = 1.0
        if amp:
            g = p2[k] / avg
            if g > 1.0:
                g = 1.0
        pred = th + om
        e = wrap(ph[k] - pred)
        step = om + g * kp * e
        om += g * ki * e
        th = wrap(pred + g * kp * e)
        out[k] = step
    return out


@njit(cache=True)
def d_pll_fixed(sym_ph, p2, kp_sh, kp_add, ki_sh):
    """FPGA-style integer version of plla: phase from the 10-bit LUT,
    theta and omega with 6 fraction bits (65536 per turn), the correction
    gain g quantised to eighths from |z|^2 against a slow average (time
    constant 4096), kp = 2^-kp_sh (+ 2^-kp_add if kp_add > 0),
    ki = 2^-ki_sh. Output: phase step in radians."""
    n = len(sym_ph)
    out = np.zeros(n)
    th = sym_ph[0] << 6
    om = 0
    avg = 64 << 12                       # mean of 4 |z|^2, times 4096
    for k in range(1, n):
        p = int(p2[k] * 4)               # 4 |z|^2 of the cell centre (integer)
        avg += p - (avg >> 12)
        mean = avg >> 12
        g8 = 8
        if mean > 0:
            g8 = min(8, (p * 8) // mean)
        pred = th + om
        e = ((sym_ph[k] << 6) - pred + 32768) % 65536 - 32768
        ge = (e * g8) >> 3
        corr = ge >> kp_sh
        if kp_add > 0:
            corr += ge >> kp_add
        step = om + corr
        om += ge >> ki_sh
        th = (pred + corr) % 65536
        out[k] = step * (2 * np.pi / 65536)
    return out


@njit(cache=True)
def d_pll_fixed_delay(sym_ph, p2, kp_sh, kp_add, ki_sh, delay, pow2=0):
    """d_pll_fixed with the correction applied `delay` samples late (a
    pipelined FPGA loop: the error of sample n moves theta and omega only
    from sample n + delay on). The gain eighths come from thresholds k *
    mean (no divide), as in the HDL."""
    n = len(sym_ph)
    out = np.zeros(n)
    th = sym_ph[0] << 6
    om = 0
    avg = 64 << 12
    pc = np.zeros(delay + 1, np.int64)       # pending corrections
    pi = np.zeros(delay + 1, np.int64)
    for k in range(1, n):
        p = int(p2[k] * 4)
        avg += p - (avg >> 12)
        mean = avg >> 12
        g8 = 0
        if pow2 == 1:                        # g in {0, 1/4, 1/2, 1}: a shift mux
            if p >= mean:
                g8 = 8
            elif 2 * p >= mean:
                g8 = 4
            elif 4 * p >= mean:
                g8 = 2
        elif pow2 == 2:                      # g in {0, 1/4, 1/2, 3/4, 1}
            if p >= mean:
                g8 = 8
            elif 4 * p >= 3 * mean:
                g8 = 6
            elif 2 * p >= mean:
                g8 = 4
            elif 4 * p >= mean:
                g8 = 2
        else:
            for j in range(1, 9):
                if 8 * p >= j * mean:
                    g8 = j
        # apply the correction that is due now
        c_now = pc[0]
        i_now = pi[0]
        for j in range(delay):
            pc[j] = pc[j + 1]
            pi[j] = pi[j + 1]
        th = (th + om + c_now) % 65536
        om += i_now
        out[k] = (om - i_now) + c_now        # phase step this sample
        e = ((sym_ph[k] << 6) - th + 32768) % 65536 - 32768
        ge = (e * g8) >> 3
        corr = ge >> kp_sh
        if kp_add > 0:
            corr += ge >> kp_add
        pc[delay] = corr
        pi[delay] = ge >> ki_sh
        if delay == 0:
            th = (th + corr) % 65536
            om += pi[0]
            out[k] += corr
            pc[0] = 0
            pi[0] = 0
    return out * (2 * np.pi / 65536)


def load_p64(path):
    """The 1024-word U80P64-R1 table from C5VRX's main/p64_tables.h."""
    text = open(path, encoding="utf-8").read().split("p64_table[1024] = {", 1)[1].split("}", 1)[0]
    lut = np.array([int(v, 16) for v in re.findall(r"0x[0-9a-fA-F]+", text)], np.int64)
    assert len(lut) == 1024, path
    return lut


@njit(cache=True)
def d_p64(sym, lut):
    lo = 2 * np.pi * -6.0e6 / F
    span = 2 * np.pi * 15.0e6 / F
    out = np.zeros(len(sym))
    s = 0
    for n in range(0, len(sym) - 3, 4):
        b = sym[n]
        tok = (lut[(b >> 4) | ((b & 15) << 4)] >> 12) & 15
        w = lut[(s << 4) | tok]
        s = (w >> 6) & 63
        d = lo + (w & 63) * span / 63
        for k in range(4):
            out[n + k] = d
    return out


@njit(cache=True)
def iir(d, kp):
    """One-pole low-pass y += kp (x - y): what a first-order tracker is
    when the phase never wraps (linear reference for trk1)."""
    out = np.zeros(len(d))
    y = 0.0
    for k in range(len(d)):
        y += kp * (d[k] - y)
        out[k] = y
    return out


def boxcar(d):
    c = np.cumsum(d)
    return c - np.concatenate([np.zeros(N_BOX), c[:-N_BOX]])


def sinad(vid, ire, region, burn=6000):
    """Luma SINAD in dB against the noise-free source through the boxcar."""
    truth = boxcar(ire)
    m = region == 1
    m[:burn] = False
    m[-burn:] = False
    best = None
    for lag in range(-60, 61, 2):
        a = np.roll(vid, -lag)[m][::7]
        t = truth[m][::7]
        A = np.c_[a, np.ones(len(a))]
        coef, res, *_ = np.linalg.lstsq(A, t, rcond=None)
        err = np.mean((A @ coef - t) ** 2)
        if best is None or err < best[0]:
            best = (err, lag)
    lag = best[1]
    a = np.roll(vid, -lag)[m]
    t = truth[m]
    A = np.c_[a, np.ones(len(a))]
    coef = np.linalg.lstsq(A, t, rcond=None)[0]
    err = np.mean((A @ coef - t) ** 2)
    return 10 * np.log10(np.var(t) / err)


def demods(full=False, p64=None):
    """Candidates; each takes c = (phase rad, |z|^2, 10-bit phase, symbol)."""
    out = {"current": lambda c: d_adjacent(c[0]),
           "lin 0.5": lambda c: iir(d_adjacent(c[0]), 0.5)}
    if full:
        out["wavg"] = lambda c: d_weighted(c[0], c[1], 0)
        out["wnorm"] = lambda c: d_weighted(c[0], c[1], 1)
        for kp in (0.85, 0.6, 0.5, 0.35):
            out[f"trk1 {kp}"] = (lambda kp: lambda c: d_tracker(c[0], c[1], kp, 0.0, False))(kp)
    for kp in (0.6, 0.5, 0.35):
        out[f"trk1a {kp}"] = (lambda kp: lambda c: d_tracker(c[0], c[1], kp, 0.0, True))(kp)
    for kp, ki in ((0.5, 0.08), (0.35, 0.04), (0.25, 0.02), (0.18, 0.01), (0.12, 0.005)):
        if full or kp == 0.25:
            out[f"pll {kp}/{ki}"] = (lambda kp, ki: lambda c: d_tracker(c[0], c[1], kp, ki, False))(kp, ki)
        out[f"plla {kp}/{ki}"] = (lambda kp, ki: lambda c: d_tracker(c[0], c[1], kp, ki, True))(kp, ki)
    # integer versions (shift gains)
    out["fix 1/4,1/64"] = lambda c: d_pll_fixed(c[2], c[1], 2, 0, 6)
    out["fix 3/8,1/32"] = lambda c: d_pll_fixed(c[2], c[1], 2, 3, 5)
    out["fix 1/8,1/128"] = lambda c: d_pll_fixed(c[2], c[1], 3, 0, 7)
    if p64 is not None:
        out["C5 U80P64-R1"] = lambda c: d_p64(c[3], p64)
    return out


@njit(cache=True)
def slicer(y, thr, db=24):
    """The FPGA's pulse slicer (src/video_in.v): a crossing counts after db
    samples on the other side. Returns fall times and widths of pulses."""
    below = False
    other = 0
    falls = np.zeros(len(y) // db + 1, np.int64)
    widths = np.zeros(len(y) // db + 1, np.int64)
    m = 0
    t_fall = 0
    for t in range(len(y)):
        yb = y[t] < thr
        cross = (not yb) if below else yb
        other = other + 1 if cross else 0
        if cross and other == db:
            other = 0
            below = not below
            if below:
                t_fall = t - db + 1
            else:
                falls[m] = t_fall
                widths[m] = t - db + 1 - t_fall
                m += 1
    return falls[:m], widths[:m]


def sync_stats(vid, ire, region, burn=6000):
    """H sync on the demodulated video with the FPGA slicer (threshold half
    way between the median sync tip and blank levels): fraction of lines
    with a H pulse (240..640 samples) whose falling edge is within +-200
    samples of the noise-free one, and the rms edge error of those."""
    truth = boxcar(ire)
    # Level windows in the delayed signal (source FIR 40 + boxcar 22):
    # sync tip s+70..s+400, front porch blank s-40..s+30 (s = region start).
    sync = np.zeros(len(region), bool)
    blank = np.zeros(len(region), bool)
    for s in np.nonzero(np.diff((region == 2).astype(np.int8)) == 1)[0] + 1:
        sync[s + 70:s + 400] = True
        blank[max(s - 40, 0):s + 30] = True

    def thr(y):
        return (np.median(y[sync]) + np.median(y[blank])) / 2
    rf, rw = slicer(truth, thr(truth))
    ref = rf[(rw >= 240) & (rw < 640) & (rf > burn) & (rf < len(truth) - burn)]
    if np.median(vid[sync]) > np.median(vid[blank]):   # the LUT's phase sense
        vid = -vid
    f, w = slicer(vid, thr(vid))
    f = f[(w >= 240) & (w < 640)]
    errs = []
    for r in ref:
        near = f[np.abs(f - r) <= 200]
        if len(near):
            errs.append(near[np.argmin(np.abs(near - r))] - r)
    if not errs:
        return 0.0, 200.0
    errs = np.array(errs, float)
    return len(errs) / len(ref), float(np.std(errs))


def threshold(cnrs, vals, level):
    """Lowest C/N from which SINAD stays >= level (linear interpolation)."""
    vals = np.asarray(vals)
    cnrs, vals = cnrs[:-1], vals[:-1]             # without the 40 dB column
    above = vals >= level
    if above.all():
        return cnrs[0]
    if not above[-1]:
        return float("nan")
    k = len(vals) - 1
    while k > 0 and above[k - 1]:
        k -= 1
    c0, c1, v0, v1 = cnrs[k - 1], cnrs[k], vals[k - 1], vals[k]
    return c0 + (level - v0) * (c1 - c0) / (v1 - v0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", type=float, default=0.78)
    ap.add_argument("--filter", type=float, default=10.0, help="MHz, 0 = C5 channel only")
    ap.add_argument("--seeds", type=int, default=2)
    ap.add_argument("--cnr", default="-4:21:1")
    ap.add_argument("--offset", type=float, default=0.0, help="residual AFC error, MHz")
    ap.add_argument("--full", action="store_true", help="also the rejected candidates")
    ap.add_argument("--p64", help="C5VRX main/p64_tables.h: also the C5's U80P64-R1")
    args = ap.parse_args()
    a, b, s = (float(x) for x in args.cnr.split(":"))
    cnrs = np.append(np.arange(a, b, s), 40.0)    # 40 dB: sharpness (distortion floor)
    ds = demods(args.full, load_p64(args.p64) if args.p64 else None)
    table = {name: [] for name in ds}
    hits = {name: [] for name in ds}
    jit = {name: [] for name in ds}
    for c in cnrs:
        acc = {name: np.zeros(3) for name in ds}
        for seed in range(args.seeds):
            sym, ire, region = make_case(seed, c, args.dev, args.filter, offset_hz=args.offset * 1e6)
            ph, p2 = cells(sym)
            cc = (ph, p2, LUT10[sym], sym)
            for name, fn in ds.items():
                vid = boxcar(fn(cc))
                h, j = sync_stats(vid, ire, region)
                acc[name] += (sinad(vid, ire, region), h, j)
        for name in ds:
            v = acc[name] / args.seeds
            table[name].append(v[0])
            hits[name].append(v[1])
            jit[name].append(v[2])
        print(f"C/N {c:4.1f} dB done", file=sys.stderr, flush=True)
    print(f"deviation {args.dev}, filter {args.filter} MHz, AFC offset {args.offset} MHz, {args.seeds} seeds")
    show = [i for i, c in enumerate(cnrs) if c in (-4, -2, 0, 2, 4, 6, 8, 12, 20, 40)]
    head = "".join(f"{cnrs[i]:>7.0f}" for i in show)
    print(f"\nluma SINAD (dB) at C/N (dB)\n{'demodulator':<16}{head}   C/N@0dB        C/N@10dB")
    base0 = threshold(cnrs, table["current"], 0)
    base10 = threshold(cnrs, table["current"], 10)
    for name, v in table.items():
        t0, t10 = threshold(cnrs, v, 0), threshold(cnrs, v, 10)
        print(f"{name:<16}" + "".join(f"{v[i]:7.2f}" for i in show)
              + f"   {t0:6.2f} ({base0 - t0:+.2f})  {t10:6.2f} ({base10 - t10:+.2f})")
    print(f"\nH sync found (% of lines)\n{'demodulator':<16}{head}   C/N@90%")
    b90 = threshold(cnrs, hits["current"], 0.9)
    for name, v in hits.items():
        t90 = threshold(cnrs, v, 0.9)
        print(f"{name:<16}" + "".join(f"{100 * v[i]:7.1f}" for i in show) + f"   {t90:6.2f} ({b90 - t90:+.2f})")
    print(f"\nH edge error rms (samples, 12.5 ns; 200 = none found)\n{'demodulator':<16}{head}")
    for name, v in jit.items():
        print(f"{name:<16}" + "".join(f"{v[i]:7.1f}" for i in show))


if __name__ == "__main__":
    main()
