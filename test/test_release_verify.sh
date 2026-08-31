#!/bin/sh

set -eu

verifier=${1:?expected path to release verifier}

fail() {
  printf '%s\n' "release-verify-test: $*" >&2
  exit 1
}

expect_success() {
  label=$1
  shift
  if ! "$@"; then
    fail "$label unexpectedly failed"
  fi
}

expect_failure() {
  label=$1
  expected_message=$2
  failure_output="$temporary_directory/failure-output"
  shift
  shift
  if "$@" >"$failure_output" 2>&1; then
    fail "$label unexpectedly succeeded"
  fi
  grep -F -- "$expected_message" "$failure_output" >/dev/null \
    || fail "$label did not report: $expected_message"
}

archive_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-release-verify-test.XXXXXX") \
  || fail "cannot create disposable test directory"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

repository="$temporary_directory/repository"
gpg_home="$temporary_directory/gnupg"
archive="$temporary_directory/yeokcham-v4.tar.gz"
mkdir -m 700 "$repository" "$gpg_home"

export GNUPGHOME="$gpg_home"
git init -q "$repository"
git -C "$repository" config user.name "Yeokcham Release Fixture"
git -C "$repository" config user.email "release-fixture@example.invalid"
printf '%s\n' source >"$repository/README"
git -C "$repository" add README
git -C "$repository" commit -q -m initial
commit=$(git -C "$repository" rev-parse HEAD)

gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "Yeokcham Release Fixture <release-fixture@example.invalid>" \
  ed25519 sign 0 >/dev/null 2>&1
fingerprint=$(gpg --batch --with-colons --list-keys \
  "release-fixture@example.invalid" 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10; exit }')
[ -n "$fingerprint" ] || fail "fixture signer fingerprint is missing"

git -C "$repository" -c user.signingkey="$fingerprint" \
  -c gpg.format=openpgp tag -s -m "V4 fixture source release" v0.0.0-test
git -C "$repository" tag lightweight-test
git -C "$repository" tag -a -m "unsigned fixture tag" unsigned-test

gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "Yeokcham Subkey Fixture <subkey-fixture@example.invalid>" \
  ed25519 cert 0 >/dev/null 2>&1
subkey_primary=$(gpg --batch --with-colons --list-keys \
  "subkey-fixture@example.invalid" 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-add-key "$subkey_primary" ed25519 sign 0 >/dev/null 2>&1
subkey_signing=$(gpg --batch --with-colons --list-keys \
  "subkey-fixture@example.invalid" 2>/dev/null \
  | awk -F: '$1 == "fpr" { count += 1; if (count == 2) { print $10; exit } }')
[ -n "$subkey_primary" ] && [ -n "$subkey_signing" ] \
  || fail "fixture signing subkey is missing"
git -C "$repository" -c user.signingkey="$subkey_signing" \
  -c gpg.format=openpgp tag -s -m "V4 fixture subkey source release" \
  v0.0.0-subkey-test

printf '%s\n' fixture-archive >"$archive"
checksum=$(archive_checksum <"$archive")

expect_success "valid signed candidate" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$commit" \
  --fingerprint "$fingerprint" --archive "$archive" --sha256 "$checksum"
expect_success "primary fingerprint accepts a signing subkey" \
  "$verifier" --repo "$repository" --tag v0.0.0-subkey-test --commit "$commit" \
  --fingerprint "$subkey_primary" --archive "$archive" --sha256 "$checksum"
expect_success "signing-subkey fingerprint is explicit" \
  "$verifier" --repo "$repository" --tag v0.0.0-subkey-test --commit "$commit" \
  --fingerprint "$subkey_signing" --archive "$archive" --sha256 "$checksum"
expect_failure "missing checksum" \
  "usage:" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$commit" \
  --fingerprint "$fingerprint" --archive "$archive"
expect_failure "malformed fingerprint" \
  "fingerprint must be" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$commit" \
  --fingerprint invalid --archive "$archive" --sha256 "$checksum"
expect_failure "lightweight tag" \
  "tag is lightweight" \
  "$verifier" --repo "$repository" --tag lightweight-test --commit "$commit" \
  --fingerprint "$fingerprint" --archive "$archive" --sha256 "$checksum"
expect_failure "unsigned annotated tag" \
  "tag signature did not verify" \
  "$verifier" --repo "$repository" --tag unsigned-test --commit "$commit" \
  --fingerprint "$fingerprint" --archive "$archive" --sha256 "$checksum"
expect_failure "mismatched signer" \
  "does not match expected fingerprint" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$commit" \
  --fingerprint 0000000000000000000000000000000000000000 --archive "$archive" \
  --sha256 "$checksum"

printf '%s\n' changed >>"$repository/README"
git -C "$repository" add README
git -C "$repository" commit -q -m changed
wrong_commit=$(git -C "$repository" rev-parse HEAD)
expect_failure "wrong commit" \
  "tag resolves to" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$wrong_commit" \
  --fingerprint "$fingerprint" --archive "$archive" --sha256 "$checksum"

printf '%s\n' changed-archive >>"$archive"
expect_failure "changed archive" \
  "archive SHA-256 is" \
  "$verifier" --repo "$repository" --tag v0.0.0-test --commit "$commit" \
  --fingerprint "$fingerprint" --archive "$archive" --sha256 "$checksum"

[ ! -e "$repository/.yeokcham" ] \
  || fail "release verification created Yeokcham project state"
