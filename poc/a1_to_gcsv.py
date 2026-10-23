#!/usr/bin/env python3
"""Convert NiYien SenseFlow A1 logs (*_mix.bin) to Gyroflow .gcsv, sliced per MLV clip.

A1 format (reverse-engineered from firmware V1.2.8):
  - 0x200-byte header: magic "SenseFlow", model, serial, orientation string at 0x3c,
    start date/time at 0x40 (yy mm dd hh mi ss, one byte each), mount quaternion at 0x4c.
  - then 16-byte records: aa 55 03 | ax ay az gx gy gz (int16 LE) | 1 byte checksum.
    Every 1000 samples a "55 aa 40" one-second marker record is inserted.
  - 1000 Hz, accel 4096 LSB/g (+-8 g), gyro 32.8 LSB/(deg/s) (+-1000 deg/s).

Usage:
  a1_to_gcsv.py LOG.bin                      -> whole log as LOG.gcsv
  a1_to_gcsv.py LOG.bin CLIP.MLV [...]       -> one CLIP.gcsv per clip overlapping the log
"""
import datetime as dt
import math
import os
import struct
import sys

RATE_HZ = 1000
ACC_LSB_PER_G = 4096.0
GYRO_LSB_PER_DPS = 32.8
MARGIN_S = 2.0  # both clocks have 1 s resolution; Gyroflow autosync refines the rest


def read_a1(path):
    data = open(path, 'rb').read()
    if not data.startswith(b'SenseFlow'):
        raise ValueError('%s: not a SenseFlow log' % path)
    yy, mo, dd, hh, mi, ss = data[0x40:0x46]
    start = dt.datetime(2000 + yy, mo, dd, hh, mi, ss)
    orientation = data[0x3c:0x40].split(b'\0')[0].decode() or 'XYZ'
    samples = []
    for off in range(0x200, len(data) - 15, 16):
        if data[off:off + 3] == b'\xaa\x55\x03':
            samples.append(struct.unpack_from('<6h', data, off + 3))
    return start, orientation, samples


def read_mlv(path):
    """Return (wall-clock time of first frame, duration in s, fps) from MLV headers."""
    rtc = rtc_ts = first_ts = None
    frames = fps = None
    with open(path, 'rb') as f:
        while rtc is None or first_ts is None:
            hdr = f.read(16)
            if len(hdr) < 16:
                break
            btype, size, ts = struct.unpack('<4sIQ', hdr)
            if btype == b'MLVI':
                body = hdr[8:] + f.read(size - 16)
                frames, = struct.unpack_from('<I', body, 28)
                num, den = struct.unpack_from('<II', body, 36)
                fps = num / den
                continue
            if btype == b'RTCI':
                sec, mn, hr, mday, mon, yr = struct.unpack('<6H', f.read(12))
                rtc = dt.datetime(yr + 1900, mon + 1, mday, hr, mn, sec)
                rtc_ts = ts
                f.seek(size - 28, 1)
                continue
            if btype == b'VIDF' and first_ts is None:
                first_ts = ts
            f.seek(size - 16, 1)
    if rtc is None or first_ts is None or not fps:
        raise ValueError('%s: missing RTCI/VIDF/MLVI block' % path)
    first_frame = rtc + dt.timedelta(microseconds=first_ts - rtc_ts)
    return first_frame, frames / fps, fps


def write_gcsv(path, orientation, samples, t0_index):
    with open(path, 'w') as out:
        out.write('GYROFLOW IMU LOG\nversion,1.3\nid,niyien_a1\n')
        out.write('orientation,%s\n' % orientation)
        out.write('tscale,%g\n' % (1.0 / RATE_HZ))
        out.write('gscale,%.10g\n' % (math.pi / 180 / GYRO_LSB_PER_DPS))
        out.write('ascale,%.10g\n' % (1.0 / ACC_LSB_PER_G))
        out.write('t,gx,gy,gz,ax,ay,az\n')
        for i, (ax, ay, az, gx, gy, gz) in enumerate(samples):
            out.write('%d,%d,%d,%d,%d,%d,%d\n' % (t0_index + i, gx, gy, gz, ax, ay, az))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    log, clips = argv[1], argv[2:]
    start, orientation, samples = read_a1(log)
    end = start + dt.timedelta(seconds=len(samples) / RATE_HZ)
    print('A1 log %s -> %s (%d samples)' % (start, end.time(), len(samples)))
    if not clips:
        out = os.path.splitext(log)[0] + '.gcsv'
        write_gcsv(out, orientation, samples, 0)
        print('wrote', out)
        return
    for clip in clips:
        first, dur, fps = read_mlv(clip)
        print('%s: %s, %.2f s @ %g fps' % (os.path.basename(clip), first, dur, fps))
        # t=0 in the .gcsv is the clip's first frame, so the slice starts at a negative index
        offset = (first - start).total_seconds()
        lo = max(0, int((offset - MARGIN_S) * RATE_HZ))
        hi = min(len(samples), int((offset + dur + MARGIN_S) * RATE_HZ))
        if hi <= lo:
            print('  no overlap with the A1 log, skipped')
            continue
        out = os.path.splitext(clip)[0] + '.gcsv'
        write_gcsv(out, orientation, samples[lo:hi], lo - int(offset * RATE_HZ))
        print('  wrote %s (%.1f s of gyro)' % (out, (hi - lo) / RATE_HZ))


if __name__ == '__main__':
    main(sys.argv)
