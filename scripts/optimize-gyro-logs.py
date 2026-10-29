#!/usr/bin/env python3
"""Limit mlv2Resolve's constant-offset SenseFlow logs to each clip, with 10 s handles.

Dry run: python3 scripts/optimize-gyro-logs.py /path/to/shoot
Apply:   python3 scripts/optimize-gyro-logs.py /path/to/shoot --apply

Original logs stay untouched. Original .gyroflow files are copied to
.mlv2resolve-gyro/backups before replacement. Excerpts live next to those backups.
This changes the files associated with DNGs, so restart Resolve to release old
Gyroflow caches. Variable sync offsets and other sensor formats are refused.
"""
import argparse
import array
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import tempfile
from urllib.parse import unquote, urlsplit


def index_log(data):
    if len(data) < 512 or data[:9] != b'SenseFlow' or (len(data) - 512) % 16:
        raise ValueError('Not a supported SenseFlow A1 log')
    hz = struct.unpack_from('<I', data, 92)[0]
    if not 1 <= hz <= 10000:
        raise ValueError('Invalid sampling rate')
    indices = array.array('Q')
    for pos in range(512, len(data), 16):
        tag = data[pos:pos + 3]
        if tag == b'\xaa\x55\x03':
            if sum(data[pos + 3:pos + 15]) % 256 != data[pos + 15]:
                raise ValueError(f'Invalid checksum at {pos}; timing cannot be guaranteed')
            indices.append(pos)
        elif tag != b'\x55\xaa\x40':
            raise ValueError(f'Unsupported sensor record at {pos}')
    if not indices:
        raise ValueError('No motion samples')
    return indices, hz


def excerpt(data, index, offset_ms, duration_ms, padding_ms=10000):
    indices, hz = index
    lag = -offset_ms
    if not all(math.isfinite(x) for x in [lag, duration_ms, padding_ms]):
        raise ValueError('Non-finite timing')
    if duration_ms <= 0 or padding_ms < 0 or lag < 0 or lag + duration_ms > len(indices) / hz * 1000 + 1:
        raise ValueError('Clip falls outside the gyro log')
    # Whole seconds keep the header date exact; sample timing starts at zero in the parser.
    shift_ms = max(0, math.floor((lag - padding_ms) / 1000) * 1000)
    first = int(shift_ms * hz / 1000)
    end = min(len(indices), math.ceil((lag + duration_ms + padding_ms) * hz / 1000))
    if first >= end:
        raise ValueError('Empty gyro excerpt')
    header = bytearray(data[:512])
    date = datetime.datetime(2000 + header[64], *header[65:70]) + datetime.timedelta(milliseconds=shift_ms)
    header[64:70] = bytes([date.year - 2000, date.month, date.day, date.hour, date.minute, date.second])
    stop = indices[end] if end < len(indices) else len(data)
    return bytes(header) + data[indices[first]:stop], shift_ms


def constant_offset(offsets):
    if not offsets:
        raise ValueError('No synchronization points')
    values = list(offsets.values())
    if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in values) or max(values) != min(values):
        raise ValueError('Only constant synchronization offsets are supported')
    for key in offsets:
        int(key)
    return values[0]


def atomic_write(dest, data):
    fd, temp = tempfile.mkstemp(dir=dest.parent, prefix='.' + dest.name + '.')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.replace(temp, dest)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def optimize(folder, apply=False):
    folder = folder.resolve()
    storage = folder / '.mlv2resolve-gyro'
    cache = {}
    count = old_bytes = new_bytes = 0
    for project in sorted(folder.glob('*.gyroflow')):
        original = project.read_bytes()
        p = json.loads(original)
        uri = p.get('gyro_source', {}).get('filepath', '')
        if not uri.startswith('file:///'):
            print(f'SKIP {project.name}: no local gyro log')
            continue
        source = Path(unquote(urlsplit(uri).path)).resolve()
        if storage in source.parents:
            print(f'SKIP {project.name}: already optimized')
            continue
        try:
            offset = constant_offset(p.get('offsets', {}))
            duration = p['video_info']['num_frames'] / p['video_info']['fps'] * 1000
            if source not in cache:
                data = source.read_bytes()
                cache[source] = data, index_log(data)
            data, index = cache[source]
            cropped, shift = excerpt(data, index, offset, duration)
            # Content names keep previous project backups valid after regeneration.
            binary = storage / (project.stem + '-' + hashlib.sha256(cropped).hexdigest()[:20] + '.bin')
            p['gyro_source']['filepath'] = binary.as_uri()
            p['offsets'] = {str(int(k) - shift * 1000): v + shift for k, v in p['offsets'].items()}
            encoded = json.dumps(p, indent=2, ensure_ascii=False).encode()
            if apply:
                backups = storage / 'backups'
                backups.mkdir(parents=True, exist_ok=True)
                backup = backups / (project.stem + '-' + hashlib.sha256(original).hexdigest()[:20] + '.gyroflow')
                if not backup.exists():
                    shutil.copy2(project, backup)
                atomic_write(binary, cropped)
                atomic_write(project, encoded)
            count += 1
            old_bytes += len(data)
            new_bytes += len(cropped)
            print(f'{project.name}: {len(data):,} -> {len(cropped):,} bytes')
        except (ValueError, KeyError, TypeError, OSError) as error:
            print(f'SKIP {project.name}: {error}')
    print(f'{"APPLIED" if apply else "DRY RUN"}: {count} projects; repeated log input {old_bytes:,} -> {new_bytes:,} bytes')
    return count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    optimize(args.folder, args.apply)
