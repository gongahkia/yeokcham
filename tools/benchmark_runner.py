#!/usr/bin/env python3
"""Measure the existing CLI with verified deterministic fixtures, outside Git."""
import argparse
import copy
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True

import benchmark_fixture as fixture

BASELINE = 'd03ac1e095af7c896eede2334c5a1f5fc50c4e74'
REPO = Path(__file__).resolve().parents[1]
OPERATIONS = ('initial_capture', 'no_op', 'small_edit', 'undo_restore')


def output(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def write_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def assert_external(path):
    path = path.resolve()
    if path.is_relative_to(REPO) or REPO.is_relative_to(path):
        raise ValueError('benchmark destination must be outside the implementation checkout')
    return path


def verify_source(source, revision):
    """Compare every tracked file to git archive; generated build outputs are ignored."""
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['git', 'archive', revision], cwd=REPO, stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as tree:
            for member in tree:
                path = source / member.name
                if member.isfile():
                    if not path.is_file() or path.read_bytes() != tree.extractfile(member).read():
                        raise ValueError(f'source differs from {revision}: {member.name}')
                elif member.issym() and (not path.is_symlink() or os.readlink(path) != member.linkname):
                    raise ValueError(f'source link differs: {member.name}')


def export_baseline(destination, switch):
    destination = assert_external(destination)
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['git', 'archive', BASELINE], cwd=REPO, stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as tree:
            tree.extractall(destination, filter='data')
    verify_source(destination, BASELINE)
    command = ['opam', 'exec', '--switch', str(switch), '--', 'dune', 'build', '@all']
    subprocess.run(command, cwd=destination, check=True)
    verify_source(destination, BASELINE)
    write_json(destination.parent / (destination.name + '-export.json'),
               {'revision': BASELINE, 'source': str(destination), 'build_command': command,
                'binary_sha256': fixture.file_hash(destination / '_build/default/bin/yeokcham_v1.exe')})


def machine(root):
    def optional(command):
        try:
            return output(command)
        except (OSError, subprocess.CalledProcessError):
            return None
    return {
        'platform': platform.platform(), 'uname': list(platform.uname()),
        'python': sys.version, 'cpu_count': os.cpu_count(),
        'cpu': optional(['lscpu']), 'memory': optional(['free', '-b']),
        'filesystem': optional(['df', '-T', str(root)]),
        'storage': optional(['lsblk', '-o', 'NAME,MODEL,ROTA,SIZE,FSTYPE']),
        'ocaml': optional(['opam', 'exec', '--', 'ocamlc', '-version']),
        'dune': optional(['opam', 'exec', '--', 'dune', '--version']),
        'ocamlformat': optional(['opam', 'exec', '--', 'ocamlformat', '--version']),
    }


def storage(root):
    logical = allocated = count = 0
    for directory, _, files in os.walk(root):
        for name in files:
            info = (Path(directory) / name).lstat()
            logical += info.st_size
            allocated += info.st_blocks * 512
            count += 1
    return dict(file_bytes=logical, allocated_bytes=allocated, files=count)


def command(binary, root, operation):
    args = {'initial_capture': ['init', '--username', 'benchmark', '--draft', 'baseline', '--title', 'G01 baseline'],
            'no_op': ['save'], 'small_edit': ['save'],
            'undo_restore': ['undo', '--to', '0']}[operation]
    return [str(binary), *args, '--root', str(root)]


def invoke(argv, env):
    # wait4 yields per-child usage; stdout never enters artifacts (init prints recovery secrets).
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        start = time.perf_counter_ns()
        process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = (time.perf_counter_ns() - start) / 1e9
        process.returncode = os.waitstatus_to_exitcode(status)
        stderr.seek(0)
        errors = stderr.read().decode(errors='replace')
        if process.returncode:
            raise RuntimeError(f'command exited {process.returncode}: {argv}: {errors}')
        stdout.seek(0)
        result = stdout.read().decode()
    return result, dict(seconds=elapsed, cpu_user_seconds=usage.ru_utime,
                        cpu_system_seconds=usage.ru_stime,
                        peak_rss_bytes=usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024),
                        input_blocks=usage.ru_inblock, output_blocks=usage.ru_oublock)


def history(binary, root, env):
    text, _ = invoke([str(binary), 'undo-tree', '--root', str(root), '--format', 'json'], env)
    return json.loads(text)['result']


def check_history(binary, root, env, count, current):
    tree = history(binary, root, env)
    if len(tree['nodes']) != count or tree['current'] != str(current) or not all(n['available'] for n in tree['nodes']):
        raise ValueError(f'history fidelity failure: expected {count} nodes, current {current}')
    return tree


def edit(root, base, step):
    """Replace up to 64 bytes in exactly one file, preserving its length and mode."""
    entry = next(e for e in base['entries'] if e['kind'] == 'file')
    path = root / entry['path']
    marker = hashlib.sha256(f'edit-{step}'.encode()).hexdigest().encode()[:min(64, entry['bytes'])]
    with path.open('r+b') as stream:
        stream.write(marker)
    expected = copy.deepcopy(base)
    target = next(e for e in expected['entries'] if e['path'] == entry['path'])
    target['sha256'] = fixture.file_hash(path)
    expected['tree_sha256'] = fixture.digest(expected['entries'])
    return expected


