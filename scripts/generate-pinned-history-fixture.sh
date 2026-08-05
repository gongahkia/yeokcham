#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [output-directory]" >&2
  exit 2
fi

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_root=$(cd -- "$fixture_script_dir/.." && pwd -P)
fixture_output=${1:-"$fixture_root/fixtures/pinned/sha1-history-v1"}

case "$fixture_output" in
  ""|/|.|..)
    echo "refusing unsafe fixture output: $fixture_output" >&2
    exit 2
    ;;
esac

if [[ -e "$fixture_output" || -L "$fixture_output" ]]; then
  echo "fixture output already exists: $fixture_output" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "git is required" >&2
  exit 127
}

fixture_parent=$(dirname -- "$fixture_output")
fixture_name=$(basename -- "$fixture_output")
mkdir -p -- "$fixture_parent"
fixture_stage=$(mktemp -d "$fixture_parent/.${fixture_name}.tmp.XXXXXX")

cleanup() {
  if [[ -n "${fixture_stage:-}" && -d "$fixture_stage" ]]; then
    rm -rf -- "$fixture_stage"
  fi
}
trap cleanup EXIT HUP INT TERM

fixture_loose="$fixture_stage/loose.git"
fixture_packed="$fixture_stage/packed.git"
fixture_data="$fixture_stage/data"
mkdir -- "$fixture_data"
git init --bare --quiet --object-format=sha1 --initial-branch=main "$fixture_loose"

printf 'Yeokcham pinned history fixture\n' >"$fixture_data/README-v1"
printf 'Keep exact Git object bytes recoverable.\n' >"$fixture_data/guide-v1"
for number in $(seq 1 4096); do
  printf 'line-%04d 0123456789abcdef\n' "$number"
done >"$fixture_data/large-v1"

blob_readme_v1=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/README-v1")
blob_guide_v1=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/guide-v1")
blob_large_v1=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/large-v1")
tree_docs_v1=$(printf '100644 blob %s\tguide.txt\n' "$blob_guide_v1" | git --git-dir="$fixture_loose" mktree)
tree_v1=$(printf '100644 blob %s\tREADME.md\n040000 tree %s\tdocs\n100644 blob %s\tlarge.txt\n' "$blob_readme_v1" "$tree_docs_v1" "$blob_large_v1" | git --git-dir="$fixture_loose" mktree)
commit_v1=$(printf 'initial fixture\n' | env \
  GIT_AUTHOR_NAME='Yeokcham Fixture' \
  GIT_AUTHOR_EMAIL='fixture@yeokcham.invalid' \
  GIT_AUTHOR_DATE='@946684800 +0000' \
  GIT_COMMITTER_NAME='Yeokcham Fixture' \
  GIT_COMMITTER_EMAIL='fixture@yeokcham.invalid' \
  GIT_COMMITTER_DATE='@946684800 +0000' \
  git --git-dir="$fixture_loose" commit-tree "$tree_v1")

printf 'Yeokcham pinned history fixture, revision two\n' >"$fixture_data/README-v2"
printf 'Recovery verifies content before trust.\n' >"$fixture_data/guide-v2"
for number in $(seq 1 4096); do
  if (( number == 2048 )); then
    printf 'line-%04d localised-change\n' "$number"
  else
    printf 'line-%04d 0123456789abcdef\n' "$number"
  fi
done >"$fixture_data/large-v2"

blob_readme_v2=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/README-v2")
blob_guide_v2=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/guide-v2")
blob_large_v2=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/large-v2")
tree_docs_v2=$(printf '100644 blob %s\tguide.txt\n' "$blob_guide_v2" | git --git-dir="$fixture_loose" mktree)
tree_v2=$(printf '100644 blob %s\tREADME.md\n040000 tree %s\tdocs\n100644 blob %s\tlarge.txt\n' "$blob_readme_v2" "$tree_docs_v2" "$blob_large_v2" | git --git-dir="$fixture_loose" mktree)
commit_v2=$(printf 'second fixture\n' | env \
  GIT_AUTHOR_NAME='Yeokcham Fixture' \
  GIT_AUTHOR_EMAIL='fixture@yeokcham.invalid' \
  GIT_AUTHOR_DATE='@946771200 +0000' \
  GIT_COMMITTER_NAME='Yeokcham Fixture' \
  GIT_COMMITTER_EMAIL='fixture@yeokcham.invalid' \
  GIT_COMMITTER_DATE='@946771200 +0000' \
  git --git-dir="$fixture_loose" commit-tree "$tree_v2" -p "$commit_v1")

tag_v2=$(printf 'object %s\ntype commit\ntag fixture-v2\ntagger Yeokcham Fixture <fixture@yeokcham.invalid> 946771200 +0000\n\npinned fixture release\n' "$commit_v2" | git --git-dir="$fixture_loose" mktag)
git --git-dir="$fixture_loose" update-ref refs/heads/main "$commit_v2"
git --git-dir="$fixture_loose" update-ref refs/heads/release "$commit_v1"
git --git-dir="$fixture_loose" update-ref refs/tags/fixture-v2 "$tag_v2"

cp -R -- "$fixture_loose" "$fixture_packed"
git --git-dir="$fixture_packed" repack -adq --no-write-bitmap-index
git --git-dir="$fixture_packed" prune-packed
rm -rf -- "$fixture_loose/hooks" "$fixture_packed/hooks"
rm -f -- "$fixture_loose/info/exclude" "$fixture_packed/info/exclude"

all_ids=$(git --git-dir="$fixture_loose" rev-list --objects --all | awk '{print $1}' | sort)
all_ids_hash=$(printf '%s\n' "$all_ids" | shasum -a 256 | awk '{print $1}')
{
  printf 'fixture_format=1\n'
  printf 'hash_algorithm=sha1\n'
  printf 'commit_v1=%s\n' "$commit_v1"
  printf 'commit_v2=%s\n' "$commit_v2"
  printf 'tag_v2=%s\n' "$tag_v2"
  printf 'tree_v2=%s\n' "$tree_v2"
  printf 'large_blob_v2=%s\n' "$blob_large_v2"
  printf 'reachable_object_ids_sha256=%s\n' "$all_ids_hash"
  printf 'ref_main=refs/heads/main\n'
  printf 'ref_release=refs/heads/release\n'
  printf 'ref_tag=refs/tags/fixture-v2\n'
} >"$fixture_stage/manifest.txt"

rm -rf -- "$fixture_data"
mv -- "$fixture_stage" "$fixture_output"
fixture_stage=
trap - EXIT HUP INT TERM
printf 'pinned fixture at %s\n' "$fixture_output"
