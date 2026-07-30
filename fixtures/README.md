# Git fixtures

Run `scripts/generate-git-fixtures.sh` to create `fixtures/generated/`, or pass a different output directory. The generator refuses to overwrite an existing path and publishes the completed fixture directory atomically.

The generated format version 1 contains two bare SHA-1 repositories with the same deterministic commit, tree, and blob:

- `loose.git` stores the objects loose.
- `packed.git` stores the reachable objects in one pack and index.
- `manifest.txt` records the expected object IDs and ref.

Generated repositories are not committed. Run `scripts/verify-git-fixtures.sh` to generate two independent copies, compare their identities, validate storage forms, and run `git fsck --full --strict`.

`scripts/generate-sparse-workspace-fixture.sh` creates a deterministic two-commit SHA-1 repository for the W5 sparse-workspace benchmark. Its current `app/` path is small; `assets/current.bin` is a 4 MiB current excluded path; `history/obsolete.bin` is a separate 4 MiB historical blob. The generator output is untracked. `scripts/verify-sparse-workspace-fixture.sh` generates it twice, compares manifests, validates object identities, and checks the checkout layout.
