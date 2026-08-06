# ADR-028 — Git interchange mapping records

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 8 has a non-persistent, bounded Git preflight adapter only. It has
no durable association from a verified Git object to an imported Yeokcham result,
or from an exported Yeokcham result to the Git object Git created. ADR-009 makes
Git an interchange format, while ADR-020 through ADR-027 require immutable,
typed, versioned objects and create-only visibility. The mapping must support
SHA-1 and SHA-256 Git repositories without treating a Git object ID as a
Yeokcham identity, repository identity, or compatibility guarantee.

## Decision drivers

- Bind every durable bridge result to a typed Git object ID and exact Yeokcham
  target without changing scratch, capsule, workspace, or release semantics.
- Preserve Git hash algorithm identity and reject malformed or mismatched IDs.
- Make mapping publication immutable, restart-safe, and independently
  inspectable.
- Keep Git-object parsing in bounded direct-argv adapters; no Git object bytes,
  packs, refs, or topology become canonical Yeokcham state merely by mapping.
- Add no mutable mapping index, overwrite path, or implicit deduplication.

## Considered options

### Store Git IDs in a rebuildable index

- Fast lookup and no persistent schema expansion.
- Loses bridge evidence on index loss and cannot satisfy immutable-format
  requirements.

### Reuse Yeokcham stored-object IDs for Git IDs

- Avoids a separate Git ID type.
- Conflates Git's algorithm and object namespace with ADR-020's
  domain-separated Envelope identity.

### Store raw Git objects in Yeokcham object envelopes

- Keeps an archival copy beside the mapping.
- Declares unbounded Git-format compatibility and duplicates the later import
  schemas before their individual scope decisions.

### Add immutable typed mapping objects and create-only bindings

- Retains precise, independently verifiable bridge evidence while keeping Git
  parsing and Yeokcham canonical objects separate.
- Requires an additive object type, canonical ref codec, goldens, and restart
  coverage in each importing/exporting vertical slice.

## Decision outcome

Add one additive Envelope-1 object type, `Git_mapping = 23`. It records a
single verified direction, exact Git object reference, and typed Yeokcham bridge
subject. It does not store a raw Git object, Git ref name, remote URL, working
tree path, pack data, or repository identity.

The pure model gains distinct opaque values:

```ocaml
type git_object_format = Git_sha1 | Git_sha256
type git_object_id
type git_object_kind = Git_tree | Git_commit
type git_mapping_id

type git_mapping_subject =
  | Imported_snapshot of snapshot_id
  | Imported_revision of capsule_id * capsule_revision_id * stored_object_id
  | Exported_release of release_id * stored_object_id * snapshot_id
  | Exported_revision of capsule_id * capsule_revision_id * stored_object_id * snapshot_id

type git_mapping = {
  id : git_mapping_id;
  direction : Import | Export;
  git_object : git_object_format * git_object_id;
  git_kind : git_object_kind;
  subject : git_mapping_subject;
}
```

`git_object_id` is raw bytes, never user-supplied hexadecimal text in a
canonical payload. Its format is `Git_sha1` with exactly 20 bytes or
`Git_sha256` with exactly 32 bytes. A caller may render it as lowercase hex for
display only. `Git_tree` and `Git_commit` are the only v1 kinds. Git tag,
gitlink/submodule, alternate hash, ref, and raw-object preservation need a
later additive schema decision; they cannot be encoded as an unknown v1 value.

The exact canonical Profile-1 payload is:

```text
git-object-id-v1 = [git-object-format, git-object-id-bytes]
git-object-format = 1 / 2                 ; sha1 / sha256
git-object-kind = 1 / 2                   ; tree / commit
git-mapping-direction = 0 / 1             ; import / export

imported-snapshot-v1 = [0, snapshot-id]
imported-revision-v1 = [1, capsule-id, capsule-revision-id, revision-object-id]
exported-release-v1 = [2, release-id, release-object-id, final-snapshot-id]
exported-revision-v1 = [3, capsule-id, capsule-revision-id,
                         revision-object-id, final-snapshot-id]
git-mapping-subject-v1 = imported-snapshot-v1 / imported-revision-v1 /
                         exported-release-v1 / exported-revision-v1

git-mapping-v1 = [
  1, git-mapping-id, git-mapping-direction, git-object-kind,
  git-object-id-v1, git-mapping-subject-v1
]
```

Every Yeokcham logical and physical ID in a subject is exactly 32 raw bytes. A
decoder rejects direction/subject combinations not listed below:

```text
import/tree   -> imported-snapshot
import/commit -> imported-revision
export/commit -> exported-release / exported-revision
```

`Git_mapping_id` is exactly:

```text
SHA-256("yeokcham:git-mapping:v1\\000" || encode(git-mapping-identity-v1))

git-mapping-identity-v1 = [
  1, direction, git-object-kind, git-object-id-v1, git-mapping-subject-v1
]
```

It excludes its own ID; mappings carry no timestamp or other observational
field, so an equal retry has identical complete Envelope-1 bytes. The physical
`Stored_object_id` continues to be ADR-020's identity over those bytes. A
mapping resolver verifies the logical preimage, Envelope type/version/features,
Git ID length, subject combination, referenced object type, and logical/physical
agreement before returning a record.

