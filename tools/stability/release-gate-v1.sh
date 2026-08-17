#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: release-gate-v1.sh --version MAJOR.MINOR.PATCH --signing-fingerprint 40_HEX --evidence-dir ABSOLUTE_DIRECTORY --archive ABSOLUTE_ARCHIVE.tar.gz' \
    'Verifies a signed, clean release tag and recorded Linux/macOS/WSL evidence, then creates a new source archive and SHA-256 sidecar.' >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    printf '%s\n' 'requires sha256sum or shasum' >&2
    return 127
  fi
}

version=''
signing_fingerprint=''
evidence_dir=''
archive=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || usage
      version=$2
      shift 2
      ;;
    --signing-fingerprint)
      [ "$#" -ge 2 ] || usage
      signing_fingerprint=$2
      shift 2
      ;;
    --evidence-dir)
      [ "$#" -ge 2 ] || usage
      evidence_dir=$2
      shift 2
      ;;
    --archive)
      [ "$#" -ge 2 ] || usage
      archive=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$version" ] && [ -n "$signing_fingerprint" ] && [ -n "$evidence_dir" ] && [ -n "$archive" ] || usage
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  printf '%s\n' 'release version must be MAJOR.MINOR.PATCH' >&2
  exit 2
}
printf '%s\n' "$signing_fingerprint" | grep -Eq '^[0-9A-Fa-f]{40}$' || {
  printf '%s\n' 'signing fingerprint must be exactly 40 hexadecimal characters' >&2
  exit 2
}
signing_fingerprint=$(printf '%s' "$signing_fingerprint" | tr 'A-F' 'a-f')

case "$evidence_dir" in
  /*) ;;
  *)
    printf '%s\n' '--evidence-dir must be absolute' >&2
    exit 2
    ;;
esac
case "$archive" in
  /*) ;;
  *)
    printf '%s\n' '--archive must be absolute' >&2
    exit 2
    ;;
esac

[ -d "$evidence_dir" ] || {
  printf '%s\n' 'evidence directory does not exist' >&2
  exit 2
}
[ ! -e "$archive" ] && [ ! -L "$archive" ] || {
  printf '%s\n' 'archive already exists; refusing to overwrite it' >&2
  exit 2
}
[ ! -e "$archive.sha256" ] && [ ! -L "$archive.sha256" ] || {
  printf '%s\n' 'archive checksum sidecar already exists; refusing to overwrite it' >&2
  exit 2
}

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
cd "$repository_root"

tag=v$version
head=$(git rev-parse HEAD)
tag_commit=$(git rev-list -n 1 "$tag" 2>/dev/null) || {
  printf '%s\n' "missing release tag $tag" >&2
  exit 1
}
[ "$head" = "$tag_commit" ] || {
  printf '%s\n' "release tag $tag does not name HEAD" >&2
  exit 1
}
git cat-file -e "$tag^{tag}" 2>/dev/null || {
  printf '%s\n' "release tag $tag must be annotated" >&2
  exit 1
}
signature_status=$(git verify-tag --raw "$tag" 2>&1) || {
  printf '%s\n' "$signature_status" >&2
  printf '%s\n' "release tag $tag has no valid signature" >&2
  exit 1
}
printf '%s\n' "$signature_status" |
  awk -v expected="$signing_fingerprint" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      for (index = 3; index <= NF; index++) {
        if (tolower($index) == expected) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' || {
  printf '%s\n' "release tag $tag was not signed by the expected fingerprint" >&2
  exit 1
}

[ -z "$(git status --porcelain)" ] || {
  printf '%s\n' 'working tree is not clean' >&2
  exit 1
}

schema=$repository_root/docs/stability/field-trial-v1.schema.json
for platform in linux macos wsl; do
  evidence=$evidence_dir/$platform.json
  [ -f "$evidence" ] || {
    printf '%s\n' "missing $platform field-trial evidence: $evidence" >&2
    exit 1
  }
  python3 -m jsonschema --instance "$evidence" "$schema"
  python3 - "$evidence" "$platform" "$version" "$head" <<'PY'
import json
import sys

path, platform, version, commit = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    evidence = json.load(handle)
if evidence["platform"] != platform:
    raise SystemExit(f"{path}: expected platform {platform}")
if evidence["release-version"] != version:
    raise SystemExit(f"{path}: expected release version {version}")
if evidence["commit"] != commit:
    raise SystemExit(f"{path}: expected commit {commit}")
PY
done

make check
git archive --format=tar.gz --prefix="yeokcham-$version/" "$tag" > "$archive"
sha256_file "$archive" > "$archive.sha256"
printf 'tag=%s\narchive=%s\nchecksum=%s\n' "$tag" "$archive" "$archive.sha256"
