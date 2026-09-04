#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
benchmark="$repository_root/tools/run-evidence-workspace-benchmark.sh"

fail() {
  printf '%s\n' "evidence-workspace-benchmark-test: $*" >&2
  exit 1
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-evidence-workspace-test.XXXXXX") \
  || fail 'cannot create disposable test directory'
cleanup() {
  rm -r "$scratch"
}
trap cleanup EXIT HUP INT TERM

before_status=$(git -C "$repository_root" status --porcelain)
output="$scratch/output"
"$benchmark" --output "$output" --paths 10 --bytes 1000 --iterations 1
[ -f "$output/profile.txt" ] || fail 'profile was not retained'
[ -f "$output/workspace-runs.tsv" ] || fail 'run measurements were not retained'
[ "$(wc -l < "$output/workspace-runs.tsv" | tr -d ' ')" = 2 ] \
  || fail 'expected one measurement plus TSV header'
awk -F '\t' 'NR == 2 { exit NF == 15 ? 0 : 1 }' "$output/workspace-runs.tsv" \
  || fail 'measurement row does not have the documented TSV columns'
awk -F '\t' 'NR == 2 { exit ($13 ~ /^[0-9]+$/ && $14 ~ /^[0-9]+$/ && $15 ~ /^[0-9]+$/) ? 0 : 1 }' "$output/workspace-runs.tsv" \
  || fail 'measurement row does not retain allocated storage bytes'
grep -F 'paths=10' "$output/profile.txt" >/dev/null \
  || fail 'profile did not retain the exact path count'
grep -F 'logical_bytes=1000' "$output/profile.txt" >/dev/null \
  || fail 'profile did not retain the exact byte count'

if "$benchmark" --output relative --paths 10 --bytes 1000 --iterations 1 >/dev/null 2>&1; then
  fail 'relative output root was accepted'
fi
if "$benchmark" --output "$repository_root/evidence-output" --paths 10 --bytes 1000 --iterations 1 >/dev/null 2>&1; then
  fail 'repository output root was accepted'
fi
if "$benchmark" --output "$scratch/invalid" --paths 1 --bytes 1 --iterations 1 >/dev/null 2>&1; then
  fail 'invalid fixture profile was accepted'
fi

after_status=$(git -C "$repository_root" status --porcelain)
[ "$before_status" = "$after_status" ] \
  || fail 'benchmark changed the source repository'

printf '%s\n' 'evidence workspace benchmark test passed'
