#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
  echo "usage: $0" >&2
  exit 2
fi

audit_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
audit_root=$(cd -- "$audit_script_dir/.." && pwd -P)
audit_cargo=${CARGO:-cargo}

command -v "$audit_cargo" >/dev/null || { echo "cargo is required" >&2; exit 127; }
audit_version=$($audit_cargo audit --version 2>/dev/null || true)
[[ "$audit_version" == "cargo-audit-audit 0.22.2" ]] || {
  echo "cargo-audit 0.22.2 is required; install with: cargo install cargo-audit --version 0.22.2 --locked" >&2
  exit 127
}

audit_options=(--deny warnings)
if [[ ${YEOKCHAM_AUDIT_OFFLINE:-0} == 1 ]]; then
  audit_options+=(--no-fetch --stale)
fi

"$audit_cargo" audit "${audit_options[@]}" --file "$audit_root/Cargo.lock"
"$audit_cargo" audit "${audit_options[@]}" --file "$audit_root/fuzz/Cargo.lock"
