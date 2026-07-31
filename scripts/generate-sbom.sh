#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <absent-output-directory>" >&2
  exit 2
fi

sbom_script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
sbom_root=$(cd -- "$sbom_script_dir/.." && pwd -P)
sbom_output=$1
sbom_parent=$(dirname -- "$sbom_output")
sbom_name=$(basename -- "$sbom_output")
sbom_cargo=${CARGO:-cargo}

[[ "$sbom_name" != . && "$sbom_name" != .. ]] || { echo "output directory name is invalid" >&2; exit 2; }
mkdir -p -- "$sbom_parent"
sbom_parent=$(cd -- "$sbom_parent" && pwd -P)
sbom_output="$sbom_parent/$sbom_name"
[[ ! -e "$sbom_output" && ! -L "$sbom_output" ]] || { echo "output directory already exists: $sbom_output" >&2; exit 1; }
command -v "$sbom_cargo" >/dev/null || { echo "cargo is required" >&2; exit 127; }

sbom_version=$($sbom_cargo cyclonedx --version 2>/dev/null || true)
[[ "$sbom_version" == "cargo-cyclonedx-cyclonedx 0.5.9" ]] || {
  echo "cargo-cyclonedx 0.5.9 is required; install with: cargo install cargo-cyclonedx --version 0.5.9 --locked" >&2
  exit 127
}

sbom_lock_before=$(shasum -a 256 "$sbom_root/Cargo.lock")
sbom_marker=$(mktemp "$sbom_root/.yeokcham-cdx.XXXXXX")
sbom_filename=$(basename -- "$sbom_marker")
sbom_stage=$(mktemp -d "$sbom_parent/.${sbom_name}.tmp.XXXXXX")

cleanup() {
  find "$sbom_root" -path "$sbom_root/.git" -prune -o -path "$sbom_root/target" -prune -o -type f -name "$sbom_filename.json" -delete
  rm -f -- "$sbom_marker"
  [[ -z ${sbom_stage:-} ]] || rm -rf -- "$sbom_stage"
}
trap cleanup EXIT HUP INT TERM

if find "$sbom_root" -path "$sbom_root/.git" -prune -o -path "$sbom_root/target" -prune -o -type f -name "$sbom_filename.json" -print -quit | grep -q .; then
  echo "generated SBOM filename already exists" >&2
  exit 1
fi

SOURCE_DATE_EPOCH=$(git -C "$sbom_root" log -1 --format=%ct) \
  "$sbom_cargo" cyclonedx --manifest-path "$sbom_root/Cargo.toml" --format json --all --all-features --target all --spec-version 1.5 --override-filename "$sbom_filename" -qq

[[ "$(shasum -a 256 "$sbom_root/Cargo.lock")" == "$sbom_lock_before" ]] || {
  echo "SBOM generation modified Cargo.lock" >&2
  exit 1
}

sbom_generated=()
while IFS= read -r -d '' sbom_file; do
  sbom_generated+=("$sbom_file")
done < <(find "$sbom_root/crates" -type f -name "$sbom_filename.json" -print0 | sort -z)
(( ${#sbom_generated[@]} == 4 )) || {
  echo "expected four workspace SBOM files, found ${#sbom_generated[@]}" >&2
  exit 1
}

for sbom_file in "${sbom_generated[@]}"; do
  perl -MJSON::PP -e '
    my $json = decode_json(do { local $/; <> });
    ref($json) eq "HASH" && $json->{bomFormat} eq "CycloneDX" && $json->{specVersion} eq "1.5"
      or die "invalid CycloneDX 1.5 JSON\n";
  ' "$sbom_file"
  sbom_package=$(basename -- "$(dirname -- "$sbom_file")")
  cp -- "$sbom_file" "$sbom_stage/$sbom_package.cdx.json"
done

(
  cd -- "$sbom_stage"
  shasum -a 256 -- *.cdx.json >SHA256SUMS
)
mv -- "$sbom_stage" "$sbom_output"
sbom_stage=
echo "SBOM files: $sbom_output"
