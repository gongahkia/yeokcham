#!/bin/sh
set -eu

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
gate=$repository_root/tools/stability/release-gate-v1.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-release-gate-test.XXXXXX")
lightweight_tag=v999.0.0
unsigned_tag=v999.0.1
wrong_commit_tag=v999.0.2
signed_tag=v999.0.3
cleanup() {
  git -C "$repository_root" tag -d "$lightweight_tag" "$unsigned_tag" "$wrong_commit_tag" "$signed_tag" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

sh -n "$gate"

if sh "$gate" --version invalid --signing-fingerprint 0000000000000000000000000000000000000000 --evidence-dir /tmp --archive /tmp/yeokcham-release-gate-invalid.tar.gz >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted an invalid semantic version' >&2
  exit 1
fi

if sh "$gate" --version 1.0.0 --signing-fingerprint invalid --evidence-dir /tmp --archive /tmp/yeokcham-release-gate-invalid.tar.gz >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted an invalid signing fingerprint' >&2
  exit 1
fi

for tag in "$lightweight_tag" "$unsigned_tag" "$wrong_commit_tag" "$signed_tag"; do
  if git -C "$repository_root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    printf '%s\n' "test tag already exists: $tag" >&2
    exit 1
  fi
done

git -C "$repository_root" tag "$lightweight_tag"
if sh "$gate" --version 999.0.0 --signing-fingerprint 0000000000000000000000000000000000000000 --evidence-dir "$temporary" --archive "$temporary/archive.tar.gz" >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted a lightweight tag' >&2
  exit 1
fi

git -C "$repository_root" -c user.name='Release Gate Test' -c user.email='release-gate-test@example.invalid' tag -a "$unsigned_tag" -m 'unsigned test tag'
if sh "$gate" --version 999.0.1 --signing-fingerprint 0000000000000000000000000000000000000000 --evidence-dir "$temporary" --archive "$temporary/archive.tar.gz" >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted an unsigned annotated tag' >&2
  exit 1
fi

git -C "$repository_root" tag "$wrong_commit_tag" HEAD^
if sh "$gate" --version 999.0.2 --signing-fingerprint 0000000000000000000000000000000000000000 --evidence-dir "$temporary" --archive "$temporary/archive.tar.gz" >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted a tag for the wrong commit' >&2
  exit 1
fi

command -v gpg >/dev/null 2>&1 || {
  printf '%s\n' 'release-gate test requires gpg' >&2
  exit 1
}
export GNUPGHOME=$temporary/gnupg
mkdir "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
if ! gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Release Gate Test <release-gate-test@example.invalid>' ed25519 sign 0; then
  printf '%s\n' 'skipping expected-key mismatch fixture: temporary GPG key generation is unavailable' >&2
  exit 0
fi
fingerprint=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" { print $5; exit }')
[ -n "$fingerprint" ] || {
  printf '%s\n' 'failed to create a temporary test signing key' >&2
  exit 1
}
git -C "$repository_root" -c user.signingkey="$fingerprint" tag -s "$signed_tag" -m 'signed test tag'
if sh "$gate" --version 999.0.3 --signing-fingerprint 0000000000000000000000000000000000000000 --evidence-dir "$temporary" --archive "$temporary/archive.tar.gz" >/dev/null 2>&1; then
  printf '%s\n' 'release gate accepted a signature from an unexpected key' >&2
  exit 1
fi
