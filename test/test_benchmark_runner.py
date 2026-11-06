"""Exercise real CLI measurements and refusal paths on small disposable fixtures."""
import argparse
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import benchmark_fixture as fixture
import benchmark_runner as runner
import benchmark_summary as summary


class RunnerTests(unittest.TestCase):
    def test_subprocess_failure_and_resource_measurement(self):
        with self.assertRaisesRegex(RuntimeError, 'exited 7'):
            runner.invoke([sys.executable, '-c', 'raise SystemExit(7)'], {})
        text, usage = runner.invoke([sys.executable, '-c', 'print("ok")'], {})
        self.assertEqual('ok\n', text)
        self.assertGreater(usage['seconds'], 0)
        self.assertGreater(usage['peak_rss_bytes'], 0)

    def test_checkout_destination_refused(self):
        for path in (runner.REPO, runner.REPO / 'fixtures', runner.REPO.parent):
            with self.assertRaisesRegex(ValueError, 'outside'):
                runner.assert_external(path)

    def test_storage_includes_directory_allocation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index in range(8):
                directory = root / str(index)
                directory.mkdir()
                (directory / 'data').write_bytes(b'data' * 1024)
            observed = runner.storage(root)
            du_bytes = int(subprocess.check_output(['du', '-sk', str(root)]).split()[0]) * 1024
            self.assertEqual(du_bytes, observed['allocated_bytes'])
            self.assertEqual(9, observed['directories'])
            self.assertEqual(8, observed['files'])
            self.assertEqual(32768, observed['file_bytes'])
            self.assertEqual(observed['allocated_bytes'], observed['allocated_file_bytes'] + observed['allocated_directory_bytes'])

    def test_destination_restore_uses_stored_bytes_and_rejects_corruption(self):
        binary = runner.REPO / 'bin/yeokcham_v1.exe'
        if not binary.exists():
            binary = runner.REPO / '_build/default/bin/yeokcham_v1.exe'
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp)
            root = scratch / 'tree'
            expected = fixture.generate(root, 8192, 8, 'asset', attributes=True)
            signers = scratch / 'signers'
            signers.mkdir(mode=0o700)
            env = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(signers))
            runner.invoke(runner.command(binary, root, 'initial_capture'), env)
            tree = runner.check_history(binary, root, env, 1, 0)
            runner.edit(root, expected, -1)
            with self.assertRaisesRegex(ValueError, 'fidelity'):
                fixture.verify(root, expected)
            runner.verify_checkpoint(binary, root, env, tree, 0, expected, scratch)
            original = runner.invoke
            def corrupt_destination(argv, environment):
                result = original(argv, environment)
                destination = Path(argv[argv.index('--destination') + 1])
                (destination / 'unexpected').write_bytes(b'corruption')
                return result
            with patch.object(runner, 'invoke', corrupt_destination):
                with self.assertRaisesRegex(ValueError, 'fidelity'):
                    runner.verify_checkpoint(binary, root, env, tree, 0, expected, scratch)

    def test_summaries_exclude_warmups(self):
        samples = [dict(operation='no_op', temperature='warm', seconds=n) for n in range(1, 31)]
        samples.append(dict(operation='no_op', temperature='warmup', seconds=10000))
        summary = runner.summarize(samples)['no_op']['warm']
        self.assertEqual(30, summary['count'])
        self.assertEqual(15.5, summary['median_seconds'])
        self.assertEqual(29, summary['p95_seconds'])

    def test_real_cli_and_corruption_rejection(self):
        binary = runner.REPO / 'bin/yeokcham_v1.exe'
        if not binary.exists():
            binary = runner.REPO / '_build/default/bin/yeokcham_v1.exe'
        self.assertTrue(binary.is_file(), 'make build is required for the focused runner checks')
        for shape in ('linear', 'branching'):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as tmp:
                args = argparse.Namespace(binary=binary, suite='asset', seed=1, depth=2,
                                          fanout=3, large_file_bytes=0, attributes=True,
                                          history_nodes=5, history_shape=shape,
                                          cold=1, warm=2, warmups=1)
                case = runner.run_case(args, Path(tmp) / 'case', 8192, 8)
                self.assertEqual('passed', case['status'])
                self.assertEqual(16, len(case['samples']))
                self.assertFalse(case['failures'])
                self.assertEqual(2, case['summary']['undo_restore']['warm']['count'])
                raw = dict(schema='yeokcham-benchmark-run-v2', status='passed', failures=[], cases=[case],
                           settings=dict(cold=1, warm=2, warmups=1))
                small = summary.compact(raw)
                self.assertEqual(16, len(small['cases'][0]['samples']))
                self.assertEqual(case['summary'], small['cases'][0]['summary'])
                case['samples'].append(dict(case['samples'][0], operation='unknown'))
                with self.assertRaisesRegex(ValueError, 'unexpected'):
                    summary.compact(raw)
                case['samples'].pop()
                case['samples'].pop()
                with self.assertRaisesRegex(ValueError, 'incomplete'):
                    summary.compact(raw)
        with tempfile.TemporaryDirectory() as tmp:
            original = runner.invoke
            def corrupt(argv, env):
                result = original(argv, env)
                if argv[1] == 'save' and Path(argv[-1]).name == 'sample':
                    (Path(argv[-1]) / 'unexpected-file').write_bytes(b'corruption')
                return result
            with patch.object(runner, 'invoke', corrupt):
                with self.assertRaisesRegex(ValueError, 'fixture fidelity failure'):
                    runner.run_case(args, Path(tmp) / 'broken', 8192, 8)
            import json
            failed = json.loads((Path(tmp) / 'broken/result.json').read_text())
            self.assertEqual('failed', failed['status'])
            self.assertEqual('no_op', failed['failures'][0]['operation'])


if __name__ == '__main__':
    unittest.main()
