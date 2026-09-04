#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
summary="$repository_root/tools/summarize-evidence-workspace-benchmark.sh"

fail() {
  printf '%s\n' "evidence-workspace-summary-test: $*" >&2
  exit 1
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-evidence-workspace-summary-test.XXXXXX") \
  || fail 'cannot create disposable test directory'
cleanup() {
  rm -r "$scratch"
}
trap cleanup EXIT HUP INT TERM

before_status=$(git -C "$repository_root" status --porcelain)
printf '%s\n' \
  'source_revision=0123456789abcdef0123456789abcdef01234567' \
  'paths=100000' \
  'logical_bytes=5368709120' \
  'iterations=5' > "$scratch/profile.txt"
printf '%s\n' \
  'iteration	paths	logical_bytes	init_s	prepare_s	package_s	bootstrap_s	activate_s	wall_s	user_cpu_s	system_cpu_s	max_rss_kib	source_v4_disk_bytes	package_disk_bytes	target_v4_disk_bytes' \
  '1	100000	5368709120	5	4	3	2	1	20	10	9	100	500	400	300' \
  '2	100000	5368709120	1	2	3	4	5	16	6	7	200	100	300	200' \
  '3	100000	5368709120	3	3	3	3	3	18	8	8	300	300	100	500' \
  '4	100000	5368709120	2	1	3	5	4	17	7	6	400	200	500	400' \
  '5	100000	5368709120	4	5	3	1	2	19	9	10	500	400	200	100' \
  > "$scratch/workspace-runs.tsv"

output=$("$summary" --input "$scratch/workspace-runs.tsv" --iterations 5)
printf '%s\n' "$output" | grep -Fx 'metric=init_s	median=3	p95_nearest_rank=5' >/dev/null \
  || fail 'summary did not report the expected median and p95'
printf '%s\n' "$output" | grep -Fx 'metric=source_v4_disk_bytes	median=300	p95_nearest_rank=500' >/dev/null \
  || fail 'summary did not report storage statistics'

if "$summary" --input relative --iterations 5 >/dev/null 2>&1; then
  fail 'relative input was accepted'
fi
if "$summary" --input "$scratch/workspace-runs.tsv" --iterations 4 >/dev/null 2>&1; then
  fail 'even iteration count was accepted'
fi
sed '$d' "$scratch/workspace-runs.tsv" > "$scratch/incomplete.tsv"
if "$summary" --input "$scratch/incomplete.tsv" --iterations 5 >/dev/null 2>&1; then
  fail 'incomplete measurements were accepted'
fi

after_status=$(git -C "$repository_root" status --porcelain)
[ "$before_status" = "$after_status" ] \
  || fail 'summary changed the source repository'

printf '%s\n' 'evidence workspace summary test passed'
