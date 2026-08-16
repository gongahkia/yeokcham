#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
fixture_parent=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-peer-sync-cli-test.XXXXXX")
cleanup() {
  rm -rf "$fixture_parent"
}
trap cleanup EXIT HUP INT TERM

source_root=$fixture_parent/source
destination_root=$fixture_parent/destination
source_key=$fixture_parent/source.key
destination_key=$fixture_parent/destination.key
mkdir "$source_root" "$destination_root"

run() {
  opam exec -- dune exec bin/yeokcham.exe -- "$@"
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

run init --root "$source_root" >/dev/null
run init --root "$destination_root" >/dev/null

source_identity=$(run peer identity init --key "$source_key" --root "$source_root")
destination_identity=$(run peer identity init --key "$destination_key" --root "$destination_root")

[ "$(file_mode "$source_key")" = 600 ]
[ "$(file_mode "$destination_key")" = 600 ]

source_peer=$(printf '%s\n' "$source_identity" | sed -n 's/^peer=//p')
source_public_key=$(printf '%s\n' "$source_identity" | sed -n 's/^public-key=//p')
destination_peer=$(printf '%s\n' "$destination_identity" | sed -n 's/^peer=//p')
[ -n "$source_peer" ]
[ -n "$source_public_key" ]
[ -n "$destination_peer" ]

run peer identity show "$source_peer" --root "$source_root" |
  grep -F "peer=$source_peer" >/dev/null

contact=$(run peer contact add source --peer-public-key "$source_public_key" \
  --direct "$source_root" --root "$destination_root")
contact_id=$(printf '%s\n' "$contact" | sed -n 's/^contact=//p')
[ -n "$contact_id" ]
run peer contact show "$contact_id" --root "$destination_root" |
  grep -F "endpoint=local:$source_root" >/dev/null

printf 'synchronized bytes\n' > "$source_root/tracked"
snapshot=$(run peer sync snapshot --root "$source_root" |
  sed -n 's/^snapshot=//p')
[ -n "$snapshot" ]
sync_node=$(run peer sync node create --identity "$source_peer" \
  --key "$source_key" --snapshot "$snapshot" --root "$source_root" |
  sed -n 's/^sync-node=//p')
[ -n "$sync_node" ]
run peer sync local --to "$destination_root" --contact "$contact_id" \
  --destination-identity "$destination_peer" --source-key "$source_key" \
  --head "$sync_node" --tracking main --root "$source_root" |
  grep -F 'tracking=advanced' >/dev/null
run verify --root "$destination_root" >/dev/null

if run peer identity init --key "$source_key" --root "$source_root" \
  >/dev/null 2>&1; then
  printf '%s\n' 'peer identity init overwrote an existing private key' >&2
  exit 1
fi
