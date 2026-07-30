#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [runs-per-target]" >&2
  exit 2
fi

runs=${1:-1000}
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || {
  echo "runs-per-target must be a positive integer" >&2
  exit 2
}

fuzz_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fuzz_root=$(cd -- "$fuzz_script_dir/.." && pwd -P)

cd "$fuzz_root/fuzz"
for target in canonical_decoder segment_reader segment_index manifests refs; do
  cargo +nightly fuzz run "$target" -- -runs="$runs"
done
