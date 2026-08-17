#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
cd "$repository_root"

opam exec -- dune build -p yeokcham @install
installed=$repository_root/_build/install/default/bin/yeokcham
[ -x "$installed" ] || {
  printf '%s\n' "package install target omitted executable: $installed" >&2
  exit 1
}
"$installed" --help >/dev/null
