#!/usr/bin/env python3
"""Find where an MLV clip sits inside an A1 log by matching image motion to gyro rotation.

For each candidate lag, the gyro is integrated over each frame interval and a linear
map (3 gyro axes -> image dx, dy) is fitted; the lag with the best fit wins.
Needs numpy. Run mlv_motion.py on the clip first.

Usage: sync_gyro.py LOG.bin CLIP.motion.csv [fps=25]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a1_to_gcsv import GYRO_LSB_PER_DPS, MARGIN_S, RATE_HZ, read_a1, write_gcsv


def fit(G, M):
    X = np.hstack([G, np.ones((len(G), 1))])
    A, *_ = np.linalg.lstsq(X, M, rcond=None)
    res = M - X @ A
    r2 = 1 - (res ** 2).sum() / ((M - M.mean(0)) ** 2).sum()
    return r2, A


def main():
    log, motion = sys.argv[1], sys.argv[2]
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 25.0
    start, orientation, samples = read_a1(log)
    gyro = np.array(samples, float)[:, 3:] / GYRO_LSB_PER_DPS * np.pi / 180 / RATE_HZ
    angle = np.vstack([np.zeros(3), np.cumsum(gyro, 0)])  # integrated rad, index = ms

    m = np.loadtxt(motion, delimiter=',', skiprows=1)
    frames, M = m[:, 0], m[:, 1:3]
    keep = m[:, 3] > np.percentile(m[:, 3], 10)  # drop the least reliable matches
    t1 = np.round(frames * 1000 / fps).astype(int)  # end of interval, ms from first frame
    t0 = np.round((frames - 1) * 1000 / fps).astype(int)

    def score(lag):
        G = angle[lag + t1] - angle[lag + t0]
        return fit(G[keep], M[keep])

    max_lag = len(angle) - 1 - t1.max()
    coarse = [(score(l)[0], l) for l in range(0, max_lag, 10)]
    coarse.sort(reverse=True)
    best_r2, best = coarse[0]
    fine = max((score(l)[0], l) for l in range(max(0, best - 15), min(max_lag, best + 16)))
    r2, lag = fine
    _, A = score(lag)
    second = next(r for r, l in coarse if abs(l - lag) > 500)
    t = start.timestamp() + lag / 1000
    import datetime as dt
    print('best lag %.3f s into the log -> first frame at %s' % (lag / 1000, dt.datetime.fromtimestamp(t).time()))
    print('R2 = %.3f (next best peak elsewhere: %.3f)' % (r2, second))
    print('gyro->image map (px/rad), rows gx gy gz, cols dx dy:')
    print(np.round(A[:3]).astype(int))

    # .gcsv next to the clip, t=0 at its first frame
    margin = int(MARGIN_S * RATE_HZ)
    lo, hi = max(0, lag - margin), min(len(samples), lag + t1.max() + margin)
    out = motion.replace('.motion.csv', '.gcsv')
    write_gcsv(out, orientation, samples[lo:hi], lo - lag)
    print('wrote', out)


if __name__ == '__main__':
    main()