The sole canonical mapping visibility point is an expected-absent binding:

```text
.yeokcham/refs/git-mappings/<lowercase-git-mapping-id-hex>

git-mapping-binding-v1 = [1, git-mapping-id, git-mapping-object-id, checksum]
checksum = SHA-256(
  "yeokcham:git-mapping-binding:v1\\000" ||
  encode([1, git-mapping-id, git-mapping-object-id])
)
```

Bindings use ADR-020/ADR-023 same-directory temporary writes, fsync, checked
compare-and-swap, and directory fsync where supported. They are create-only:
an equal retry succeeds and a different physical object for the same logical
mapping ID returns a structured collision/corruption error. A future mapping
listing must enumerate and verify these bindings; any lookup index is
rebuildable and non-canonical.

An importer or exporter may create its normal Yeokcham target only through that
target's accepted publication protocol. After it verifies the target and the
exact Git input/output object, it writes the immutable mapping and then creates
the mapping binding. The target visibility point and mapping binding are not a
cross-ref transaction. An interruption after target visibility but before the
mapping binding leaves a valid Yeokcham target plus an incomplete bridge record;
retrying the same request must verify and publish the same mapping or return a
structured mismatch. An interruption before the binding leaves only
unreferenced immutable data. No mapping ref may advance, rewrite, hide, or
otherwise change a Yeokcham history ref.

## Consequences

- Git and Yeokcham IDs remain type- and algorithm-distinct.
- The mapping can prove an exact bridge association, not that Yeokcham preserves
  all Git semantics or that a Git repository is globally identified.
- Git tree/commit import and commit export can share one auditable mapping
  contract, while tags and gitlinks fail closed until separately designed.
- Import/export implementations need a recovery path for the documented
  cross-ref interruption state.
- The current preflight result remains process-local and is never written as a
  repository identity or configuration field.

## Model and invariant impact

- A mapping's Git ID length exactly matches its declared Git hash algorithm.
- A mapping subject has the declared direction/kind combination and resolves to
  the exact typed Yeokcham object(s) it names.
- A Git mapping cannot stand in for a scratch checkpoint, capsule, workspace,
  conflict, release, or stored-object identity.
- Mapping creation is idempotent only for identical canonical mapping semantics.
- A visible mapping never mutates Yeokcham histories; missing mappings after an
  interrupted bridge operation remain explicit rather than inferred.

## Persistent-format and migration impact

This is additive: Envelope type 23, `Git_mapping_v1`, and
`git-mapping-binding-v1` are new. Existing Envelope type codes 1–22, formats,
refs, object IDs, and golden fixtures remain byte-identical. Existing
repositories simply have no `refs/git-mappings/` directory. No current mapping
or generic Git-object store exists to migrate.

A later mapping schema, Git kind, hash format, or subject requires a new ADR,
a retained v1 decoder/golden, and coexistence through new immutable objects and
bindings. No mapping or target object is rewritten in place.

## Verification

- Golden and inverse-decoder tests for SHA-1 and SHA-256 import/export mapping
  objects and create-only bindings.
- Unit tests for logical-ID preimages, all valid direction/kind/subject forms,
  canonical bytes, exact typed links, and listing without an index.
- Bounded deterministic properties for mapping encode/decode, identity
  determinism, and rejection of wrong-length IDs and noncanonical forms.
- Failure/restart tests before target visibility, before mapping binding, and
  after mapping binding; retries must be idempotent or structured mismatches.
- Corruption/type/link/ref-checksum tests and regression checks proving all
  ADR-020 through ADR-027 golden bytes remain unchanged.
- Focused local Git fixtures must obtain object type and bytes through bounded
  direct argv, then verify exact snapshot or exported-checkout results. Git's
  `cat-file` protocol supplies object type and declared size; supported file
  modes are validated by the importing/exporting slice, not inferred by this
  record. [git-cat-file](https://git-scm.com/docs/git-cat-file)
- Benchmark bridge operations separately with recorded Git version, object
  format, fixture checksum, cache state, object count, and host metadata; no
  timing result is a correctness claim.

## CLI and user impact

No command is added by this decision alone. Later `import git`, `export git`,
and inspection commands must report Git object format/ID, mapping ID, direction,
subject IDs, and explicit incomplete/retryable bridge states. They must not
promise arbitrary Git-format compatibility. Git documents tree modes `100644`,
`100755`, and `120000` as regular, executable, and symlink entries; v1 mapping
records do not reinterpret those modes. [git-fast-import](https://git-scm.com/docs/git-fast-import)

M8-01 adds `yeokcham git import tree --repository <absolute-git-directory>
--tree <full-git-tree-id>`. It prints the snapshot and mapping IDs after the
create-only mapping binding succeeds. It does not add a commit, export, or
mapping-list command.

## Implementation verification evidence

M8-01 adds a canonical `Git_mapping_v1` golden fixture plus focused local Git
fixtures for nested files, executable mode, symlink target bytes, retry/reopen,
unsafe names, unsupported modes, missing objects, blob bounds, and corrupt
mapping bindings. Its seeded generated test checks exact bytes, executable mode,
snapshot identity, and mapping identity across repeated imports.
