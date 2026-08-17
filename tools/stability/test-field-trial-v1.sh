#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
runner=$repository_root/tools/stability/record-field-trial-v1.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-field-trial-test.XXXXXX")
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

sh -n "$runner"

if sh "$runner" --platform unknown --release-version 1.0.0 --evidence-dir "$temporary" >/dev/null 2>&1; then
  printf '%s\n' 'field-trial runner accepted an unknown platform' >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) mismatch=wsl ;;
  Linux) mismatch=macos ;;
  *) mismatch=macos ;;
esac
if sh "$runner" --platform "$mismatch" --release-version 1.0.0 --evidence-dir "$temporary" >/dev/null 2>&1; then
  printf '%s\n' 'field-trial runner accepted a mismatched host platform' >&2
  exit 1
fi
