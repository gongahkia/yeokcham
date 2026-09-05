#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

fail() {
  printf '%s\n' "development-artifacts: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: tools/build-development-artifacts.sh --output DIRECTORY [--version VERSION] [--release RELEASE]

Build unsigned, development-only Linux x86_64 client artifacts in the named
otherwise-empty directory. BuildKit exports SPDX SBOM and provenance files.
This command does not publish, sign, install, invoke Yeokcham, or alter a V1
repository. CI signs SHA256SUMS and the external build record separately.
EOF
}

output=
version=0.0.0
release=0.dev
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || fail "--output requires a directory"
      output=$2
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || fail "--version requires a value"
      version=$2
      shift 2
      ;;
    --release)
      [ "$#" -ge 2 ] || fail "--release requires a value"
      release=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$output" ] || {
  usage >&2
  exit 2
}
case "$output" in
  /*) ;;
  *) fail "--output must be an absolute directory outside the repository" ;;
esac
case "$output" in
  "$repo_root" | "$repo_root"/*) fail "artifact output must be outside the repository" ;;
esac
case "$version" in
  '' | *[!A-Za-z0-9._+-]*) fail "version and release must be nonempty RPM-safe text" ;;
esac
case "$release" in
  '' | *[!A-Za-z0-9._+-]*) fail "version and release must be nonempty RPM-safe text" ;;
esac

for tool in docker git sha256sum sort find awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

if [ -e "$output" ]; then
  [ -d "$output" ] || fail "output is not a directory: $output"
  [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "output directory is not empty: $output"
else
  mkdir -p "$output" || fail "cannot create output directory: $output"
fi
output=$(cd -- "$output" && pwd -P)
case "$output" in
  "$repo_root" | "$repo_root"/*) fail "artifact output resolves inside the repository" ;;
esac

source_status=$(git status --porcelain)
check_source_status() {
  [ "$(git status --porcelain)" = "$source_status" ] \
    || fail "build changed repository source files"
}
trap 'status=$?; check_source_status; exit "$status"' EXIT HUP INT TERM

source_timestamp=$(git show -s --format=%ct HEAD) \
  || fail "cannot determine source timestamp"
case "$source_timestamp" in
  '' | *[!0-9]*) fail "source timestamp is not an integer" ;;
esac

docker buildx build --progress=plain --sbom=true --provenance=mode=max \
  --file containers/client/Containerfile --target export \
  --build-arg "SOURCE_DATE_EPOCH=$source_timestamp" \
  --build-arg "DEVELOPMENT_VERSION=$version" \
  --build-arg "DEVELOPMENT_RELEASE=$release" \
  --output "type=local,dest=$output" .

for artifact in sbom.spdx.json provenance.json; do
  [ -f "$output/$artifact" ] || fail "BuildKit did not export $artifact"
done

(
  cd "$output"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort \
    | while IFS= read -r artifact; do
        sha256sum "$artifact"
      done
) >"$output/SHA256SUMS"

printf '%s\n' "unsigned development artifacts written to $output"
