#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

fail() {
  printf '%s\n' "development-build-record: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: tools/write-development-build-record.sh --directory DIRECTORY --bundle FILENAME \
  --workflow-identity URI --oidc-issuer URI

Verify the unsigned artifact checksum manifest, extract the SHA-256 fingerprint
of the certificate in its Cosign bundle, and write the canonical external
development-build-record-v1.json. The bundle must sign SHA256SUMS. This command
does not sign, publish, install, invoke Yeokcham, or alter a V4 repository.
EOF
}

directory=
bundle=
workflow_identity=
oidc_issuer=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --directory)
      [ "$#" -ge 2 ] || fail "--directory requires a value"
      directory=$2
      shift 2
      ;;
    --bundle)
      [ "$#" -ge 2 ] || fail "--bundle requires a filename"
      bundle=$2
      shift 2
      ;;
    --workflow-identity)
      [ "$#" -ge 2 ] || fail "--workflow-identity requires a value"
      workflow_identity=$2
      shift 2
      ;;
    --oidc-issuer)
      [ "$#" -ge 2 ] || fail "--oidc-issuer requires a value"
      oidc_issuer=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -d "$directory" ] || fail "--directory must name an existing directory"
directory=$(cd -- "$directory" && pwd -P)
case "$directory" in
  "$repo_root" | "$repo_root"/*) fail "artifact directory must be outside the repository" ;;
esac
[ -n "$bundle" ] || fail "--bundle is required"
[ -n "$workflow_identity" ] || fail "--workflow-identity is required"
[ -n "$oidc_issuer" ] || fail "--oidc-issuer is required"
case "$bundle" in
  */* | .* | *'..'*) fail "--bundle must be a plain filename" ;;
esac

for tool in awk base64 find git jq mktemp sed sha256sum stat wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

source_status=$(git status --porcelain)
check_source_status() {
  [ "$(git status --porcelain)" = "$source_status" ] \
    || fail "record generation changed repository source files"
}
trap 'status=$?; check_source_status; exit "$status"' EXIT HUP INT TERM

[ -f "$directory/SHA256SUMS" ] || fail "checksum manifest is absent"
[ -s "$directory/$bundle" ] || fail "signing bundle is absent"
[ ! -e "$directory/development-build-record-v1.json" ] \
  || fail "build record already exists"

for artifact in sbom.spdx.json provenance.json; do
  [ -f "$directory/$artifact" ] || fail "artifact is absent: $artifact"
done
(cd "$directory" && sha256sum --check SHA256SUMS >/dev/null) \
  || fail "checksum manifest does not verify"

value_from_lock() {
  key=$1
  value=$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' \
    containers/client/build-inputs.lock)
  [ -n "$value" ] || fail "client build-inputs lock lacks $key"
  printf '%s\n' "$value"
}

source_commit=$(git rev-parse HEAD) || fail "cannot determine source commit"
source_timestamp=$(git show -s --format=%ct HEAD) \
  || fail "cannot determine source timestamp"
opam_lock_sha256=$(sha256sum yeokcham.opam.locked | awk '{ print $1 }')
builder_image=$(value_from_lock builder)
fedora_image=$(value_from_lock fedora)
ocaml_version=$(value_from_lock ocaml)
dune_version=$(value_from_lock dune)
sbom_sha256=$(sha256sum "$directory/sbom.spdx.json" | awk '{ print $1 }')
certificate_raw=$(jq -er '.verificationMaterial.certificate.rawBytes' \
  "$directory/$bundle") || fail "signing bundle has no certificate"
certificate_file=$(mktemp "$directory/.signing-certificate.XXXXXX") \
  || fail "cannot create a temporary certificate file"
trap 'status=$?; rm -f "$certificate_file"; check_source_status; exit "$status"' EXIT HUP INT TERM
printf %s "$certificate_raw" | base64 --decode >"$certificate_file" \
  || fail "signing bundle certificate is not base64"
[ -s "$certificate_file" ] || fail "signing bundle certificate is empty"
certificate_sha256=$(sha256sum "$certificate_file" | awk '{ print $1 }')
rm -f "$certificate_file"

find_artifact() {
  pattern=$1
  found=$(find "$directory" -maxdepth 1 -type f -name "$pattern" -printf '%f\n')
  [ "$(printf '%s\n' "$found" | sed '/^$/d' | wc -l)" -eq 1 ] \
    || fail "expected exactly one artifact matching $pattern"
  printf '%s\n' "$found"
}

archive=$(find_artifact 'yeokcham-*-linux-x86_64.tar.zst')
rpm=$(find_artifact 'yeokcham-*.x86_64.rpm')
temporary=$(mktemp "$directory/.development-build-record-v1.XXXXXX") \
  || fail "cannot create a temporary record"
trap 'status=$?; rm -f "$temporary" "$certificate_file"; check_source_status; exit "$status"' EXIT HUP INT TERM

# Artifact names, digests, and sizes are build-controlled hexadecimal/text
# values. The renderer receives each item as one explicit argv element.
set -- \
  --source-commit "$source_commit" \
  --source-timestamp "$source_timestamp" \
  --architecture linux-x86_64 \
  --ocaml-version "$ocaml_version" \
  --dune-version "$dune_version" \
  --opam-lock-sha256 "$opam_lock_sha256" \
  --builder-image "$builder_image" \
  --fedora-image "$fedora_image" \
  --sbom-sha256 "$sbom_sha256" \
  --workflow-identity "$workflow_identity" \
  --oidc-issuer "$oidc_issuer" \
  --certificate-sha256 "$certificate_sha256" \
  --bundle-filename "$bundle"
for pair in "client-archive:$archive" "fedora-rpm:$rpm"; do
  kind=${pair%%:*}
  filename=${pair#*:}
  sha256=$(sha256sum "$directory/$filename" | awk '{ print $1 }')
  size=$(stat -c %s "$directory/$filename")
  set -- "$@" --artifact "$kind:$filename:$sha256:$size"
done

opam exec -- dune exec tools/render_development_build_record.exe -- "$@" \
  >"$temporary" || fail "canonical record renderer refused the delivery inputs"
mv "$temporary" "$directory/development-build-record-v1.json"
printf '%s\n' "development build record written to $directory/development-build-record-v1.json"
