#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workflow="$repository_root/.github/workflows/ci.yml"

fail() {
  printf '%s\n' "workflow-ci-test: $*" >&2
  exit 1
}

command -v ruby >/dev/null 2>&1 || fail 'Ruby is required to parse CI YAML'
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow"

for expected in \
  'runner: [ubuntu-latest, macos-latest]' \
  'package-and-oci-smoke:' \
  'verify Docker service' \
  'make development-artifact-test'; do
  grep -F "$expected" "$workflow" >/dev/null \
    || fail "CI workflow is missing: $expected"
done

printf '%s\n' 'workflow CI test passed'
