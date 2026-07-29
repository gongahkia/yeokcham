# Formal Model

This document defines the conceptual model before implementation details.

Notation is descriptive rather than a complete mechanised proof.

## 1. Primitive identities

```ocaml
type repository_id
type content_id
type snapshot_id
type checkpoint_id
type capsule_id
type capsule_revision_id
type release_id
type conflict_id
type operation_id
type device_id
type validation_id
type resolution_id
```

All persistent identities must have:

- Canonical byte representation.
- Explicit versioning where applicable.
- Equality independent of in-memory representation.
- Human-readable shortened form for CLI use.

## 2. Canonical content model

### Encoding profile

Paengi CBOR Profile 1, defined by [ADR-017](docs/adr/017-restricted-deterministic-cbor.md), is the canonical payload encoding. It represents signed 64-bit integers, byte strings, valid UTF-8 text, arrays, non-negative integer-key maps, booleans, and null. It rejects all other CBOR forms, non-minimal heads, indefinite lengths, duplicate or unordered map keys, invalid UTF-8 text, and trailing bytes. Filesystem bytes and path components are byte strings.

The profile is a pure payload rule. Fixed Object Envelope 1, defined by [ADR-018](docs/adr/018-fixed-object-envelope.md), frames each payload with a 57-byte big-endian header containing object type, object-format version, mandatory-feature mask, SHA-256 algorithm code, payload length, and checksum. [ADR-019](docs/adr/019-object-format-versions-and-mandatory-features.md) constrains Envelope 1 to object-format version `1` and mandatory-feature mask `0`; a reader rejects other values after checksum validation and before it passes payload bytes to Profile 1.

### File content

```ocaml
type file_content =
  | Inline of bytes
  | Manifest of chunk_ref list
```

### File metadata

```ocaml
type file_mode =
  | Regular
  | Executable
  | Symlink

type file_entry = {
  mode : file_mode;
  content : content_id;
}
```

### Directory

```ocaml
type tree_entry =
  | File of file_entry
  | Directory of snapshot_id

type tree = (path_component * tree_entry) list
```

Entries must be canonically ordered.

### Snapshot

A snapshot is an immutable root tree plus repository-format metadata.

```ocaml
type snapshot = {
  root : snapshot_id;
  format_version : int;
}
```

The snapshot ID must be derivable from canonical content, not timestamps.

## 3. Scratch history

### Scratch event

A scratch event describes an observed transition.

```ocaml
type scratch_operation =
  | Create_file of path * content_id * file_mode
  | Modify_file of path * content_id * content_id
  | Delete_path of path * prior_entry
  | Move_path of path * path * prior_entry
  | Change_mode of path * file_mode * file_mode

type scratch_event = {
  id : operation_id;
  parent_checkpoint : checkpoint_id;
  operations : scratch_operation list;
  observed_at : timestamp;
  source : observation_source;
}
```

### Checkpoint

```ocaml
type retention_reason =
  | User_pinned
  | Capsule_boundary of capsule_id
  | Release_boundary of release_id
  | Validation_passed of validation_id
  | Periodic_retention
  | Recent_window
  | Conflict_reference of conflict_id

type checkpoint = {
  id : checkpoint_id;
  parent : checkpoint_id option;
  snapshot : snapshot_id;
  event : operation_id option;
  created_at : timestamp;
  retention : retention_reason list;
}
```

### Scratch-history invariant

For every retained checkpoint `c`:

```text
materialise(c.snapshot) = exact recorded filesystem state for c
```

Compaction may remove intermediate events or checkpoints only if this remains true for every retained checkpoint.

## 4. Compaction model

A compaction plan transforms one scratch representation into another.

```ocaml
type compaction_plan = {
  removable_checkpoints : checkpoint_id list;
  replacement_objects : content_id list;
  retained_checkpoints : checkpoint_id list;
  estimated_before : int64;
  estimated_after : int64;
}
```

### Compaction invariants

1. Every retained checkpoint ID still resolves.
2. Every retained checkpoint materialises to identical bytes and metadata.
3. Every capsule, conflict, or release reference remains resolvable.
4. No pinned checkpoint is removed.
5. Compaction is idempotent with respect to repository meaning.
6. A failed compaction leaves the old valid generation available.

Possible transformations:

- Remove exact inverse event pairs between retained boundaries.
- Replace chains with direct snapshot deltas.
- Deduplicate repeated content.
- Keep periodic materialised snapshots to bound replay depth.
- Remove unreferenced short-lived checkpoints after retention expiry.

## 5. Intent history

### Capsule

```ocaml
type capsule = {
  id : capsule_id;
  title : string;
  description : string;
  created_at : timestamp;
  dependencies : dependency list;
  revisions : capsule_revision_id list;
  current_revision : capsule_revision_id;
}
```

### Dependency

```ocaml
type dependency =
  | Requires_capsule of capsule_id * revision_constraint
  | Requires_release of release_id
  | Conflicts_with_capsule of capsule_id
  | Ordered_after of capsule_id
```

### Capsule revision

