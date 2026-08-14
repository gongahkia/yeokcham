# ADR-074 — Git archive preservation and exit

- Status: Accepted
- Date: 2026-08-15
- Deciders: maintainer
- Governing issue: [#234](https://github.com/gongahkia/yeokcham/issues/234)
- Supersedes: None
- Superseded by: None

## Context and problem statement

The existing Git bridge imports individual trees, commits, and tags and exports
selected Yeokcham releases or revision sequences. It does not preserve a Git
repository as a migration source or let a user reconstruct the selected Git
history when leaving Yeokcham. A source path, Git configuration, index,
worktree, hook, credential, and reflog must not become Yeokcham canonical state
just to offer that safety boundary.

Git documents bundles as an offline transfer of reachable objects and refs. A
self-contained bundle can seed a new repository; it does not contain a working
tree, index, configuration, or hooks. That boundary matches the desired
preservation/exit promise.

## Decision drivers

- Preserve selected Git history without making Git objects canonical Yeokcham
  model values.
- Retain Git object IDs and ref names byte-for-byte where Git permits them.
- Make repeated import, corruption, shallow history, and interruption explicit.
- Reconstruct an ordinary Git repository and verify it with Git itself.

## Considered options

### Copy the `.git` directory

- Appears lossless for one implementation.
- Captures user-specific configuration and credentials, depends on pack/ref
  storage details, and does not define a portable canonical boundary.

### Flatten imported commits into Yeokcham capsules

- Gives an immediately familiar UI.
- Invents human intent and loses Git graph meaning before the user has chosen
  an adoption policy.

### Store a self-contained Git bundle with an immutable Yeokcham archive record

- Uses Git's documented object/ref transfer representation.
- Keeps the archive foreign and permits an independently verified exit.
- Deliberately excludes working-tree and local Git operational state.

## Decision outcome

Use a self-contained Git bundle and an immutable `Git_archive_v1` record.

ADR-075 extends new creation to `Git_archive_v2` for exact ref selection and
source capability provenance. The V1 record and decoder remain valid for
already-created archives; this decision continues to define the preservation
and exit boundary for both versions.

The importer inventories all selected Git refs with `--no-replace-objects`,
rejects shallow repositories before publication, and creates a self-contained
bundle for the same ref set. It stores the exact bundle bytes as ordinary
versioned Yeokcham content. It then publishes an immutable archive record and
create-only binding. The archive record preserves the Git object format and an
ascending bytewise list of ref-name/object-ID pairs. It does not record a source
path, remote URL, Git configuration, worktree, index, reflog, hook, or
credential.

The archive logical ID is derived from the object format and ref inventory, not
from the bundle's physical pack representation:

```text
git-archive-id-v1 = SHA-256(
  "yeokcham:git-archive:v1\000" || encode(git-archive-identity-v1)
)

git-archive-identity-v1 = [1, git-object-format, [* git-archive-ref-v1]]
git-archive-ref-v1 = [ref-name-bytes, git-object-id-bytes]
git-archive-v1 = [
  1, git-archive-id, git-object-format, bundle-content-object-id,
  [* git-archive-ref-v1]
]
```

`git-object-format` is `1` for SHA-1 or `2` for SHA-256. Git object IDs are
exactly 20 or 32 bytes respectively. Ref names are nonempty raw bytes, sorted
strictly bytewise, and validated through Git's own ref enumeration. Every
Yeokcham object ID is exactly 32 raw bytes. If the same inventory is imported
again, the existing verified archive binding is returned; a different bundle
representation cannot replace it.

Exit reconstructs a new mirror repository from the verified stored bundle,
runs `git fsck --full`, and inventories refs again. It succeeds only when the
object format and sorted ref inventory equal the archive record. It refuses a
nonempty destination and never modifies the source Yeokcham repository.

Explicit adoption remains a separate transition. It may use the reconstructed
archive as the source for the existing opaque tree/commit/tag bridge, but it
cannot create a capsule, workspace, release, or conflict resolution without an
explicit user choice.

## Consequences

- A Git user has a durable exit path for the selected reachable object/ref
  graph, independent of source-path availability.
- Unreachable objects, working-tree state, index, configuration, reflogs,
  hooks, credentials, and remote service state are not preserved.
- Replace refs are disabled during inventory and bundle creation. Shallow
  history rejects before any archive record publishes. Other Git object kinds
  remain foreign bundle content; their native Yeokcham adoption policy is
  separate.
- The archive is not a Git remote, an automatic two-way synchronisation record,
  or a claim of semantic round-trip equivalence.

## Model and invariant impact

The `git_archive_id` conceptual type from ADR-073 gains an immutable record.

1. An archive ID is determined only by its version, Git object format, and
   strictly ordered ref inventory.
2. A visible archive binding names one verified `Git_archive` object whose
   logical preimage and bundle content reference match its path.
3. A stored bundle is never parsed as native Yeokcham intent or release state.
4. Exit uses only the archive's verified bundle and succeeds only after Git
   verifies the reconstructed object graph and ref inventory.
5. An adoption operation is separate from archive creation and cannot be an
   implicit side effect of preservation or exit.

## Persistent-format and migration impact

This adds Envelope object type `Git_archive` and an additive
`refs/git-archives/<lowercase-archive-id-hex>` create-only binding. Existing
objects, mappings, and refs remain byte-identical. Decoders retain the V1
schema and reject unknown mandatory features, wrong object-ID lengths,
noncanonical lists, malformed bindings, missing bundle content, and incorrect
object types.

## Verification

- Unit and golden tests for archive identity, canonical record/binding bytes,
  malformed inputs, ref ordering, and SHA-1/SHA-256 ID lengths.
- Git fixtures with multiple branches, annotated tags, merges, executable files,
  symlinks, and an ordinary SHA-1 repository; add SHA-256 where the installed
  Git supports it.
- Preservation/exit tests prove `git fsck --full`, exact ref inventory, and
  checkout bytes after reconstruction.
- Failure tests cover shallow repositories, source corruption, archive binding
  corruption, nonempty exits, and repeated creation without replacement.
- Generated tests vary ordered ref inventories and prove canonical
  encode/decode and archive-ID determinism.

## CLI and user impact

The first commands are equivalent to:

```text
yeokcham git archive create --repository <git-directory>
yeokcham git archive list
yeokcham git archive show <archive-id>
yeokcham git archive exit <archive-id> --destination <directory>
```

They report the archive ID, Git object format, ref count, and bundle content
ID. They do not imply that preserved Git commits have become Yeokcham capsules.

## References

- [Git bundle documentation](https://git-scm.com/docs/git-bundle)
- [Git clone documentation](https://git-scm.com/docs/git-clone)
