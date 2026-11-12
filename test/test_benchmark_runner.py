"""Exercise real CLI measurements and refusal paths on small disposable fixtures."""
import argparse
import copy
import hashlib
import json
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
    def test_resume_preserves_samples_and_refuses_changed_inputs(self):
        binary = runner.REPO / 'bin/yeokcham_v1.exe'
        if not binary.exists():
            binary = runner.REPO / '_build/default/bin/yeokcham_v1.exe'
        for shape in ('linear', 'branching'):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'run'
                argv = ['benchmark_runner.py', '--output', str(root), '--binary', str(binary),
                        '--suite', 'asset', '--bytes', '8192', '--files', '8', '--attributes',
                        '--history-nodes', '5', '--history-shape', shape,
                        '--cold', '1', '--warmups', '1', '--warm', '2']
                observed_machine = runner.machine(Path(tmp))
                invoke = runner.invoke
                def interrupt(argv, env):
                    if argv[1] == 'save' and Path(argv[-1]).name == 'sample':
                        raise KeyboardInterrupt('simulated process interruption')
                    return invoke(argv, env)
                # Source export checks have their own integration evidence; all measured CLI calls here are real.
                with patch.object(runner, 'verify_source'), patch.object(runner, 'machine', return_value=observed_machine):
                    with patch.object(sys, 'argv', argv), patch.object(runner, 'invoke', interrupt):
                        with self.assertRaises(KeyboardInterrupt):
                            runner.main()
                    case_dir = root / 'asset-8192-8'
                    original_bytes = (case_dir / 'result.json').read_bytes()
                    accepted = json.loads(original_bytes)['samples']
                    self.assertEqual(4, len(accepted))
                    # Model an abruptly killed in-flight copy, which must be preserved and never accepted.
                    (case_dir / 'sample').mkdir()
                    (case_dir / 'sample/unfinished').write_bytes(b'partial operation')
                    resumed = [*argv, '--resume']
                    with (root / '.benchmark.lock').open('a') as lock:
                        runner.fcntl.flock(lock, runner.fcntl.LOCK_EX | runner.fcntl.LOCK_NB)
                        with patch.object(sys, 'argv', resumed):
                            with self.assertRaisesRegex(ValueError, 'already in use'):
                                runner.main()
                    for extra, message in [(['--warm', '3'], 'settings mismatch'),
                                           (['--binary', sys.executable], 'binary_sha256')]:
                        with patch.object(sys, 'argv', [*resumed, *extra]):
                            with self.assertRaisesRegex(ValueError, message):
                                runner.main()
                        self.assertEqual(original_bytes, (case_dir / 'result.json').read_bytes())
                    changed = copy.deepcopy(observed_machine)
                    changed['cpu_count'] += 1
                    with patch.object(runner, 'machine', return_value=changed), patch.object(sys, 'argv', resumed):
                        with self.assertRaisesRegex(ValueError, 'machine/toolchain/filesystem mismatch'):
                            runner.main()
                    # A fixture for Git's prior source keeps this check usable in shallow CI checkouts.
                    previous = json.loads((root / 'summary.json').read_text())
                    old_source = Path(runner.__file__).read_bytes() + b'\n# earlier compatible runner\n'
                    previous['runner_revision'] = 'previous-test-runner'
                    check_output = subprocess.check_output
                    recorded_source = old_source.replace(b"'initial_capture': ['init'", b"'initial_capture': ['changed-init'")
                    def source_output(command, *args, **kwargs):
                        if command == ['git', 'show', 'previous-test-runner:tools/benchmark_runner.py']:
                            return recorded_source
                        return check_output(command, *args, **kwargs)
                    with patch.object(subprocess, 'check_output', side_effect=source_output):
                        previous['runner_sha256'] = hashlib.sha256(recorded_source).hexdigest()
                        runner.write_json(root / 'summary.json', previous)
                        with patch.object(sys, 'argv', resumed):
                            with self.assertRaisesRegex(ValueError, 'measurement or verification code changed'):
                                runner.main()
                        recorded_source = old_source
                        previous['runner_sha256'] = hashlib.sha256(recorded_source).hexdigest()
                        runner.write_json(root / 'summary.json', previous)
                        with patch.object(sys, 'argv', resumed):
                            runner.main()
                result = json.loads((root / 'summary.json').read_text())
                samples = result['cases'][0]['samples']
                self.assertEqual('passed', result['status'])
                self.assertEqual(accepted, samples[:4])
                self.assertEqual(16, len(samples))
                event = result['continuations'][0]
                self.assertEqual(4, event['accepted_before']['asset-8192-8'])
                self.assertEqual(original_bytes, (Path(event['snapshot']) / 'asset-8192-8/result.json').read_bytes())
                leftovers = list(case_dir.glob('interrupted-sample-*/unfinished'))
                self.assertEqual([b'partial operation'], [p.read_bytes() for p in leftovers])
                self.assertEqual(16, len(summary.compact(result)['cases'][0]['samples']))
                # A truncated/reordered accepted prefix is not silently repaired or rerun.
                case = json.loads((case_dir / 'result.json').read_text())
                case['samples'][0], case['samples'][1] = case['samples'][1], case['samples'][0]
                runner.write_json(case_dir / 'result.json', case)
                args = argparse.Namespace(binary=binary, suite='asset', seed=1, depth=3, fanout=8,
                                          large_file_bytes=0, attributes=True, history_nodes=5,
                                          history_shape=shape, cold=1, warmups=1, warm=2)
                with self.assertRaisesRegex(ValueError, 'exact accepted sample prefix'):
                    runner.resume_case(args, case_dir, 8192, 8)

    def test_resume_preserves_interrupted_preparation(self):
        binary = runner.REPO / 'bin/yeokcham_v1.exe'
        if not binary.exists():
            binary = runner.REPO / '_build/default/bin/yeokcham_v1.exe'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'run'
            argv = ['benchmark_runner.py', '--output', str(root), '--binary', str(binary),
                    '--bytes', '2048', '--files', '4', '--history-nodes', '2',
                    '--cold', '0', '--warmups', '0', '--warm', '1']
            observed_machine = runner.machine(Path(tmp))
            with patch.object(runner, 'verify_source'), patch.object(runner, 'machine', return_value=observed_machine):
                with patch.object(sys, 'argv', argv), patch.object(runner, 'invoke', side_effect=KeyboardInterrupt):
                    with self.assertRaises(KeyboardInterrupt):
                        runner.main()
                first_manifest = (root / 'source-2048-4/fixture-manifest.json').read_bytes()
                with patch.object(sys, 'argv', [*argv, '--resume']):
                    runner.main()
            preserved = list(root.glob('interrupted-preparation-*/fixture-manifest.json'))
            self.assertEqual([first_manifest], [p.read_bytes() for p in preserved])
            result = json.loads((root / 'summary.json').read_text())
            self.assertEqual('passed', result['status'])
            self.assertEqual(4, len(result['cases'][0]['samples']))

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
