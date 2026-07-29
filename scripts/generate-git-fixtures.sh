#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [output-directory]" >&2
  exit 2
fi

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_root=$(cd -- "$fixture_script_dir/.." && pwd -P)
fixture_output=${1:-"$fixture_root/fixtures/generated"}

case "$fixture_output" in
  ""|/|.|..)
    echo "refusing unsafe fixture output: $fixture_output" >&2
    exit 2
    ;;
esac

if [[ -e "$fixture_output" || -L "$fixture_output" ]]; then
  echo "fixture output already exists: $fixture_output" >&2
  exit 2
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
git init --bare --quiet --object-format=sha1 --initial-branch=main "$fixture_loose"

fixture_blob=$(printf 'yeokcham fixture blob\n' | git --git-dir="$fixture_loose" hash-object -w --stdin)
fixture_tree=$(printf '100644 blob %s\tblob.txt\n' "$fixture_blob" | git --git-dir="$fixture_loose" mktree)
fixture_commit=$(printf 'deterministic fixture\n' | env \
  GIT_AUTHOR_NAME='Yeokcham Fixture' \
  GIT_AUTHOR_EMAIL='fixture@yeokcham.invalid' \
  GIT_AUTHOR_DATE='@946684800 +0000' \
  GIT_COMMITTER_NAME='Yeokcham Fixture' \
  GIT_COMMITTER_EMAIL='fixture@yeokcham.invalid' \
  GIT_COMMITTER_DATE='@946684800 +0000' \
  git --git-dir="$fixture_loose" commit-tree "$fixture_tree")
git --git-dir="$fixture_loose" update-ref refs/heads/main "$fixture_commit"

cp -R -- "$fixture_loose" "$fixture_packed"
git --git-dir="$fixture_packed" repack -adq --no-write-bitmap-index
git --git-dir="$fixture_packed" prune-packed

{
  printf 'fixture_format=1\n'
  printf 'hash_algorithm=sha1\n'
  printf 'blob_oid=%s\n' "$fixture_blob"
  printf 'tree_oid=%s\n' "$fixture_tree"
  printf 'commit_oid=%s\n' "$fixture_commit"
  printf 'ref=refs/heads/main\n'
} >"$fixture_stage/manifest.txt"

mv -- "$fixture_stage" "$fixture_output"
fixture_stage=
trap - EXIT HUP INT TERM
printf 'generated fixtures at %s\n' "$fixture_output"
