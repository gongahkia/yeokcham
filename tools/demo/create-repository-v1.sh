#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: create-repository-v1.sh --root <absolute-new-directory>' >&2
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
  '' | . | ..) fail 'demo root must name one new directory' ;;
esac
[ -d "$parent" ] || fail 'demo root parent must already exist'
parent=$(cd "$parent" && pwd -P)
root=$parent/$name
[ ! -e "$root" ] && [ ! -L "$root" ] || fail 'demo root already exists'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
created=0
initial_log=''

cleanup_failure() {
  status=$?
  trap - 0 HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$created" -eq 1 ] \
    && [ -f "$root/.paengi-demo-owned-v1" ] \
    && [ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ]; then
    rm -rf -- "$root"
  fi
  [ -z "$initial_log" ] || rm -f -- "$initial_log"
  exit "$status"
}

trap cleanup_failure 0 HUP INT TERM

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

mkdir -m 700 "$root"
created=1
mkdir "$root/bin" "$root/docs"
printf '%s\n' 'paengi-demo-owned-v1' > "$root/.paengi-demo-owned-v1"
printf '%s\n' '# Demo repository' '' 'Initial local-only fixture state.' > "$root/README.md"
printf '%s\n' 'keep exact bytes' > "$root/docs/todo.txt"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "demo"' > "$root/bin/run-demo"
chmod 755 "$root/bin/run-demo"
ln -s docs/todo.txt "$root/current-note"

initial_log=$(mktemp "$parent/.paengi-demo-v1-initial.XXXXXX")
run_paengi init > "$initial_log"
mv "$initial_log" "$root/.paengi/demo-v1-initial-checkpoint"
initial_log=''
mv "$root/README.md" "$root/CHANGELOG.md"
printf '%s\n' 'keep exact bytes, revised' > "$root/docs/todo.txt"
printf '%s\n' 'created after the initial checkpoint' > "$root/notes.txt"
chmod 644 "$root/bin/run-demo"
run_paengi checkpoint > "$root/.paengi/demo-v1-change-checkpoint"
run_paengi timeline --limit 8 > "$root/.paengi/demo-v1-timeline"

printf 'root=%s\n' "$root"
printf 'initial-checkpoint=%s\n' \
  "$(cat "$root/.paengi/demo-v1-initial-checkpoint")"
printf 'change-checkpoint=%s\n' \
  "$(cat "$root/.paengi/demo-v1-change-checkpoint")"
