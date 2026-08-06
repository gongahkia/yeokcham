#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-conflict-v1.sh --root <absolute-demo-directory>' >&2
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
[ -f "$root/.yeokcham/demo-v1-initial-checkpoint" ] || fail 'initial checkpoint record is missing'
[ ! -e "$root/.yeokcham/demo-v1-conflict-initial-restore" ] || fail 'conflict demonstration was already run for this root'

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
create_capsule() {
  capsule=$1
  title=$2
  description=$3
  log=$4
  run_yeokcham capsule create --current --id "$capsule" --title "$title" --description "$description" > "$log"
  output=$(cat "$log")
  case "$output" in "capsule=$capsule revision="*) ;; *) fail 'capsule creation output is invalid' ;; esac
  revision=${output#"capsule=$capsule revision="}
  revision=${revision%% *}
  printf '%s\n' "$revision"
}

initial_checkpoint=$(cat "$root/.yeokcham/demo-v1-initial-checkpoint")
[ "${#initial_checkpoint}" -eq 64 ] || fail 'initial checkpoint ID is invalid'
case "$initial_checkpoint" in *[!0123456789abcdef]*) fail 'initial checkpoint ID is invalid' ;; esac
base_snapshot=$(run_workspace_base "$initial_checkpoint")
first_capsule=6666666666666666666666666666666666666666666666666666666666666666
second_capsule=7777777777777777777777777777777777777777777777777777777777777777
independent_capsule=8888888888888888888888888888888888888888888888888888888888888888
workspace=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

run_yeokcham restore "$initial_checkpoint" > "$root/.yeokcham/demo-v1-conflict-initial-restore"
printf '%s\n' 'first conflicting bytes' > "$root/docs/todo.txt"
first_revision=$(create_capsule "$first_capsule" 'first conflicting change' 'writes todo first' "$root/.yeokcham/demo-v1-conflict-capsule-first")
run_yeokcham restore "$initial_checkpoint" > "$root/.yeokcham/demo-v1-conflict-second-restore"
printf '%s\n' 'second conflicting bytes' > "$root/docs/todo.txt"
second_revision=$(create_capsule "$second_capsule" 'second conflicting change' 'writes todo second' "$root/.yeokcham/demo-v1-conflict-capsule-second")
run_yeokcham restore "$initial_checkpoint" > "$root/.yeokcham/demo-v1-conflict-independent-restore"
printf '%s\n' 'independent bytes remain available' > "$root/conflict-unrelated.txt"
independent_revision=$(create_capsule "$independent_capsule" 'independent change' 'writes unrelated path' "$root/.yeokcham/demo-v1-conflict-capsule-independent")

run_yeokcham work create --id "$workspace" --base "$base_snapshot" --name 'local conflict' --description 'explicit skip only' > "$root/.yeokcham/demo-v1-conflict-workspace-create"
run_yeokcham work enable "$workspace" "$first_revision" > "$root/.yeokcham/demo-v1-conflict-workspace-enable-first"
run_yeokcham work enable "$workspace" "$second_revision" > "$root/.yeokcham/demo-v1-conflict-workspace-enable-second"
run_yeokcham work enable "$workspace" "$independent_revision" > "$root/.yeokcham/demo-v1-conflict-workspace-enable-independent"
run_yeokcham work reorder "$workspace" --order "$first_revision,$second_revision,$independent_revision" > "$root/.yeokcham/demo-v1-conflict-workspace-reorder"
run_yeokcham work materialise "$workspace" > "$root/.yeokcham/demo-v1-conflict-partial"
run_yeokcham conflict list "$workspace" > "$root/.yeokcham/demo-v1-conflict-list"
conflict_output=$(cat "$root/.yeokcham/demo-v1-conflict-list")
case "$conflict_output" in conflict=*) ;; *) fail 'persistent conflict list is invalid' ;; esac
conflict=${conflict_output#conflict=}
conflict=${conflict%% *}
run_yeokcham conflict show "$conflict" > "$root/.yeokcham/demo-v1-conflict-show-before-skip"
run_yeokcham work show "$workspace" > "$root/.yeokcham/demo-v1-conflict-workspace-before-unsupported"
if run_yeokcham conflict resolve "$workspace" "$conflict" --action replace > "$root/.yeokcham/demo-v1-conflict-unsupported-resolution" 2>&1; then
  fail 'unsupported resolution action was accepted'
fi
run_yeokcham work show "$workspace" > "$root/.yeokcham/demo-v1-conflict-workspace-after-unsupported"
cmp -s "$root/.yeokcham/demo-v1-conflict-workspace-before-unsupported" "$root/.yeokcham/demo-v1-conflict-workspace-after-unsupported" || fail 'unsupported resolution changed workspace state'
run_yeokcham conflict resolve "$workspace" "$conflict" --action skip > "$root/.yeokcham/demo-v1-conflict-skip"
run_yeokcham conflict show "$conflict" > "$root/.yeokcham/demo-v1-conflict-show-after-skip"
run_yeokcham conflict list "$workspace" > "$root/.yeokcham/demo-v1-conflict-list-after-skip"
run_yeokcham work materialise "$workspace" > "$root/.yeokcham/demo-v1-conflict-complete"
printf 'workspace=%s\nconflict=%s\nfirst-capsule=%s\nsecond-capsule=%s\nindependent-capsule=%s\nfirst-revision=%s\nsecond-revision=%s\nindependent-revision=%s\n' "$workspace" "$conflict" "$first_capsule" "$second_capsule" "$independent_capsule" "$first_revision" "$second_revision" "$independent_revision"
