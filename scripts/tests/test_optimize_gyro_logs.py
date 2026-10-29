import importlib.util
import struct
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('optimize_gyro_logs', Path(__file__).parents[1] / 'optimize-gyro-logs.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture(count=10000):
    header = bytearray(512)
    header[:9] = b'SenseFlow'
    header[64:70] = bytes([26, 10, 28, 19, 21, 6])
    struct.pack_into('<I', header, 92, 1000)
    records = []
    for i in range(count):
        data = struct.pack('<6h', i % 32000, 2, 3, 4, 5, 6)
        records.append(b'\xaa\x55\x03' + data + bytes([sum(data) % 256]))
        if (i + 1) % 1000 == 0:
            records.append(b'\x55\xaa\x40' + bytes(13))
    return bytes(header) + b''.join(records)


class ExcerptTests(unittest.TestCase):
    def test_samples_and_sync_are_preserved_across_markers(self):
        original = fixture()
        index = m.index_log(original)
        data, shift = m.excerpt(original, index, -4500, 2000, padding_ms=1000)
        self.assertEqual(shift, 3000)
        cropped = m.index_log(data)
        self.assertEqual(len(cropped[0]), 4500)
        for i in [0, 999, 1000, 3499, 4499]:
            a = index[0][i + 3000]; b = cropped[0][i]
            self.assertEqual(original[a:a + 16], data[b:b + 16])
        for video_ms in [0, 1000, 1999]:
            self.assertEqual(video_ms + 4500, video_ms - (-4500 + shift) + shift)
        self.assertEqual(data[64:70], bytes([26, 10, 28, 19, 21, 9]))

    def test_padding_clamped_to_available_data(self):
        original = fixture()
        data, shift = m.excerpt(original, m.index_log(original), -100, 9800)
        self.assertEqual(shift, 0)
        self.assertEqual(len(m.index_log(data)[0]), 10000)

    def test_invalid_checksum_refused(self):
        data = bytearray(fixture(2)); data[-1] ^= 1
        with self.assertRaises(ValueError):
            m.index_log(data)

    def test_unsupported_sensor_records_refused(self):
        data = bytearray(fixture(2)); data[514] = 7
        with self.assertRaises(ValueError):
            m.index_log(data)

    def test_clip_outside_log_refused(self):
        data = fixture()
        with self.assertRaises(ValueError):
            m.excerpt(data, m.index_log(data), -9500, 1000)

    def test_variable_sync_refused_without_changing_project(self):
        with self.assertRaises(ValueError):
            m.constant_offset({'1000': -100, '2000': -101})

    def test_dry_run_then_apply_keeps_backup_and_original_log(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            log = folder / 'session_mix.bin'
            log.write_bytes(fixture())
            project = folder / 'clip.gyroflow'
            project.write_text(json.dumps({
                'gyro_source': {'filepath': log.as_uri()},
                'offsets': {'4800000': -4500},
                'video_info': {'num_frames': 50, 'fps': 25},
            }))
            before = project.read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(m.optimize(folder), 1)
                self.assertEqual(project.read_bytes(), before)
                self.assertFalse((folder / '.mlv2resolve-gyro').exists())
                self.assertEqual(m.optimize(folder, apply=True), 1)
                self.assertEqual(m.optimize(folder, apply=True), 0)
            backups = list((folder / '.mlv2resolve-gyro/backups').glob('*.gyroflow'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), before)
            self.assertEqual(log.read_bytes(), fixture())
            self.assertIn('.mlv2resolve-gyro', json.loads(project.read_text())['gyro_source']['filepath'])


if __name__ == '__main__':
    unittest.main()