```ocaml
type capsule_revision = {
  id : capsule_revision_id;
  capsule : capsule_id;
  parent_revision : capsule_revision_id option;
  declared_base : snapshot_id;
  operations : change_operation list;
  expected_result : snapshot_id option;
  evidence : validation_evidence list;
  created_at : timestamp;
}
```

The capsule ID is stable. The revision ID is immutable.

## 6. Change operations

```ocaml
type confidence =
  | Exact
  | High
  | Medium
  | Low
  | Unknown

type text_anchor = {
  before_context : bytes;
  selected : bytes;
  after_context : bytes;
}

type semantic_anchor = {
  language : string;
  symbol_kind : string;
  symbol_identity : string option;
  structural_path : string list;
  fallback : text_anchor;
}

type semantic_operation =
  | Rename_symbol of semantic_anchor * string * string
  | Move_symbol of semantic_anchor * path
  | Replace_node of semantic_anchor * semantic_payload
  | Insert_node of semantic_anchor * relative_position * semantic_payload
  | Delete_node of semantic_anchor

type change_operation =
  | Exact_file_transition of path * content_id option * content_id option
  | Text_edit of path * text_anchor * bytes
  | Semantic_edit of path * semantic_operation * confidence
  | Move of path * path
  | Mode_change of path * file_mode * file_mode
```

Exact bytes remain authoritative. Semantic operations are replay assistance and explanation.

## 7. Application result

```ocaml
type operation_outcome =
  | Applied_exactly
  | Applied_with_confidence of confidence
  | Already_satisfied
  | Conflict of conflict_id
  | Blocked of dependency
  | Rejected of error

type application_result = {
  resulting_snapshot : snapshot_id;
  outcomes : (operation_id * operation_outcome) list;
  conflicts : conflict_id list;
}
```

A semantic operation with low or unknown confidence must not be represented as exact success.

## 8. Conflict model

```ocaml
type conflict_kind =
  | Missing_anchor
  | Ambiguous_anchor
  | Competing_edits
  | Delete_modify
  | Move_modify
  | Dependency_unsatisfied
  | Semantic_uncertainty
  | Validation_failure
  | Binary_conflict

type conflict = {
  id : conflict_id;
  kind : conflict_kind;
  base_snapshot : snapshot_id;
  capsule_revision : capsule_revision_id;
  path : path option;
  candidates : resolution_candidate list;
  status : conflict_status;
}
```

```ocaml
type conflict_status =
  | Unresolved
  | Resolved of resolution_id
  | Superseded of conflict_id
```

Conflicts are repository objects and may outlive a process invocation.

## 9. Workspace model

```ocaml
type workspace_spec = {
  base_release : release_id option;
  base_snapshot : snapshot_id;
  enabled_capsules : capsule_revision_id list;
  explicit_order : capsule_revision_id list option;
  policies : workspace_policy list;
}
```

Materialisation:

1. Validate dependency closure.
2. Derive deterministic order.
3. Apply capsule revisions.
4. Collect conflicts and outcomes.
5. Produce workspace snapshot and materialisation report.

### Composition invariant

For identical:

- Base snapshot.
- Capsule revisions.
- Dependency graph.
- Explicit order.
- Policies.
- Tool version and mandatory format features.

the resulting snapshot and conflict set must be identical.

## 10. Revision and retargeting

Retargeting a capsule revision onto a new base does not mutate the old revision.

```text
retarget(old_revision, new_base)
  -> application report
  -> user or policy resolution
  -> new immutable revision
  -> same stable capsule ID
```

Possible outcomes:

- Exact replay.
- Confident semantic replay.
- Partial replay with conflicts.
- Complete rejection.

## 11. Release model

```ocaml
type release = {
  id : release_id;
  parent_releases : release_id list;
  base_snapshot : snapshot_id;
  capsules : capsule_revision_id list;
  final_snapshot : snapshot_id;
  evidence : validation_evidence list;
  created_at : timestamp;
  signature : signature option;
}
```

### Release invariants

- `final_snapshot` is reproducible from declared inputs.
- The release is immutable.
- Validation evidence is bound to the final snapshot.
- Signatures bind all release fields.
- Exported bytes match the final snapshot.

## 12. Validation evidence

```ocaml
type validation_status =
  | Passed
  | Failed of int
  | Timed_out
  | Not_run

type validation_evidence = {
  command : string list;
  environment_fingerprint : string option;
  snapshot : snapshot_id;
  status : validation_status;
  stdout_digest : content_id option;
  stderr_digest : content_id option;
  started_at : timestamp;
  duration_ms : int64;
}
```

paengi records evidence. It does not claim that passing tests proves correctness.

## 13. Git bridge model

### Import

A Git commit maps to:

- Imported snapshot.
- Imported opaque capsule revision or snapshot transition.
- Git commit ID mapping.
- Optional later semantic inference.

### Export

An ordered capsule-revision sequence maps to one of:

- One Git commit per capsule revision.
- Squashed release commit.
- Explicit merge topology.

The export policy must be recorded.

### Bridge invariant

The final Git checkout for an exported release must match the paengi release snapshot exactly.
