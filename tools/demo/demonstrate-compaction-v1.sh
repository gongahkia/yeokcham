#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-compaction-v1.sh --root <absolute-demo-directory> [--prune]' >&2
  exit 2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

root=''
prune=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage
      [ -z "$root" ] || usage
      root=$2
      shift 2
      ;;
    --prune)
      [ "$prune" -eq 0 ] || usage
      prune=1
      shift
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
[ -f "$root/.paengi-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ] \
  || fail 'demo ownership marker is invalid'
[ -f "$root/.paengi/demo-v1-initial-checkpoint" ] \
  || fail 'initial checkpoint record is missing'
[ ! -e "$root/.paengi/demo-v1-compaction-head" ] \
  || fail 'compaction demonstration was already run for this root'

initial=$(cat "$root/.paengi/demo-v1-initial-checkpoint")
[ "${#initial}" -eq 64 ] || fail 'initial checkpoint ID is invalid'
case "$initial" in
  *[!0123456789abcdef]*) fail 'initial checkpoint ID is invalid' ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")

run_paengi() {
  if [ -n "${PAENGI_BIN:-}" ]; then
    [ -x "$PAENGI_BIN" ] || fail 'PAENGI_BIN must name an executable'
    "$PAENGI_BIN" "$@" --root "$root"
  else
    (
      cd "$project_root"
      opam exec -- dune exec bin/paengi.exe -- "$@" --root "$root"
    )
  fi
}

run_paengi pin "$initial" > "$root/.paengi/demo-v1-compaction-pin"
sleep 3
printf '%s\n' 'compaction head bytes' > "$root/notes.txt"
run_paengi checkpoint > "$root/.paengi/demo-v1-compaction-head"
head=$(cat "$root/.paengi/demo-v1-compaction-head")
[ "${#head}" -eq 64 ] || fail 'head checkpoint ID is invalid'
case "$head" in
  *[!0123456789abcdef]*) fail 'head checkpoint ID is invalid' ;;
esac

compaction_now=$(date +%s)
[ "${#compaction_now}" -gt 0 ] || fail 'compaction time is invalid'
case "$compaction_now" in
  *[!0123456789]*) fail 'compaction time is invalid' ;;
esac
policy='--recent-seconds 1 --periodic-seconds 0'

run_paengi compact --dry-run --explain $policy \
  --now-unix-seconds "$compaction_now" \
  > "$root/.paengi/demo-v1-compaction-dry-run"
run_paengi compact --explain $policy --now-unix-seconds "$compaction_now" \
  > "$root/.paengi/demo-v1-compaction-activate"
run_paengi compact --resume > "$root/.paengi/demo-v1-compaction-resume"
run_paengi restore --dry-run "$initial" \
  > "$root/.paengi/demo-v1-compaction-initial-plan"
run_paengi restore --dry-run "$head" \
  > "$root/.paengi/demo-v1-compaction-head-plan"
run_paengi timeline --limit 8 > "$root/.paengi/demo-v1-compaction-timeline"

if [ "$prune" -eq 1 ]; then
  run_paengi compact --prune > "$root/.paengi/demo-v1-compaction-prune"
fi

printf 'retained-initial=%s\n' "$initial"
printf 'retained-head=%s\n' "$head"
printf 'prune-requested=%s\n' "$prune"