def cache_prepare(root, binary, cold):
    """No global cache changes: cold is a disclosed advisory file-page eviction."""
    paths = [binary]
    for directory, _, files in os.walk(root):
        paths.extend(Path(directory) / name for name in files)
    for path in paths:
        if path.is_symlink():
            continue
        with path.open('rb') as stream:
            if cold:
                if not hasattr(os, 'posix_fadvise'):
                    raise ValueError('cold file-page eviction requires posix_fadvise on this host')
                os.fsync(stream.fileno())
                os.posix_fadvise(stream.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
            else:
                while stream.read(1024 * 1024):
                    pass


def summarize(samples):
    result = {}
    for operation in OPERATIONS:
        result[operation] = {}
        for temperature in ('cold', 'warm'):
            values = [s['seconds'] for s in samples if s['operation'] == operation and s['temperature'] == temperature]
            if not values:
                continue
            ordered = sorted(values)
            result[operation][temperature] = dict(
                count=len(values), median_seconds=statistics.median(values),
                min_seconds=min(values), max_seconds=max(values),
                p95_seconds=ordered[math.ceil(.95 * len(values)) - 1],
                stdev_seconds=statistics.stdev(values) if len(values) > 1 else 0)
    return result


def run_case(args, case_dir, total_bytes, files):
    case_dir.mkdir()
    pristine = case_dir / 'fixture'
    manifest = fixture.generate(pristine, total_bytes, files, args.suite, args.seed,
                                args.depth, args.fanout, args.large_file_bytes, args.attributes)
    write_json(case_dir / 'fixture-manifest.json', manifest)
    signers = case_dir / 'signers'
    signers.mkdir(mode=0o700)
    env = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(signers))
    master = case_dir / 'history'
    shutil.copytree(pristine, master, symlinks=True)
    invoke(command(args.binary, master, 'initial_capture'), env)
    states = [manifest]
    for node in range(1, args.history_nodes):
        repeat = args.history_shape == 'branching' and node % 3 == 0 and node != args.history_nodes - 1
        if args.history_shape == 'branching' and node > 1 and node % 2 == 0 and not repeat:
            invoke([str(args.binary), 'undo', '--to', '0', '--root', str(master)], env)
        if repeat:
            entry = next(e for e in manifest['entries'] if e['kind'] == 'file')
            shutil.copy2(pristine / entry['path'], master / entry['path'])
            states.append(manifest)
        else:
            states.append(edit(master, manifest, node))
        invoke(command(args.binary, master, 'small_edit'), env)
    check_history(args.binary, master, env, args.history_nodes, args.history_nodes - 1)
    # Prove every retained checkpoint restores, not just the current working copy.
    for node, state in enumerate(states):
        invoke([str(args.binary), 'undo', '--to', str(node), '--root', str(master)], env)
        fixture.verify(master, state)
    baseline_storage = storage(master / '.yeokcham')
    case = dict(config=manifest['config'], tree_sha256=manifest['tree_sha256'],
                manifest_sha256=fixture.file_hash(case_dir / 'fixture-manifest.json'),
                fixture_manifest=str(case_dir / 'fixture-manifest.json'),
                history_nodes=args.history_nodes, history_shape=args.history_shape,
                logical_captured_bytes=total_bytes * args.history_nodes,
                history_storage=baseline_storage, samples=[], failures=[], status='running')
    write_json(case_dir / 'result.json', case)
    for operation in OPERATIONS:
        for temperature, count in [('cold', args.cold), ('warmup', args.warmups), ('warm', args.warm)]:
            for sample_index in range(count):
                sample_root = case_dir / 'sample'
                shutil.copytree(pristine if operation == 'initial_capture' else master, sample_root, symlinks=True)
                try:
                    expected = manifest if operation in ('initial_capture', 'undo_restore') else states[-1]
                    if operation == 'small_edit':
                        expected = edit(sample_root, states[-1], args.history_nodes)
                    fixture.verify(sample_root, expected if operation != 'undo_restore' else states[-1])
                    cache_prepare(sample_root, args.binary, temperature == 'cold')
                    argv = command(args.binary, sample_root, operation)
                    _, metrics = invoke(argv, env)
                    measured_storage = storage(sample_root / '.yeokcham')
                    fixture.verify(sample_root, expected)
                    node_count = 1 if operation == 'initial_capture' else args.history_nodes + (operation == 'small_edit')
                    current = 0 if operation in ('initial_capture', 'undo_restore') else node_count - 1
                    check_history(args.binary, sample_root, env, node_count, current)
                    # A successful save and untouched files do not prove stored content: force a restore.
                    edit(sample_root, expected, -1)
                    invoke([str(args.binary), 'undo', '--to', str(current), '--root', str(sample_root)], env)
                    fixture.verify(sample_root, expected)
                    case['samples'].append(dict(operation=operation, temperature=temperature,
                                                index=sample_index, command=argv, **metrics,
                                                storage=measured_storage, verified_tree_sha256=expected['tree_sha256']))
                    write_json(case_dir / 'result.json', case)
                except Exception as error:
                    case['failures'].append(dict(operation=operation, temperature=temperature,
                                                 index=sample_index, error=str(error)))
                    case['status'] = 'failed'
                    write_json(case_dir / 'result.json', case)
                    raise
                finally:
                    shutil.rmtree(sample_root)
            print(f'{case_dir.name}: {operation} {temperature} {count} verified', flush=True)
    case.update(status='passed', summary=summarize(case['samples']))
    write_json(case_dir / 'result.json', case)
    # Disposable test keys and large fixture/history remain outside Git for inspection.
    return case


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-baseline', type=Path)
    parser.add_argument('--switch', type=Path, default=REPO)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--source-tree', type=Path, default=REPO)
    parser.add_argument('--revision', default='HEAD')
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--suite', choices=fixture.TIERS, default='source')
    parser.add_argument('--tiers', default='0,1,2', help='zero-based tier indexes')
    parser.add_argument('--bytes', type=int, help='custom size (requires --files)')
    parser.add_argument('--files', type=int)
    parser.add_argument('--history-nodes', type=int, default=10)
    parser.add_argument('--history-shape', choices=('linear', 'branching'), default='linear')
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--depth', type=int, default=3)
    parser.add_argument('--fanout', type=int, default=8)
    parser.add_argument('--large-file-bytes', type=int, default=0)
    parser.add_argument('--attributes', action='store_true')
    parser.add_argument('--cold', type=int, default=5)
    parser.add_argument('--warmups', type=int, default=3)
    parser.add_argument('--warm', type=int, default=30)
    args = parser.parse_args()
    if args.export_baseline:
        export_baseline(args.export_baseline, args.switch)
        return
    if not args.output or args.history_nodes < 2 or min(args.cold, args.warm, args.warmups) < 0 or not args.cold + args.warm:
        parser.error('require --output, history-nodes >= 2, nonnegative sample counts and at least one sample')
    if (args.bytes is None) != (args.files is None):
        parser.error('--bytes and --files must be supplied together')
    tiers = [(args.bytes, args.files)] if args.bytes is not None else [fixture.TIERS[args.suite][int(i)] for i in args.tiers.split(',')]
    args.source_tree = args.source_tree.resolve()
    args.binary = (args.binary or args.source_tree / '_build/default/bin/yeokcham_v1.exe').resolve()
    revision = output(['git', 'rev-parse', args.revision], REPO)
    verify_source(args.source_tree, revision)
    if not args.binary.is_file():
        raise ValueError(f'build the benchmark executable first: {args.binary}')
    args.output = assert_external(args.output)
    args.output.mkdir(parents=True, exist_ok=False)
    print(f'Selected {tiers}; allow at least 4x live bytes plus retained history, and substantial inode space.', flush=True)
    result = {
        'schema': 'yeokcham-benchmark-run-v1', 'status': 'running',
        'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source_revision': revision, 'source_tree': str(args.source_tree),
        'runner_revision': output(['git', 'rev-parse', 'HEAD'], REPO),
        'runner_sha256': fixture.file_hash(Path(__file__)),
        'generator_sha256': fixture.file_hash(Path(fixture.__file__)),
        'binary_sha256': fixture.file_hash(args.binary), 'invocation': sys.argv,
        'machine': machine(args.output), 'settings': {
            'cold': args.cold, 'warmups': args.warmups, 'warm': args.warm,
            'signer': 'explicit disposable test-file provider, outside worktree',
            'cold_reset': 'fsync + POSIX_FADV_DONTNEED on fixture/store/binary files; advisory, metadata and shared libraries not reset',
            'warm_reset': 'fresh identical repository copy; pre-read fixture/store/binary files; new CLI process each time',
            'ignore': 'no ignore files; all generated paths included',
            'watcher': 'off', 'network': 'none', 'server': 'none',
            'storage': 'existing runtime defaults; no codec/packing changes',
        },
        'not_measured': [
            '1-GiB/full extended tiers unless selected; G19',
            '1000/10000-node deep and branching sessions unless selected; G19',
            'native macOS/Linux/Windows comparisons; G19/G20',
            '10-minute idle CPU and 30-minute interference; G19',
            'Git/codec comparisons and licensed real snapshots; G19',
            'shared sync/review/integration, private archive/eviction, managed background scheduler: target operations not implemented at pinned baseline',
            'device-level I/O bytes unavailable: rusage block counters only; no network operation',
        ], 'cases': [], 'failures': [],
    }
    write_json(args.output / 'summary.json', result)
    try:
        for total_bytes, files in tiers:
            case = run_case(args, args.output / f'{args.suite}-{total_bytes}-{files}', total_bytes, files)
            result['cases'].append(case)
            write_json(args.output / 'summary.json', result)
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['failures'].append(str(error))
        raise
    finally:
        result['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_json(args.output / 'summary.json', result)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(json.dumps({'status': 'error', 'error': str(error)}), file=sys.stderr)
        sys.exit(1)
