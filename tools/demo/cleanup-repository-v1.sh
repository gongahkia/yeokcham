#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: cleanup-repository-v1.sh --root <absolute-demo-directory>' >&2
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
[ -f "$root/.paengi-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ] \
  || fail 'demo ownership marker is invalid'

rm -rf -- "$root"
