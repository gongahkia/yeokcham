#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [output-directory]" >&2
  exit 2
fi

fixture_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
fixture_root=$(cd -- "$fixture_script_dir/.." && pwd -P)
fixture_output=${1:-"$fixture_root/fixtures/pinned/sparse-workspace-v1"}

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

for command in git perl shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 127
  }
done

fixture_parent=$(dirname -- "$fixture_output")
fixture_name=$(basename -- "$fixture_output")
mkdir -p -- "$fixture_parent"
fixture_stage=$(mktemp -d "$fixture_parent/.${fixture_name}.tmp.XXXXXX")

cleanup() {
  rm -rf -- "$fixture_stage"
}
trap cleanup EXIT HUP INT TERM

write_binary() {
  local seed=$1
  local output=$2
  perl -e '
    my ($state, $length) = @ARGV;
    my $buffer = q{};
    for (1 .. $length) {
      $state ^= ($state << 13) & 0xffffffff;
      $state ^= $state >> 17;
      $state ^= ($state << 5) & 0xffffffff;
      $state &= 0xffffffff;
      $buffer .= chr($state & 0xff);
      if (length($buffer) == 65536) {
        print $buffer;
        $buffer = q{};
      }
    }
    print $buffer;
  ' "$seed" $((4 * 1024 * 1024)) >"$output"
}

fixture_loose="$fixture_stage/loose.git"
fixture_data="$fixture_stage/data"
mkdir -- "$fixture_data"
git init --bare --quiet --object-format=sha1 --initial-branch=main "$fixture_loose"

printf 'selected sparse path, revision one\n' >"$fixture_data/app-v1.txt"
printf 'selected sparse path, revision two\n' >"$fixture_data/app-v2.txt"
write_binary 305419896 "$fixture_data/current.bin"
write_binary 2271560481 "$fixture_data/historical.bin"

blob_app_v1=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/app-v1.txt")
blob_app_v2=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/app-v2.txt")
blob_current=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/current.bin")
blob_historical=$(git --git-dir="$fixture_loose" hash-object -w --stdin <"$fixture_data/historical.bin")

tree_app_v1=$(printf '100644 blob %s\tmain.txt\n' "$blob_app_v1" | git --git-dir="$fixture_loose" mktree)
tree_app_v2=$(printf '100644 blob %s\tmain.txt\n' "$blob_app_v2" | git --git-dir="$fixture_loose" mktree)
tree_assets=$(printf '100644 blob %s\tcurrent.bin\n' "$blob_current" | git --git-dir="$fixture_loose" mktree)
tree_history=$(printf '100644 blob %s\tobsolete.bin\n' "$blob_historical" | git --git-dir="$fixture_loose" mktree)
tree_v1=$(printf '040000 tree %s\tapp\n040000 tree %s\tassets\n040000 tree %s\thistory\n' "$tree_app_v1" "$tree_assets" "$tree_history" | git --git-dir="$fixture_loose" mktree)
tree_v2=$(printf '040000 tree %s\tapp\n040000 tree %s\tassets\n' "$tree_app_v2" "$tree_assets" | git --git-dir="$fixture_loose" mktree)
commit_v1=$(printf 'sparse fixture initial\n' | env \
  GIT_AUTHOR_NAME='Yeokcham Fixture' \
  GIT_AUTHOR_EMAIL='fixture@yeokcham.invalid' \
  GIT_AUTHOR_DATE='@946684800 +0000' \
  GIT_COMMITTER_NAME='Yeokcham Fixture' \
  GIT_COMMITTER_EMAIL='fixture@yeokcham.invalid' \
  GIT_COMMITTER_DATE='@946684800 +0000' \
  git --git-dir="$fixture_loose" commit-tree "$tree_v1")
commit_v2=$(printf 'sparse fixture current\n' | env \
  GIT_AUTHOR_NAME='Yeokcham Fixture' \
  GIT_AUTHOR_EMAIL='fixture@yeokcham.invalid' \
  GIT_AUTHOR_DATE='@946771200 +0000' \
  GIT_COMMITTER_NAME='Yeokcham Fixture' \
  GIT_COMMITTER_EMAIL='fixture@yeokcham.invalid' \
  GIT_COMMITTER_DATE='@946771200 +0000' \
  git --git-dir="$fixture_loose" commit-tree "$tree_v2" -p "$commit_v1")
git --git-dir="$fixture_loose" update-ref refs/heads/main "$commit_v2"

all_ids=$(git --git-dir="$fixture_loose" rev-list --objects --all | awk '{print $1}' | sort)
all_ids_hash=$(printf '%s\n' "$all_ids" | shasum -a 256 | awk '{print $1}')
{
  printf 'fixture_format=1\n'
  printf 'hash_algorithm=sha1\n'
  printf 'commit_v1=%s\n' "$commit_v1"
  printf 'commit_v2=%s\n' "$commit_v2"
  printf 'app_blob_v2=%s\n' "$blob_app_v2"
  printf 'current_asset_blob=%s\n' "$blob_current"
  printf 'historical_blob_v1=%s\n' "$blob_historical"
  printf 'reachable_object_ids_sha256=%s\n' "$all_ids_hash"
  printf 'ref_main=refs/heads/main\n'
} >"$fixture_stage/manifest.txt"

rm -rf -- "$fixture_data" "$fixture_loose/hooks"
rm -f -- "$fixture_loose/info/exclude"
mv -- "$fixture_stage" "$fixture_output"
fixture_stage=
trap - EXIT HUP INT TERM
printf 'sparse workspace fixture at %s\n' "$fixture_output"
