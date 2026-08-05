# Git interchange contract

Git is an interchange format, not Paengi's model. This document describes the
implemented M8 bridge only. It does not claim that a Git repository and a
Paengi repository, commit, branch, capsule, workspace, or release are
equivalent.

## Evidence boundary

An ADR-028 Git mapping records one verified association between a typed Paengi
subject and one exact Git object. It can identify the object format and prove
that association later. It does not make the mapped Git object canonical Paengi
state, identify a complete Git repository, or supply a general reverse
conversion.

External Git refs, commits, trees, blobs, temporary indexes, and temporary
message files are never Paengi canonical storage. Paengi source objects and
refs remain authoritative after every export.

## Paengi to Git export

| Category | Current contract |
| --- | --- |
| Preserved | A release root commit and each explicitly selected linear capsule revision commit represent the selected snapshot's regular-file bytes, executable mode, symlink-target bytes, and representable tree structure exactly. A selected revision sequence preserves only its declared order as root-plus-sole-parent Git commits. Each successful export has a typed mapping to its exact Git commit. |
| Intentionally opaque | Default or explicitly configured Git author, committer, and message fields describe the export presentation. They are not Paengi authorship, capsule intent, signature, validation evidence, or release semantics. Git ref names select external export artifacts only. |
| Unsupported and rejected | Nested empty directories, Gitlinks, unsupported snapshot nodes, exporting a mutable workspace, automatic revision ordering, Git merge topology, tags, signatures, remotes, and configured revision metadata are not implemented export policies. Representational and policy failures reject structurally rather than encoding a substitute. |
| Irreversibly absent from Git alone | Scratch checkpoints, retention and compaction history, pins, safety checkpoints, stable current capsule refs, unselected capsule revisions, declared dependencies, workspace inputs/order/attempts, conflict and resolution objects, release validation evidence, and Paengi object/ref publication history cannot be reconstructed from an exported Git ref. A Git mapping retained in the Paengi store is required to connect a Git commit to its source object. |

An empty root snapshot is supported. A nested empty directory is not: Git has
no tree entry for it, so export stops before ref or mapping publication.

Configured release metadata changes only the exported Git commit, its
metadata-qualified external ref, and the mapping ID. It does not change the
release ID, release object, snapshot, workspace, or Paengi authoring data.

## Git to Paengi import

| Category | Current contract |
| --- | --- |
| Preserved | Supported Git tree entries become exact Paengi snapshot regular-file bytes, executable mode, symlink-target bytes, and tree structure. Commit parent object IDs and bounded raw commit metadata are retained in an immutable opaque imported transition. Lightweight and annotated tag identity/target data are retained by the supported tag importer. |
| Intentionally opaque | Imported commits become opaque transitions, not inferred capsules, releases, workspaces, conflicts, or semantic edits. Retained author, committer, message, and raw annotated-tag bytes have no Paengi semantic meaning. |
| Unsupported and rejected | Unsupported tree modes, malformed or truncated objects, unsafe paths, invalid symlink targets, unbounded hostile input, and unsupported tag targets reject with structured import errors. The bridge does not synthesize a replacement Paengi concept. |
| Irreversibly absent from Paengi alone | Git branch/ref topology, remote configuration, reflogs, index state, hooks, attributes, filters, signatures as trusted assertions, and Git's repository-wide configuration are not converted into Paengi canonical state. The bridge retains only the documented object-level evidence and mappings. |

Importing a Git merge retains its ordered parent object references in opaque
provenance. It does not turn that merge graph into Paengi capsule dependencies,
workspace composition, conflict resolution, or release ancestry.

## Round trips

No current round trip is an equivalence guarantee.

- Paengi to Git to Paengi can preserve a supported checkout tree, but cannot
  recover Paengi scratch, capsule, workspace, conflict, release, or validation
  semantics from Git alone.
- Git to Paengi to Git can preserve supported snapshot bytes through a later
  explicit export, but does not promise original commit IDs, ref names,
  topology, timestamps, signatures, metadata policy, or repository identity.
- A mapping is bridge evidence in the Paengi repository. Losing that mapping
  loses the approved association even when the Git object still exists.

The supported way to inspect an export is its reported Git ref, commit, and
mapping ID. The supported way to recover Paengi semantics is the original
Paengi repository, not a Git checkout.
