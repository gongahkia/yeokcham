#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
fixture_parent=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-backup-test.XXXXXX")
cleanup() {
  rm -rf "$fixture_parent"
}
trap cleanup EXIT HUP INT TERM

source_root=$fixture_parent/source
archive=$fixture_parent/source.tar
mkdir -p "$source_root/.yeokcham/objects" "$source_root/nested"
printf 'canonical-object-bytes\n' > "$source_root/.yeokcham/objects/object"
printf '#!/bin/sh\nprintf ok\n' > "$source_root/nested/run"
chmod 755 "$source_root/nested/run"
ln -s 'nested/run' "$source_root/linked-run"

output=$(sh "$repository_root/tools/stability/backup-full-repository-v1.sh" \
  --source "$source_root" --archive "$archive")

[ -f "$archive" ]
[ -f "$archive.sha256" ]
printf '%s\n' "$output" | grep -F "archive=$archive" >/dev/null
tar -tf "$archive" | grep -F 'source/.yeokcham/objects/object' >/dev/null
tar -tf "$archive" | grep -F 'source/linked-run' >/dev/null

if sh "$repository_root/tools/stability/backup-full-repository-v1.sh" \
  --source "$source_root" --archive "$archive" >/dev/null 2>&1; then
  printf '%s\n' 'backup tool overwrote an existing archive' >&2
  exit 1
fi
