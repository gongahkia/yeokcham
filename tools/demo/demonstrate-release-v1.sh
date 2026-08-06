#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: demonstrate-release-v1.sh --root <absolute-demo-directory>' >&2
  exit 2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

valid_id() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0123456789abcdef]*) return 1 ;; esac
}

root=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage
      [ -z "$root" ] || usage
      root=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$root" ] || usage
case "$root" in /*) ;; *) fail 'demo root must be absolute' ;; esac
parent=$(dirname "$root")
name=$(basename "$root")
case "$name" in '' | . | ..) fail 'demo root must name one directory' ;; esac
[ -d "$parent" ] || fail 'demo root parent must exist'
parent=$(cd "$parent" && pwd -P)
root=$parent/$name
[ -d "$root" ] || fail 'demo root must be a directory'
[ -f "$root/.paengi-demo-owned-v1" ] || fail 'demo ownership marker is missing'
[ "$(cat "$root/.paengi-demo-owned-v1")" = 'paengi-demo-owned-v1' ] || fail 'demo ownership marker is invalid'
[ ! -e "$root/.paengi/demo-v1-release-create" ] || fail 'release demonstration was already run for this root'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(dirname "$(dirname "$script_dir")")
run_paengi() {
  if [ -n "${PAENGI_BIN:-}" ]; then
    [ -x "$PAENGI_BIN" ] || fail 'PAENGI_BIN must name an executable'
    "$PAENGI_BIN" "$@" --root "$root"
  else
    (cd "$project_root" && opam exec -- dune exec bin/paengi.exe -- "$@" --root "$root")
  fi
}
run_release_evidence() {
  release=$1
  if [ -n "${PAENGI_RELEASE_EVIDENCE_BIN:-}" ]; then
    [ -x "$PAENGI_RELEASE_EVIDENCE_BIN" ] || fail 'PAENGI_RELEASE_EVIDENCE_BIN must name an executable'
    "$PAENGI_RELEASE_EVIDENCE_BIN" --root "$root" --release "$release"
  else
    (cd "$project_root" && opam exec -- dune exec bin/release_evidence_v1.exe -- --root "$root" --release "$release")
  fi
}

workspace=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
missing_parent=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
sh "$script_dir/demonstrate-workspace-v1.sh" --root "$root"
run_paengi work materialise "$workspace" > "$root/.paengi/demo-v1-release-materialise"
materialise=$(cat "$root/.paengi/demo-v1-release-materialise")
case "$materialise" in *'partial=false'*) ;; *) fail 'release workspace materialisation is partial' ;; esac
run_paengi release create --workspace "$workspace" --message 'demo release' --validation-exec /usr/bin/true > "$root/.paengi/demo-v1-release-create"
release_output=$(cat "$root/.paengi/demo-v1-release-create")
case "$release_output" in release=*' final='*' evidence=1') ;; *) fail 'release creation output is invalid' ;; esac
release=${release_output#release=}
release=${release%% *}
final=${release_output#* final=}
final=${final%% *}
valid_id "$release" && valid_id "$final" || fail 'release identity is invalid'
run_paengi release show "$release" > "$root/.paengi/demo-v1-release-show-before-change"
run_paengi release verify "$release" > "$root/.paengi/demo-v1-release-verify-before-change"
run_release_evidence "$release" > "$root/.paengi/demo-v1-release-evidence"
evidence_output=$(cat "$root/.paengi/demo-v1-release-evidence")
case "$evidence_output" in "release=$release evidence="*' object='*) ;; *) fail 'release evidence output is invalid' ;; esac
evidence=${evidence_output#"release=$release evidence="}
evidence=${evidence%% *}
evidence_object=${evidence_output##* object=}
valid_id "$evidence" && valid_id "$evidence_object" || fail 'release evidence identity is invalid'
run_paengi validation run --snapshot "$final" --exec /usr/bin/true > "$root/.paengi/demo-v1-release-validation"
validation_output=$(cat "$root/.paengi/demo-v1-release-validation")
case "$validation_output" in evidence=*' object='*' status=passed') ;; *) fail 'validation evidence output is invalid' ;; esac
validation_evidence=${validation_output#evidence=}
validation_evidence=${validation_evidence%% *}
validation_object=${validation_output#* object=}
validation_object=${validation_object%% *}
[ "$evidence" = "$validation_evidence" ] || fail 'release evidence logical identity differs'
run_paengi release list > "$root/.paengi/demo-v1-release-list-before-unsupported"
if run_paengi release create --workspace "$workspace" --parent "$missing_parent" --validation-exec /usr/bin/true > "$root/.paengi/demo-v1-release-unsupported-parent" 2>&1; then
  fail 'missing release parent was accepted'
fi
run_paengi release list > "$root/.paengi/demo-v1-release-list-after-unsupported"
cmp -s "$root/.paengi/demo-v1-release-list-before-unsupported" "$root/.paengi/demo-v1-release-list-after-unsupported" || fail 'missing release parent changed visible releases'
printf '%s\n' 'post-release scratch bytes' > "$root/release-after.txt"
run_paengi checkpoint > "$root/.paengi/demo-v1-release-post-change-checkpoint"
run_paengi release show "$release" > "$root/.paengi/demo-v1-release-show-after-change"
run_paengi release verify "$release" > "$root/.paengi/demo-v1-release-verify-after-change"
cmp -s "$root/.paengi/demo-v1-release-show-before-change" "$root/.paengi/demo-v1-release-show-after-change" || fail 'release display changed after scratch edit'
cmp -s "$root/.paengi/demo-v1-release-verify-before-change" "$root/.paengi/demo-v1-release-verify-after-change" || fail 'release verification changed after scratch edit'
printf 'release=%s\nfinal=%s\nevidence=%s\nevidence-object=%s\nvalidation-evidence-object=%s\n' "$release" "$final" "$evidence" "$evidence_object" "$validation_object"
