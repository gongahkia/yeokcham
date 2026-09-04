#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

usage() {
  printf '%s\n' \
    'usage: tools/summarize-evidence-workspace-benchmark.sh --input ABSOLUTE_WORKSPACE_RUNS_TSV --iterations ODD_COUNT' >&2
  exit 2
}

fail() {
  printf '%s\n' "evidence-workspace-summary: $*" >&2
  exit 2
}

input=
iterations=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=${2-}; shift 2 ;;
    --iterations) iterations=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$input" ] && [ -n "$iterations" ] || usage
case "$input" in
  /*) ;;
  *) fail '--input must be absolute' ;;
esac
case "$iterations" in
  *[!0123456789]* | '') fail '--iterations must be a positive odd integer' ;;
esac
[ "$iterations" -gt 0 ] && [ $((iterations % 2)) -eq 1 ] \
  || fail '--iterations must be a positive odd integer'
[ -f "$input" ] || fail "input is not a regular file: $input"

expected_header='iteration	paths	logical_bytes	init_s	prepare_s	package_s	bootstrap_s	activate_s	wall_s	user_cpu_s	system_cpu_s	max_rss_kib	source_v4_disk_bytes	package_disk_bytes	target_v4_disk_bytes'
actual_header=$(sed -n '1p' "$input")
[ "$actual_header" = "$(printf '%b' "$expected_header")" ] \
  || fail 'input header does not match workspace-runs.tsv schema version 1'

awk -F '\t' -v iterations="$iterations" '
  BEGIN { failed = 0 }
  NR > 1 {
    if (NF != 15 || $1 != NR - 1 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) {
      failed = 1
      next
    }
    for (field = 4; field <= 15; field++) {
      if ($field !~ /^[0-9]+([.][0-9]+)?$/) failed = 1
    }
    if (NR == 2) {
      paths = $2
      logical_bytes = $3
    } else if ($2 != paths || $3 != logical_bytes) {
      failed = 1
    }
  }
  END {
    if (NR != iterations + 1 || failed) exit 1
  }
' "$input" || fail 'input rows are malformed, inconsistent, or incomplete'

profile=$(dirname -- "$input")/profile.txt
[ -f "$profile" ] || fail "profile.txt is absent beside input: $profile"
source_revision=$(sed -n 's/^source_revision=//p' "$profile")
profile_paths=$(sed -n 's/^paths=//p' "$profile")
profile_bytes=$(sed -n 's/^logical_bytes=//p' "$profile")
profile_iterations=$(sed -n 's/^iterations=//p' "$profile")
case "$source_revision" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) fail 'profile source_revision is not a lowercase 40-hex commit ID' ;;
esac

paths=$(awk -F '\t' 'NR == 2 { print $2 }' "$input")
logical_bytes=$(awk -F '\t' 'NR == 2 { print $3 }' "$input")
[ "$profile_paths" = "$paths" ] \
  || fail 'profile path count does not match measurement rows'
[ "$profile_bytes" = "$logical_bytes" ] \
  || fail 'profile logical byte count does not match measurement rows'
[ "$profile_iterations" = "$iterations" ] \
  || fail 'profile iteration count does not match requested summary count'

metric_summary() {
  column=$1
  name=$2
  values=$(mktemp "${TMPDIR:-/tmp}/yeokcham-evidence-workspace-summary.XXXXXX") \
    || fail 'cannot create disposable summary file'
  trap 'rm -r "$values"' EXIT HUP INT TERM
  awk -F '\t' -v column="$column" 'NR > 1 { print $column }' "$input" \
    | sort -n > "$values"
  median_rank=$(((iterations + 1) / 2))
  p95_rank=$(((95 * iterations + 99) / 100))
  median=$(sed -n "${median_rank}p" "$values")
  p95=$(sed -n "${p95_rank}p" "$values")
  printf 'metric=%s\tmedian=%s\tp95_nearest_rank=%s\n' "$name" "$median" "$p95"
  rm -r "$values"
  trap - EXIT HUP INT TERM
}

printf '%s\n' 'schema_version=1'
printf '%s\n' "source_revision=$source_revision"
printf '%s\n' "iterations=$iterations"
printf '%s\n' "paths=$paths"
printf '%s\n' "logical_bytes=$logical_bytes"
metric_summary 4 init_s
metric_summary 5 prepare_s
metric_summary 6 package_s
metric_summary 7 bootstrap_s
metric_summary 8 activate_s
metric_summary 9 wall_s
metric_summary 10 user_cpu_s
metric_summary 11 system_cpu_s
metric_summary 12 max_rss_kib
metric_summary 13 source_v4_disk_bytes
metric_summary 14 package_disk_bytes
metric_summary 15 target_v4_disk_bytes
