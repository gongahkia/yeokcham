"""Exercise real CLI measurements and refusal paths on small disposable fixtures."""
import argparse
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
                raw = dict(status='passed', failures=[], cases=[case],
                           settings=dict(cold=1, warm=2, warmups=1))
                small = summary.compact(raw)
                self.assertEqual(16, len(small['cases'][0]['samples']))
                self.assertEqual(case['summary'], small['cases'][0]['summary'])
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
