# Git interchange contract

Git is an interchange format, not Yeokcham's model. This document describes the
implemented M8 bridge only. It does not claim that a Git repository and a
Yeokcham repository, commit, branch, capsule, workspace, or release are
equivalent.

## Evidence boundary

An ADR-028 Git mapping records one verified association between a typed Yeokcham
subject and one exact Git object. It can identify the object format and prove
that association later. It does not make the mapped Git object canonical Yeokcham
state, identify a complete Git repository, or supply a general reverse
conversion.

External Git refs, commits, trees, blobs, temporary indexes, and temporary
message files are never Yeokcham canonical storage. Yeokcham source objects and
refs remain authoritative after every export.

## Supported operational profile

The bridge accepts one existing absolute local Git repository directory at a
time and invokes a discovered `git` executable through direct argv with an
empty inherited environment. It first verifies `rev-parse --is-bare-repository`
and `rev-parse --show-object-format`. No minimum or maximum Git version is
declared; a local Git implementation is supported only when these checks and
the documented plumbing operations succeed with the structured bounds below.

Only the inspected repository's `sha1` and `sha256` object formats are
supported. Git object IDs are kept format-tagged and are never interchangeable
with Yeokcham content, snapshot, stored-object, or logical-history IDs. Other
object formats reject before import or export publication.

Default limits are part of the bridge contract:

| Resource | Default bound |
| --- | ---: |
| Process timeout | 5 seconds |
| Retained stdout / stderr | 1 KiB / 4 KiB per command unless an object read applies its narrower operation-specific bound |
| One tree / all tree-path bytes | 8 MiB / 64 MiB |
| One blob / all export blob bytes | 128 MiB / 256 MiB |
| Tree entries / depth | 100,000 / 256 |
| Commit or tag bytes | 8 MiB each |
| Commit parents / exported revisions | 4,096 / 4,096 |
| Tag-name bytes | 1 KiB |

The adapter rejects empty, relative, NUL-containing, non-directory, or
over-4-KiB repository paths. It returns typed errors for missing executables,
process status/timeout/output truncation, malformed plumbing output, invalid
object identity or representation, limits, mapping corruption, and unsupported
export representation. It does not invoke a shell or turn a process/parsing
failure into a Yeokcham ref, release, capsule, workspace, or mapping update.

## Current policies

- Tree import supports Git modes `100644`, `100755`, and `120000`; commit
  import retains ordered Git parent IDs and bounded opaque metadata; tag import
  supports lightweight and annotated tags that directly target a commit, tree,
  or blob.
- Release export produces one root commit; revision export requires an explicit
  nonempty ordered sequence and produces one root-plus-linear-parent commit
  chain. Exported commits are verified and `git fsck --full --no-dangling` runs
  before Yeokcham mapping publication.
- Export refs are create-only: an absent ref is created, an equal existing ref
  is an idempotent retry, and a different existing target is a structured
  collision. Git ref and Yeokcham mapping publication are separately visible and
  retryable.
- Every supported import/export publishes an ADR-028 mapping only after its
  typed source and Git object validate. The mapping is bridge evidence, not a
  repository-wide import/export guarantee.

## Yeokcham to Git export

| Category | Current contract |
| --- | --- |
| Preserved | A release root commit and each explicitly selected linear capsule revision commit represent the selected snapshot's regular-file bytes, executable mode, symlink-target bytes, and representable tree structure exactly. A selected revision sequence preserves only its declared order as root-plus-sole-parent Git commits. Each successful export has a typed mapping to its exact Git commit. |
| Intentionally opaque | Default or explicitly configured Git author, committer, and message fields describe the export presentation. They are not Yeokcham authorship, capsule intent, signature, validation evidence, or release semantics. Git ref names select external export artifacts only. |
| Unsupported and rejected | Nested empty directories, Gitlinks, unsupported snapshot nodes, exporting a mutable workspace, automatic revision ordering, Git merge topology, tags, signatures, remotes, and configured revision metadata are not implemented export policies. Representational and policy failures reject structurally rather than encoding a substitute. |
| Irreversibly absent from Git alone | Scratch checkpoints, retention and compaction history, pins, safety checkpoints, stable current capsule refs, unselected capsule revisions, declared dependencies, workspace inputs/order/attempts, conflict and resolution objects, release validation evidence, and Yeokcham object/ref publication history cannot be reconstructed from an exported Git ref. A Git mapping retained in the Yeokcham store is required to connect a Git commit to its source object. |

An empty root snapshot is supported. A nested empty directory is not: Git has
no tree entry for it, so export stops before ref or mapping publication.

Configured release metadata changes only the exported Git commit, its
metadata-qualified external ref, and the mapping ID. It does not change the
release ID, release object, snapshot, workspace, or Yeokcham authoring data.

## Git to Yeokcham import

| Category | Current contract |
| --- | --- |
| Preserved | Supported Git tree entries become exact Yeokcham snapshot regular-file bytes, executable mode, symlink-target bytes, and tree structure. Commit parent object IDs and bounded raw commit metadata are retained in an immutable opaque imported transition. Lightweight and annotated tag identity/target data are retained by the supported tag importer. |
| Intentionally opaque | Imported commits become opaque transitions, not inferred capsules, releases, workspaces, conflicts, or semantic edits. Retained author, committer, message, and raw annotated-tag bytes have no Yeokcham semantic meaning. |
| Unsupported and rejected | Unsupported tree modes, malformed or truncated objects, unsafe paths, invalid symlink targets, unbounded hostile input, and unsupported tag targets reject with structured import errors. The bridge does not synthesize a replacement Yeokcham concept. |
| Irreversibly absent from Yeokcham alone | Git branch/ref topology, remote configuration, reflogs, index state, hooks, attributes, filters, signatures as trusted assertions, and Git's repository-wide configuration are not converted into Yeokcham canonical state. The bridge retains only the documented object-level evidence and mappings. |

Importing a Git merge retains its ordered parent object references in opaque
provenance. It does not turn that merge graph into Yeokcham capsule dependencies,
workspace composition, conflict resolution, or release ancestry.

## Round trips

No current round trip is an equivalence guarantee.

- Yeokcham to Git to Yeokcham can preserve a supported checkout tree, but cannot
  recover Yeokcham scratch, capsule, workspace, conflict, release, or validation
  semantics from Git alone.
- Git to Yeokcham to Git can preserve supported snapshot bytes through a later
  explicit export, but does not promise original commit IDs, ref names,
  topology, timestamps, signatures, metadata policy, or repository identity.
- A mapping is bridge evidence in the Yeokcham repository. Losing that mapping
  loses the approved association even when the Git object still exists.

The supported way to inspect an export is its reported Git ref, commit, and
mapping ID. The supported way to recover Yeokcham semantics is the original
Yeokcham repository, not a Git checkout.

## Verification

Run the repository gates from the project root:

```text
make format
make check
make property-test PROPERTY_TEST_SEED=17
```

Focused fixtures cover the local preflight, supported tree/commit/tag import,
release and linear-revision export, mapping reopen/corruption, create-only ref
retry/collision, interruption, `git fsck --full`, and the shared final-byte
oracle. These checks verify the stated bridge contract only; they do not claim
full Git compatibility.
