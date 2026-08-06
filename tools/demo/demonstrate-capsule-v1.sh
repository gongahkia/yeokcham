#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-capsule-v1.sh --root <absolute-demo-directory>' >&2
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
case "$root" in
  /*) ;;
  *) fail 'demo root must be absolute' ;;
esac
parent=$(dirname "$root")
name=$(basename "$root")
case "$name" in '' | . | ..) fail 'demo root must name one directory' ;; esac
[ -d "$parent" ] || fail 'demo root parent must exist'
parent=$(cd "$parent" && pwd -P)
root=$parent/$name
[ -d "$root" ] || fail 'demo root must be a directory'
[ -f "$root/.paengi-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ] \
  || fail 'demo ownership marker is invalid'
[ ! -e "$root/.paengi/demo-v1-capsule-create" ] \
  || fail 'capsule demonstration was already run for this root'

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

capsule_id=1111111111111111111111111111111111111111111111111111111111111111
left_id=2222222222222222222222222222222222222222222222222222222222222222
right_id=3333333333333333333333333333333333333333333333333333333333333333
printf '%s\n' 'messy capsule bytes' > "$root/docs/todo.txt"
printf '%s\n' 'temporary debug note retained deliberately' > "$root/debug-note.txt"
chmod 755 "$root/bin/run-demo"
run_paengi capsule create --current --id "$capsule_id" --title 'demo capsule' \
  --description 'curated from messy scratch edits' \
  > "$root/.paengi/demo-v1-capsule-create"
creation=$(cat "$root/.paengi/demo-v1-capsule-create")
case "$creation" in
  "capsule=$capsule_id revision="*' from='*' to='*) ;;
  *) fail 'capsule creation output is invalid' ;;
esac
first_revision=${creation#"capsule=$capsule_id revision="}
first_revision=${first_revision%% *}
run_paengi capsule show "$capsule_id" > "$root/.paengi/demo-v1-capsule-show-first"
run_paengi capsule current-diff "$capsule_id" > "$root/.paengi/demo-v1-capsule-diff"
anchor_output=$(run_paengi capsule edit "$capsule_id")
case "$anchor_output" in editing-anchor=*) ;; *) fail 'editing anchor output is invalid' ;; esac
anchor=${anchor_output#editing-anchor=}
printf '%s\n' 'folded capsule bytes' > "$root/debug-note.txt"
run_paengi checkpoint > "$root/.paengi/demo-v1-capsule-fold-checkpoint"
fold_target=$(cat "$root/.paengi/demo-v1-capsule-fold-checkpoint")
run_paengi capsule fold "$capsule_id" --from "$anchor" --to "$fold_target" \
  > "$root/.paengi/demo-v1-capsule-fold"
fold=$(cat "$root/.paengi/demo-v1-capsule-fold")
case "$fold" in "capsule=$capsule_id revision="*) ;; *) fail 'capsule fold output is invalid' ;; esac
second_revision=${fold#"capsule=$capsule_id revision="}
[ "$first_revision" != "$second_revision" ] || fail 'fold did not create an immutable revision'
run_paengi capsule show "$capsule_id" > "$root/.paengi/demo-v1-capsule-show-second"
run_paengi capsule history "$capsule_id" > "$root/.paengi/demo-v1-capsule-history"
if split_output=$(run_paengi capsule split "$capsule_id" --left-id "$left_id" \
  --left-title 'planned left' --left-description 'not published' --right-id "$right_id" \
  --right-title 'planned right' --right-description 'not published' --left-indices 0 2>&1); then
  fail 'split published without explicit confirmation'
fi
printf '%s\n' "$split_output" > "$root/.paengi/demo-v1-capsule-split-plan"
case "$split_output" in *'plan split '*) ;; *) fail 'split plan output is invalid' ;; esac
case "$split_output" in *'explicit confirmation is required'*) ;; *) fail 'split confirmation error is invalid' ;; esac
printf 'capsule=%s\nfirst-revision=%s\ncurrent-revision=%s\n' \
  "$capsule_id" "$first_revision" "$second_revision"
