#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <expected-git-version>" >&2
  exit 2
fi

expected_version=$1
actual_version=$(git version)
if [[ "$actual_version" != "git version $expected_version" ]]; then
  echo "Git version does not match the requested integration matrix entry" >&2
  exit 1
fi

cargo test -p yeokcham-cli --test tracing \
  remote_helper_clones_lists_refs_and_repeats_fetch_without_source_disclosure -- --exact
