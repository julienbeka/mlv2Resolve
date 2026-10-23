#!/usr/bin/env python3
"""Estimate frame-to-frame image motion of an LJ92-compressed MLV clip.

Writes CLIP.motion.csv: frame, dx, dy (in vertical-pixel units of the 2x-binned image,
dx already multiplied by the horizontal squeeze factor).
Needs numpy and imagecodecs.

Usage: mlv_motion.py CLIP.MLV [squeeze=3]
"""
import multiprocessing as mp
import os
import struct
import sys

import imagecodecs
import numpy as np


def frame_offsets(path):
    """Yield (frame_number, data_offset, data_size) for each VIDF block."""
    out = []
    with open(path, 'rb') as f:
        f.read(52)  # MLVI
        while True:
            hdr = f.read(16)
            if len(hdr) < 16:
                break
            btype, size, _ = struct.unpack('<4sIQ', hdr)
            if btype == b'VIDF':
                body = f.read(16)
                num = struct.unpack_from('<I', body, 0)[0]
                space = struct.unpack_from('<I', body, 12)[0]
                start = f.tell() + space
                out.append((num, start, size - 32 - space))
                f.seek(size - 32, 1)
            else:
                f.seek(size - 16, 1)
    return sorted(out)


def load_gray(args):
    path, off, size = args
    with open(path, 'rb') as f:
        f.seek(off)
        raw = imagecodecs.ljpeg_decode(f.read(size))
    h, w2, c = raw.shape
    bayer = raw.reshape(h, w2 * c).astype(np.float32)
    # 2x2 Bayer bin -> luminance-ish, then 2x more to speed things up
    g = bayer[0::2, 0::2] + bayer[0::2, 1::2] + bayer[1::2, 0::2] + bayer[1::2, 1::2]
    g = g[: g.shape[0] // 2 * 2, : g.shape[1] // 2 * 2]
    g = g.reshape(g.shape[0] // 2, 2, g.shape[1] // 2, 2).mean((1, 3))
    g = np.log1p(np.maximum(g - g.min(), 0))
    g -= g.mean()
    win = np.outer(np.hanning(g.shape[0]), np.hanning(g.shape[1]))
    return g * win


def phase_shift(a, b):
    """Subpixel translation of b relative to a."""
    fa, fb = np.fft.fft2(a), np.fft.fft2(b)
    r = fb * np.conj(fa)
    r /= np.abs(r) + 1e-9
    c = np.fft.ifft2(r).real
    iy, ix = np.unravel_index(np.argmax(c), c.shape)

    def sub(cm, i, n):
        y0, y1, y2 = cm[(i - 1) % n], cm[i], cm[(i + 1) % n]
        d = y0 - 2 * y1 + y2
        return i + (0.5 * (y0 - y2) / d if d else 0)
    dy = sub(c[:, ix], iy, c.shape[0])
    dx = sub(c[iy, :], ix, c.shape[1])
    if dy > c.shape[0] / 2: dy -= c.shape[0]
    if dx > c.shape[1] / 2: dx -= c.shape[1]
    return dx, dy, c.max()


def main():
    path = sys.argv[1]
    squeeze = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
    frames = frame_offsets(path)
    with mp.Pool(max(1, os.cpu_count() - 1)) as pool:
        imgs = pool.map(load_gray, [(path, o, s) for _, o, s in frames], chunksize=4)
    out = os.path.splitext(path)[0] + '.motion.csv'
    with open(out, 'w') as f:
        f.write('frame,dx,dy,peak\n')
        for i in range(1, len(imgs)):
            dx, dy, peak = phase_shift(imgs[i - 1], imgs[i])
            f.write('%d,%.3f,%.3f,%.4f\n' % (frames[i][0], dx * squeeze, dy, peak))
    print('wrote', out, len(imgs), 'frames')


if __name__ == '__main__':
    main()
