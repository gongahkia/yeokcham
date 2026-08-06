#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
  printf '%s\n' 'usage: demonstrate-retargeting-v1.sh' >&2
  exit 2
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
if [ -n "${PAENGI_RETARGETING_DEMO_BIN:-}" ]; then
  [ -x "$PAENGI_RETARGETING_DEMO_BIN" ] || {
    printf '%s\n' 'PAENGI_RETARGETING_DEMO_BIN must name an executable' >&2
    exit 2
  }
  "$PAENGI_RETARGETING_DEMO_BIN"
else
  (cd "$project_root" && opam exec -- dune exec bin/retargeting_demo_v1.exe)
fi
