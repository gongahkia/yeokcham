#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf '%s\n' "workflow-security-test: $*" >&2
  exit 1
}

assert_pin() {
  workflow=$1
  action=$2
  revision=$3
  tag=$4
  line=$(grep -F "uses: $action@$revision" "$repository_root/$workflow" || true)
  [ -n "$line" ] || fail "$workflow does not pin $action to $revision"
  case "$line" in
    *"# $tag") ;;
    *) fail "$workflow does not record $action release tag $tag" ;;
  esac
}

find "$repository_root/.github/workflows" -type f -name '*.yml' -print |
  while IFS= read -r workflow; do
    sed -n 's/^[[:space:]]*[-]*[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
      "$workflow" |
      while IFS= read -r reference; do
        revision=${reference##*@}
        case "$revision" in
          '' | *[!0123456789abcdef]*)
            fail "mutable or malformed action reference $reference"
            ;;
        esac
        [ "${#revision}" -eq 40 ] \
          || fail "action reference is not a full commit SHA: $reference"
      done
  done

assert_pin .github/workflows/ci.yml actions/checkout \
  d23441a48e516b6c34aea4fa41551a30e30af803 v6.1.0
assert_pin .github/workflows/ci.yml ocaml/setup-ocaml \
  e89b2ded52a6e13f50162220cf5fe47290162032 v3.8.0
assert_pin .github/workflows/ci.yml ocaml/setup-ocaml/lint-fmt \
  e89b2ded52a6e13f50162220cf5fe47290162032 v3.8.0
assert_pin .github/workflows/ci.yml docker/setup-buildx-action \
  e468171a9de216ec08956ac3ada2f0791b6bd435 v3.11.1
assert_pin .github/workflows/development-client-artifact.yml actions/checkout \
  d23441a48e516b6c34aea4fa41551a30e30af803 v6.1.0
assert_pin .github/workflows/development-client-artifact.yml ocaml/setup-ocaml \
  e89b2ded52a6e13f50162220cf5fe47290162032 v3.8.0
assert_pin .github/workflows/development-client-artifact.yml docker/setup-buildx-action \
  e468171a9de216ec08956ac3ada2f0791b6bd435 v3.11.1
assert_pin .github/workflows/development-client-artifact.yml sigstore/cosign-installer \
  6f9f17788090df1f26f669e9d70d6ae9567deba6 v4.1.2
assert_pin .github/workflows/development-client-artifact.yml actions/upload-artifact \
  ea165f8d65b6e75b540449e92b4886f43607fa02 v4.6.2
assert_pin .github/workflows/relay-artifact.yml actions/checkout \
  d23441a48e516b6c34aea4fa41551a30e30af803 v6.1.0
assert_pin .github/workflows/relay-artifact.yml docker/setup-buildx-action \
  e468171a9de216ec08956ac3ada2f0791b6bd435 v3.11.1
assert_pin .github/workflows/relay-artifact.yml docker/login-action \
  af1e73f918a031802d376d3c8bbc3fe56130a9b0 v4.4.0
assert_pin .github/workflows/relay-artifact.yml docker/build-push-action \
  53b7df96c91f9c12dcc8a07bcb9ccacbed38856a v7.3.0
assert_pin .github/workflows/relay-artifact.yml sigstore/cosign-installer \
  6f9f17788090df1f26f669e9d70d6ae9567deba6 v4.1.2

printf '%s\n' 'workflow security test passed'
