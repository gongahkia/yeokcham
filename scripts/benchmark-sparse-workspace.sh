#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  echo "usage: $0 [output-directory] [repetitions]" >&2
  exit 2
fi

benchmark_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
benchmark_root=$(cd -- "$benchmark_script_dir/.." && pwd -P)
benchmark_output=${1:-"$benchmark_root/benchmarks/results/sparse-workspace-$(date -u +%Y%m%dT%H%M%SZ)"}
benchmark_repetitions=${2:-5}
benchmark_binary_directory="$benchmark_root/target/release"
benchmark_binary="$benchmark_binary_directory/yeokcham"
fixture_generator="$benchmark_script_dir/generate-sparse-workspace-fixture.sh"

[[ $(uname -s) == Darwin ]] || {
  echo "this benchmark currently requires macOS /usr/bin/time -l" >&2
  exit 1
}
[[ "$benchmark_repetitions" =~ ^[1-9][0-9]*$ ]] || {
  echo "repetitions must be a positive integer" >&2
  exit 2
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

benchmark_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-sparse-benchmark.XXXXXX")

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

pack_bytes() {
  find "$1/.git/objects/pack" -type f -name '*.pack' -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }'
}

pack_count() {
  find "$1/.git/objects/pack" -type f -name '*.pack' | wc -l | tr -d ' '
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

run_sparse_workflow() {
  local target=$1
  local time_file=$2
  /usr/bin/time -l env "PATH=$benchmark_binary_directory:$PATH" /bin/sh -c '
    git clone --no-checkout --filter=blob:none "yeokcham::$1" "$2"
    git -C "$2" sparse-checkout set --cone app
    git -C "$2" checkout main
  ' sparse-workspace "$benchmark_store" "$target" >/dev/null 2>"$time_file"
  [[ -f "$target/app/main.txt" && ! -e "$target/assets/current.bin" && ! -e "$target/history/obsolete.bin" ]] || {
    echo "sparse workflow did not produce the expected workspace" >&2
    exit 1
  }
}

write_result() {
  local state=$1
  local started_at=$2
  local ended_at=$3
  local median_wall=$4
  local p95_wall=$5
  local p99_wall=$6
  local median_cpu=$7
  local peak_rss=$8
  local median_pack_count=$9
  local median_pack_bytes=${10}
  local median_storage=${11}
  local result_file="$benchmark_output/$state.json"
  local commit git_version rust_version os_name os_version kernel architecture cpu memory storage filesystem available fixture_checksum dirty
  commit=$(git -C "$benchmark_root" rev-parse HEAD)
  git_version=$(git --version)
  rust_version=$(rustc --version)
  os_name=$(uname -s)
  os_version=$(sw_vers -productVersion)
  kernel=$(uname -r)
  architecture=$(uname -m)
  cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model)
  memory=$(sysctl -n hw.memsize)
  storage=$(df -P "$benchmark_root" | awk 'NR == 2 {print $1}')
  filesystem=$(stat -f '%T' "$benchmark_root")
  available=$(df -Pk "$benchmark_root" | awk 'NR == 2 {print $4 * 1024}')
  fixture_checksum=$(shasum -a 256 "$benchmark_fixture/manifest.txt" | awk '{print $1}')
  if git -C "$benchmark_root" diff --quiet --ignore-submodules --; then dirty=false; else dirty=true; fi
  cat >"$result_file" <<EOF
{
  "schema_version": 1,
  "result_kind": "measured",
  "contains_sensitive_data": false,
  "benchmark_id": "local-helper-sparse-workspace-${state}",
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
    "id": "generated-sparse-workspace",
    "version": "1",
    "workload": "w5_monorepo_sparse_workspace",
    "checksum_algorithm": "sha256",
    "checksum": "$fixture_checksum",
    "parameters": {"revisions": 2, "selected_paths": 1, "excluded_current_bytes": 4194304, "excluded_historical_bytes": 4194304}
  },
  "configuration": {
    "cache_state": "$state",
    "backend_kind": "local_remote_helper",
    "parameters": {"filter": "blob:none", "sparse_mode": "cone", "sparse_paths": ["app"], "cache_layer": "snapshot-pack", "transport_metric": "client .pack payload bytes"}
  },
  "network_conditions": {
    "mode": "local",
    "description": "local git-remote-yeokcham process transport; received pack payload bytes are recorded below",
    "round_trip_latency_ms": 0,
    "packet_loss_percent": 0,
    "bandwidth_limit_bytes_per_second": null
  },
  "run": {
    "started_at": "$started_at",
    "ended_at": "$ended_at",
    "repetitions": $benchmark_repetitions,
    "warmup_repetitions": 1,
    "command": ["git", "clone --no-checkout --filter=blob:none yeokcham::<store> <target>", "git sparse-checkout set --cone app", "git checkout main"]
  },
  "metrics": {
    "median_wall_time_ns": $median_wall,
    "p95_wall_time_ns": $p95_wall,
    "p99_wall_time_ns": $p99_wall,
    "median_cpu_time_ns": $median_cpu,
    "peak_rss_bytes": $peak_rss,
    "io_bytes_read": null,
    "io_bytes_written": null,
    "network_request_count": $median_pack_count,
    "network_bytes_sent": 0,
    "network_bytes_received": $median_pack_bytes,
    "final_storage_bytes": $median_storage
  }
}
EOF
}

