#!/usr/bin/env bash
set -euo pipefail

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_root=$(cd -- "$fixture_script_dir/.." && pwd -P)
fixture_temp=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-sparse-fixture-test.XXXXXX")

cleanup() {
  rm -rf -- "$fixture_temp"
}
trap cleanup EXIT HUP INT TERM

"$fixture_script_dir/generate-sparse-workspace-fixture.sh" "$fixture_temp/first" >/dev/null
"$fixture_script_dir/generate-sparse-workspace-fixture.sh" "$fixture_temp/second" >/dev/null
cmp "$fixture_temp/first/manifest.txt" "$fixture_temp/second/manifest.txt"

fixture_repo="$fixture_temp/first/loose.git"
fixture_manifest="$fixture_temp/first/manifest.txt"
manifest_value() {
  sed -n "s/^$1=//p" "$fixture_manifest"
}

commit_v1=$(manifest_value commit_v1)
commit_v2=$(manifest_value commit_v2)
app_blob_v2=$(manifest_value app_blob_v2)
current_asset_blob=$(manifest_value current_asset_blob)
historical_blob_v1=$(manifest_value historical_blob_v1)
reachable_hash=$(manifest_value reachable_object_ids_sha256)
for value in "$commit_v1" "$commit_v2" "$app_blob_v2" "$current_asset_blob" "$historical_blob_v1"; do
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || {
    echo "sparse fixture has an invalid object ID" >&2
    exit 1
  }
done
[[ "$reachable_hash" =~ ^[0-9a-f]{64}$ ]] || {
  echo "sparse fixture has an invalid reachable-object digest" >&2
  exit 1
}

git --git-dir="$fixture_repo" fsck --full --strict --no-dangling
[[ $(git --git-dir="$fixture_repo" rev-parse refs/heads/main) == "$commit_v2" ]]
[[ $(git --git-dir="$fixture_repo" rev-parse "$commit_v2:app/main.txt") == "$app_blob_v2" ]]
[[ $(git --git-dir="$fixture_repo" rev-parse "$commit_v2:assets/current.bin") == "$current_asset_blob" ]]
[[ $(git --git-dir="$fixture_repo" rev-parse "$commit_v1:history/obsolete.bin") == "$historical_blob_v1" ]]
actual_hash=$(git --git-dir="$fixture_repo" rev-list --objects --all | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}')
[[ "$actual_hash" == "$reachable_hash" ]]

git clone --quiet "$fixture_repo" "$fixture_temp/checkout"
[[ -f "$fixture_temp/checkout/app/main.txt" ]]
[[ -f "$fixture_temp/checkout/assets/current.bin" ]]
[[ ! -e "$fixture_temp/checkout/history/obsolete.bin" ]]

echo "Sparse workspace fixture verified"
