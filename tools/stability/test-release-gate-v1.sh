#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
gate=$repository_root/tools/stability/release-gate-v1.sh

sh -n "$gate"

if sh "$gate" --version invalid --evidence-dir /tmp +  --archive /tmp/yeokcham-release-gate-invalid.tar.gz >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted an invalid semantic version' >&2
  exit 1
fi
