#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-workspace-v1.sh --root <absolute-demo-directory>' >&2
  exit 2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 2
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
[ -f "$root/.yeokcham/demo-v1-change-checkpoint" ] || fail 'base checkpoint record is missing'
[ ! -e "$root/.yeokcham/demo-v1-workspace-create" ] || fail 'workspace demonstration was already run for this root'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
run_yeokcham() {
  if [ -n "${YEOKCHAM_BIN:-}" ]; then
    [ -x "$YEOKCHAM_BIN" ] || fail 'YEOKCHAM_BIN must name an executable'
    "$YEOKCHAM_BIN" "$@" --root "$root"
  else
    (cd "$project_root" && opam exec -- dune exec bin/yeokcham.exe -- "$@" --root "$root")
  fi
}
run_workspace_base() {
  checkpoint=$1
  if [ -n "${YEOKCHAM_WORKSPACE_BASE_BIN:-}" ]; then
    [ -x "$YEOKCHAM_WORKSPACE_BASE_BIN" ] || fail 'YEOKCHAM_WORKSPACE_BASE_BIN must name an executable'
    "$YEOKCHAM_WORKSPACE_BASE_BIN" --root "$root" --checkpoint "$checkpoint"
  else
    (cd "$project_root" && opam exec -- dune exec bin/workspace_base_v1.exe -- --root "$root" --checkpoint "$checkpoint")
  fi
}

base_checkpoint=$(cat "$root/.yeokcham/demo-v1-change-checkpoint")
base_snapshot=$(run_workspace_base "$base_checkpoint")
first_capsule=4444444444444444444444444444444444444444444444444444444444444444
second_capsule=5555555555555555555555555555555555555555555555555555555555555555
workspace=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' 'workspace first capsule bytes' > "$root/docs/todo.txt"
run_yeokcham capsule create --current --id "$first_capsule" --title 'workspace first' --description 'first selected revision' > "$root/.yeokcham/demo-v1-workspace-capsule-first"
first_output=$(cat "$root/.yeokcham/demo-v1-workspace-capsule-first")
case "$first_output" in "capsule=$first_capsule revision="*) ;; *) fail 'first capsule output is invalid' ;; esac
first_revision=${first_output#"capsule=$first_capsule revision="}
first_revision=${first_revision%% *}
printf '%s\n' 'workspace second capsule bytes' > "$root/notes.txt"
run_yeokcham capsule create --current --id "$second_capsule" --title 'workspace second' --description 'second selected revision' > "$root/.yeokcham/demo-v1-workspace-capsule-second"
second_output=$(cat "$root/.yeokcham/demo-v1-workspace-capsule-second")
case "$second_output" in "capsule=$second_capsule revision="*) ;; *) fail 'second capsule output is invalid' ;; esac
second_revision=${second_output#"capsule=$second_capsule revision="}
second_revision=${second_revision%% *}
run_yeokcham work create --id "$workspace" --base "$base_snapshot" --name 'two capsules' --description 'ordered local selection' > "$root/.yeokcham/demo-v1-workspace-create"
run_yeokcham work enable "$workspace" "$first_revision" > "$root/.yeokcham/demo-v1-workspace-enable-first"
run_yeokcham work enable "$workspace" "$second_revision" > "$root/.yeokcham/demo-v1-workspace-enable-second"
run_yeokcham work reorder "$workspace" --order "$first_revision,$second_revision" > "$root/.yeokcham/demo-v1-workspace-reorder"
run_yeokcham work explain-order "$workspace" > "$root/.yeokcham/demo-v1-workspace-order-first"
run_yeokcham work disable "$workspace" "$second_capsule" > "$root/.yeokcham/demo-v1-workspace-disabled"
run_yeokcham work enable "$workspace" "$second_revision" > "$root/.yeokcham/demo-v1-workspace-reenabled"
run_yeokcham work reorder "$workspace" --order "$first_revision,$second_revision" > "$root/.yeokcham/demo-v1-workspace-reorder-final"
run_yeokcham work explain-order "$workspace" > "$root/.yeokcham/demo-v1-workspace-order-final"
printf 'workspace=%s\nfirst-capsule=%s\nsecond-capsule=%s\nfirst-revision=%s\nsecond-revision=%s\n' "$workspace" "$first_capsule" "$second_capsule" "$first_revision" "$second_revision"
