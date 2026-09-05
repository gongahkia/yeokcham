#!/bin/sh

# Verify one supplied V1 source-release candidate. This is intentionally
# outside the Yeokcham model and never invokes the yeokcham executable.

set -eu
umask 077

usage() {
  cat >&2 <<'EOF'
usage: verify-v1-source-release.sh [--repo PATH] --tag TAG --commit COMMIT \
  --fingerprint OPENPGP_FINGERPRINT --archive PATH --sha256 SHA256

All candidate values are explicit. The verifier checks an annotated OpenPGP-
signed Git tag, its exact commit, its signer fingerprint, and an archive digest.
EOF
  exit 64
}

fail() {
  printf '%s\n' "release-verify: $*" >&2
  exit 2
}

require_value() {
  [ "$#" -ge 2 ] || usage
  [ -n "$2" ] || usage
}

normalize_hex() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

is_full_fingerprint() {
  value=$1
  case $value in
    *[!0123456789ABCDEFabcdef]* | '') return 1 ;;
  esac
  length=${#value}
  [ "$length" -eq 40 ] || [ "$length" -eq 64 ]
}

is_sha256() {
  value=$1
  case $value in
    *[!0123456789ABCDEFabcdef]* | '') return 1 ;;
  esac
  [ "${#value}" -eq 64 ]
}

repository=.
seen_repository=0
tag=
expected_commit=
expected_fingerprint=
archive=
expected_sha256=

while [ "$#" -gt 0 ]; do
  case $1 in
    --repo)
      require_value "$@"
      [ "$seen_repository" -eq 0 ] || fail "--repo was supplied more than once"
      repository=$2
      seen_repository=1
      shift 2
      ;;
    --tag)
      require_value "$@"
      [ -z "$tag" ] || fail "--tag was supplied more than once"
      tag=$2
      shift 2
      ;;
    --commit)
      require_value "$@"
      [ -z "$expected_commit" ] || fail "--commit was supplied more than once"
      expected_commit=$2
      shift 2
      ;;
    --fingerprint)
      require_value "$@"
      [ -z "$expected_fingerprint" ] || fail "--fingerprint was supplied more than once"
      expected_fingerprint=$2
      shift 2
      ;;
    --archive)
      require_value "$@"
      [ -z "$archive" ] || fail "--archive was supplied more than once"
      archive=$2
      shift 2
      ;;
    --sha256)
      require_value "$@"
      [ -z "$expected_sha256" ] || fail "--sha256 was supplied more than once"
      expected_sha256=$2
      shift 2
      ;;
    --help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$tag" ] || usage
[ -n "$expected_commit" ] || usage
[ -n "$expected_fingerprint" ] || usage
[ -n "$archive" ] || usage
[ -n "$expected_sha256" ] || usage

command -v git >/dev/null 2>&1 || fail "Git is required"
gpg_program=${GPG:-gpg}
case $gpg_program in
  *' '* | *'	'*) fail "GPG must name one executable, not a shell command" ;;
esac
gpg_path=$(command -v "$gpg_program") || fail "OpenPGP verifier is unavailable: $gpg_program"

[ -d "$repository" ] || fail "repository directory does not exist: $repository"
git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "not a Git repository: $repository"

tag_ref="refs/tags/$tag"
git -C "$repository" check-ref-format --allow-onelevel "$tag_ref" \
  >/dev/null 2>&1 || fail "invalid tag name: $tag"

case $expected_commit in
  *[!0123456789ABCDEFabcdef]* | '') fail "expected commit is not hexadecimal" ;;
esac
object_format=$(git -C "$repository" rev-parse --show-object-format)
case $object_format in
  sha1) expected_commit_length=40 ;;
  sha256) expected_commit_length=64 ;;
  *) fail "unsupported Git object format: $object_format" ;;
esac
[ "${#expected_commit}" -eq "$expected_commit_length" ] \
  || fail "expected commit must be a full $object_format object ID"

is_full_fingerprint "$expected_fingerprint" \
  || fail "fingerprint must be a full 40- or 64-hex-character OpenPGP fingerprint"
is_sha256 "$expected_sha256" \
  || fail "SHA-256 must be a 64-hex-character digest"
[ -f "$archive" ] || fail "archive is not a regular file: $archive"

tag_object=$(git -C "$repository" rev-parse --verify --quiet "$tag_ref") \
  || fail "tag does not exist: $tag"
[ "$(git -C "$repository" cat-file -t "$tag_object")" = tag ] \
  || fail "tag is lightweight; an annotated signed tag is required"
actual_commit=$(git -C "$repository" rev-parse --verify --quiet "${tag_object}^{commit}") \
  || fail "annotated tag does not resolve to a commit: $tag"

expected_commit=$(normalize_hex "$expected_commit")
actual_commit=$(normalize_hex "$actual_commit")
[ "$actual_commit" = "$expected_commit" ] \
  || fail "tag resolves to $actual_commit, not expected commit $expected_commit"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-release-verify.XXXXXX") \
  || fail "cannot create a disposable verification directory"
status_file="$temporary_directory/gpg-status"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$repository" -c gpg.format=openpgp \
  -c "gpg.openpgp.program=$gpg_path" verify-tag --raw "$tag_ref" \
  >"$status_file" 2>&1; then
  sed 's/^/release-verify: Git\/GnuPG: /' "$status_file" >&2
  fail "tag signature did not verify"
fi

expected_fingerprint=$(normalize_hex "$expected_fingerprint")
matching_signer=0
signer_file="$temporary_directory/signers"
awk '/^\[GNUPG:\] VALIDSIG / { print $3; print $NF }' "$status_file" \
  >"$signer_file"
while IFS= read -r signer; do
  if is_full_fingerprint "$signer" \
    && [ "$(normalize_hex "$signer")" = "$expected_fingerprint" ]; then
    matching_signer=1
  fi
done <"$signer_file"
[ "$matching_signer" -eq 1 ] \
  || fail "valid tag signature does not match expected fingerprint $expected_fingerprint"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256=$(sha256sum <"$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256=$(shasum -a 256 <"$archive" | awk '{ print $1 }')
else
  fail "neither sha256sum nor shasum is available"
fi
actual_sha256=$(normalize_hex "$actual_sha256")
expected_sha256=$(normalize_hex "$expected_sha256")
[ "$actual_sha256" = "$expected_sha256" ] \
  || fail "archive SHA-256 is $actual_sha256, not expected $expected_sha256"

printf '%s\n' "release-verify: verified source tag $tag"
printf '%s\n' "release-verify: commit $actual_commit"
printf '%s\n' "release-verify: signer $expected_fingerprint"
printf '%s\n' "release-verify: archive-sha256 $actual_sha256"
