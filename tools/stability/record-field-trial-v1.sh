#!/bin/sh
set -eu
umask 077

usage() {
  printf '%s\n' \
    'usage: record-field-trial-v1.sh --platform linux|macos|wsl --release-version MAJOR.MINOR.PATCH --evidence-dir ABSOLUTE_DIRECTORY' >&2
  exit 2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

platform=''
release_version=''
evidence_dir=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform)
      [ "$#" -ge 2 ] || usage
      platform=$2
      shift 2
      ;;
    --release-version)
      [ "$#" -ge 2 ] || usage
      release_version=$2
      shift 2
      ;;
    --evidence-dir)
      [ "$#" -ge 2 ] || usage
      evidence_dir=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$platform" ] && [ -n "$release_version" ] && [ -n "$evidence_dir" ] || usage
printf '%s\n' "$release_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  printf '%s\n' 'release version must be MAJOR.MINOR.PATCH' >&2
  exit 2
}
case "$evidence_dir" in
  /*) ;;
  *)
    printf '%s\n' '--evidence-dir must be absolute' >&2
    exit 2
    ;;
esac

system=$(uname -s)
is_wsl=false
if [ "$system" = Linux ] && grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
  is_wsl=true
fi
case "$platform" in
  macos)
    [ "$system" = Darwin ] || fail 'requested macos evidence on a non-macOS host'
    ;;
  wsl)
    [ "$system" = Linux ] && [ "$is_wsl" = true ] ||
      fail 'requested wsl evidence on a host that is not WSL'
    ;;
  linux)
    [ "$system" = Linux ] && [ "$is_wsl" = false ] ||
      fail 'requested linux evidence on a non-Linux or WSL host'
    ;;
  *)
    usage
    ;;
esac

repository_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
cd "$repository_root"
[ -z "$(git status --porcelain)" ] || fail 'field trial requires a clean source commit'
commit=$(git rev-parse HEAD)

mkdir -p "$evidence_dir"
evidence=$evidence_dir/$platform.json
log=$evidence_dir/$platform.log
[ ! -e "$evidence" ] && [ ! -L "$evidence" ] || fail "evidence already exists: $evidence"
[ ! -e "$log" ] && [ ! -L "$log" ] || fail "log already exists: $log"

fixture_parent=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-field-trial.XXXXXX")
cleanup() {
  rm -rf "$fixture_parent"
}
trap cleanup EXIT HUP INT TERM

run() {
  {
    printf '$'
    for argument do
      printf ' %s' "$argument"
    done
    printf '\n'
    "$@"
    printf '\n'
  } >> "$log" 2>&1
}

host_os=$system
if [ "$system" = Darwin ] && command -v sw_vers >/dev/null 2>&1; then
  host_os=$(sw_vers -productName)
  host_version=$(sw_vers -productVersion)
else
  host_version=$(uname -r)
fi
architecture=$(uname -m)
git_version=$(git --version)
opam_version=$(opam --version)
ocaml_version=$(opam exec -- ocamlc -version)
dune_version=$(opam exec -- dune --version)

{
  printf 'platform=%s\ncommit=%s\nrelease-version=%s\n' "$platform" "$commit" "$release_version"
  printf 'host=%s %s %s\n' "$host_os" "$host_version" "$architecture"
  printf 'toolchain: %s; opam=%s; ocaml=%s; dune=%s\n\n' "$git_version" "$opam_version" "$ocaml_version" "$dune_version"
} > "$log"

run opam install . --deps-only --with-test --yes
run make check

source_root=$fixture_parent/repository
restore_parent=$fixture_parent/restore
archive=$fixture_parent/repository.tar
run mkdir "$source_root" "$restore_parent"
run opam exec -- dune exec bin/yeokcham.exe -- init --root "$source_root"
printf 'field-trial bytes\n' > "$source_root/payload"
chmod 754 "$source_root/payload"
ln -s payload "$source_root/payload-link"
run sh tools/stability/backup-full-repository-v1.sh --source "$source_root" --archive "$archive"
run tar -xf "$archive" -C "$restore_parent"
run opam exec -- dune exec bin/yeokcham.exe -- verify --root "$restore_parent/repository"

[ -x /usr/sbin/sshd ] && [ -x /usr/bin/ssh-keygen ] ||
  fail 'real known-contact SSH evidence requires /usr/sbin/sshd and /usr/bin/ssh-keygen'
run opam exec -- dune exec test/test_peer_sync_ssh.exe
grep -F 'real OpenSSH sync advances tracking' "$log" | grep -F '[OK]' >/dev/null ||
  fail 'the real known-contact OpenSSH test did not pass'

export FIELD_TRIAL_PLATFORM=$platform
export FIELD_TRIAL_RELEASE_VERSION=$release_version
export FIELD_TRIAL_COMMIT=$commit
export FIELD_TRIAL_HOST_OS=$host_os
export FIELD_TRIAL_HOST_VERSION=$host_version
export FIELD_TRIAL_ARCHITECTURE=$architecture
export FIELD_TRIAL_OCAML=$ocaml_version
export FIELD_TRIAL_OPAM=$opam_version
export FIELD_TRIAL_DUNE=$dune_version
export FIELD_TRIAL_GIT=$git_version
export FIELD_TRIAL_LOG=$(basename "$log")
python3 - "$evidence" <<'PY' >> "$log" 2>&1
import json
import os
import sys

path = sys.argv[1]
evidence = {
    "schema-version": 1,
    "platform": os.environ["FIELD_TRIAL_PLATFORM"],
    "release-version": os.environ["FIELD_TRIAL_RELEASE_VERSION"],
    "commit": os.environ["FIELD_TRIAL_COMMIT"],
    "host": {
        "os": os.environ["FIELD_TRIAL_HOST_OS"],
        "os-version": os.environ["FIELD_TRIAL_HOST_VERSION"],
        "architecture": os.environ["FIELD_TRIAL_ARCHITECTURE"],
    },
    "toolchain": {
        "ocaml": os.environ["FIELD_TRIAL_OCAML"],
        "opam": os.environ["FIELD_TRIAL_OPAM"],
        "dune": os.environ["FIELD_TRIAL_DUNE"],
    },
    "commands": [
        "opam install . --deps-only --with-test --yes",
        "make check",
        "yeokcham init --root <temporary>",
        "backup-full-repository-v1.sh --source <temporary> --archive <temporary>",
        "tar -xf <temporary archive> -C <temporary>",
        "yeokcham verify --root <temporary restored repository>",
        "opam exec -- dune exec test/test_peer_sync_ssh.exe",
    ],
    "checks": {
        "make-check": True,
        "full-backup-restore": True,
        "peer-ssh": True,
    },
    "result": "pass",
    "notes": "{}; retained command log={}".format(
        os.environ["FIELD_TRIAL_GIT"], os.environ["FIELD_TRIAL_LOG"]
    ),
}
with open(path, "x", encoding="utf-8") as handle:
    json.dump(evidence, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
python3 -m jsonschema --instance "$evidence" docs/stability/field-trial-v1.schema.json >> "$log" 2>&1

printf 'evidence=%s\nlog=%s\n' "$evidence" "$log"
