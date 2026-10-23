#!/usr/bin/env python3
"""Dev-only: write reference raw frames for mount_test.py --expect-raw.

Usage: make_reference.py <clip.MLV> <ref_dir> <frame> [<frame> ...]

Needs numpy + imagecodecs (not stdlib; mount_test.py itself stays stdlib-only).
For each requested frame number, finds the VIDF block in the (single-chunk) MLV, takes the payload after the
32-byte VIDF header + frameSpace padding, decodes it with imagecodecs.ljpeg_decode (current Magic Lantern
lossless = standard LJ92 with 2 interleaved components per row), reshapes (h, w/2, 2) -> (h, w) and writes
<ref_dir>/<clip>_<frame>.u16 as little-endian uint16, row-major.

Frame layout as decoded by MLV App (https://github.com/ilia3101/MLV-App, src/mlv/video_mlv.c).
SPDX-License-Identifier: GPL-3.0-or-later
"""
import os, struct, sys

import imagecodecs
import numpy as np

VIDF_HDR = 32


def vidf_payloads(path, wanted):
    """Yield (frameNumber, payload bytes) for VIDF blocks whose frameNumber is in wanted."""
    wanted = set(wanted)
    with open(path, "rb") as f:
        size = os.fstat(f.fileno()).st_size
        pos = 0
        while pos + 16 <= size and wanted:
            f.seek(pos)
            hdr = f.read(VIDF_HDR)
            btype, bsize = hdr[:4], struct.unpack_from("<I", hdr, 4)[0]
            if bsize < 16:
                raise SystemExit("corrupt block at %d (size %d)" % (pos, bsize))
            if btype == b"VIDF":
                frame_number = struct.unpack_from("<I", hdr, 16)[0]
                frame_space = struct.unpack_from("<I", hdr, 28)[0]
                if frame_number in wanted:
                    f.seek(pos + VIDF_HDR + frame_space)
                    yield frame_number, f.read(bsize - VIDF_HDR - frame_space)
                    wanted.discard(frame_number)
            pos += bsize
    if wanted:
        raise SystemExit("frames not found: %s" % sorted(wanted))


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    clip, ref_dir, frames = sys.argv[1], sys.argv[2], [int(x) for x in sys.argv[3:]]
    name = os.path.splitext(os.path.basename(clip))[0]
    os.makedirs(ref_dir, exist_ok=True)
    for n, payload in vidf_payloads(clip, frames):
        if payload[:2] != b"\xff\xd8":
            raise SystemExit("frame %d payload does not start with SOI: %r" % (n, payload[:4]))
        img = imagecodecs.ljpeg_decode(payload)
        if img.ndim == 3:
            img = img.reshape(img.shape[0], img.shape[1] * img.shape[2])
        img = np.ascontiguousarray(img, dtype="<u2")
        out = os.path.join(ref_dir, "%s_%d.u16" % (name, n))
        img.tofile(out)
        print("%s: frame %d %dx%d min=%d median=%d max=%d" % (
            out, n, img.shape[1], img.shape[0], img.min(), int(np.median(img)), img.max()))


if __name__ == "__main__":
    main()
