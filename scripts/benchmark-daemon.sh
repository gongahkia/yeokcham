#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then echo "usage: $0 [output-directory] [repetitions]" >&2; exit 2; fi
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$script_dir/.." && pwd -P)
output=${1:-"$root/benchmarks/results/daemon-$(date -u +%Y%m%dT%H%M%SZ)"}
repetitions=${2:-5}
binary="$root/target/release/yeokcham-daemon"
[[ $(uname -s) == Darwin ]] || { echo "this benchmark requires macOS /usr/bin/time -l" >&2; exit 1; }
[[ "$repetitions" =~ ^[1-9][0-9]*$ && ! -e "$output" && ! -L "$output" ]] || { echo "invalid repetitions or existing output" >&2; exit 2; }
for command in cargo perl /usr/bin/time sysctl uname sw_vers df stat git shasum; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 127; }; done
temporary=$(mktemp -d "${TMPDIR:?TMPDIR is required}/yeokcham-daemon-benchmark.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT HUP INT TERM
json() { perl -MJSON::PP -e 'print encode_json($ARGV[0])' "$1"; }
ns() { perl -e 'printf "%.0f\n", $ARGV[0] * 1000000000' "$1"; }
quantile() { local fraction=$1 file=$2 count index; count=$(wc -l <"$file" | tr -d ' '); index=$(perl -e 'use POSIX qw(ceil); print ceil($ARGV[0] * $ARGV[1]) - 1' "$fraction" "$count"); sed -n "$((index + 1))p" "$file"; }
metric() { local key=$1 file=$2; case "$key" in real) awk '/ real / {print $1; exit}' "$file";; user) awk '/ real / {print $3; exit}' "$file";; sys) awk '/ real / {print $5; exit}' "$file";; rss) awk '/maximum resident set size/ {print $1; exit}' "$file";; esac; }
request() {
  local socket=$1 tag=$2 expected=$3
  perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '
    my ($path, $tag, $expected) = @ARGV;
    my $socket;
    for (1..100) { $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) and last; select undef, undef, undef, 0.01; }
    die "daemon socket did not become ready\n" unless $socket;
    my $frame = pack("Na4nCCQ>", 16, "YKDP", 1, 1, $tag, 1);
    print {$socket} $frame or die "write failed\n";
    my $response = q{};
    while (length($response) < 20) { my $read = read($socket, my $part, 20 - length($response)); defined $read && $read > 0 or die "read failed\n"; $response .= $part; }
    my ($length, $magic, $version, $direction, $message, $id) = unpack("Na4nCCQ>", $response);
    die "invalid daemon response\n" unless $length == 16 && $magic eq "YKDP" && $version == 1 && $direction == 2 && $message == $expected && $id == 1;
  ' "$socket" "$tag" "$expected"
}
cargo build --release --locked -p yeokcham-daemon >/dev/null
mkdir -p -- "$output"
wall="$temporary/wall"; cpu="$temporary/cpu"; rss="$temporary/rss"; started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for ((iteration=0; iteration<repetitions; iteration++)); do
  socket="$temporary/$iteration.sock"; time_file="$temporary/$iteration.time"
  /usr/bin/time -l -o "$time_file" "$binary" --socket "$socket" >"$temporary/$iteration.out" 2>"$temporary/$iteration.err" & pid=$!
  request "$socket" 1 1
  request "$socket" 2 2
  wait "$pid"
  real=$(metric real "$time_file"); user=$(metric user "$time_file"); sys=$(metric sys "$time_file"); peak=$(metric rss "$time_file")
  [[ -n "$real" && -n "$user" && -n "$sys" && -n "$peak" ]] || { echo "could not parse macOS time metrics" >&2; exit 1; }
  ns "$real" >>"$wall"; perl -e 'printf "%.0f\n", ($ARGV[0] + $ARGV[1]) * 1000000000' "$user" "$sys" >>"$cpu"; printf '%s\n' "$peak" >>"$rss"
done
ended=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); sort -n -o "$wall" "$wall"; sort -n -o "$cpu" "$cpu"; sort -n -o "$rss" "$rss"
commit=$(git -C "$root" rev-parse HEAD); dirty=false; git -C "$root" diff --quiet --ignore-submodules -- || dirty=true
cat >"$output/startup.json" <<EOF
{"schema_version":1,"result_kind":"measured","contains_sensitive_data":false,"benchmark_id":"local-daemon-startup","recorded_at":"$ended","provenance":{"yeokcham_version":$(json "$(git -C "$root" describe --always --dirty)"),"yeokcham_commit":$(json "$commit"),"worktree_dirty":$dirty,"git_version":$(json "$(git --version)"),"rust_version":$(json "$(rustc --version)"),"harness_version":"1"},"environment":{"os_name":$(json "$(uname -s)"),"os_version":$(json "$(sw_vers -productVersion)"),"kernel_version":$(json "$(uname -r)"),"architecture":$(json "$(uname -m)"),"cpu_model":$(json "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model)"),"logical_cpu_count":$(sysctl -n hw.ncpu),"memory_bytes":$(sysctl -n hw.memsize),"storage_device":$(json "$(df -P "$root" | awk 'NR == 2 {print $1}')"),"filesystem":$(json "$(stat -f '%T' "$root")"),"available_disk_bytes":$(df -Pk "$root" | awk 'NR == 2 {print $4 * 1024}')},"fixture":{"id":"daemon-protocol-v1","version":"1","workload":"daemon_start_ping_shutdown","checksum_algorithm":"sha256","checksum":"$(printf 'YKDP-v1-ping-shutdown' | shasum -a 256 | awk '{print $1}')","parameters":{"messages":2,"socket_transport":"unix"}},"configuration":{"cache_state":"not_applicable","backend_kind":"local_daemon","parameters":{"socket":"private temporary Unix socket","protocol":"YKDP-v1"}},"network_conditions":{"mode":"local","description":"private AF_UNIX socket; no network listener","round_trip_latency_ms":0,"packet_loss_percent":0,"bandwidth_limit_bytes_per_second":null},"run":{"started_at":"$started","ended_at":"$ended","repetitions":$repetitions,"warmup_repetitions":0,"command":["yeokcham-daemon --socket <private-temp-socket>","YKDP ping","YKDP shutdown"]},"metrics":{"median_wall_time_ns":$(quantile 0.5 "$wall"),"p95_wall_time_ns":$(quantile 0.95 "$wall"),"p99_wall_time_ns":$(quantile 0.99 "$wall"),"median_cpu_time_ns":$(quantile 0.5 "$cpu"),"peak_rss_bytes":$(quantile 1 "$rss"),"io_bytes_read":null,"io_bytes_written":null,"network_request_count":0,"network_bytes_sent":0,"network_bytes_received":0,"final_storage_bytes":0}}
EOF
echo "startup result: $output/startup.json"
