"""Synthetic-only tests: never commit user ride data."""
import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / 'tools' / 'motor_did_coverage.py'
spec = importlib.util.spec_from_file_location('motor_did_coverage', SRC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class CoverageTest(unittest.TestCase):
    def test_mode01_only_uses_observed_ecu01(self):
        self.assertEqual(mod.decode_mode01('010D', b'18DAF10203410D32\r18DAF10103410D1E'), 30)
        self.assertEqual(mod.decode_mode01('010C', b'18DAF10104410C1770'), 1500)
        self.assertIsNone(mod.decode_mode01('010D', b'18DAF10203410D32'))

    def test_age_gate_avoids_stale_speed(self):
        points = [(100.0, 25.0)]
        self.assertEqual(mod.last_before(points, 101.0, 1.5), 25.0)
        self.assertIsNone(mod.last_before(points, 103.0, 1.5))
        self.assertIsNone(mod.last_before(points, 99.0, 1.5))

    def test_read_only_coverage_no_false_motor_claim(self):
        with tempfile.TemporaryDirectory() as root:
            db = Path(root) / 'sample.sqlite3'
            conn = sqlite3.connect(db)
            conn.executescript('''
                CREATE TABLE commands(ts_utc TEXT,command TEXT,raw_response BLOB);
                CREATE TABLE did_drive_samples(ts_utc TEXT,ecu TEXT,did INTEGER,
                    payload BLOB,response_can_id TEXT,success INTEGER,partial INTEGER);
            ''')
            for i in range(6):
                at = f'2026-10-24T00:00:{i:02d}.000Z'
                conn.execute('INSERT INTO commands VALUES (?,?,?)',
                             (at, '010D', f'18DAF10103410D{12+i:02X}'.encode()))
                conn.execute('INSERT INTO commands VALUES (?,?,?)',
                             (at, '010C', b'18DAF10104410C0000'))
                conn.execute('INSERT INTO did_drive_samples VALUES (?,?,?,?,?,?,?)',
                             (at, '01', 0x2001, bytes([i, i+10]), '18DAF101', 1, 0))
            conn.execute('INSERT INTO did_drive_samples VALUES (?,?,?,?,?,?,?)',
                         ('2026-10-24T00:00:07.000Z','01',0x2001,b'xxx','18DAF101',1,1))
            conn.commit()
            conn.close()
            before = db.read_bytes()
            report = mod.summarize(db)
            self.assertEqual(db.read_bytes(), before)
            self.assertEqual(report['priority_ecus_without_samples'], ['0E','EF'])
            self.assertEqual(report['invalid_or_partial_did_samples'], 1)
            did = report['did_coverage'][0]
            self.assertEqual(did['changing_byte_offsets'], [0,1])
            self.assertEqual(did['contexts']['ev_moving'], 6)
            self.assertEqual(did['semantics'], 'UNKNOWN')
            self.assertFalse(did['screening_ready'])


if __name__ == '__main__':
    unittest.main()
