#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  echo "usage: $0 [output-directory] [repetitions]" >&2
  exit 2
fi

benchmark_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
benchmark_root=$(cd -- "$benchmark_script_dir/.." && pwd -P)
benchmark_output=${1:-"$benchmark_root/benchmarks/results/parallel-import-$(date -u +%Y%m%dT%H%M%SZ)"}
benchmark_repetitions=${2:-5}
benchmark_binary="$benchmark_root/target/release/yeokcham"
benchmark_object_count=8
benchmark_object_bytes=$((4 * 1024 * 1024))
benchmark_parallel_workers=2

[[ $(uname -s) == Darwin ]] || { echo "this benchmark requires macOS /usr/bin/time -l" >&2; exit 1; }
[[ "$benchmark_repetitions" =~ ^[1-9][0-9]*$ ]] || { echo "repetitions must be a positive integer" >&2; exit 2; }
[[ ! -e "$benchmark_output" && ! -L "$benchmark_output" ]] || { echo "benchmark output already exists" >&2; exit 1; }
for command in cargo git perl shasum sysctl uname df stat /usr/bin/time; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required" >&2; exit 127; }
done

benchmark_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-parallel-import.XXXXXX")
cleanup() {
  rm -rf -- "$benchmark_temp"
}
trap cleanup EXIT HUP INT TERM

json_string() {
  perl -MJSON::PP -e 'print encode_json($ARGV[0])' "$1"
}

seconds_to_ns() {
  perl -e 'printf "%.0f\n", $ARGV[0] * 1000000000' "$1"
}

quantile_file() {
  local fraction=$1
  local file=$2
  local count index
  count=$(wc -l <"$file" | tr -d ' ')
  index=$(perl -e 'use POSIX qw(ceil); print ceil($ARGV[0] * $ARGV[1]) - 1' "$fraction" "$count")
  sed -n "$((index + 1))p" "$file"
}

storage_bytes() {
  du -sk -- "$1" | awk '{print $1 * 1024}'
}

time_metric() {
  local key=$1
  local file=$2
  case "$key" in
    real) awk '/ real / {print $1; exit}' "$file" ;;
    user) awk '/ real / {print $3; exit}' "$file" ;;
    sys) awk '/ real / {print $5; exit}' "$file" ;;
    rss) awk '/maximum resident set size/ {print $1; exit}' "$file" ;;
  esac
}

create_fixture() {
  local fixture=$1
  local index
  mkdir -p -- "$fixture"
  git -C "$fixture" init -b main >/dev/null
  git -C "$fixture" config user.name "Yeokcham Benchmark"
  git -C "$fixture" config user.email "benchmark@example.invalid"
  for (( index = 0; index < benchmark_object_count; index++ )); do
    perl -e '
      use strict;
      use warnings;
      my ($path, $index, $size) = @ARGV;
      open my $file, q{>:raw}, $path or die "open: $!\n";
      print {$file} pack(q{N}, $index);
      print {$file} chr($index % 256) x ($size - 4);
      close $file or die "close: $!\n";
    ' "$fixture/object-$index.bin" "$index" "$benchmark_object_bytes"
  done
  git -C "$fixture" add .
  git -C "$fixture" commit -m "parallel import fixture" >/dev/null
  git -C "$fixture" gc --prune=now >/dev/null
  git -C "$fixture" rev-list --objects --all | LC_ALL=C sort >"$fixture/manifest.txt"
}

