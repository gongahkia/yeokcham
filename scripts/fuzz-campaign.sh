#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <seconds-per-target> <absent-output-directory>" >&2
  exit 2
fi

fuzz_seconds=$1
fuzz_output=$2
[[ "$fuzz_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "seconds-per-target must be a positive integer" >&2; exit 2; }

fuzz_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fuzz_root=$(cd -- "$fuzz_script_dir/.." && pwd -P)
fuzz_parent=$(dirname -- "$fuzz_output")
fuzz_name=$(basename -- "$fuzz_output")

[[ "$fuzz_name" != . && "$fuzz_name" != .. ]] || { echo "output directory name is invalid" >&2; exit 2; }
mkdir -p -- "$fuzz_parent"
fuzz_parent=$(cd -- "$fuzz_parent" && pwd -P)
fuzz_output="$fuzz_parent/$fuzz_name"
[[ ! -e "$fuzz_output" && ! -L "$fuzz_output" ]] || { echo "output directory already exists: $fuzz_output" >&2; exit 1; }

fuzz_version=$(cargo +nightly fuzz --version 2>/dev/null || true)
[[ "$fuzz_version" == "cargo-fuzz 0.13.2" ]] || {
  echo "cargo-fuzz 0.13.2 with the nightly toolchain is required" >&2
  exit 127
}

cargo +nightly metadata --manifest-path "$fuzz_root/fuzz/Cargo.toml" --locked --format-version=1 >/dev/null
fuzz_workspace_lock_before=$(shasum -a 256 "$fuzz_root/Cargo.lock")
fuzz_lock_before=$(shasum -a 256 "$fuzz_root/fuzz/Cargo.lock")

verify_locks_unchanged() {
  [[ "$(shasum -a 256 "$fuzz_root/Cargo.lock")" == "$fuzz_workspace_lock_before" ]] || {
    echo "fuzz campaign modified Cargo.lock" >&2
    exit 1
  }
  [[ "$(shasum -a 256 "$fuzz_root/fuzz/Cargo.lock")" == "$fuzz_lock_before" ]] || {
    echo "fuzz campaign modified fuzz/Cargo.lock" >&2
    exit 1
  }
}

mkdir -- "$fuzz_output"
mkdir -- "$fuzz_output/artifacts" "$fuzz_output/corpus" "$fuzz_output/logs" "$fuzz_output/target"

for fuzz_target in canonical_decoder segment_reader segment_index manifests refs remote_helper_protocol; do
  mkdir -- "$fuzz_output/artifacts/$fuzz_target"
  cp -R -- "$fuzz_root/fuzz/corpus/$fuzz_target" "$fuzz_output/corpus/$fuzz_target"
  if ! (
    cd -- "$fuzz_root/fuzz"
    cargo +nightly fuzz run --target-dir "$fuzz_output/target" "$fuzz_target" "$fuzz_output/corpus/$fuzz_target" -- \
      -max_total_time="$fuzz_seconds" \
      -artifact_prefix="$fuzz_output/artifacts/$fuzz_target/" \
      -print_final_stats=1
  ) >"$fuzz_output/logs/$fuzz_target.log" 2>&1; then
    echo "fuzz failure for $fuzz_target; inspect $fuzz_output/logs/$fuzz_target.log and $fuzz_output/artifacts/$fuzz_target" >&2
    exit 1
  fi
  verify_locks_unchanged
done

echo "fuzz campaign complete: $fuzz_output"
