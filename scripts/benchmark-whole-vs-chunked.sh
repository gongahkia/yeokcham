#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  echo "usage: $0 [output-directory] [repetitions]" >&2
  exit 2
fi

benchmark_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
benchmark_root=$(cd -- "$benchmark_script_dir/.." && pwd -P)
benchmark_output=${1:-"$benchmark_root/benchmarks/results/whole-vs-chunked-$(date -u +%Y%m%dT%H%M%SZ)"}
benchmark_repetitions=${2:-5}
benchmark_fixture="$benchmark_root/fixtures/pinned/sha1-history-v1/loose.git"
benchmark_manifest="$benchmark_root/fixtures/pinned/sha1-history-v1/manifest.txt"
benchmark_binary="$benchmark_root/target/release/yeokcham"

[[ "$benchmark_repetitions" =~ ^[1-9][0-9]*$ ]] || {
  echo "repetitions must be a positive integer" >&2
  exit 2
}
[[ -d "$benchmark_fixture" && -f "$benchmark_manifest" ]] || {
  echo "pinned benchmark fixture is unavailable" >&2
  exit 1
}
[[ ! -e "$benchmark_output" && ! -L "$benchmark_output" ]] || {
  echo "benchmark output already exists" >&2
  exit 1
}
for command in cargo git perl shasum sysctl uname df stat /usr/bin/time; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 127
  }
done

benchmark_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-benchmark.XXXXXX")

cleanup() {
  rm -rf -- "$benchmark_temp"
}
trap cleanup EXIT HUP INT TERM

json_string() {
  perl -MJSON::PP -e 'print encode_json($ARGV[0])' "$1"
}

seconds_to_ns() {
  perl -e 'printf "%.0f", $ARGV[0] * 1000000000' "$1"
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

write_result() {
  local policy=$1
  local threshold=$2
  local median_wall=$3
  local p95_wall=$4
  local p99_wall=$5
  local median_cpu=$6
  local peak_rss=$7
  local final_storage=$8
  local result_file="$benchmark_output/$policy.json"
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
  fixture_checksum=$(shasum -a 256 "$benchmark_manifest" | awk '{print $1}')
  if git -C "$benchmark_root" diff --quiet --ignore-submodules --; then dirty=false; else dirty=true; fi
  cat >"$result_file" <<EOF
{
  "schema_version": 1,
  "result_kind": "measured",
  "contains_sensitive_data": false,
  "benchmark_id": "whole-vs-chunked-storage-${policy}",
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
    "memory_bytes": $memory,
    "storage_device": $(json_string "$storage"),
    "filesystem": $(json_string "$filesystem"),
    "available_disk_bytes": $available
  },
  "fixture": {
    "id": "pinned-sha1-history",
    "version": "1",
    "workload": "w3_large_changing_binary",
    "checksum_algorithm": "sha256",
    "checksum": "$fixture_checksum",
    "parameters": {"revisions": 2, "localized_change_lines": 1}
  },
  "configuration": {
    "cache_state": "cold",
    "backend_kind": "local_filesystem",
    "parameters": {"storage_policy": "$policy", "chunked_blob_minimum_bytes": $threshold}
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
    "command": ["yeokcham", "init", "--from-git", "pinned-sha1-history-v1", "--chunked-blob-minimum", "$threshold"]
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

run_policy() {
  local policy=$1
  local threshold=$2
  local values_file="$benchmark_temp/$policy.wall"
  local cpu_values_file="$benchmark_temp/$policy.cpu"
  local rss_values_file="$benchmark_temp/$policy.rss"
  local storage_values_file="$benchmark_temp/$policy.storage"
  local iteration target time_file real user sys wall_ns cpu_ns rss bytes
  target="$benchmark_temp/warmup-$policy"
  "$benchmark_binary" init --from-git "$benchmark_fixture" "$target" --chunked-blob-minimum "$threshold" >/dev/null
  rm -rf -- "$target"
  for (( iteration = 0; iteration < benchmark_repetitions; iteration++ )); do
    target="$benchmark_temp/$policy-$iteration"
    time_file="$benchmark_temp/$policy-$iteration.time"
    /usr/bin/time -l "$benchmark_binary" init --from-git "$benchmark_fixture" "$target" --chunked-blob-minimum "$threshold" >/dev/null 2>"$time_file"
    real=$(time_metric real "$time_file")
    user=$(time_metric user "$time_file")
    sys=$(time_metric sys "$time_file")
    rss=$(time_metric rss "$time_file")
    [[ -n "$real" && -n "$user" && -n "$sys" && -n "$rss" ]] || {
      echo "could not read macOS time metrics" >&2
      exit 1
    }
    wall_ns=$(seconds_to_ns "$real")
    cpu_ns=$(perl -e 'printf "%.0f", ($ARGV[0] + $ARGV[1]) * 1000000000' "$user" "$sys")
    bytes=$(storage_bytes "$target")
    printf '%s\n' "$wall_ns" >>"$values_file"
    printf '%s\n' "$cpu_ns" >>"$cpu_values_file"
    printf '%s\n' "$rss" >>"$rss_values_file"
    printf '%s\n' "$bytes" >>"$storage_values_file"
  done
  sort -n -o "$values_file" "$values_file"
  sort -n -o "$cpu_values_file" "$cpu_values_file"
  sort -n -o "$rss_values_file" "$rss_values_file"
  sort -n -o "$storage_values_file" "$storage_values_file"
  write_result \
    "$policy" \
    "$threshold" \
    "$(quantile_file 0.5 "$values_file")" \
    "$(quantile_file 0.95 "$values_file")" \
    "$(quantile_file 0.99 "$values_file")" \
    "$(quantile_file 0.5 "$cpu_values_file")" \
    "$(quantile_file 1 "$rss_values_file")" \
    "$(quantile_file 0.5 "$storage_values_file")"
}

mkdir -p -- "$benchmark_output"
cargo build --release --locked -p yeokcham-cli
run_policy whole 67108864
run_policy chunked 4096

echo "whole result: $benchmark_output/whole.json"
echo "chunked result: $benchmark_output/chunked.json"
