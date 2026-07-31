#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  echo "usage: $0 <baseline-result.json> <candidate-result.json> <maximum-regression-percent>" >&2
  exit 2
fi

benchmark_baseline=$1
benchmark_candidate=$2
benchmark_limit=$3
[[ -f "$benchmark_baseline" && ! -L "$benchmark_baseline" ]] || { echo "baseline must be a regular file" >&2; exit 2; }
[[ -f "$benchmark_candidate" && ! -L "$benchmark_candidate" ]] || { echo "candidate must be a regular file" >&2; exit 2; }

perl -MJSON::PP -e '
  use strict;
  use warnings;

  my ($baseline_path, $candidate_path, $limit) = @ARGV;
  $limit =~ /\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/ or die "maximum-regression-percent must be a non-negative decimal\n";
  my $decoder = JSON::PP->new->utf8;
  sub read_json {
    my ($path) = @_;
    open my $file, "<:raw", $path or die "open $path: $!\n";
    local $/;
    return $decoder->decode(<$file>);
  }
  my $baseline = read_json($baseline_path);
  my $candidate = read_json($candidate_path);
  for my $result ($baseline, $candidate) {
    ref($result) eq "HASH" or die "benchmark result must be a JSON object\n";
    $result->{schema_version} == 1 or die "benchmark result must use schema version 1\n";
    $result->{result_kind} eq "measured" or die "benchmark result must be measured\n";
    !$result->{contains_sensitive_data} or die "benchmark result must not contain sensitive data\n";
  }
  my $canonical = JSON::PP->new->canonical;
  for my $field (qw(benchmark_id fixture configuration network_conditions)) {
    $canonical->encode($baseline->{$field}) eq $canonical->encode($candidate->{$field})
      or die "incomparable benchmark $field\n";
  }
  for my $field (qw(os_name os_version kernel_version architecture cpu_model logical_cpu_count memory_bytes storage_device filesystem)) {
    ($baseline->{environment}{$field} // "") eq ($candidate->{environment}{$field} // "")
      or die "incomparable benchmark environment.$field\n";
  }
  $baseline->{run}{repetitions} == $candidate->{run}{repetitions}
    or die "incomparable benchmark run.repetitions\n";
  my @metrics = qw(
    median_wall_time_ns p95_wall_time_ns p99_wall_time_ns median_cpu_time_ns peak_rss_bytes
    network_request_count network_bytes_sent network_bytes_received final_storage_bytes
  );
  my $failed = 0;
  for my $metric (@metrics) {
    my $old = $baseline->{metrics}{$metric};
    my $new = $candidate->{metrics}{$metric};
    defined($old) && defined($new) && $old =~ /\A[0-9]+\z/ && $new =~ /\A[0-9]+\z/
      or die "invalid metric $metric\n";
    if ($old == 0) {
      if ($new != 0) {
        warn "$metric regressed: baseline=0 candidate=$new\n";
        $failed = 1;
      }
      next;
    }
    my $allowed = $old * (1 + $limit / 100);
    if ($new > $allowed) {
      warn "$metric regressed: baseline=$old candidate=$new limit=${limit}%\n";
      $failed = 1;
    }
  }
  exit($failed ? 1 : 0);
' "$benchmark_baseline" "$benchmark_candidate" "$benchmark_limit"
