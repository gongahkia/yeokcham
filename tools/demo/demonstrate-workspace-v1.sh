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
[ -f "$root/.paengi-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ] || fail 'demo ownership marker is invalid'
[ -f "$root/.paengi/demo-v1-change-checkpoint" ] || fail 'base checkpoint record is missing'
[ ! -e "$root/.paengi/demo-v1-workspace-create" ] || fail 'workspace demonstration was already run for this root'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
run_paengi() {
  if [ -n "${PAENGI_BIN:-}" ]; then
    [ -x "$PAENGI_BIN" ] || fail 'PAENGI_BIN must name an executable'
    "$PAENGI_BIN" "$@" --root "$root"
  else
    (cd "$project_root" && opam exec -- dune exec bin/paengi.exe -- "$@" --root "$root")
  fi
}
run_workspace_base() {
  checkpoint=$1
  if [ -n "${PAENGI_WORKSPACE_BASE_BIN:-}" ]; then
    [ -x "$PAENGI_WORKSPACE_BASE_BIN" ] || fail 'PAENGI_WORKSPACE_BASE_BIN must name an executable'
    "$PAENGI_WORKSPACE_BASE_BIN" --root "$root" --checkpoint "$checkpoint"
  else
    (cd "$project_root" && opam exec -- dune exec bin/workspace_base_v1.exe -- --root "$root" --checkpoint "$checkpoint")
  fi
}

base_checkpoint=$(cat "$root/.paengi/demo-v1-change-checkpoint")
base_snapshot=$(run_workspace_base "$base_checkpoint")
first_capsule=4444444444444444444444444444444444444444444444444444444444444444
second_capsule=5555555555555555555555555555555555555555555555555555555555555555
workspace=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' 'workspace first capsule bytes' > "$root/docs/todo.txt"
run_paengi capsule create --current --id "$first_capsule" --title 'workspace first' --description 'first selected revision' > "$root/.paengi/demo-v1-workspace-capsule-first"
first_output=$(cat "$root/.paengi/demo-v1-workspace-capsule-first")
case "$first_output" in "capsule=$first_capsule revision="*) ;; *) fail 'first capsule output is invalid' ;; esac
first_revision=${first_output#"capsule=$first_capsule revision="}
first_revision=${first_revision%% *}
printf '%s\n' 'workspace second capsule bytes' > "$root/notes.txt"
run_paengi capsule create --current --id "$second_capsule" --title 'workspace second' --description 'second selected revision' > "$root/.paengi/demo-v1-workspace-capsule-second"
second_output=$(cat "$root/.paengi/demo-v1-workspace-capsule-second")
case "$second_output" in "capsule=$second_capsule revision="*) ;; *) fail 'second capsule output is invalid' ;; esac
second_revision=${second_output#"capsule=$second_capsule revision="}
second_revision=${second_revision%% *}
run_paengi work create --id "$workspace" --base "$base_snapshot" --name 'two capsules' --description 'ordered local selection' > "$root/.paengi/demo-v1-workspace-create"
run_paengi work enable "$workspace" "$first_revision" > "$root/.paengi/demo-v1-workspace-enable-first"
run_paengi work enable "$workspace" "$second_revision" > "$root/.paengi/demo-v1-workspace-enable-second"
run_paengi work reorder "$workspace" --order "$first_revision,$second_revision" > "$root/.paengi/demo-v1-workspace-reorder"
run_paengi work explain-order "$workspace" > "$root/.paengi/demo-v1-workspace-order-first"
run_paengi work disable "$workspace" "$second_capsule" > "$root/.paengi/demo-v1-workspace-disabled"
run_paengi work enable "$workspace" "$second_revision" > "$root/.paengi/demo-v1-workspace-reenabled"
run_paengi work reorder "$workspace" --order "$first_revision,$second_revision" > "$root/.paengi/demo-v1-workspace-reorder-final"
run_paengi work explain-order "$workspace" > "$root/.paengi/demo-v1-workspace-order-final"
printf 'workspace=%s\nfirst-capsule=%s\nsecond-capsule=%s\nfirst-revision=%s\nsecond-revision=%s\n' "$workspace" "$first_capsule" "$second_capsule" "$first_revision" "$second_revision"
