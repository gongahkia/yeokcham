#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-recovery-v1.sh --root <absolute-demo-directory>' >&2
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
case "$name" in
  '' | . | ..) fail 'demo root must name one directory' ;;
esac
[ -d "$parent" ] || fail 'demo root parent must exist'
parent=$(cd "$parent" && pwd -P)
root=$parent/$name
[ -d "$root" ] || fail 'demo root must be a directory'
[ -f "$root/.yeokcham-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.yeokcham-demo-owned-v1")" = 'yeokcham-demo-owned-v1' ] \
  || fail 'demo ownership marker is invalid'
[ -f "$root/.yeokcham/demo-v1-initial-checkpoint" ] \
  || fail 'initial checkpoint record is missing'

initial=$(cat "$root/.yeokcham/demo-v1-initial-checkpoint")
[ "${#initial}" -eq 64 ] || fail 'initial checkpoint ID is invalid'
case "$initial" in
  *[!0123456789abcdef]*) fail 'initial checkpoint ID is invalid' ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")

run_yeokcham() {
  if [ -n "${YEOKCHAM_BIN:-}" ]; then
    [ -x "$YEOKCHAM_BIN" ] || fail 'YEOKCHAM_BIN must name an executable'
    YEOKCHAM_LEGACY_DEMO_V1=1 "$YEOKCHAM_BIN" "$@" --root "$root"
  else
    (
      cd "$project_root"
      YEOKCHAM_LEGACY_DEMO_V1=1 opam exec -- dune exec bin/yeokcham.exe -- "$@" --root "$root"
    )
  fi
}

printf '%s\n' 'divergent bytes before recovery' > "$root/docs/todo.txt"
printf '%s\n' 'uncheckpointed divergent file' > "$root/divergent.txt"
chmod 755 "$root/bin/run-demo"
rm "$root/current-note"
ln -s notes.txt "$root/current-note"

run_yeokcham restore --dry-run "$initial" > "$root/.yeokcham/demo-v1-recovery-dry-run"
restore_output=$(run_yeokcham restore "$initial")
case "$restore_output" in
  'restored safety='*) safety=${restore_output#restored safety=} ;;
  *) fail 'restore did not report a safety checkpoint' ;;
esac
[ "${#safety}" -eq 64 ] || fail 'reported safety checkpoint ID is invalid'
case "$safety" in
  *[!0123456789abcdef]*) fail 'reported safety checkpoint ID is invalid' ;;
esac
printf '%s\n' "$restore_output" > "$root/.yeokcham/demo-v1-recovery"
run_yeokcham timeline --limit 8 > "$root/.yeokcham/demo-v1-recovery-timeline"

printf 'restored-to=%s\n' "$initial"
printf 'safety-checkpoint=%s\n' "$safety"
