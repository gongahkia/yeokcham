#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workflow="$repository_root/.github/workflows/ci.yml"
development_artifact_workflow="$repository_root/.github/workflows/development-client-artifact.yml"

fail() {
  printf '%s\n' "workflow-ci-test: $*" >&2
  exit 1
}

command -v ruby >/dev/null 2>&1 || fail 'Ruby is required to parse CI YAML'
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow"
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$development_artifact_workflow"

for expected in \
  'runner: [ubuntu-latest, macos-latest]' \
  'package-and-oci-smoke:' \
  'verify Docker service' \
  'docker/setup-buildx-action@e468171a9de216ec08956ac3ada2f0791b6bd435' \
  'make development-artifact-test'; do
  grep -F "$expected" "$workflow" >/dev/null \
    || fail "CI workflow is missing: $expected"
done

sed -n '/^  package-and-oci-smoke:/,$p' "$workflow" \
  | grep -F 'sudo apt-get update && sudo apt-get install --yes --no-install-recommends socat' >/dev/null \
  || fail 'package-and-oci-smoke does not install socat'

if grep -F 'ARTIFACT_DIRECTORY: ${{ runner.temp }}' "$development_artifact_workflow" >/dev/null; then
  fail 'development artifact workflow uses runner.temp in job-level env'
fi

grep -F 'ARTIFACT_DIRECTORY=$RUNNER_TEMP/yeokcham-development-artifacts' \
  "$development_artifact_workflow" >/dev/null \
  || fail 'development artifact workflow does not initialize ARTIFACT_DIRECTORY at step scope'

grep -F 'sudo apt-get update && sudo apt-get install --yes --no-install-recommends gnupg openssl socat' \
  "$development_artifact_workflow" >/dev/null \
  || fail 'development artifact workflow does not install its CI test tools'

grep -F 'opam install ocamlformat.0.29.0 --yes' "$development_artifact_workflow" >/dev/null \
  || fail 'development artifact workflow does not install the pinned formatter'

printf '%s\n' 'workflow CI test passed'
