"""Determinism, byte accounting, attribute and corruption gates."""
import copy
import gzip
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import benchmark_fixture as fixture


class FixtureTests(unittest.TestCase):
    def test_reproducible_and_exact_all_suites(self):
        with tempfile.TemporaryDirectory() as tmp:
            for suite in fixture.TIERS:
                root = Path(tmp) / suite
                a = fixture.generate(root, 123457, 23, suite, attributes=True)
                b = fixture.generate(Path(tmp) / (suite + '-again'), 123457, 23, suite, attributes=True)
                self.assertEqual(a, b)
                for path in root.rglob('*.gz'):
                    self.assertGreater(len(gzip.decompress(path.read_bytes())), 0)
                self.assertEqual(123457, sum(e.get('bytes', 0) for e in a['entries']))
                self.assertEqual(23, sum(e['kind'] == 'file' for e in a['entries']))
                self.assertTrue(any(e.get('executable') for e in a['entries']))
                self.assertTrue(any(e['kind'] == 'symlink' for e in a['entries']))
                c = fixture.generate(Path(tmp) / (suite + '-seed'), 123457, 23, suite, seed=2, attributes=True)
                self.assertNotEqual(a['tree_sha256'], c['tree_sha256'])

    def test_fidelity_rejects_bytes_modes_links_extra_and_missing(self):
        for change in ('bytes', 'mode', 'link', 'extra', 'missing', 'manifest'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'tree'
                manifest = fixture.generate(root, 4096, 4, attributes=True)
                path = root / next(e['path'] for e in manifest['entries'] if e.get('executable'))
                if change == 'bytes':
                    path.write_bytes(b'broken')
                elif change == 'mode':
                    path.chmod(0o644)
                elif change == 'link':
                    (root / 'fixture-link').unlink()
                    (root / 'fixture-link').symlink_to('missing')
                elif change == 'extra':
                    (root / 'unrecorded').write_bytes(b'')
                elif change == 'missing':
                    path.unlink()
                else:
                    manifest = copy.deepcopy(manifest)
                    manifest['tree_sha256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'fidelity|hash mismatch'):
                    fixture.verify(root, manifest)

    def test_large_file_and_invalid_parameters(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'tree'
            manifest = fixture.generate(root, 100000, 4, 'asset', large_file_bytes=90000)
            self.assertEqual([3333, 3333, 3334, 90000], sorted(e['bytes'] for e in manifest['entries'] if e['kind'] == 'file'))
            for kwargs in ({'files': 0}, {'files': 101}, {'depth': -1}, {'fanout': 0}, {'large_file_bytes': 100}):
                args = dict(root=Path(tmp) / 'invalid', total_bytes=100, files=4)
                args.update(kwargs)
                with self.assertRaises(ValueError):
                    fixture.generate(**args)

    def test_refuses_existing_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileExistsError):
                fixture.generate(Path(tmp), 100, 2)


if __name__ == '__main__':
    unittest.main()