write_result() {
  local mode=$1
  local workers=$2
  local median_wall=$3
  local p95_wall=$4
  local p99_wall=$5
  local median_cpu=$6
  local peak_rss=$7
  local final_storage=$8
  local result="$benchmark_output/$mode.json"
  local commit git_version rust_version os_name os_version kernel architecture cpu memory storage filesystem available fixture_checksum dirty
  commit=$(git -C "$benchmark_root" rev-parse HEAD)
  git_version=$(git --version)
  rust_version=$(rustc --version)
  os_name=$(uname -s)
  os_version=$(sw_vers -productVersion 2>/dev/null || uname -r)
  kernel=$(uname -r)
  architecture=$(uname -m)
  cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model)
  memory=$(sysctl -n hw.memsize)
  storage=$(df -P "$benchmark_root" | awk 'NR == 2 {print $1}')
  filesystem=$(stat -f '%T' "$benchmark_root")
  available=$(df -Pk "$benchmark_root" | awk 'NR == 2 {print $4 * 1024}')
  fixture_checksum=$(shasum -a 256 "$benchmark_fixture/manifest.txt" | awk '{print $1}')
  if git -C "$benchmark_root" diff --quiet --ignore-submodules --; then dirty=false; else dirty=true; fi
  cat >"$result" <<EOF
{
  "schema_version": 1,
  "result_kind": "measured",
  "contains_sensitive_data": false,
  "benchmark_id": "local-import-parallel-object-read-${mode}",
  "recorded_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "provenance": {
    "yeokcham_version": $(json_string "$(git -C "$benchmark_root" describe --always --dirty)"),
    "yeokcham_commit": $(json_string "$commit"),
    "worktree_dirty": $dirty,
    "git_version": $(json_string "$git_version"),
    "rust_version": $(json_string "$rust_version"),
    "harness_version": "1"
  },
  "environment": {
    "os_name": $(json_string "$os_name"),
    "os_version": $(json_string "$os_version"),
    "kernel_version": $(json_string "$kernel"),
    "architecture": $(json_string "$architecture"),
    "cpu_model": $(json_string "$cpu"),
    "logical_cpu_count": $(sysctl -n hw.ncpu),
    "memory_bytes": $(sysctl -n hw.memsize),
    "storage_device": $(json_string "$storage"),
    "filesystem": $(json_string "$filesystem"),
    "available_disk_bytes": $available
  },
  "fixture": {
    "id": "parallel-import-large-object-v1",
    "version": "1",
    "workload": "w3_large_changing_binary",
    "checksum_algorithm": "sha256",
    "checksum": "$fixture_checksum",
    "parameters": {"object_count": $benchmark_object_count, "object_bytes": $benchmark_object_bytes, "history_revisions": 1}
  },
  "configuration": {
    "cache_state": "cold",
    "backend_kind": "local_filesystem",
    "parameters": {"object_read_workers": $workers, "chunked_blob_minimum_bytes": 67108864}
  },
  "network_conditions": {
    "mode": "local",
    "description": "local filesystem only",
    "round_trip_latency_ms": 0,
    "packet_loss_percent": 0,
    "bandwidth_limit_bytes_per_second": null
  },
  "run": {
    "started_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "ended_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "repetitions": $benchmark_repetitions,
    "warmup_repetitions": 1,
    "command": ["yeokcham", "init", "--from-git", "parallel-import-large-object-v1", "--chunked-blob-minimum", "67108864", "--object-read-workers", "$workers"]
  },
  "metrics": {
    "median_wall_time_ns": $median_wall,
    "p95_wall_time_ns": $p95_wall,
    "p99_wall_time_ns": $p99_wall,
    "median_cpu_time_ns": $median_cpu,
    "peak_rss_bytes": $peak_rss,
    "io_bytes_read": null,
    "io_bytes_written": null,
    "network_request_count": 0,
    "network_bytes_sent": 0,
    "network_bytes_received": 0,
    "final_storage_bytes": $final_storage
  }
}
EOF
}

run_mode() {
  local mode=$1
  local workers=$2
  local values="$benchmark_temp/$mode.wall"
  local cpu_values="$benchmark_temp/$mode.cpu"
  local rss_values="$benchmark_temp/$mode.rss"
  local storage_values="$benchmark_temp/$mode.storage"
  local iteration target time_file real user sys rss
  target="$benchmark_temp/warmup-$mode"
  "$benchmark_binary" init --from-git "$benchmark_fixture" "$target" --chunked-blob-minimum 67108864 --object-read-workers "$workers" >/dev/null
  rm -rf -- "$target"
  for (( iteration = 0; iteration < benchmark_repetitions; iteration++ )); do
    target="$benchmark_temp/$mode-$iteration"
    time_file="$benchmark_temp/$mode-$iteration.time"
    /usr/bin/time -l "$benchmark_binary" init --from-git "$benchmark_fixture" "$target" --chunked-blob-minimum 67108864 --object-read-workers "$workers" >/dev/null 2>"$time_file"
    real=$(time_metric real "$time_file")
    user=$(time_metric user "$time_file")
    sys=$(time_metric sys "$time_file")
    rss=$(time_metric rss "$time_file")
    [[ -n "$real" && -n "$user" && -n "$sys" && -n "$rss" ]] || { echo "could not read macOS time metrics" >&2; exit 1; }
    seconds_to_ns "$real" >>"$values"
    perl -e 'printf "%.0f\n", ($ARGV[0] + $ARGV[1]) * 1000000000' "$user" "$sys" >>"$cpu_values"
    printf '%s\n' "$rss" >>"$rss_values"
    storage_bytes "$target" >>"$storage_values"
  done
  sort -n -o "$values" "$values"
  sort -n -o "$cpu_values" "$cpu_values"
  sort -n -o "$rss_values" "$rss_values"
  sort -n -o "$storage_values" "$storage_values"
  write_result "$mode" "$workers" "$(quantile_file 0.5 "$values")" "$(quantile_file 0.95 "$values")" "$(quantile_file 0.99 "$values")" "$(quantile_file 0.5 "$cpu_values")" "$(quantile_file 1 "$rss_values")" "$(quantile_file 0.5 "$storage_values")"
}

cargo build --release --locked -p yeokcham-cli
benchmark_fixture="$benchmark_temp/fixture"
create_fixture "$benchmark_fixture"
mkdir -p -- "$benchmark_output"
run_mode serial 1
run_mode parallel "$benchmark_parallel_workers"

echo "serial result: $benchmark_output/serial.json"
echo "parallel result: $benchmark_output/parallel.json"
