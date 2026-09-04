#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generator="${EVIDENCE_FIXTURE_GENERATOR:-$repository_root/_build/default/bench/evidence_fixture_generator.exe}"

fail() {
  printf '%s\n' "evidence-fixture-test: $*" >&2
  exit 1
}

[ -x "$generator" ] || fail "fixture generator is unavailable: $generator"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-evidence-fixture-test.XXXXXX") \
  || fail "cannot create disposable test directory"
cleanup() {
  rm -r "$scratch"
}
trap cleanup EXIT HUP INT TERM

first="$scratch/first"
second="$scratch/second"
mkdir "$first" "$second"
before_status=$(git -C "$repository_root" status --porcelain)

"$generator" --root "$first" --paths 10 --bytes 1000 >"$scratch/first.out"
"$generator" --root "$second" --paths 10 --bytes 1000 >"$scratch/second.out"

[ "$(find "$first" -mindepth 1 -print | wc -l | tr -d ' ')" = 10 ] \
  || fail "fixture did not create its exact path count"
[ "$(find "$first" -type f -printf '%s\n' | awk '{ total += $1 } END { print total }')" = 1000 ] \
  || fail "fixture did not create its exact logical bytes"

first_digest=$(find "$first" -type f -print0 | sort -z | xargs -0 sha256sum | awk '{ print $1 }' | sha256sum | awk '{ print $1 }')
second_digest=$(find "$second" -type f -print0 | sort -z | xargs -0 sha256sum | awk '{ print $1 }' | sha256sum | awk '{ print $1 }')
[ "$first_digest" = "$second_digest" ] \
  || fail "fixture bytes are not deterministic"

if "$generator" --root relative --paths 10 --bytes 1000 >/dev/null 2>&1; then
  fail "relative output root was accepted"
fi
if "$generator" --root "$first" --paths 10 --bytes 1000 >/dev/null 2>&1; then
  fail "nonempty output root was accepted"
fi
if "$generator" --root "$scratch" --paths 1 --bytes 1 >/dev/null 2>&1; then
  fail "profile without a file was accepted"
fi
if "$generator" --root "$scratch" --paths 10 --bytes 1 >/dev/null 2>&1; then
  fail "profile with zero-byte files was accepted"
fi

after_status=$(git -C "$repository_root" status --porcelain)
[ "$before_status" = "$after_status" ] \
  || fail "fixture generation changed the source repository"

printf '%s\n' 'evidence fixture test passed'
