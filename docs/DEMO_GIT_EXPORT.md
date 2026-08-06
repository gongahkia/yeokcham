# GitHub-ready Git export demonstration

## M11-09 vertical slice

`tools/demo/demonstrate-git-export-v1.sh` composes the M11-08 immutable release
fixture, rejects an invalid Git destination, creates a fresh local Git
repository, and exports the verified release through the existing M8 bridge.
It records the Paengi release/final-snapshot/mapping IDs plus the Git tree,
commit, and deterministic export ref.

The script runs `git fsck --full`, resolves the export ref to the reported
commit, checks the exact regular-file byte oracle, renamed-path absence,
nonexecutable mode, symlink target, and absence of later scratch bytes. The
new Git repository has no remote, and the script never invokes `git push`.

## Run and inspect

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/paengi-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-git-export-v1.sh --root "$demo_root"
```

The script invokes the M11-08 release fixture itself. Git evidence is kept
under `.paengi/`; the isolated local export repository is `$demo_root/git-export`.
`demo-v1-git-export-fsck`, `demo-v1-git-export-ref`, and the two byte-oracle
files make the exported tree inspectable without a network operation.

## Interchange boundary

This is a Git commit/tree export for the verified release snapshot, not a full
Git compatibility or GitHub publication claim. Git alone does not reconstruct
Paengi scratch checkpoints, retention/pins, capsule current refs and intent,
workspace selection/attempt/conflict/resolution state, release validation
evidence, or Paengi ref-publication history. See `docs/GIT_INTERCHANGE.md` for
the complete preserved/opaque/rejected/lost contract.

Bad roots, unowned fixtures, repeated runs, invalid output IDs, invalid Git
destination acceptance, ref mismatch, fsck failure, missing byte/mode/symlink
oracle, or unexpected remote reject nonzero. Git process failures become the
existing structured bridge error path and do not publish an export mapping.

No model type, persistent format, ADR, `paengi` CLI behavior, Git import,
remote configuration, push, credential, signing, full-Git compatibility, or
performance claim is added.

## Verification

`test_demo_git_export` checks the focused export fixture's fsck/ref/byte/mode/
symlink oracle, later-scratch exclusion, empty remotes, invalid-destination
rejection, and unowned-root rejection. `make check` runs the focused test.
