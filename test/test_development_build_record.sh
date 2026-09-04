#!/bin/sh

set -eu

repo_root=${YEOKCHAM_REPOSITORY:-${DUNE_SOURCEROOT:-$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)}}
cd "$repo_root"

fail() {
  printf '%s\n' "development-build-record-test: $*" >&2
  exit 1
}

for tool in base64 git jq mktemp sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

source_status=$(git status --porcelain)
scratch=$(mktemp -d /tmp/yeokcham-development-build-record-test.XXXXXX) \
  || fail "cannot create a disposable directory"
cleanup() {
  status=$?
  rm -r "$scratch"
  [ "$(git status --porcelain)" = "$source_status" ] \
    || fail "record test changed repository source files"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

artifacts=$scratch/artifacts
mkdir "$artifacts"
printf '%s\n' archive >"$artifacts/yeokcham-0.0.0-linux-x86_64.tar.zst"
printf '%s\n' rpm >"$artifacts/yeokcham-0.0.0-0.dev.fc43.x86_64.rpm"
printf '%s\n' sbom >"$artifacts/sbom.spdx.json"
printf '%s\n' provenance >"$artifacts/provenance.json"
(
  cd "$artifacts"
  sha256sum \
    yeokcham-0.0.0-linux-x86_64.tar.zst \
    yeokcham-0.0.0-0.dev.fc43.x86_64.rpm \
    sbom.spdx.json \
    provenance.json >SHA256SUMS
)
certificate='development record test certificate'
certificate_raw=$(printf %s "$certificate" | base64 -w 0)
printf '%s\n' \
  "{\"verificationMaterial\":{\"certificate\":{\"rawBytes\":\"$certificate_raw\"}}}" \
  >"$artifacts/SHA256SUMS.sigstore.json"

workflow_identity=https://github.com/example/yeokcham/.github/workflows/development-client-artifact.yml@refs/heads/main
oidc_issuer=https://token.actions.githubusercontent.com
tools/write-development-build-record.sh --directory "$artifacts" \
  --bundle SHA256SUMS.sigstore.json \
  --workflow-identity "$workflow_identity" --oidc-issuer "$oidc_issuer"

record=$artifacts/development-build-record-v1.json
[ -f "$record" ] || fail "canonical record was not written"
jq -e \
  --arg identity "$workflow_identity" \
  --arg issuer "$oidc_issuer" \
  '.schema_version == 1
   and .architecture == "linux-x86_64"
   and .signing.workflow_identity == $identity
   and .signing.oidc_issuer == $issuer
   and .signing.bundle_filename == "SHA256SUMS.sigstore.json"
   and (.artifacts | length == 2)' "$record" >/dev/null \
  || fail "record does not bind the expected delivery inputs"

rm -f "$record" "$artifacts/SHA256SUMS.sigstore.json"
if tools/write-development-build-record.sh --directory "$artifacts" \
  --bundle SHA256SUMS.sigstore.json \
  --workflow-identity "$workflow_identity" --oidc-issuer "$oidc_issuer" \
  >/dev/null 2>&1; then
  fail "record generation accepted an absent signing bundle"
fi
[ ! -e "$record" ] || fail "absent-bundle refusal wrote a record"

printf '%s\n' \
  "{\"verificationMaterial\":{\"certificate\":{\"rawBytes\":\"$certificate_raw\"}}}" \
  >"$artifacts/SHA256SUMS.sigstore.json"
printf '%s\n' corruption >>"$artifacts/yeokcham-0.0.0-linux-x86_64.tar.zst"
if tools/write-development-build-record.sh --directory "$artifacts" \
  --bundle SHA256SUMS.sigstore.json \
  --workflow-identity "$workflow_identity" --oidc-issuer "$oidc_issuer" \
  >/dev/null 2>&1; then
  fail "record generation accepted a checksum mismatch"
fi
[ ! -e "$record" ] || fail "checksum refusal wrote a record"

if tools/write-development-build-record.sh --directory "$repo_root" \
  --bundle SHA256SUMS.sigstore.json \
  --workflow-identity "$workflow_identity" --oidc-issuer "$oidc_issuer" \
  >/dev/null 2>&1; then
  fail "record generation accepted repository output"
fi

printf '%s\n' 'development build record test passed'
