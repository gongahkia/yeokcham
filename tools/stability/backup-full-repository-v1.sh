#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: backup-full-repository-v1.sh --source ABSOLUTE_ROOT --archive ABSOLUTE_ARCHIVE.tar' \
    'Creates a new full archive and SHA-256 sidecar; never overwrites either file.' >&2
  exit 2
}

physical_directory() {
  cd -P "$1" && pwd
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

source_root=''
archive=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || usage
      source_root=$2
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

[ -n "$source_root" ] && [ -n "$archive" ] || usage

case "$source_root" in
  /*) ;;
  *)
    printf '%s\n' '--source must be an absolute path' >&2
    exit 2
    ;;
esac

case "$archive" in
  /*) ;;
  *)
    printf '%s\n' '--archive must be an absolute path' >&2
    exit 2
    ;;
esac

[ -d "$source_root" ] || {
  printf '%s\n' 'source root is not a directory' >&2
  exit 2
}
[ -d "$source_root/.yeokcham" ] || {
  printf '%s\n' 'source root does not contain .yeokcham' >&2
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

source_root=$(physical_directory "$source_root")
source_parent=$(physical_directory "$(dirname "$source_root")")
source_name=$(basename "$source_root")
archive_parent=$(physical_directory "$(dirname "$archive")")
archive_name=$(basename "$archive")

case "$source_root" in
  /)
    printf '%s\n' 'refusing to archive the filesystem root' >&2
    exit 2
    ;;
esac

case "$source_name" in
  ''|.|..|-*|*'
'|*'
'*)
    printf '%s\n' 'source root basename is unsafe for a portable tar archive' >&2
    exit 2
    ;;
esac

case "$archive_name" in
  ''|.|..|-*|*'
'|*'
'*)
    printf '%s\n' 'archive basename is unsafe' >&2
    exit 2
    ;;
esac

archive=$archive_parent/$archive_name
case "$archive" in
  "$source_root"/*)
    printf '%s\n' 'archive must be outside the source root' >&2
    exit 2
    ;;
esac

restore_parent=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-backup-restore.XXXXXX")
cleanup() {
  rm -rf "$restore_parent"
}
trap cleanup EXIT HUP INT TERM

: > "$archive"
chmod 600 "$archive"
tar -cf "$archive" -C "$source_parent" "$source_name"
: > "$archive.sha256"
chmod 600 "$archive.sha256"
sha256_file "$archive" > "$archive.sha256"

# Detect a source mutation during archiving before declaring the copy usable.
tar -df "$archive" -C "$source_parent"
tar -xf "$archive" -C "$restore_parent"
tar -df "$archive" -C "$restore_parent"

printf 'archive=%s\nchecksum=%s\nrestored-root=%s\n' \
  "$archive" "$archive.sha256" "$restore_parent/$source_name"
