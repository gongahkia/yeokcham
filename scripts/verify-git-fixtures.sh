#!/usr/bin/env bash
set -euo pipefail

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-fixture-test.XXXXXX")

cleanup() {
  rm -rf -- "$fixture_temp"
}
trap cleanup EXIT HUP INT TERM

"$fixture_script_dir/generate-git-fixtures.sh" "$fixture_temp/first" >/dev/null
"$fixture_script_dir/generate-git-fixtures.sh" "$fixture_temp/second" >/dev/null
cmp "$fixture_temp/first/manifest.txt" "$fixture_temp/second/manifest.txt"

fixture_manifest="$fixture_temp/first/manifest.txt"
fixture_blob=$(sed -n 's/^blob_oid=//p' "$fixture_manifest")
fixture_tree=$(sed -n 's/^tree_oid=//p' "$fixture_manifest")
fixture_commit=$(sed -n 's/^commit_oid=//p' "$fixture_manifest")

[[ "$fixture_blob" == 03b4de812266812fa9c3259af74f878cc4e87886 ]]
[[ "$fixture_tree" == 0f0c3955cd1a70f37623a21e181c9465eb6bdeaa ]]
[[ "$fixture_commit" == 50b4326347c3552b6b4d2ff2ab56416edb75f7b0 ]]
[[ "$fixture_blob" =~ ^[0-9a-f]{40}$ ]]
[[ "$fixture_tree" =~ ^[0-9a-f]{40}$ ]]
[[ "$fixture_commit" =~ ^[0-9a-f]{40}$ ]]

for fixture_repo in "$fixture_temp/first/loose.git" "$fixture_temp/first/packed.git"; do
  git --git-dir="$fixture_repo" fsck --full --strict --no-dangling
  [[ $(git --git-dir="$fixture_repo" cat-file -t "$fixture_blob") == blob ]]
  [[ $(git --git-dir="$fixture_repo" cat-file -t "$fixture_tree") == tree ]]
  [[ $(git --git-dir="$fixture_repo" cat-file -t "$fixture_commit") == commit ]]
  [[ $(git --git-dir="$fixture_repo" cat-file blob "$fixture_blob") == 'yeokcham fixture blob' ]]
  [[ $(git --git-dir="$fixture_repo" rev-parse refs/heads/main) == "$fixture_commit" ]]
done

fixture_loose_object="$fixture_temp/first/loose.git/objects/${fixture_blob:0:2}/${fixture_blob:2}"
fixture_packed_object="$fixture_temp/first/packed.git/objects/${fixture_blob:0:2}/${fixture_blob:2}"
[[ -f "$fixture_loose_object" ]]
[[ ! -e "$fixture_packed_object" ]]

shopt -s nullglob
fixture_packs=("$fixture_temp/first/packed.git/objects/pack/"*.pack)
fixture_indexes=("$fixture_temp/first/packed.git/objects/pack/"*.idx)
(( ${#fixture_packs[@]} == 1 ))
(( ${#fixture_indexes[@]} == 1 ))

if "$fixture_script_dir/generate-git-fixtures.sh" "$fixture_temp/first" >/dev/null 2>&1; then
  echo "generator overwrote an existing output" >&2
  exit 1
fi

echo "Git fixtures verified"
