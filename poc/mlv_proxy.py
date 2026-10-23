#!/usr/bin/env python3
"""Make a small H.264 proxy of an LJ92 MLV clip, desqueezed, for Gyroflow sync and preview.

Usage: mlv_proxy.py CLIP.MLV [squeeze=3] [width=1200]
Needs numpy, imagecodecs and ffmpeg on PATH.
"""
import multiprocessing as mp
import os
import subprocess
import sys

import imagecodecs
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mlv_motion import frame_offsets


def decode_rgb(args):
    path, off, size, out_w, out_h = args
    with open(path, 'rb') as f:
        f.seek(off)
        raw = imagecodecs.ljpeg_decode(f.read(size))
    h, w2, c = raw.shape
    b = raw.reshape(h, w2 * c).astype(np.float32)
    # half-res debayer, RGGB assumed
    rgb = np.stack([b[0::2, 0::2], (b[0::2, 1::2] + b[1::2, 0::2]) / 2, b[1::2, 1::2]], -1)
    # nearest-neighbour resample to the desqueezed output size
    ys = (np.arange(out_h) * rgb.shape[0] / out_h).astype(int)
    xs = (np.arange(out_w) * rgb.shape[1] / out_w).astype(int)
    return rgb[ys][:, xs]


def main():
    path = sys.argv[1]
    squeeze = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
    out_w = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
    frames = frame_offsets(path)
    # recorded size from the first frame, then output height from the desqueezed aspect
    with open(path, 'rb') as f:
        f.seek(frames[0][1])
        h, w2, c = imagecodecs.ljpeg_decode(f.read(frames[0][2])).shape
    out_h = int(round(out_w * h / (w2 * c * squeeze) / 2)) * 2
    with mp.Pool(max(1, os.cpu_count() - 1)) as pool:
        imgs = pool.map(decode_rgb, [(path, o, s, out_w, out_h) for _, o, s in frames], chunksize=4)
    stack = np.stack(imgs)
    black = np.percentile(stack, 0.5, axis=(0, 1, 2))
    stack = np.maximum(stack - black, 0)
    stack /= np.percentile(stack, 99.5, axis=(0, 1, 2))  # also a crude grey-world balance
    stack = (np.clip(stack, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
    out = os.path.splitext(path)[0] + '_proxy.mp4'
    ff = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                           '-s', '%dx%d' % (out_w, out_h), '-r', '25', '-i', '-',
                           '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p', out],
                          stdin=subprocess.PIPE)
    ff.stdin.write(stack.tobytes())
    ff.stdin.close()
    ff.wait()
    print('wrote', out, '%dx%d' % (out_w, out_h), len(stack), 'frames')


if __name__ == '__main__':
    main()