run_state() {
  local state=$1
  local wall_values="$benchmark_temp/$state.wall"
  local cpu_values="$benchmark_temp/$state.cpu"
  local rss_values="$benchmark_temp/$state.rss"
  local pack_count_values="$benchmark_temp/$state.pack-count"
  local pack_bytes_values="$benchmark_temp/$state.pack-bytes"
  local storage_values="$benchmark_temp/$state.storage"
  local iteration target time_file real user sys rss started_at ended_at
  "$benchmark_binary" cache clear "$benchmark_store" >/dev/null
  target="$benchmark_temp/$state-warmup"
  run_sparse_workflow "$target" "$benchmark_temp/$state-warmup.time"
  rm -rf -- "$target"
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  for (( iteration = 0; iteration < benchmark_repetitions; iteration++ )); do
    if [[ "$state" == cold ]]; then
      "$benchmark_binary" cache clear "$benchmark_store" >/dev/null
    fi
    target="$benchmark_temp/$state-$iteration"
    time_file="$benchmark_temp/$state-$iteration.time"
    run_sparse_workflow "$target" "$time_file"
    real=$(time_metric real "$time_file")
    user=$(time_metric user "$time_file")
    sys=$(time_metric sys "$time_file")
    rss=$(time_metric rss "$time_file")
    [[ -n "$real" && -n "$user" && -n "$sys" && -n "$rss" ]] || {
      echo "could not read macOS time metrics" >&2
      exit 1
    }
    seconds_to_ns "$real" >>"$wall_values"
    perl -e 'printf "%.0f\n", ($ARGV[0] + $ARGV[1]) * 1000000000' "$user" "$sys" >>"$cpu_values"
    printf '%s\n' "$rss" >>"$rss_values"
    pack_count "$target" >>"$pack_count_values"
    pack_bytes "$target" >>"$pack_bytes_values"
    storage_bytes "$target" >>"$storage_values"
  done
  ended_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  for file in "$wall_values" "$cpu_values" "$rss_values" "$pack_count_values" "$pack_bytes_values" "$storage_values"; do
    sort -n -o "$file" "$file"
  done
  write_result \
    "$state" \
    "$started_at" \
    "$ended_at" \
    "$(quantile_file 0.5 "$wall_values")" \
    "$(quantile_file 0.95 "$wall_values")" \
    "$(quantile_file 0.99 "$wall_values")" \
    "$(quantile_file 0.5 "$cpu_values")" \
    "$(quantile_file 1 "$rss_values")" \
    "$(quantile_file 0.5 "$pack_count_values")" \
    "$(quantile_file 0.5 "$pack_bytes_values")" \
    "$(quantile_file 0.5 "$storage_values")"
}

benchmark_fixture="$benchmark_temp/fixture"
benchmark_store="$benchmark_temp/store"
"$fixture_generator" "$benchmark_fixture" >/dev/null
cargo build --release --locked -p yeokcham-cli
"$benchmark_binary" init --from-git "$benchmark_fixture/loose.git" "$benchmark_store" >/dev/null
mkdir -p -- "$benchmark_output"
run_state cold
run_state warm

echo "cold result: $benchmark_output/cold.json"
echo "warm result: $benchmark_output/warm.json"
