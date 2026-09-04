#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

fail() {
  printf '%s\n' "development-artifact-test: $*" >&2
  exit 1
}

for tool in docker git sha256sum tar mktemp sed; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

source_status=$(git status --porcelain)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-development-artifact-test.XXXXXX") \
  || fail "cannot create a disposable directory"
cleanup() {
  status=$?
  rm -r "$scratch"
  [ "$(git status --porcelain)" = "$source_status" ] \
    || fail "artifact test changed repository source files"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ -n "${YEOKCHAM_DEVELOPMENT_ARTIFACTS:-}" ]; then
  artifacts=$YEOKCHAM_DEVELOPMENT_ARTIFACTS
  case "$artifacts" in
    /*) ;;
    *) fail "YEOKCHAM_DEVELOPMENT_ARTIFACTS must be an absolute directory" ;;
  esac
  [ -d "$artifacts" ] || fail "named development artifact directory is absent"
else
  artifacts=$scratch/artifacts
  tools/build-development-artifacts.sh --output "$artifacts"
fi
(cd "$artifacts" && sha256sum --check SHA256SUMS)

archive=$(find "$artifacts" -maxdepth 1 -name 'yeokcham-*-linux-x86_64.tar.zst' -type f -print -quit)
rpm=$(find "$artifacts" -maxdepth 1 -name 'yeokcham-*.x86_64.rpm' -type f -print -quit)
[ -n "$archive" ] || fail "client archive is absent"
[ -n "$rpm" ] || fail "Fedora RPM is absent"

archive_root=$scratch/archive
mkdir "$archive_root"
tar --zstd -xf "$archive" -C "$archive_root"
[ "$(tar --zstd -tf "$archive" | LC_ALL=C sort)" = './
./LICENSE
./usr/
./usr/bin/
./usr/bin/yeokcham' ] || fail "archive layout changed"
[ -x "$archive_root/usr/bin/yeokcham" ] || fail "archive client is not executable"
"$archive_root/usr/bin/yeokcham" --version >/dev/null

fedora_image=registry.fedoraproject.org/fedora:43@sha256:8d775fbb86b8aa62172a2fd33203d285743ad2b74df8416322066e59e917b4ef
docker run --rm \
  --mount "type=bind,src=$artifacts,dst=/artifacts,readonly" \
  --mount "type=bind,src=$scratch,dst=/smoke" \
  "$fedora_image" sh -eu -c '
    dnf install --assumeyes --setopt=install_weak_deps=False /artifacts/*.rpm
    test -x /usr/bin/yeokcham
    test -z "$(rpm -q --scripts yeokcham)"
    test ! -e /usr/lib/systemd/system/yeokcham.service
    test ! -e /etc/systemd/system/yeokcham.service
    mkdir /smoke/signer /smoke/project
    printf "%s\\n" before > /smoke/project/note.txt
    export YEOKCHAM_V4_TEST_SIGNER_DIRECTORY=/smoke/signer
    initial=$(/usr/bin/yeokcham init --root /smoke/project --username smoke --draft package --title package-smoke | sed -n "s/^saved //p" | sed -n "1p")
    test "${#initial}" = 64
    printf "%s\\n" after > /smoke/project/note.txt
    /usr/bin/yeokcham save --root /smoke/project >/dev/null
    /usr/bin/yeokcham restore --root /smoke/project --checkpoint "$initial" >/dev/null
    test "$(cat /smoke/project/note.txt)" = before
    /usr/bin/yeokcham verify --root /smoke/project >/dev/null
    dnf remove --assumeyes yeokcham
    test ! -e /usr/bin/yeokcham
    chmod -R a+rwX /smoke/project /smoke/signer
  '

YEOKCHAM_RELAY_TEST_CLIENT="$archive_root/usr/bin/yeokcham" \
  make relay-container-test

printf '%s\n' 'development artifact integration passed'
