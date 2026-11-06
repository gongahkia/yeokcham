#!/usr/bin/env python3
"""Reduce a verified runner result to a small, lossless sample-metric manifest."""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import benchmark_fixture as fixture
import benchmark_runner as runner

COLUMNS = ['operation', 'temperature', 'index', 'seconds', 'cpu_user_seconds',
           'cpu_system_seconds', 'peak_rss_bytes', 'input_blocks', 'output_blocks',
           'stored_file_bytes', 'allocated_bytes', 'stored_files', 'verified_tree_sha256']


def compact(raw):
    if raw['status'] != 'passed' or raw['failures'] or not raw['cases']:
        raise ValueError('only completed, verified runs can be summarized as evidence')
    result = {key: value for key, value in raw.items() if key != 'cases'}
    result['schema'] = 'yeokcham-benchmark-summary-v1'
    result['sample_columns'] = COLUMNS
    result['cases'] = []
    for case in raw['cases']:
        if case['status'] != 'passed' or case['failures']:
            raise ValueError('case contains failures')
        expected = raw['settings']
        for operation in runner.OPERATIONS:
            for temperature, count in [('cold', expected['cold']), ('warm', expected['warm']), ('warmup', expected['warmups'])]:
                observed = [s for s in case['samples'] if s['operation'] == operation and s['temperature'] == temperature]
                if len(observed) != count or {s['index'] for s in observed} != set(range(count)):
                    raise ValueError('incomplete or duplicate sample set')
        reduced = {key: value for key, value in case.items() if key not in ('samples', 'summary')}
        reduced['summary'] = runner.summarize(case['samples'])
        reduced['commands'] = {op: runner.command(Path('$BINARY'), Path('$SAMPLE'), op) for op in runner.OPERATIONS}
        reduced['samples'] = []
        for sample in case['samples']:
            values = dict(sample, stored_file_bytes=sample['storage']['file_bytes'],
                          allocated_bytes=sample['storage']['allocated_bytes'],
                          stored_files=sample['storage']['files'])
            reduced['samples'].append([values[column] for column in COLUMNS])
        reduced['investigation_budgets'] = {
            op: dict(warm_median_seconds=summary['warm']['median_seconds'] * 1.10,
                     warm_p95_seconds=summary['warm']['p95_seconds'] * 1.10,
                     peak_rss_bytes=max(s['peak_rss_bytes'] for s in case['samples'] if s['operation'] == op and s['temperature'] != 'warmup') * 1.15,
                     allocated_bytes=max(s['storage']['allocated_bytes'] for s in case['samples'] if s['operation'] == op and s['temperature'] != 'warmup') * 1.15)
            for op, summary in reduced['summary'].items() if 'warm' in summary
        }
        result['cases'].append(reduced)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = compact(json.loads(args.input.read_text()))
    result['raw_summary_sha256'] = fixture.file_hash(args.input)
    # Compact arrays keep every sample while avoiding repeated long command paths.
    args.output.write_text(json.dumps(result, separators=(',', ':')) + '\n')
    for case in result['cases']:
        print(f"{case['config']['suite']} {case['config']['total_bytes']} bytes / {case['config']['files']} files / {case['history_nodes']} nodes")
        for operation, values in case['summary'].items():
            print(operation, json.dumps(values, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print(json.dumps({'status': 'error', 'error': str(error)}), file=sys.stderr)
        sys.exit(1)
