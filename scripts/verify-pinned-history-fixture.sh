#!/usr/bin/env bash
set -euo pipefail

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_root=$(cd -- "$fixture_script_dir/.." && pwd -P)
fixture_directory="$fixture_root/fixtures/pinned/sha1-history-v1"
fixture_manifest="$fixture_directory/manifest.txt"
fixture_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-pinned-fixture-test.XXXXXX")

cleanup() {
  rm -rf -- "$fixture_temp"
}
trap cleanup EXIT HUP INT TERM

[[ -f "$fixture_manifest" ]] || {
  echo "pinned fixture manifest is missing" >&2
  exit 1
}

manifest_value() {
  sed -n "s/^$1=//p" "$fixture_manifest"
}

commit_v1=$(manifest_value commit_v1)
commit_v2=$(manifest_value commit_v2)
tag_v2=$(manifest_value tag_v2)
tree_v2=$(manifest_value tree_v2)
large_blob_v2=$(manifest_value large_blob_v2)
reachable_hash=$(manifest_value reachable_object_ids_sha256)

for value in "$commit_v1" "$commit_v2" "$tag_v2" "$tree_v2" "$large_blob_v2"; do
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || {
    echo "pinned fixture has an invalid object ID" >&2
    exit 1
  }
done
[[ "$reachable_hash" =~ ^[0-9a-f]{64}$ ]] || {
  echo "pinned fixture has an invalid reachable-object digest" >&2
  exit 1
}

for fixture_repo in "$fixture_directory/loose.git" "$fixture_directory/packed.git"; do
  git --git-dir="$fixture_repo" fsck --full --strict --no-dangling
  [[ $(git --git-dir="$fixture_repo" rev-parse refs/heads/main) == "$commit_v2" ]]
  [[ $(git --git-dir="$fixture_repo" rev-parse refs/heads/release) == "$commit_v1" ]]
  [[ $(git --git-dir="$fixture_repo" rev-parse refs/tags/fixture-v2) == "$tag_v2" ]]
  [[ $(git --git-dir="$fixture_repo" rev-parse "$commit_v2^{tree}") == "$tree_v2" ]]
  [[ $(git --git-dir="$fixture_repo" rev-parse "$commit_v2:large.txt") == "$large_blob_v2" ]]
  actual_hash=$(git --git-dir="$fixture_repo" rev-list --objects --all | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}')
  [[ "$actual_hash" == "$reachable_hash" ]]
done

git clone --quiet "$fixture_directory/loose.git" "$fixture_temp/loose"
git clone --quiet "$fixture_directory/packed.git" "$fixture_temp/packed"
diff -ru --exclude=.git -- "$fixture_temp/loose" "$fixture_temp/packed"

"$fixture_script_dir/generate-pinned-history-fixture.sh" "$fixture_temp/regenerated" >/dev/null
cmp "$fixture_manifest" "$fixture_temp/regenerated/manifest.txt"

echo "Pinned history fixture verified"
