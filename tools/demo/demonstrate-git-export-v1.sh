#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-git-export-v1.sh --root <absolute-demo-directory>' >&2
  exit 2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

valid_id() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0123456789abcdef]*) return 1 ;; esac
}

valid_git_id() {
  case "${#1}" in 40 | 64) ;; *) return 1 ;; esac
  case "$1" in *[!0123456789abcdef]*) return 1 ;; esac
}

root=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage
      [ -z "$root" ] || usage
      root=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$root" ] || usage
case "$root" in /*) ;; *) fail 'demo root must be absolute' ;; esac
parent=$(dirname "$root")
name=$(basename "$root")
case "$name" in '' | . | ..) fail 'demo root must name one directory' ;; esac
[ -d "$parent" ] || fail 'demo root parent must exist'
parent=$(cd "$parent" && pwd -P)
root=$parent/$name
[ -d "$root" ] || fail 'demo root must be a directory'
[ -f "$root/.yeokcham-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.yeokcham-demo-owned-v1")" = 'yeokcham-demo-owned-v1' ] || fail 'demo ownership marker is invalid'
[ ! -e "$root/.yeokcham/demo-v1-git-export" ] || fail 'Git export demonstration was already run for this root'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
run_yeokcham() {
  if [ -n "${YEOKCHAM_BIN:-}" ]; then
    [ -x "$YEOKCHAM_BIN" ] || fail 'YEOKCHAM_BIN must name an executable'
    YEOKCHAM_LEGACY_DEMO_V1=1 "$YEOKCHAM_BIN" "$@" --root "$root"
  else
    (cd "$project_root" && YEOKCHAM_LEGACY_DEMO_V1=1 opam exec -- dune exec bin/yeokcham.exe -- "$@" --root "$root")
  fi
}

sh "$script_dir/demonstrate-release-v1.sh" --root "$root"
release_output=$(cat "$root/.yeokcham/demo-v1-release-create")
release=${release_output#release=}
release=${release%% *}
final=${release_output#* final=}
final=${final%% *}
valid_id "$release" && valid_id "$final" || fail 'release fixture identity is invalid'
if run_yeokcham git export release --repository "$root/not-a-git-repository" --release "$release" > "$root/.yeokcham/demo-v1-git-export-invalid-repository" 2>&1; then
  fail 'invalid Git repository was accepted'
fi
git_repository=$root/git-export
[ ! -e "$git_repository" ] || fail 'Git export destination already exists'
git init -q "$git_repository" > "$root/.yeokcham/demo-v1-git-export-init"
run_yeokcham git export release --repository "$git_repository" --release "$release" > "$root/.yeokcham/demo-v1-git-export"
export_output=$(cat "$root/.yeokcham/demo-v1-git-export")
case "$export_output" in "release=$release snapshot=$final git-tree="*' metadata=default') ;; *) fail 'Git export output is invalid' ;; esac
git_tree=${export_output#* git-tree=}
git_tree=${git_tree%% *}
git_commit=${export_output#* git-commit=}
git_commit=${git_commit%% *}
git_ref=${export_output#* ref=}
git_ref=${git_ref%% *}
mapping=${export_output#* mapping=}
mapping=${mapping%% *}
valid_git_id "$git_tree" && valid_git_id "$git_commit" && valid_id "$mapping" || fail 'Git export identity is invalid'
git -C "$git_repository" fsck --full > "$root/.yeokcham/demo-v1-git-export-fsck"
git -C "$git_repository" rev-parse "$git_ref" > "$root/.yeokcham/demo-v1-git-export-ref"
[ "$(cat "$root/.yeokcham/demo-v1-git-export-ref")" = "$git_commit" ] || fail 'Git ref does not name exported commit'
git -C "$git_repository" remote > "$root/.yeokcham/demo-v1-git-export-remotes"
[ ! -s "$root/.yeokcham/demo-v1-git-export-remotes" ] || fail 'demo Git repository unexpectedly has a remote'
git -C "$git_repository" checkout -q "$git_commit"
printf '%s\n' 'workspace first capsule bytes' > "$root/.yeokcham/demo-v1-git-export-todo-oracle"
printf '%s\n' 'workspace second capsule bytes' > "$root/.yeokcham/demo-v1-git-export-notes-oracle"
cmp -s "$root/.yeokcham/demo-v1-git-export-todo-oracle" "$git_repository/docs/todo.txt" || fail 'Git export todo bytes differ'
cmp -s "$root/.yeokcham/demo-v1-git-export-notes-oracle" "$git_repository/notes.txt" || fail 'Git export notes bytes differ'
[ -f "$git_repository/CHANGELOG.md" ] || fail 'Git export lost renamed file'
[ ! -e "$git_repository/README.md" ] || fail 'Git export retained old renamed path'
[ ! -e "$git_repository/release-after.txt" ] || fail 'Git export included later scratch bytes'
[ ! -x "$git_repository/bin/run-demo" ] || fail 'Git export changed nonexecutable mode'
[ "$(readlink "$git_repository/current-note")" = 'docs/todo.txt' ] || fail 'Git export symlink differs'
printf 'release=%s\nfinal=%s\ngit-tree=%s\ngit-commit=%s\nref=%s\nmapping=%s\n' "$release" "$final" "$git_tree" "$git_commit" "$git_ref" "$mapping"
