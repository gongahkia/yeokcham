#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generator="$repository_root/_build/default/bench/evidence_fixture_generator.exe"
scenario="$repository_root/_build/default/bench/evidence_workspace_scenario.exe"

fail() {
  printf '%s\n' "evidence-workspace-benchmark: $*" >&2
  exit 2
}

usage() {
  printf '%s\n' \
    'usage: tools/run-evidence-workspace-benchmark.sh --output ABSOLUTE_DIRECTORY --paths COUNT --bytes COUNT --iterations COUNT' >&2
  exit 2
}

output=
paths=
bytes=
iterations=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=${2-}; shift 2 ;;
    --paths) paths=${2-}; shift 2 ;;
    --bytes) bytes=${2-}; shift 2 ;;
    --iterations) iterations=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$output" ] && [ -n "$paths" ] && [ -n "$bytes" ] && [ -n "$iterations" ] \
  || usage
case "$output" in
  /*) ;;
  *) fail '--output must be absolute' ;;
esac
case "$paths:$bytes:$iterations" in
  *[!0123456789:]* | :* | *::*) fail 'counts must be positive base-10 integers' ;;
esac
[ "$paths" -gt 0 ] && [ "$bytes" -gt 0 ] && [ "$iterations" -gt 0 ] \
  || fail 'counts must be positive'
[ -x "$generator" ] && [ -x "$scenario" ] \
  || fail 'build the benchmark executables first with opam exec -- dune build @all'
[ "$(uname)" = Linux ] || fail 'this measurement harness requires Linux /usr/bin/time'

output_parent=$(dirname -- "$output")
output_name=$(basename -- "$output")
[ -d "$output_parent" ] || fail '--output parent must already exist'
output_parent=$(cd -- "$output_parent" && pwd -P)
output="$output_parent/$output_name"
case "$output" in
  "$repository_root" | "$repository_root"/*)
    fail '--output resolves inside the source repository'
    ;;
esac
[ ! -e "$output" ] || fail '--output must not exist'
mkdir "$output"

results="$output/workspace-runs.tsv"
printf '%s\n' 'iteration\tpaths\tlogical_bytes\tinit_s\tprepare_s\tpackage_s\tbootstrap_s\tactivate_s\twall_s\tuser_cpu_s\tsystem_cpu_s\tmax_rss_kib' > "$results"
printf '%s\n' "source_revision=$(git -C "$repository_root" rev-parse HEAD)" > "$output/profile.txt"
printf '%s\n' "paths=$paths" >> "$output/profile.txt"
printf '%s\n' "logical_bytes=$bytes" >> "$output/profile.txt"
printf '%s\n' "iterations=$iterations" >> "$output/profile.txt"

iteration=1
while [ "$iteration" -le "$iterations" ]; do
  run="$output/run-$iteration"
  mkdir "$run" "$run/source" "$run/target"
  "$generator" --root "$run/source" --paths "$paths" --bytes "$bytes" > "$run/fixture.txt"
  /usr/bin/time -f '%e\t%U\t%S\t%M' -o "$run/resources.tsv" \
    "$scenario" --source "$run/source" --target "$run/target" --package "$run/package" \
    > "$run/scenario.txt"
  target_entries=$(find "$run/target" -path "$run/target/.yeokcham" -prune -o -mindepth 1 -print | wc -l | tr -d ' ')
  [ "$target_entries" = "$paths" ] \
    || fail "workspace activation did not materialise $paths exact entries"
  diff -qr --exclude .yeokcham "$run/source" "$run/target" >/dev/null \
    || fail 'workspace activation did not reproduce the source fixture exactly'
  init_seconds=$(sed -n 's/^source_init_seconds=//p' "$run/scenario.txt")
  prepare_seconds=$(sed -n 's/^bootstrap_prepare_seconds=//p' "$run/scenario.txt")
  package_seconds=$(sed -n 's/^package_materialize_seconds=//p' "$run/scenario.txt")
  bootstrap_seconds=$(sed -n 's/^bootstrap_seconds=//p' "$run/scenario.txt")
  activate_seconds=$(sed -n 's/^workspace_activate_seconds=//p' "$run/scenario.txt")
  resources=$(cat "$run/resources.tsv")
  printf '%s\n' "$iteration\t$paths\t$bytes\t$init_seconds\t$prepare_seconds\t$package_seconds\t$bootstrap_seconds\t$activate_seconds\t$resources" >> "$results"
  rm -r "$run"
  iteration=$((iteration + 1))
done

printf '%s\n' "workspace evidence written to $results"
