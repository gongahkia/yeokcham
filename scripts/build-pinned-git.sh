#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <git-version> <empty-install-prefix>" >&2
  exit 2
fi

git_version=$1
install_prefix=$2
case "$git_version" in
  2.54.0)
    archive_sha256=f689162364c10de79ef89aa8dbf48731eb057e34edbbd20aca510ce0154681a3
    ;;
  2.55.0)
    archive_sha256=457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357
    ;;
  *)
    echo "unsupported pinned Git version: $git_version" >&2
    exit 2
    ;;
esac

if [[ -e "$install_prefix" ]]; then
  echo "Git install prefix already exists" >&2
  exit 2
fi

build_root=$(mktemp -d)
trap 'rm -rf -- "$build_root"' EXIT
archive="$build_root/git-$git_version.tar.xz"
source_directory="$build_root/git-$git_version"
archive_url="https://www.kernel.org/pub/software/scm/git/git-$git_version.tar.xz"

curl --fail --location --retry 3 --output "$archive" "$archive_url"
actual_sha256=$(shasum -a 256 "$archive")
if [[ "${actual_sha256%% *}" != "$archive_sha256" ]]; then
  echo "pinned Git source checksum does not match" >&2
  exit 1
fi
tar --extract --file "$archive" --xz --directory "$build_root"
make -C "$source_directory" NO_GETTEXT=YesPlease NO_TCLTK=YesPlease -j2
make -C "$source_directory" NO_GETTEXT=YesPlease NO_TCLTK=YesPlease prefix="$install_prefix" install

actual_version=$("$install_prefix/bin/git" version)
if [[ "$actual_version" != "git version $git_version" ]]; then
  echo "pinned Git build reported an unexpected version" >&2
  exit 1
fi
