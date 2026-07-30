# Formal Model

This document defines the conceptual model before implementation details.

Notation is descriptive rather than a complete mechanised proof.

## 1. Primitive identities

```ocaml
type repository_id
type stored_object_id
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

`stored_object_id` is a format-specific storage identity, not a semantic snapshot, checkpoint, capsule, revision, release, or conflict identity. ADR-020 defines its Envelope-1 preimage and path layout.

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

### Persisted snapshot subset

Milestone 1 stores content, trees, and snapshots as separate Envelope-1 objects under ADR-021. The retained Milestone 0 in-memory snapshot payload remains a distinct model fixture and is not reinterpreted as this store schema.

```text
content-v1 = [1, bytes]
chunk-v1 = [1, bytes]
file-manifest-v1 = [
  1,
  total-plaintext-length,
  chunking-algorithm,
  window-size,
  min-chunk-size,
  average-chunk-size,
  max-chunk-size,
  full-content-id,
  [* [chunk-stored-object-id, plaintext-chunk-length]]
]
tree-v1 = [1, [* tree-entry-v1]]
file-entry-v1 = [0, name-bytes, mode, content-stored-object-id]
directory-entry-v1 = [1, name-bytes, tree-stored-object-id]
snapshot-v1 = [1, root-tree-stored-object-id]
```

Every stored-object reference and `full-content-id` is exactly 32 raw bytes. A Tree v1 file reference resolves to Content v1 or File_manifest v1. Content v1 is canonical for file lengths `<= 65536`; empty and exactly-boundary-sized files are inline. File_manifest v1 is canonical above that limit and currently accepts only Buzhash-64-v1 (`algorithm=1`, window `64`, minimum `16384`, average `65536`, maximum `131072`). Its full-content ID is `SHA-256("paengi:content:v1\000" || complete plaintext)`. Tree names are nonempty safe path components and are strictly bytewise ascending. Mode codes are regular `0`, executable `1`, and symlink `2`. A scanner stores a symlink target as authoritative content bytes without following it; `.paengi` is excluded and `.paengiignore` uses exact safe relative paths only.

Manifest invariant: every referenced object is a verified Chunk v1; declared chunk lengths sum to total plaintext length; chunk order is significant and matches canonical Buzhash boundaries; and the reconstructed bytes match `full-content-id`. Missing, malformed, corrupt, incorrectly typed, reordered, or noncanonical chunk sequences reject.

### Materialisation invariant

For a valid persisted snapshot `s` and an empty real destination directory `d`:

```text
scan(materialise(s, d)) = s
```

for regular-file bytes, executable mode, directory structure, and symlink target bytes supported by the host filesystem. Materialisation accepts only decoded safe tree names, creates output files exclusively, and returns an explicit error rather than overwriting a nonempty destination.

## 3. Scratch history

### Persisted scratch subset

Milestone 2 stores Scratch_event v1 and Scratch_checkpoint v1 as immutable
Envelope-1 objects.  Their stored IDs are typed separately at the API boundary;
they use the ADR-020 stored-object identity and do not introduce semantic ID
hashing.  ADR-023 defines their canonical payloads and the mutable, non-object
scratch-head ref.  An event names its parent checkpoint, base snapshot, result
snapshot, ordered operations, source, and observation time.  A checkpoint names
its optional parent/event pair, result snapshot, creation time, and intrinsic
retention.  Initial checkpoints have neither parent nor event; all other
checkpoints have both.  Event/checkpoint linkage and exact replay are verified
when traversed.

Later retention edits are immutable Retention_change v1 objects chained from a
separate atomic retention-head ref.  Pinning therefore never replaces a
checkpoint.  The canonical timeline is the bounded parent chain from the
verified scratch-head; any timeline index is rebuildable cache data only.

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

For a non-initial checkpoint `c` and its event `e`:

```text
e.parent = c.parent
e.base_snapshot = snapshot(c.parent)
e.resulting_snapshot = c.snapshot
replay(snapshot(c.parent), e.operations) = c.snapshot
```

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

### Retention policy selection

The initial Milestone 3 policy is an in-memory command configuration, not a
persisted record:

```ocaml
type retention_policy = {
  recent_window_seconds : int64;
  periodic_interval_seconds : int64;
  storage_budget_bytes : int64 option;
}
```

All durations and an optional budget are non-negative. For deterministic
planning at `now`, a checkpoint with any effective retention reason other than
`Recent_window` is protected. An otherwise unprotected checkpoint is retained
when `created_at >= now - recent_window_seconds`. From the remaining expired
checkpoints, a positive periodic interval retains one checkpoint per
`created_at / periodic_interval_seconds` bucket: the greatest timestamp, then
the greatest checkpoint object ID on ties. An interval of zero retains no
periodic checkpoint. The planner reports a budget overrun but cannot override a
protected checkpoint.

ADR-024 adds immutable compacted generations without changing v1 checkpoint,
event, retention, or head records. A generation maps every retained logical
checkpoint ID directly to a verified physical Checkpoint v1 object. Its ordered
entries bind logical ID, physical ID, snapshot ID, predecessor logical ID, and
effective retention base. Physical event/checkpoint parents retain the prior
logical ID; a single resolver expands it before loading. The active generation
mapping wins over direct old-object lookup.

Generation activation is a separate CAS ref publication. A missing generation
ref uses legacy direct lookup. Retention resolution folds changes newer than
the recorded retention-head cutoff over the generation base. Cleanup moves only
superseded scratch events/checkpoints and pre-cutoff retention records to a
generation quarantine; shared content-domain objects are retained until a full
cross-domain mark exists. Explicit prune is irreversible.

For a compaction dry run, the planned cleanup set is the canonical unique
candidate list that will become the generation cleanup manifest. Planned object
count is its number of immutable object files. Planned bytes are the sum of
the exact pre-quarantine regular-file lengths at their object-store paths;
they exclude logical payload size, allocated blocks, directories, refs,
temporary files, and quarantine metadata. Activation rederives the candidate
set and rejects a mismatch of ID, expected object type, count, or stored-byte
sum before publication. Quarantine and prune test faults may stop before or
after each candidate; resuming revalidates the active generation, manifest,
candidate identity, type, and location. Missing candidates are errors during
quarantine; prune accepts a missing active-manifest candidate only as an
already-pruned result.

### Compaction invariants

1. Every retained checkpoint ID still resolves.
2. Every retained checkpoint materialises to identical bytes and metadata.
3. Every capsule, conflict, or release reference remains resolvable.
4. No pinned checkpoint is removed.
5. Compaction is idempotent with respect to repository meaning.
6. A failed compaction leaves the old valid generation available.
7. A retained logical ID resolves to the generation-declared exact snapshot.
8. An active alias is direct; alias-to-alias traversal is invalid.

Implemented transformation: replace retained boundaries with exact direct
snapshot deltas. Inverse-pair elimination and shared-content collection remain
separate experiments; no semantic equivalence claim is made.

## 5. Intent history

### Capsule

```ocaml
type capsule = {
  id : capsule_id;
  initial_title : string;
  initial_description : string;
  created_at : timestamp;
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
  expected_result : snapshot_id;
  dependencies : dependency list;
  evidence : validation_evidence list;
  source_boundaries : (checkpoint_id * checkpoint_id) list;
  provenance : created | folded | split_from | combined_from;
  created_at : timestamp;
}
```

The capsule ID is stable and caller-supplied as exactly 32 typed bytes. It is
not derived from presentation metadata, checkpoint boundaries, or a current
revision. A revision ID is immutable and is the SHA-256 logical identity over
the ADR-025 canonical semantic preimage; it excludes its own ID and
observational timestamps. Each revision is complete and directly applies from
its declared base; parent links retain history and provenance only.

### Durable Milestone 4 representation

`Capsule_v1` is immutable initial metadata. `Capsule_revision_v1` holds
dependencies, full exact operations, evidence, boundaries, and provenance.
`refs/capsules/<capsule-id>/current` is the only mutable selection and contains
both logical and physical identities with a generation and checksum. Revision
history follows same-capsule immutable parent links, detects cycles and invalid
links, and never relies on a mutable catalog. The prior in-memory catalog
remains a pure-core test utility; it is not repository state.

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
  | Exact_file_transition of exact_file_transition
  | Text_edit of text_edit
  | Semantic_edit of path * semantic_operation * confidence
  | Move of path * path
  | Mode_change of path * file_mode * file_mode

and exact_file_transition = {
  path : path;
  expected : exact_entry option;
  replacement : exact_entry option;
}

and exact_entry =
  | Exact_directory
  | Exact_file of file_mode * content_id

and text_edit = {
  path : path;
  anchor : text_anchor;
  replacement : bytes;
  fallback : exact_file_transition;
}
```

Exact bytes remain authoritative. Semantic operations are replay assistance and explanation.
The Milestone 4 text core retains, but does not silently apply, its exact
fallback: application returns an explicit fallback-required conflict until a
later text engine or user choice selects it.

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
