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
type workspace_id
type workspace_revision_id
type workspace_attempt_id
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

`release_attestation` has no logical ID in v1: its immutable physical
`stored_object_id` identifies the complete statement and remains distinct from
the `release_id` it names.

## 2. Canonical content model

### Encoding profile

Yeokcham CBOR Profile 1, defined by [ADR-017](docs/adr/017-restricted-deterministic-cbor.md), is the canonical payload encoding. It represents signed 64-bit integers, byte strings, valid UTF-8 text, arrays, non-negative integer-key maps, booleans, and null. It rejects all other CBOR forms, non-minimal heads, indefinite lengths, duplicate or unordered map keys, invalid UTF-8 text, and trailing bytes. Filesystem bytes and path components are byte strings.

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

Every stored-object reference and `full-content-id` is exactly 32 raw bytes. A Tree v1 file reference resolves to Content v1 or File_manifest v1. Content v1 is canonical for file lengths `<= 65536`; empty and exactly-boundary-sized files are inline. File_manifest v1 is canonical above that limit and currently accepts only Buzhash-64-v1 (`algorithm=1`, window `64`, minimum `16384`, average `65536`, maximum `131072`). Its full-content ID is `SHA-256("yeokcham:content:v1\000" || complete plaintext)`. Tree names are nonempty safe path components and are strictly bytewise ascending. Mode codes are regular `0`, executable `1`, and symlink `2`. A scanner stores a symlink target as authoritative content bytes without following it; `.yeokcham` is excluded and `.yeokchamignore` uses exact safe relative paths only.

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

The initial V2 inspection projection persists no index. Its status, object
counts, journal counts, and verification report are read-only functions of the
authenticated bootstrap, canonical encrypted objects, and restore journal.

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
  budget_retained_checkpoint_bytes : int64;
  budget_protected_checkpoint_bytes : int64;
  budget_exceeded_by : int64 option;
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

The budget is a deterministic retention-selection bound, not a total repository
or filesystem quota. Its per-checkpoint cost is the exact current stored-file
length of that checkpoint's source object plus its direct `Scratch_event`, if
any; `Snapshot`, `Tree`, `Content`, `Chunk`, and `File_manifest` objects remain
outside it because M3 has no complete cross-domain root mark. The logical
scratch head is required even when ordinary time/periodic selection would
expire it. Protected and required checkpoint costs are charged first and always
retained. The remaining recent candidates, then periodic candidates, are
considered newest-first with checkpoint object-ID tie-breaks; a candidate that
does not fit becomes `budget-excluded`, while later lower-priority candidates
may still fit. If protected/required cost alone exceeds the configured budget,
the plan retains those states and reports the exact overrun. No budget outcome
changes a pin, a retained required state, a logical ID, or any persistent
policy encoding.

For each gap between consecutive retained checkpoints, compaction concatenates
the exact stored source-event operations in order. It then removes only an
adjacent inverse pair (including pairs made adjacent by an earlier removal):
identical create/delete or delete/create entry pairs; same-path content or mode
swaps with reciprocal preconditions; or a move immediately followed by the
same-entry reverse move. Before a replacement event is stored, both the source
chain and the reduced chain must replay from the prior retained snapshot to the
next retained snapshot exactly. A mismatch is a structured planning failure;
unmatched operations stay intact. `inverse_pairs_eliminated` is dry-run/plan
evidence, not a new persistent record field or a reason to remove a retained
logical checkpoint.

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
9. A budget-excluded checkpoint is never a protected or required checkpoint.
10. An inverse reduction preserves the exact snapshot of both endpoints of its
    retained gap.

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
  provenance : created | folded | split_from | combined_from | retargeted_from;
  created_at : timestamp;
}
```

The capsule ID is stable and caller-supplied as exactly 32 typed bytes. It is
not derived from presentation metadata, checkpoint boundaries, or a current
revision. A revision ID is immutable and is the SHA-256 logical identity over
the ADR-025 canonical semantic preimage; it excludes its own ID and
observational timestamps. Each revision is complete and directly applies from
its declared base; parent links retain history and provenance only.

### V2-018 exact curation boundary

ADR-059 defines the V2 initial capsule record independently of the V1 durable
representation below. Given exact V2 snapshots `S` and `T`, its pure proposal
contains only deterministic structural operations `O` where `apply(S, O) = T`.
It does not infer moves, semantic edits, grouping, or user intent. An explicit
strictly ascending selection either yields an exact selected result or a
transition conflict naming the original operation index. A visible V2 revision
retains logical and encrypted links for base, result, and both source boundary
snapshots. ADR-058 protects those source snapshots before the signed capsule
binding is visible, so compaction may retire the original ledger range without
removing the cited exact bytes.

### V2-019 confirmed split and combine publication

V2 split and combine first resolve authenticated current capsule revisions and
derive a read-only exact plan. An unconfirmed request has no object, protection,
or ledger transition. Confirmation rebuilds the plan from the current durable
inputs; a missing, divergent, malformed, replay-invalid, or changed source is
an explicit error.

A split requires two new capsule IDs distinct from its source and from each
other, plus nonempty left and right operation partitions. It creates two
immutable output capsules. The left revision applies from the source declared
base to the exact intermediate result; the right revision applies from that
intermediate result to the source result. Both use ordered `Split_from` links to
the verified source revision. A combine accepts an explicit caller order of
current source capsules only when each source result exactly equals the next
declared base. It creates one new capsule revision that replays the concatenated
operations from the first base to the last result and retains ordered
`Combined_from` links.

Before an output binding is signed, every source-boundary snapshot that remains
in the active scratch history receives a separate `Capsule_boundary` protection
claim for that output revision. Capsule-created intermediate snapshots are
already immutable links of their output revisions, not invented scratch events,
and therefore receive no synthetic checkpoint or protection claim. The two
split output bindings are separate causal publications: an interruption may
leave one valid visible child and one unbound child; retry requires the same
exact publication inputs and never rewrites the visible child.

For every visible V2 split or combined revision `r`:

```text
replay(snapshot(r.declared_base), r.operations) = snapshot(r.expected_result)
```

Source ordering and provenance links are immutable evidence, not inferred user
intent, semantic equivalence, or a merge decision.

### V2-020 deterministic workspace composition and resolution records

ADR-061 defines V2 workspace composition independently of the V1
materialisation records below. A V2 workspace revision contains a verified exact
base snapshot link, unique immutable capsule revision links, explicit
precedence edges, a stored resolved order, and immutable conflict-resolution
bindings. Its logical identity is domain-separated over that canonical logical
input; encrypted object references remain physical verification links rather
than logical identity material.

```text
derive_order(selected, precedence) = ordered-selected
apply_workspace(base, ordered-selected, skip-resolutions)
  = (resulting-snapshot, ordered-outcomes, ordered-conflicts)
```

`derive_order` rejects duplicate capsule or revision identities, link/revision
mismatches, unknown or duplicate precedence edges, and cycles. It canonicalises
the selected set and uses capsule-revision identity as its only tie-breaker.
Each capsule operation is applied independently in that order. A failed
operation becomes a `Conflict`; only later operations whose touched paths
overlap that conflict are `Blocked_by_conflict`. Operations on disjoint paths
continue. Therefore equal verified inputs produce equal order, result, outcomes,
and conflict set.

A `Resolution` names one immutable conflict and has only:

```text
Skip_operation(capsule-revision-link, operation-index)
```

The action must exactly equal the cited conflict's source. It does not replace,
modify, reorder, or semantically reinterpret bytes. Binding a resolution makes
a new immutable workspace revision; replay reads all bound resolution records
and applies their exact skip actions. A conflict or a resolution is never a
process-only condition or a mutable flag.

The visible `workspace-<workspace-id>` scope has one verified causal ledger
head targeting a `Workspace_revision`. A distinct expected-absent
`workspace-attempt-<workspace-id>-<attempt-id>` scope targets an immutable
attempt. Publication writes workspace/result/conflict/resolution objects before
their revision or attempt, and writes the signed binding last. An interruption
may leave unreachable immutable objects but cannot make a partial workspace,
attempt, or resolution visible.

### V2-021 immutable releases and exact validation linkage

ADR-062 adds client-neutral V2 release evidence. A `Validation_evidence`
contains an exact snapshot link, nonempty caller-supplied check name, `Passed`
or `Failed` status, and observed time. Its domain-separated logical identity
includes the snapshot ID, check name, and status, but excludes observed time
and the physical snapshot reference. It records an observation only: no V2
process runner, reviewer, signer, or approval is implied.

A `Release` contains ordered parent links, one exact workspace-revision link,
one exact workspace-attempt link, base/final snapshot links, ordered capsule
revision links, resolution bindings, at least one canonical evidence link, an
optional message, and creation time. Its logical identity is domain-separated
over parent logical IDs, workspace/revision and attempt logical IDs, base/final
snapshot IDs, ordered capsule logical links, resolution logical IDs, and
message. Evidence links, timestamps, and all physical references are required
for verification but excluded from logical identity.

```text
visible_release(r) =>
  replay(r.attempt) = r.final_snapshot
  /\ conflicts(r.attempt) = []
  /\ evidence(r) != []
  /\ every e in evidence(r): Passed(e) /\ snapshot(e) = r.final_snapshot
  /\ parents(r) form an acyclic visible closure
```

The pure record rejects duplicate parents, self-parenting, duplicate evidence,
unknown mandatory features, identity mismatches, and noncanonical bytes. The
durable adapter resolves the named immutable workspace revision and attempt,
not a mutable workspace head, then checks the exact base, ordered capsules,
resolution bindings, and final snapshot. The sole visibility point is a signed
expected-absent `release-<release-id>` ledger scope targeting the exact Release
frame. Objects may be unreachable after interruption, but no partial release
is visible.

### V2-022 local cache reclamation from complete roots

ADR-063 separates local encrypted-cache maintenance from V2 history. Given an
authenticated inventory `I`, verified recognised ledger scopes, and unfinished
restore or transaction journals, the pure relation is:

```text
roots(I) = active-scratch(I) union protection(I) union visible-bindings(I)
         union unfinished-restores(I) union prepared-transactions(I)
mark(I) = transitive-typed-physical-closure(roots(I))
```

Every recognised visible scope must have one causal head; an unknown scope,
divergent head, missing event/object, or wrong linked frame kind makes the
relation undefined rather than producing a partial root set. Ledger-event
predecessors and targets are physical edges. Typed frame edges retain exact
snapshot, revision, conflict, resolution, evidence, attempt, and release
references; a scratch-generation value contributes only its active-anchor
event, never its audit cleanup candidates.

For nonnegative cache budget `B`, entries outside `mark(I)` are ordered by
ascending opaque reference and selected until the projected encrypted stored
byte total is at most `B`. The marked closure is never selected. If its exact
bytes already exceed `B`, the plan reports `marked_bytes - B` and selects no
candidate. The canonical local manifest retains its root digest, canonical
marked references, candidate `(reference, kind, stored-bytes)` list, totals,
budget, and feature/version fields; its ID is a domain-separated digest of its
canonical body.

```text
quarantine_or_prune(plan, I) is permitted only when
  digest(roots(I)) = plan.root_digest
```

High-level V2 publication holds a shared local guard across its complete
object-to-binding interval. Reclamation holds that guard exclusively while it
marks, quarantines, or prunes. A quarantine destination is the retry cursor;
permanent prune is a later explicit operation. Neither the manifest, lock,
byte accounting, quarantine path, nor progress state is a V2 object, ledger
event, logical identity, or visibility source.

### V2-023 repository root authority records

ADRs 064 and 065 define a repository-scoped pseudonymous authority boundary.
`user_id` and `root_key_id` are separate domain-separated SHA-256 digests of
one exact Ed25519 root public key. They are cryptographic identifiers, not
accounts, people, ownership claims, or a device signer ID. A
`Repository_authority` self-signs its exact repository ID, user/root IDs, root
public key, schema version, and mandatory feature mask. Its record identity is
the domain-separated digest of that unsigned canonical body.

Each `Device_certificate` independently binds one repository/user/device ID,
device ledger signer ID and public key, envelope/address-key commitments, local
key handle, and mandatory features. A `Device_revocation` independently binds
one repository/user/certificate ID and feature mask. Certificate and revocation
identities are domain-separated digests of their own canonical unsigned bodies;
their signatures are over separate domain-prefixed record identities.

```text
active(c, A, C, R) =>
  c in C
  /\ valid_certificate(A, c)
  /\ no r in R: valid_revocation(A, r) /\ r.certificate_id = c.id
```

The pure evaluator rejects duplicate certificate IDs, multiple certificates for
one device, duplicate revocation IDs, multiple revocations for one certificate,
and a revocation with no supplied certificate. A syntactically canonical
certificate/revocation object is not an authority decision: it remains
unverified until checked against its exact repository-authority root key.
Authority-ledger ordering is intentionally not encoded in any record identity;
the later authority-scoped causal ledger supplies that one ordering edge.

Root signing and device ledger signing public keys must differ. Existing local
bootstrap capability construction separately rejects reusing raw envelope,
opaque-address, and device ledger key material. Authority records carry public
commitments rather than private material and cannot prove whether a remote
device reused an undisclosed symmetric key; they therefore make no such claim.
All three record payloads and their typed encrypted-object frames are
versioned canonical CBOR. An object-frame decoder self-verifies a repository
authority, while certificate/revocation frames expose only validated canonical
payloads until an authority anchor performs signature verification.

### Durable Milestone 4 representation

`Capsule_v1` is immutable initial metadata. `Capsule_revision_v1` holds
dependencies, full exact operations, evidence, boundaries, and provenance.
`refs/capsules/<capsule-id>/current` is the only mutable selection and contains
both logical and physical identities with a generation and checksum. Revision
history follows same-capsule immutable parent links, detects cycles and invalid
links, and never relies on a mutable catalog. The prior in-memory catalog
remains a pure-core test utility; it is not repository state.

Current-working-diff creation holds the repository writer lock, resolves the
verified logical scratch head, and performs two exact scans. A differing pair
rejects as an external working-directory change. If the verified snapshot equals
the scratch-head snapshot, the result is `no_changes` and no scratch or capsule
ref is published. Otherwise it is recorded through the ordinary immutable
Scratch_event/Checkpoint publication, then becomes the target of the ordinary
checkpoint-range capsule creation path. The new source/target boundaries are
durably pinned before the capsule current ref is visible.

Enabling one capsule for editing resolves and verifies its current complete
revision, then invokes guarded scratch materialisation for the revision's
expected-result snapshot. A divergent working directory receives an ordinary
safety checkpoint. The target checkpoint/event is staged from that head without
moving `scratch-head`; only exact filesystem-result verification publishes it as
the new head and editing anchor. If the verified working state and current head
already equal the revision result, the head itself is reused. No edit-session
ref exists. A later fold names this anchor and a descendant scratch checkpoint.

Split and combine have a pure, read-only planning phase. A split plan preserves
the caller's strictly ascending selected operation indices, produces an exact
left intermediate snapshot and a dependent right revision, and reports both
declared bases/results and all boundary pins. A combine plan preserves the
caller-supplied source order, validates its complete base/result chain and
dependency closure, and reports the resulting complete revision. Publication
requires an explicit confirmation and recomputes the plan while holding the
repository writer lock. Parent-cycle validation remains required in durable
history; synthetic parent cycles are exercised through the pure
`Parent_resolver` graph seam because a hash-verifying persistent cycle is not a
constructible fixture.

### M12 exact durable retargeting and inspection

The durable retarget adapter has one deliberately narrow transition:

```ocaml
retarget : capsule_id -> new_base:snapshot_id ->
  [ `Retargeted of capsule_revision | `Conflicts of application_conflict list ]
```

It resolves the current verified complete revision under the capsule writer
lock, applies its existing exact operations to `new_base`, and never mutates the
old revision. A conflict returns the full pure application-conflict list and
leaves the current ref unchanged. A successful application stores its exact
result snapshot, creates a complete child revision with
`Retargeted_from(current-link)` provenance, verifies the child, rereads the old
ref bytes, and CAS-publishes the new generation. The child retains the source
revision's operations, declared dependencies, evidence, and source boundaries.
Thus a revision remains directly replayable from its own declared base.

This adapter does not invoke semantic-anchor or textual fallback inference.
Those evidence-stage experiments remain nonpersistent and cannot authorise a
durable revision. A text operation that needs its fallback is therefore a
structured retarget conflict, not an automatic rewrite.

Repository inspection is a read-only query layer. Object enumeration ignores
the dot-prefixed temporary files tolerated after interrupted publication, then
accepts only canonical object paths and runs the normal stored-object identity
and Envelope-1 verification for every entry. `verify` additionally materialises
the reachable graph of every stored snapshot, validates every stored capsule
revision and declared dependency, validates all current workspaces, and
reproduces every published release. `storage stats` groups exact object-file
lengths by object domain. Its retained-checkpoint subtotal resolves each retained
logical checkpoint through the active scratch generation and counts each
physical checkpoint object once; it is not additive with the domain totals.

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

### Milestone 7 bounded adapter

The initial TypeScript adapter is a pure, non-persistent research sidecar. Its
proposal records retain a complete exact textual fallback:

```ocaml
type exact_textual_fallback = {
  expected_source : bytes;
  replacement_source : bytes;
  textual_anchor : text_anchor;
}
```

It parses only supported top-level declaration forms and never changes a
snapshot, capsule revision, workspace, release, ref, or canonical encoding.
On a parser error it returns no proposal; ordinary byte-based behaviour remains
available. An automatic declaration-name rewrite requires exactly one target
declaration with the same kind, name, and normalized signature, including
literal tokens. Structural and syntax-similarity matches expose evidence but
require manual review; ambiguous, low-confidence, and textual-context results
are structured conflicts. Move and replacement are proposals only. The exact
fallback applies only when the input file bytes exactly equal `expected_source`.

This adapter does not claim a full TypeScript grammar, reference rename, or
semantic correctness. It introduces no persistent semantic schema.

### Milestone 7 contextual textual baseline

`yeokcham_textual_patch` is an independent pure byte-only baseline. It receives
only an original byte span, expected preimage, replacement bytes, and before/
after byte context; it has no parser, compiler, declaration, symbol, type, or
semantic-confidence input. Its deterministic stages are exact original span,
unique exact preimage, unique complete context, then explicitly requested
bounded relaxed context (at most 64 nearest bytes per side). A stage applies
only one candidate. Missing or multiple candidates return structured conflicts.
The output is an exact byte splice and verifies unchanged prefix/suffix bytes.
Its unique contextual result is not semantic `Exact` confidence. This baseline
is non-persistent and does not alter any Yeokcham format or identity.

### Optional Compiler API boundary

`yeokcham_typescript_adapter` is an ephemeral protocol-v1 boundary, not a model
object. It sends exact UTF-8 source bytes from a verified immutable snapshot to
the locally pinned TypeScript `5.9.3` Compiler API and receives only
language-neutral values: project-relative paths, declaration kind, byte spans,
lexical parent path, export status, declaration-shape/signature evidence,
symbol-derived evidence, diagnostics, and completeness flags. TypeScript
UTF-16 source positions are converted before crossing the boundary:

```text
byte_offset(s, u16_position) = utf8_length(s[0:u16_position])
```

Only a boundary without a parser diagnostic may report parser completeness.
Unresolved virtual modules or type diagnostics independently reduce resolution
and type-resolution completeness. No compiler symbol, compiler internal ID, or
derived evidence is a Yeokcham identity. The boundary is optional: missing Node or
adapter, timeout, malformed response, unsupported version, compiler crash,
invalid source, unresolved module, or configured bound failure produces
semantic-unavailable and leaves byte-based operations and exact fallback intact.

An exact `replace-node` attempt has the following preconditions:

```text
one candidate at (path, byte_span)
and exact preimage bytes and SHA-256
and declaration kind and shape digest
and parser_complete
```

Its result is `prefix ++ replacement_bytes ++ suffix`. It must reparse, retain
one declaration in the intended lexical context, and prove prefix and suffix
byte equality. A failed precondition or postcondition is a structured conflict;
it is not an edit. This statement does not establish behavioural equivalence.

No request, response, result, evidence, or replacement output from this
boundary is persistently encoded in Milestone 7.

### Milestone 9 Rust syntax boundary

`yeokcham_rust_adapter` has transient values only: a configuration, handshake,
source file, half-open byte span, top-level item fact, parser diagnostic,
analysis, explicit virtual-root selection, module fact, item-path fact,
unreachable-source fact, fallback assessment/fact, and structured unavailable
reason. An analysis is
associated with one verified immutable snapshot ID and a sorted map of safe
project-relative `.rs` files with valid UTF-8 source bytes. Each returned
item/diagnostic path names one supplied file; each half-open span lies within
that file; items and diagnostics are canonically ordered by path, byte span,
then kind/code.

M9-02 module analysis additionally requires a nonempty sorted unique list of
safe root files from that same map. A root is an anonymous virtual crate root,
not Cargo metadata. For an un-attributed `mod name;`, it tests only the
snapshot-map candidates `<child-base>/name.rs` and
`<child-base>/name/mod.rs`; exactly one resolves, while zero and two return
structured incomplete facts. Inline modules have their syntactic parent.
Module/item facts carry the requested root, source path, byte span, parser
state, and status; `module_paths_complete` is false for parser damage,
unreachable supplied source, ambiguity, missing/unsupported module input, or a
bound. They are canonically ordered by root, module segments, source path, and
span. A non-`resolved` fact grants no operation authority.

This analysis does not infer roots, Cargo crates/packages, imports, names,
types, macro output, conditional configuration, or `#[path]` modules. It
consults no host path. Module/item paths are transient evidence, not a Yeokcham
or compiler identity, persistent sidecar, semantic operation, or rewrite.

M9-03 fallback assessment requires the same sorted virtual source map and
requested snapshot ID. Every fact has one supplied path, a valid half-open byte
span, one of `macro-definition`, `macro-invocation`, `outer-attribute`, or
`parser-damage`, and fixed `textual-fallback-required` status. Facts are unique
and canonically ordered by path, span, then kind, with at most 4,096 facts.
`textual_fallback_required = (facts <> [] || not parser_complete)`. A fallback
fact reports only why an independent exact byte/text operation may be needed;
it neither supplies a replacement nor grants macro, item, module, name, type,
or rewrite authority.

`parser_complete = false` is incomplete syntax evidence, not authority to
apply an operation. Adapter absence, timeout, crash, malformed output, invalid
input/encoding, an unsupported version, or any configured bound returns an
unavailable value and leaves every snapshot, checkpoint, capsule, revision,
workspace, release, ref, object, validation result, and canonical byte string
unchanged. No Rust adapter request, response, item, diagnostic, module/item
path, fallback fact, version, or lockfile data is a Yeokcham object, identity,
semantic operation, or persistent sidecar.

### Milestone 7 evidence-stage retargeting

The nonpersistent `yeokcham_semantic_retarget` core selects from explicit,
deterministically ordered candidate evidence: (1) exact original declaration
bytes, byte span, and context; (2) canonical project-relative module path plus
exported-symbol path; (3) resolved alias or underlying-symbol text; (4)
declaration kind, overload ordinal, signature, and type-shape evidence; (5)
lexical or structural declaration path; (6) declaration-shape and token
evidence; then (7) exact textual fallback. Each candidate report records every
supporting stage and contradictory or missing stage. Candidate ordering is
`candidate_id`, module path, then byte span.

`Exact` requires the first stage's bytes, span, and context. `High` requires
complete parser, resolution, and type-resolution evidence plus kind/shape and
module/export or resolved-symbol evidence. Incomplete parsing or resolution,
lexical similarity, shape/token similarity, and exact textual fallback cannot
produce High. Equivalent surviving candidates return an ambiguity result. Low,
medium, and unknown results are explicit uncertainty, not automatic semantic
application. Compiler strings remain transient evidence and never become
Yeokcham identities.

### Milestone 7 comparative result

The experiment report is a versioned documentation artifact, not a Yeokcham
object or model value. For each shared fixture and strategy it records selected
path/span, oracle correctness, confidence/stage, completeness, fallback,
candidate count, byte-splice validation, and host-specific elapsed time. Let
`target_ok` mean the selected span equals the oracle span, `bytes_ok` mean the
resulting bytes equal the oracle bytes, and `outside_ok` mean the splice changes
no bytes outside its selected span.

```text
correct_exact = target_ok and bytes_ok and (semantic_confidence = Exact or textual_exact_span)
correct_nonexact = target_ok and bytes_ok and not correct_exact
safe_conflict = oracle_requires_or_permits_refusal and no_bytes_modified
false_confident = semantic_confidence in {Exact, High}
                   and application
                   and (not target_ok or not bytes_ok or not outside_ok
                        or oracle_requires_conflict)
false_negative = oracle_has_unique_target and outcome in {missing, ambiguous, rejected}
```

Safe conflicts do not count as applications. A report with any known
`false_confident` semantic application cannot satisfy the Milestone 7 safety
gate. Schema/report bytes and metric aggregation remain outside all Yeokcham
persistent contracts.

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
  workspace : workspace_id;
  workspace_revision : workspace_revision_id;
  workspace_attempt : workspace_attempt_id option;
  capsule : capsule_id;
  capsule_revision : capsule_revision_id;
  operation_index : int;
  paths : path list;
  current : tree_entry option;
  candidates : string list;
  created_at : timestamp;
}
```

```ocaml
type resolution = {
  id : resolution_id;
  conflict : conflict_id;
  workspace_revision : workspace_revision_id;
  workspace_attempt : workspace_attempt_id option;
  action : Skip_operation;
  expected_current : tree_entry option;
  created_at : timestamp;
}
```

Conflicts and resolutions are immutable repository objects and may outlive a
process invocation. A resolution is active only when a later immutable workspace
revision binds it to its conflict; Conflict itself has no mutable resolved flag.
The conflict's immutable `(capsule_revision, operation_index)` source identifies
the exact stored operation and its preconditions; V1 deliberately has no guessed
content, mode, or path replacement action.

## 9. Workspace model

```ocaml
type selected_capsule_revision = {
  capsule : capsule_id;
  revision : capsule_revision_id;
  revision_object : stored_object_id;
}

type workspace = {
  id : workspace_id;
  created_at : timestamp;
  initial_name : string option;
  initial_description : string option;
}

type workspace_revision = {
  id : workspace_revision_id;
  workspace : workspace_id;
  parent : workspace_revision_id option;
  base_snapshot : snapshot_id;
  selected : selected_capsule_revision list;
  explicit_precedence : (capsule_revision_id * capsule_revision_id) list;
  resolved_order : capsule_revision_id list;
  resolutions : (conflict_id * resolution_id * stored_object_id) list;
  provenance : workspace_provenance;
  created_at : timestamp;
}

type workspace_attempt = {
  id : workspace_attempt_id;
  workspace : workspace_id;
  workspace_revision : workspace_revision_id;
  base_snapshot : snapshot_id;
  ordered_capsules : selected_capsule_revision list;
  starting_checkpoint : checkpoint_id;
  starting_snapshot : snapshot_id;
  outcomes : operation_outcome list;
  resulting_snapshot : snapshot_id;
  conflicts : conflict_id list;
  created_at : timestamp;
}
```

Materialisation:

1. Validate dependency closure.
2. Derive deterministic order.
3. Apply capsule revisions.
4. Collect conflicts and outcomes.
5. Produce workspace snapshot and materialisation report.

### Dependency-order subset

The first Milestone 5 slice resolves an in-memory selected-revision set before
any workspace object or ref exists. A selection contains one revision for each
capsule. `Requires_capsule` must be selected; when it names a revision, that
exact revision must be selected. `Requires_release` is satisfied only when its
requirement is the declared base release itself or appears in that base
release's verified transitive parent closure. `Conflicts_with_capsule` rejects a selection containing
both capsules. `Ordered_after` adds a precedence edge only when its referenced
capsule is selected. An explicit order is a complete sequence containing every
selected revision exactly once; adjacent entries add precedence edges. The
resolver topologically sorts all edges, using ascending logical revision ID as
its sole unconstrained tie-breaker, and rejects any cycle.

ADR-026 makes this selection durable. `Workspace_v1` contains only stable
metadata. Each selection, base, precedence, or resolution change creates a new
immutable `Workspace_revision_v1`; its selected links include logical capsule
and revision identity plus verified physical revision object. The stored
resolved order must equal recomputation. `Workspace_attempt_v1` records one
exact application and may be partial. The current ref is the sole mutable
visibility point and carries logical/physical workspace and revision links,
optional latest attempt, checksum, and CAS generation.

`Workspace_revision_v1` records only `base_snapshot`, not a declared base
release. Therefore it cannot call the pure `Requires_release.satisfied`
ancestry predicate for durable selection: snapshot equality is insufficient and
must not be used as a substitute. The current durable resolver returns
`Required_release_unavailable` pending an additive v2 schema with a typed
base-release link; ADR-027 records the required compatibility and migration
design.

### Composition invariant

For identical:

- Base snapshot.
- Capsule revisions.
- Dependency graph.
- Explicit order.
- Policies.
- Tool version and mandatory format features.

the resulting snapshot and conflict set must be identical.

On a localized application conflict, that operation is not applied. Operations
whose exact preconditions remain valid continue; later operations proven to
depend on an affected failed path are recorded as blocked. The partial snapshot
and all outcomes are exact application evidence, not a claim that every selected
capsule applied. Guarded workspace materialisation reuses scratch safety
checkpointing and filesystem protections. Scratch-head and workspace-ref CAS
publication are a documented non-atomic two-ref boundary.

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
- Structured exact-operation conflicts with no ref mutation.
- Complete rejection.

The current durable command implements only the first two outcomes. Semantic
and textual candidates are research evidence, not durable retargeting outcomes.

## 11. Release model

```ocaml
type release = {
  id : release_id;
  parent_releases : release_id list;
  workspace : workspace_id;
  workspace_revision : workspace_revision_id;
  workspace_revision_object : stored_object_id;
  workspace_attempt : (workspace_attempt_id * stored_object_id) option;
  base_snapshot : snapshot_id;
  capsules : selected_capsule_revision list;
  resolutions : (conflict_id * resolution_id * stored_object_id) list;
  final_snapshot : snapshot_id;
  evidence : (validation_id * stored_object_id) list;
  message : string option;
  created_at : timestamp;
}
```

### Release invariants

- `final_snapshot` is reproducible from declared inputs.
- The release is immutable.
- Validation evidence is bound to the final snapshot.
- Attestations are separate immutable objects and do not alter `release_id`.
- Exported bytes match the final snapshot.

`Release_id` derives from its canonical composition (parents, workspace/revision
and attempt links, base, ordered capsule links, resolution bindings, final
snapshot, and message), never from its own bytes. Evidence links and creation
time remain immutable observed metadata but are excluded from this logical
identity so a retry after pre-binding interruption can reuse the release ID.
The physical `Stored_object_id` still hashes the complete object.

Visibility is one create-only checksummed binding at
`refs/releases/<release-id>`. The binding names both logical and physical
identity, is expected-absent, and is the sole canonical release listing source.
Release verification loads all links, replays the immutable workspace attempt,
checks exact capsule/resolution agreement and final state, checks all evidence
targets the final snapshot, and traverses ordered parent links through immutable
bindings with cycle detection.

```ocaml
type release_attestation = {
  release : release_id;
  signer_identity : string;
  algorithm : string;
  signature : bytes;
  signed_at : timestamp;
}
```

`Release_attestation_v1` is Envelope type 22. It is a separate immutable object
with only its `stored_object_id` as identity. V1 accepts a signing interface and
a deterministic test signer whose algorithm identifier explicitly says it is
not cryptographic; no authenticity, key management, or production signing
format is claimed.

## 12. Validation evidence

```ocaml
type validation_status =
  | Passed
  | Failed
  | Timed_out
  | Execution_error

type validation_command = {
  executable : string;
  arguments : string list;
  repository_relative_working_directory : path;
  timeout_ms : int64;
  maximum_stdout_bytes : int;
  maximum_stderr_bytes : int;
  environment_policy : Empty_environment | Inherit_environment;
  environment_additions : (string * string) list;
  retain_output : bool;
  format_version : int;
  mandatory_features : int64;
}

type validation_evidence = {
  id : validation_id;
  snapshot : snapshot_id;
  command : validation_command;
  command_index : int;
  status : validation_status;
  exit_code : int option;
  signal : int option;
  execution_error : string option;
  stdout_digest : bytes;
  stderr_digest : bytes;
  stdout_truncated : bool;
  stderr_truncated : bool;
  retained_stdout : stored_object_id option;
  retained_stderr : stored_object_id option;
  environment_fingerprint : bytes option;
  runner_format_version : int;
  observed_at : timestamp;
  duration_ms : int64;
}

Validation execution resolves and materialises the exact immutable snapshot into
a fresh temporary directory, then invokes the executable plus argument vector
directly. It never validates a live working directory and never advances
scratch, workspace, or release refs. Stream retention is bounded while hashes
cover all observed bytes. Timeout terminates the started process group where the
host permits; escaped descendants remain a documented portability limitation.
Repeated observations may have different physical evidence objects because
duration and observation time are observational rather than correctness inputs.

The logical validation identity derives from canonical command/result fields
excluding its own ID, duration, and observation timestamp. A stored evidence
object includes its own logical identity and complete observations, so logical,
physical, and snapshot identities remain type-distinct.

yeokcham records evidence. It does not claim that passing tests proves correctness.

### Passing-validation scratch retention policy

```ocaml
type validation_retention_policy = Pin_all_exact_snapshot_checkpoints

type validation_retention_decision =
  | Evidence_not_passed
  | No_matching_checkpoint
  | Retain of checkpoint_id list
```

The policy is invoked only by explicit `validation run
--retain-passing-checkpoints`; ordinary validation and release-created evidence
do not invoke it. It loads the stored immutable evidence, requires `Passed`,
and selects every scratch checkpoint whose snapshot ID exactly equals the
evidence snapshot ID. It writes one idempotent `Validation_passed evidence_id`
retention reason per selected logical checkpoint. A failed/timed-out/execution
error result or absent exact checkpoint produces no retention change.

Selection is over snapshot IDs, never approximate bytes, timestamps, release
ancestry, or inferred user intent. The retention update can advance only
`retention-head`; it cannot advance `scratch-head`, workspace current refs, or
release bindings. The existing retention-reason encoding already carries the
typed validation ID, so this policy adds no persistent schema field.

## 13. Git bridge model

### Mapping records

ADR-028 defines the first durable Git-interchange association. It introduces
distinct typed `git_object_format`, `git_object_id`, `git_object_kind`, and
`git_mapping_id` values; none is a Yeokcham stored-object, snapshot, capsule,
workspace, conflict, or release identity. V1 accepts only `Git_sha1` IDs of
exactly 20 raw bytes and `Git_sha256` IDs of exactly 32 raw bytes, plus tree and
commit object kinds. It stores one immutable direction, Git object reference,
and a typed Yeokcham subject in `Git_mapping_v1`; logical mapping identity is
domain-separated from its physical Envelope-1 object identity. The only
canonical mapping visibility point is a create-only, checksummed binding under
`refs/git-mappings/`.

ADR-029 adds `Imported_transition_v1` in Envelope type 24 and `Git_mapping_v2`.
An imported transition records one same-format Git commit ID, declared tree ID,
resulting snapshot ID, and zero or more unique ordered direct parent commit IDs.
Its SHA-256 logical identity excludes itself and is domain-separated from its
physical Envelope object; visibility is a create-only checksummed binding under
`refs/imported-transitions/`. Mapping v2 retains v1 forms and additionally
maps `import/commit` to the transition ID plus its verified physical object ID.
V1 payloads, identities, bindings, and goldens remain unchanged.

ADR-031 adds `Imported_transition_v2` in the same Envelope type. It retains
exact raw author and committer header values, including source timestamp/time-
zone bytes, and a Content ID for exact message bytes. Its logical identity uses
a v2 domain and includes those provenance fields; v1 transitions remain readable
without synthetic metadata. Current commit imports publish v2 transitions and
reuse the existing `import/commit -> imported-transition` Git-mapping v3 form.

A mapping verifies exact typed Yeokcham links but is bridge evidence, not a
repository identity or a source of Yeokcham-history semantics. Mapping refs never
advance, rewrite, or hide scratch, capsule, workspace, conflict, or release
refs. Target publication and mapping binding are not cross-ref atomic; a crash
after a target becomes visible but before its mapping is bound remains an
explicit, retryable incomplete bridge state. M8-01 implements
`import/tree -> imported-snapshot`; M8-02 implements
`import/commit -> imported-transition` through the same bounded direct-argv
adapter; M8-03 implements `import/tag -> imported-tag`. The latter two are
opaque provenance, not capsules, revisions, or releases; none of these slices
is an exporter or general Git compatibility claim.

### Import

M8-01 recursively reads a requested SHA-1 or SHA-256 Git tree, validates
canonical Git tree entry order and safe names, and maps `100644`, `100755`, and
`120000` to regular, executable, and symlink snapshot entries. It preserves raw
blob/symlink-target bytes and publishes the resulting snapshot mapping only
after the snapshot is stored. Gitlinks and every other mode fail closed.

M8-02 reads only the requested raw commit header block. It requires exactly one
tree header, preserves direct parent header order, verifies the named tree and
each direct parent object type, and uses M8-01 to produce the snapshot. It
establishes the v1 transition/v2-mapping compatibility form. It rejects missing,
duplicate, malformed, self, wrong-format, missing-object, or wrong-type links;
it does not recursively import graph topology.

M8-04 requires one nonempty raw `author` and `committer` header, rejects
duplicates and NUL bytes, and retains their exact byte values plus the exact
post-header message bytes in `Imported_transition_v2`. It does not parse or
normalize author, email, timestamp, time zone, or message encoding. The message
Content may be visible before transition/mapping bindings; retry remains
explicit and immutable.

M8-03 resolves exactly one requested `refs/tags/<name>` ref and records one
`Imported_tag_v1` plus a Git-mapping v3. A direct commit/tree/blob ref is a
lightweight tag. A ref resolving to a tag object must have exactly one matching
raw `tag` header, one `object` header, and one supported `type` header; its
exact bounded raw object bytes are retained through `Snapshot.Content`. Its
tagger, message, and signature bytes have no Yeokcham semantic meaning and are
not verified. Nested tag targets, missing/mismatched refs, malformed headers,
and unsupported targets fail before the imported-tag binding.

M8-08 maps one verified `Release_v1` to one root Git commit. Its tree is built
from the release final snapshot's exact regular-file bytes, executable modes,
symlink-target bytes, and representable nonempty nested trees. The author and
committer are fixed exporter metadata at the release `created_at` UTC timestamp;
the message is the release message or the documented fallback. The target ref
is create-only and deterministic from the release ID. A nested empty directory
is not representable and rejects before ref or mapping publication. The visible
ADR-028 `export/commit -> exported-release` mapping names the release ID,
release object ID, final snapshot ID, Git format, and exact commit ID; it is
bridge evidence, not Yeokcham history.

M8-10 permits an optional complete invocation value
`(author-name, author-email, committer-name, committer-email, message)` for
that release export. Each identity is bounded, nonempty, structurally safe for
a Git header, and the message is exact bounded non-NUL bytes. With this value,
the root commit has exactly the configured author and committer headers at the
unchanged release `created_at` UTC timestamp and exactly the configured message.
Its create-only ref is the release ref plus a domain-separated,
length-delimited SHA-256 metadata suffix. Absent the value, M8-08 output is
unchanged. Present metadata may change only the Git commit, external ref, and
mapping ID; Yeokcham release identity, release object, final snapshot, and
mapping payload remain unchanged. A producer verifies the emitted tree, zero
parents, headers, and message before ref/mapping publication.

M8-09 maps a nonempty explicit ordered list of immutable revision links to one
Git commit per link. A link `(c, r, o)` is accepted only when `o` decodes to a
valid replayable revision with capsule ID `c` and revision ID `r`. For adjacent
selected revisions `a`, `b`, `a.expected_result = b.declared_base` is required
before any Git ref or mapping publication. The first commit is a root whose tree
exactly represents the first result snapshot; commit `i > 0` has exactly the
preceding exported commit as its sole parent and exactly represents result
snapshot `i`. Fixed exporter metadata uses each revision's `created_at`; fixed
messages identify only the exported capsule and revision IDs. The deterministic
create-only ref derives from a domain-separated SHA-256 of the ordered link
triples. Each visible ADR-028 `Exported_revision` mapping validates the exact
revision object and result snapshot it names. This exported parent sequence is
not capsule topology, dependency order, provenance, workspace state, conflict
state, resolution, or release history.

### Export

M8-08 implements a squashed release root commit, M8-10 adds optional explicit
release presentation metadata, and M8-09 implements one Git commit per
caller-selected capsule revision. Automatic revision ordering, explicit Git
merge topology, and configured revision metadata remain future recorded export
policies.

### Bridge invariant

For every supported final bridge state, one shared oracle compares the selected
immutable Yeokcham snapshot with its materialised destination: identical entry
set, regular-file bytes, executable bit, symlink target bytes, and nested tree
structure. For Git checkout destinations only `.git` is excluded from the
entry set. A failure identifies the divergent path and kind, bytes, mode, or
symlink metadata; it is a byte-representation failure, not a claim about
semantic equivalence. The oracle applies to exported release and selected
linear-revision commits and to snapshots produced by supported Git tree/commit
import after the source worktree may have changed.

## 14. Immutable object exchange

M10-01 adds transient exchange values only:

```text
Session = Await_hello | Open(session-id, offered, requested, budgets) | Closed
Frame = u64-be(payload-length) || canonical-profile-1-cbor-message
Message = Hello | Inventory | Want | Object | End | Error
```

`Hello` must be accepted before every other message. It requires byte-identical
repository-format bytes, protocol version `1`, and no unsupported mandatory
feature. `Inventory` and `Want` carry strictly ascending unique 32-byte
`Stored_object_id` values. A receiver associates one transient 16-byte session
ID with its first inventory, accepts increasing inventory/object sequences, and
accepts an object only when its ID was explicitly requested from an offered
page.

For an accepted `Object(session, sequence, id, bytes)`, the local adapter
requires `bytes` to be one exact canonical valid Envelope-1 encoding and
requires `id = stored_object_id(bytes)`. Only then it applies the existing
create-only transition:

```text
receive(repo, object) = Yeokcham_store.put(repo, decoded-envelope)
```

The receiver bounds each control message, page, session control bytes,
requested/transferred IDs, object bytes, and caller object-byte budget as
ADR-038 specifies. Any decode, ordering, membership, sequence, feature,
budget, Envelope, identity, or publication failure is a structured incomplete
exchange result. No exchange transition reads, creates, updates, reconciles,
or deletes a mutable ref.

Restart discards `Session` and starts at `Await_hello`; already published
immutable objects are rediscovered and their byte-identical `put` retry is
idempotent. Frames and sessions are not stored objects, semantic authority, or
persistent resume state.

## 15. Verifiable ref events

M10-02 adds one immutable `Ref_event_v1` proposal and pure verification:

```text
Ref_event = (event-id, repository-format-digest, ref-name, signer-key-id,
             signer-sequence, previous-event?, observed-ref, proposed-ref,
             algorithm, signature)
Verification = Verified | Untrusted | structured rejection
```

`event-id` is SHA-256 over the domain-separated canonical unsigned payload.
The Ed25519 signature covers that exact ID-bearing canonical payload under its
own domain separator. A trusted key map is caller-supplied transient input; a
key ID is the domain-separated SHA-256 of one 32-byte Ed25519 public key. A
missing key produces `Untrusted`; it is not a successful authenticity result.

An event names an existing ref's observed `(generation, target)` and a proposed
generation exactly one greater. Verification and evaluation are pure: valid,
untrusted, invalid, stale, replayed, out-of-order, and divergent events do not
call ref CAS or alter a ref. Given a current ref and known verified events,
evaluation returns one explicit `Ready`, replay/order, stale, or divergence
result. Competing ready proposals are retained as a divergence set; v1 makes no
winner selection or device/trust claim.

Ref-event objects are additive immutable Envelope-1 records. Trust maps, key
distribution/lifecycle, replay cursors, verification indexes, and applied-ref
history are neither canonical repository state nor persistent resume state.

## 16. Local device identities

M10-03 adds one immutable public `Device_identity_v1` declaration:

```text
Device_identity = (device-id, signer-key-id, algorithm, public-key, features)
Device_resolution = Resolved | Unmapped | Ambiguous
```

`device-id` is an opaque 32-byte CSPRNG value, distinct from every signer-key,
event, and stored-object ID. The declaration binds it to exactly one Ed25519
public key and ADR-039 signer-key ID; its public canonical bytes contain no
private key, hostname, user/account, address, timestamp, label, or transport
metadata. The private capability returned during generation is caller-owned and
is never a Yeokcham object or durable repository value.

A bounded caller-supplied registry consists of exact stored public declarations.
After, and only after, ADR-039 verification, pure lookup yields one explicit
resolved, unmapped, or ambiguous device result. Registry lookup does not make a
key trusted, change an event result, advance a ref, select a divergence, rotate
or revoke a key, or persist a registry. Device declarations use additive
Envelope type 27; no existing event, ref, object, or repository format changes.

## 17. Bounded local HTTP exchange

M10-04 maps exactly one ADR-038 frame to one HTTP/1.1 `POST /v1/exchange`
request with a length-delimited `application/vnd.yeokcham.exchange-v1` body. The
destination retains only one bounded in-memory receiver state for the active
HTTP session. `Hello` yields an empty response, `Inventory` yields one exact
`Want` frame, each `Object` yields an empty response after ADR-020 publication,
and `End` clears transient state. HTTP headers and bodies, exchange frames,
object bytes, store publication, and every response shape are bounded and
checked before publication; the adapter does not read or change a mutable ref.

An interrupted HTTP session has no durable cursor. Restart creates a new Hello
and reoffers caller-declared sorted IDs; existing byte-identical immutable
objects yield an empty Want set, while absent objects are requested again. HTTP
transport does not authenticate a peer, discover identity, transfer/reconcile a
ref, choose a divergence, persist an exchange session, or alter device/trust
results.

## 18. Durable divergent ref-head sets

M10-05 adds a candidate-only immutable value and one merge-only binding:

```text
Divergence_set = (repository-digest, ref-name, observed-ref,
                  ordered (event-id, ref-event-object-id){2..4096})
Binding(ref-name) = divergence-set-object-id
```

Each linked object must decode as `Ref_event_v1`, recompute to its stored event
ID, verify as `Verified` against the caller's explicit bounded key map, and
have exactly the set's repository digest, ref name, and observed ref state.
The canonical entry order is strictly ascending by raw event ID. A candidate
set containing a duplicate ID, wrong object type, missing link, untrusted
event, or mismatched context is rejected.

For valid sets with the same context, `union` is the sorted unique union of
exact `(event-id, object-id)` links; the same event ID paired with a different
object ID is rejected. Publication reads and validates the checksummed binding,
stores the canonical union create-only, then CASes the binding; contention is
bounded to 16 retries. Thus a successful transition only adds candidate links:

```text
publish(B, incoming) = CAS(B, B ∪ incoming)
```

No transition reads or writes the application ref, chooses a candidate,
advances a generation, merges a target, or changes trust. Missing bindings are
initialised; corrupt bindings and sets reject without replacement.

## 19. Encrypted offline object bundles

M10-06 adds an external, non-object encrypted bundle value:

```text
Bundle_key = opaque 32 bytes
Encrypted_bundle = (schema, algorithm, repository-format-digest, nonce,
                    ciphertext-with-tag, mandatory-features)
Bundle_plaintext = (schema, ordered (stored-object-id, Envelope-1-bytes),
                    mandatory-features)
```

The canonical outer header and plaintext use Profile 1. `Encrypted_bundle` is
not an Envelope, stored object, ref, binding, key record, or repository state.
The header contains schema `1`, algorithm `chacha20-poly1305`, a 32-byte
repository-format digest, a 12-byte nonce, ciphertext plus a 16-byte tag, and
mandatory features `0`; its exact canonical encoding is AEAD associated data.
The plaintext has at most 4,096 strictly raw-ID-ascending entries and at most
128 MiB of encoded bytes. Every entry's exact canonical Envelope-1 bytes must
recompute to its stated stored-object ID.

`import` first fully decodes, bounds, checks the repository digest, authenticates,
and validates the complete plaintext. Only then does it call create-only
immutable publication for each entry. Thus a rejected bundle has no publication
transition, while a later store I/O failure may leave only a valid immutable
prefix that a retry can publish idempotently. Export obtains a 12-byte nonce
from the OS CSPRNG and accepts a caller-held key only at its direct API boundary.
Neither transition reads, creates, updates, reconciles, or deletes application
refs, divergence bindings, trust/device state, or key state.

## 20. Shared-directory encrypted bundle workflow

M10-08 adds an external directory adapter over ADR-042:

```text
Directory_token = opaque random 16 bytes
Partial_descriptor = (safe-v1-name, observed-byte-length)
Complete_descriptor = (safe-v1-name, observed-byte-length)
Inspection = ordered stored-object-id list
```

`partial-v1` names `.yeokcham-bundle-v1-<32-lowercase-hex>.partial` and
`complete-v1` names `yeokcham-bundle-v1-<32-lowercase-hex>.yeok`. The opaque
name token is not authenticated metadata, a bundle/object ID, a nonce, a key
ID, or authority. A complete file contains exactly ADR-042 encrypted-bundle
bytes; a partial is never decrypted or imported. Listing is a sorted immediate
directory observation of recognised regular files only and changes no file or
repository state.

Export writes and fsyncs one exclusive partial, create-only links its complete
name, fsyncs the directory, then removes its own partial. Import and inspection
revalidate the chosen complete regular file, including byte identity/size across
the read. Inspection fully opens ADR-042 but publishes nothing. Import delegates
to ADR-042's complete validation-before-publication transition, so retry after
an I/O interruption has only the existing valid immutable-prefix semantics.
The adapter has no shared cursor, repair, cleanup, auto-import, ref operation,
binding operation, trust/device operation, or key state.

## 21. V2 encrypted causal ref ledger

V2-005 adds a V2-only immutable record, separate from every Envelope-1
ref-event and mutable ref:

```text
Unsigned = (version=1, repository-id, safe-ref-name, signer-key-id,
            predecessor-event-id?, target-opaque-object-ref?, features)
Event_id = SHA-256("yeokcham:v2:ref-ledger-event:1\\0" || cbor(Unsigned))
Signature = Ed25519("yeokcham:v2:ref-ledger-signature:1\\0" || Event_id)
Record = (Unsigned, Event_id, "ed25519", Signature)
```

All identities, targets, and public keys are exactly 32 raw bytes; signatures
are 64 bytes. A caller-supplied canonical bounded key map may establish only
`Cryptographically_valid` or `Unknown_signer`; it grants no identity, trust,
membership, ownership, or authorization. Each valid non-root record needs a
known predecessor for the same repository/ref. The evaluator rejects duplicate
IDs, missing/cross-scope predecessors, and cycles. It returns the sorted set of
unreferenced valid events and every sorted same-predecessor child set with two
or more elements; it never chooses a head or changes a mutable ref.

The first adapter frames the complete canonical record as the ledger variant of
ADR-054, encrypts that frame under ADR-045, derives its ADR-046 opaque address,
and create-only publishes those bytes under the V2 `objects` directory. An
exact existing byte sequence is a retry; a different sequence at the same
address rejects. No plaintext index or mutable ledger/ref record is persisted.

## 22. V2 durable object-publication transactions

V2-006 adds ADR-049 local recovery metadata, distinct from the repository
graph and from all authority-bearing state:

```text
Staged = (opaque-object-ref, canonical-encrypted-envelope-bytes)
Prepare = (version=1, repository-id, transaction-id, features,
           ordered-nonempty Staged[1..64])
Commit = (version=1, transaction-id,
          SHA-256("yeokcham:v2:transaction-prepare:1\0" || cbor(Prepare)))
```

For a repository `R`, `prepare(R, T)` first validates every staged envelope's
decryption, ADR-054 ledger frame, canonical ledger record, signature, and
ADR-046 address. It then
durably create-only writes `journal/T.prepare`. `commit(R, T)` can durably
create-only write `journal/T.commit` only when the exact stored prepare
validates and the digest binds its bytes. Neither transition writes an object,
ref, candidate binding, key, trust value, or policy.

`recover(R)` validates all recognised records before state change. For a
prepare without a commit it removes only the exact prepare bytes. For a matching
commit it runs `publish` for each staged envelope in address order, where each
publication is independently create-only, then removes commit and prepare.
Thus a failure has one of three outcomes: unchanged valid state; a valid
immutable object prefix plus resumable journal; or a typed invalid/corrupt
journal result with no automatic repair. No recovery outcome selects a ref or
asserts user intent.

## 23. V2 read-only repository verification

Given one supplied repository/address/encryption/key-registry context,
`verify_v2(R)` has no transition on persistent state. It first parses and
cryptographically validates every ADR-049 journal candidate, returning only
the sets of prepared and committed transaction identities. It then enumerates
every canonical opaque object path, verifies each ADR-046 address and ADR-054
frame, verifies ADR-048 signatures for ledger frames, and requires each signed
ledger repository ID to equal `R`.

For every safe ref name `n`, it evaluates the complete verified set
`E(R, n)`. A missing/cross-scope predecessor, duplicate event ID, cycle, bad
signature, absent signer, invalid object path, or invalid journal causes a
typed verification error and no repair. A successful report contains only
counts of verified objects/events/ref scopes, causal heads, explicit
divergences, prepared transactions, and committed/resumable transactions.
It neither chooses heads nor turns a cryptographic result into authorization.

## 24. V2 local bootstrap authority

ADR-053 replaces ADR-052's initial bootstrap bytes with a narrow local
precondition for a bootstrap-aware V2 scratch
service. It is separate from the V2 object graph, causal ledger, transaction
journal, user identity, and authorization policy:

```text
Capability = (envelope-key, address-key, signing-private-key)
Key_handle = 32-byte opaque public locator
Bootstrap_unsigned = (version=2, repository-id, device-id, key-handle,
                      signer-key-id, signer-public-key,
                      envelope-key-commitment, address-key-commitment, features)
Bootstrap = (Bootstrap_unsigned, Ed25519-signature)
```

The three capability byte strings are pairwise distinct. The signer-key ID
recomputes from the Ed25519 public key. Each key commitment is a SHA-256 digest
of a role-specific domain separator and its 32-byte secret key. The signature
covers the canonical unsigned bytes under the distinct local-bootstrap domain.

`matches(Capability, Bootstrap)` succeeds only when the derived public signing
key, signer-key ID, encryption-key commitment, and address-key commitment all
match. It supplies no user, membership, trust, ownership, ref-selection, or
policy result. A missing or mismatched capability is an explicit refusal.

`initialize_bootstrap(R, B)` may create exactly one canonical
`local-bootstrap-v2.cbor` record in a V2 layout-version-3 root. An exact retry
returns `Already_initialized`; different existing bytes reject without
overwrite. Strictly named same-directory staging files are non-authoritative
crash remnants. Older V2 root layouts fail closed in this development phase;
there is no migration transition.

## 25. Linux Secret Service custody

ADR-053 adds one Linux-only external custody relation. The service state is
not a Yeokcham repository object:

```text
Secret_service_attributes = (application, schema, hex(Key_handle))
Custody(Key_handle) = encode_v1(Capability)
```

Only fixed public application/schema labels and the signed public key handle
are attributes. `encode_v1(Capability)` contains the three private role values
and is supplied to `secret-tool` only on standard input. It is never a
repository value, argument, log, or disk fixture.

`open_custody(Bootstrap)` first rejects locked or unavailable service state,
then looks up its key handle. Missing, malformed, and role-confused data reject.
The reconstructed capability must satisfy `matches(Capability, Bootstrap)`
before the repository opens. Enrolment writes custody before the create-only
bootstrap, so the cross-service operation is deliberately non-atomic: an
interruption may leave an unreachable service item but cannot create a
repository bootstrap that validates with wrong key material.

## 25a. macOS Keychain custody

ADR-066 adds a second platform-local custody relation without altering a
repository format:

```text
Keychain_locator = (fixed-service, versioned-account(hex(Key_handle)))
Keychain_custody(Key_handle) = encode_v1(Capability)
```

The generic-password item is Data Protection Keychain data, synchronisation is
disabled, and its accessibility is `WhenUnlockedThisDeviceOnly`. Its strict
capability value is encrypted Keychain state, not a Yeokcham object, bootstrap
field, command argument, log, or fixture. `open_keychain_custody(Bootstrap)`
rejects locked, unavailable, missing, malformed, mismatched, and
non-exportable-key results before it evaluates `matches`.

Enrolment and removal affect only `Keychain_custody(Key_handle)`. They do not
add or revoke a repository authority record, device certificate, ledger event,
or membership relation. A present non-exportable `SecKey` is not converted to
raw capability bytes; it is an explicit refusal until a future capability model
can operate on provider-held signing material.

## 25b. Browser passkey PRF custody

ADR-067 adds a browser-local encrypted relation that has no repository-object
representation:

```text
Vault_public = (version, origin, rp-id, credential-id, salt, iv)
Vault_ciphertext = AES-GCM(PRF_assertion(credential-id, salt),
                           AAD(Vault_public), Capability)
```

The browser persists only `Vault_public` and ciphertext in origin-scoped
IndexedDB. `PRF_assertion` is available only after a fresh user-verifying
WebAuthn assertion with the configured credential and salt. Its 32-byte result
is imported as a transient non-extractable AES-GCM key; it is neither stored
nor sent to a repository/server boundary. Local storage holds no plaintext
capability or key.

`open_browser_vault(Vault_public)` rejects an unavailable WebAuthn/PRF API,
wrong credential ID, changed `clientDataJSON` type/challenge/origin,
cross-origin response, RP-ID-hash mismatch, missing presence/verification
flags, corrupt public fields, or AES-GCM authentication failure. Enrolment and
removal alter only browser-local credential/storage state; they are not signed
repository join/revocation transitions.

## 25c. Offline recovery package

ADR-068 defines a portable ciphertext that recovers a V2 authority root only
with an independently retained random secret:

```text
Recovery_key = SHA-256(domain, Recovery_secret, package-id)
Recovery_package = (version, package-id, repository-id, user-id, root-key-id,
                    root-public-key,
                    ChaCha20-Poly1305(Recovery_key, Recovery_payload), features)
Recovery_payload = (version, package-id, authority, root-private-key)
```

`Recovery_secret` is a 32-byte CSPRNG value outside repository and service
state. Its deterministic verification phrase is checked before decrypting but
is only a transcription check. A valid recovery requires phrase match,
authenticated decryption, canonical authority decoding, reconstructed root
public-key/ID/user match, and equality of all duplicated public bindings.

`recover_replacement_device` can construct a root-signed device-certificate
proposal from explicit new device material. It has no transition that activates
the certificate, edits a bootstrap, resets a service account, or replaces a
repository key. Missing package or secret is explicit irreversible loss.

The optional local artifact is one canonical encrypted file at
`.yeokcham/recovery/recovery-package-v1.cbor`. Publication is create-only:
private same-directory staging files are non-authoritative; byte-exact retry is
`Already_initialized`; divergent, malformed, or unknown entries reject without
replacing an existing copy. This local package does not add a repository object,
service endpoint, or authority-state transition.

## 25d. Secure-runtime IPC

ADR-069 defines a bounded local control-plane protocol, separate from both the
repository graph and custody records:

```text
Frame = (version, kind, body, mandatory-features)
Hello = (session-id, supported-versions, required-capabilities,
         optional-capabilities)
Request = (session-id, sequence, operation-kind, opaque-payload)
Response = (session-id, sequence, operation-kind, result-kind, opaque-payload)
```

`session-id` is an opaque 32-byte caller-created identity. A server selects the
highest shared version and a canonical subset of requested capabilities only
when every required capability is supported. A client validates the returned
session, version, and capability subset before it creates a request. V1's
closed capability and operation set is `MLS | device-crypto | mesh`; the
payload is bounded opaque bytes, not a repository ID, object, ref, authority
record, or interpretation rule.

For active session `S`, `next(S)` starts at zero. A request is accepted only
when its negotiated operation capability is present and
`request.sequence = next(S)`; acceptance increments `next(S)` exactly once.
An unknown session, a restart-lost session, duplicate, or gap is an explicit
refusal. A response is valid only when its session, sequence, and operation
equal the corresponding request. Frames use a bounded four-byte length prefix
and one canonical CBOR item; malformed, noncanonical, over-limit, or unknown
mandatory-feature input has no partial result.

This relation stores nothing and supplies neither endpoint ownership nor peer
authentication. A later Unix-socket adapter owns that local OS boundary; a
later Rust runtime implements the opaque operations. No V2 repository semantics
or custom cryptographic primitive is introduced here.

## 25e. Repository MLS bootstrap

ADR-070 defines one initial MLS group as an encrypted local bootstrap artifact,
not a repository object or authority transition:

```text
Mls_group_id(R) = SHA-256("yeokcham:v2:mls-group:1\0" || R)
Mls_group_state_v1 = (version=1, R, Mls_group_id(R), D, opaque-mls-state,
                      mandatory-features)
Group_file = ChaCha20-Poly1305(Bootstrap_envelope_key,
                               Mls_group_state_v1)
```

Creation gives `opaque-mls-state` exactly one Basic MLS credential containing
the bootstrap device ID `D`. Opening requires envelope authentication,
canonical re-encoding, `R` and `D` equality with the authenticated local
bootstrap, and runtime reload that proves the MLS GroupID and wrapped local
device credential. The initial state has exactly one credential; later member
states may have more. Metadata encryption derives a fixed, domain-separated 32-byte MLS
exporter secret and applies the existing V2 envelope; it does not use a
self-addressed MLS application message. A final state is visible only after
create-only durable publication; private staging files are not group state.
Future additions, credential trust, epochs, and revocation remain separate
transitions.

## 25f. V2 MLS member invitations

ADR-071 defines a root-authorized invitation lifecycle without introducing a
second membership system. The sole currently modeled invitation policy role is
the repository authority root. Its canonical signed invitation binds `R`, the
derived `Mls_group_id(R)`, recipient device `D2`, issue/expiry times, and an
envelope containing the recipient's opaque MLS snapshot. The 32-byte envelope
key is an out-of-band invitation capability and is never record content.

```text
Invite(R, D1, D2) = MLS.Add(KeyPackage(D2)) ; Commit ; Welcome ; Join
Invitation = Sign_root(R, GroupID(R), D2, issued, expires,
                       Envelope(invitation-capability, Mls_group_state(D2)))
```

The constrained runtime applies the Commit to the issuer snapshot and joins
the Welcome for `D2` before either returned snapshot is accepted. A valid
acceptance requires an unexpired invitation, a history with one issued event
and no revocation or earlier acceptance, envelope authentication, canonical
state decoding, exact `R`/GroupID/`D2` bindings, and runtime reload. A history
event records lifecycle only; it cannot create membership without this verified
MLS state transition. Canonical encrypted invitation and event records publish
create-only under `.yeokcham/mls-invitations` and
`.yeokcham/mls-membership-events`; unknown or divergent durable bytes reject.

## 26. V2 typed encrypted objects

ADR-054 makes the authenticated plaintext of every ADR-045 envelope one
canonical typed object frame:

```text
Object_frame = (version=1, kind, canonical-payload-bytes, features)
Object_kind = Ledger_event | Scratch_snapshot | Scratch_protection
            | Scratch_generation | Capsule | Capsule_revision
            | Workspace | Workspace_revision | Workspace_attempt
            | Conflict | Resolution | Validation_evidence | Release
```

`Ledger_event` contains an exact ADR-048 record. `Scratch_snapshot` contains
the exact canonical `Yeokcham_model.Snapshot` bytes: sorted safe paths,
directories, regular bytes, modes, and raw symlink targets. The kind remains
encrypted; ADR-046 addresses bind the complete outer envelope and therefore the
frame. A reader rejects unknown kinds/features, malformed selected payloads,
and noncanonical re-encoding. ADR-059 adds Capsule and Capsule_revision frames.
ADR-061 adds the five workspace frame kinds and requires their record IDs, link
order, and mandatory-feature bits to re-encode exactly. A generic object store
creates and loads frames; the ledger store is a typed view that analyses only
ledger frames. Old development envelopes that directly contain a ledger record
reject rather than migrate. ADR-062 assigns tags 11 and 12 to
Validation_evidence and Release; the retained unknown-kind fixture consequently
uses tag 13. Existing tag 0 through 10 frame bytes remain unchanged.

## 27. V2 local scratch snapshot publication

ADR-055 assigns an ADR-053 bootstrap device `D` the deterministic ledger scope
`"scratch-" || lowercase-hex(D)`. It is a causal ref name, not a mutable head
or authorization claim. Typed-object inspection admits only verified ledger
frames in that scope. A valid ledger event must target a typed exact snapshot;
the result is no checkpoint, one `(event-id, snapshot-ref, snapshot)`, or an
ordered divergent event set.

For exact candidate snapshot `S`, equal to the sole current snapshot yields
`Unchanged` with no persistent transition. Otherwise the transition first
create-only publishes `Scratch_snapshot(S)` in an ADR-054/ADR-045 envelope,
then create-only publishes a signed ADR-048 ledger frame whose target is the
new opaque snapshot reference and whose predecessor is the sole old event if
one exists. The two envelope nonces are distinct caller inputs. A divergent
state fails before snapshot publication. An interruption therefore leaves the
old valid causal view plus, at most, an unreachable immutable snapshot; it does
not create a mutable head or select a conflict.

ADR-057 adds runtime-only automatic scheduling:

```text
Daemon_state = Scheduler_state

due(request) -> Exact_scan(root) ->
  Unchanged                         => No_checkpoint
  Changed with no/one scratch head  => Publish_checkpoint
  Divergent/corrupt/watcher loss    => explicit daemon error
```

`Daemon_state`, watcher observations, socket discovery, and monotonic timestamps
are not persisted. A daemon start creates a fresh scheduler state and queues an
`Initial_scan` whole-root request; it never reuses a lost in-memory path queue.
Only a due request scans and reaches the ADR-055 transition, which receives two
distinct fresh nonces. The Linux watcher excludes root `.yeokcham` metadata, so
canonical publication cannot become a watcher source. A watcher-loss error ends
the daemon rather than authorizing a partial observation or selecting a head.

## 28. V2 exact restore planning

Given exact observed working-tree snapshot `O` and requested target snapshot
`T`, the pure V2 restore planner defines:

```text
Restore_plan(O, T) = (precondition=O,
                      safety=none                 when O = T
                           O                    otherwise,
                      ordered_actions)
Replay_restore(O, ordered_actions) = T
```

The planner is not a filesystem transition. Its future adapter must re-scan and
require the precondition before it writes, persist the nonempty safety value
before destructive work, and refuse a stale observed result. Actions delete
paths deepest-first, create target directories shallowest-first, and then write
or mode-change target files and create target symlinks in path order. A symlink
replacement always deletes the old path first; its raw target bytes remain data
rather than an interpreted path. Equal snapshots have no action and no safety
checkpoint requirement. No journal record, mutable head, or filesystem effect
is introduced by this pure planning relation.

## 29. V2 opaque restore journal

ADR-056 gives a non-no-op `Restore_plan(O, T)` an opaque recovery record after
`O` has become a verified safety checkpoint and before any destructive action:

```text
Restore_record = (repository, operation, safety-event, target-event,
                  safety-snapshot-ref, target-snapshot-ref, generation, phase,
                  action-count)
Restore_phase  = Prepared | Applying(completed) | Materialized | Published
```

Safety and target references differ. The two event IDs preserve the explicit
device-scope sources that must be re-verified after restart; no path, content,
symlink target, or private key appears in the record. `Prepared` is generation
zero. The only transition relation is:

```text
Prepared -> Applying(0)
Applying(n) -> Applying(n + 1), n + 1 <= action-count
Applying(action-count) -> Materialized -> Published
```

The first `Applying(0)` generation precedes destructive work. Each completed
action advances the count in a new immutable record. The two terminal phases
require all actions complete. The record does not apply an action, select a
causal head, validate a working tree, or publish a post-restore snapshot.

The ADR-056 store names each record
`restore-<operation-id>-<16-digit-generation>.cbor` inside the existing strict
V2 journal directory. Filename and payload must name the same operation and
generation. For each operation, the files sorted by generation form exactly one
chain starting with `Prepared` at zero; every later record is the byte-exact
legal successor of the preceding record. The store is create-only and treats
identical existing bytes as a retry; conflicting bytes, missing predecessors,
or malformed/non-regular entries reject. The materialisation adapter starts
from a durable `Applying(n)` record, first proves the pure replay reaches `T`,
then requires `scan(root) = Replay_restore_prefix(O, n)` before it writes. For
the documented crash window after action `n + 1` is durable but before its
journal generation, an explicit retry may instead prove
`scan(root) = Replay_restore_prefix(O, n + 1)` and append that exact progress
record without rewriting the action. No other observed state is inferred as
progress. The adapter confines every action below the real root, rejects the
metadata path and symlinked/non-directory parents, makes each action durable,
and only then appends `Applying(n + 1)`. After all actions it requires
`scan(root) = T` before it appends `Materialized`.

The authenticated recovery relation re-resolves both journal event IDs in the
local signed device-scratch scope and requires their typed snapshot references
to equal the record bindings. It therefore reconstructs the same `(O, T)` plan
from verified source events rather than trusting opaque identifiers alone. For a
`Materialized` record, it rechecks `scan(root) = T`; only when the sole scratch
checkpoint is the named safety event may it causally publish `T`. A crash after
that publication but before `Published` is reconciled only when the current
scratch checkpoint is exactly `T`; other sole heads and divergence reject. The
service appends `Published` only after this verified target checkpoint. It never
selects a different head as source or target.

The implemented preparation relation accepts an explicit signed event `E` only
when it is in the local device scratch scope and resolves to the target exact
snapshot `T`. It then scans `O`. If `O = T`, it produces no safety event or
journal. Otherwise it first causally publishes `O` as a verified safety
checkpoint `(S, O-ref)`, then creates `Prepared(repository, operation, S,
O-ref, T-ref, action-count)`, and only then appends `Applying(0)`. A previously
named operation is an explicit existing-operation result, not an implicit
resume. This relation does not choose a target causal head or modify the
working tree.

## 30. V2 scratch retention and compaction generations

ADR-058 keeps V2 retention separate from the historical V1 mutable-ref model.
For bootstrap device `D`, the base scratch causal scope is `scratch-D`; optional
protection and generation scopes are separate signed ledger names. An active
sole generation head names an immutable generation value and its replacement
scratch scope. No mutable current-generation file or winner-selection rule is
introduced.

```text
Protection = (snapshot-ref, Protect | Unprotect,
              User_pin | Capsule_boundary(binding) | Release_boundary(binding))
Generation = (source-ref, source-head, active-ref, active-anchor,
              retired-refs, cleanup-candidates)
Policy     = (recent-count, storage-budget-bytes?)
```

```text
Active_scratch(D) = scratch-base(D)
                  | generation-head(D).active-ref
generation.active-anchor \preceq sole-head(Active_scratch(D))
```

Claims fold in causal order; the latest action for the same exact snapshot and
reason is effective. The current head and every effectively protected snapshot
are retained. Since V2 does not contain an accepted trusted checkpoint time,
`recent-count` selects ordinal newest positions rather than pretending to be a
time window. A storage budget counts the exact regular-file bytes of the source
event and snapshot objects. It may exclude optional recent entries, but it
reports a required-set overrun rather than evicting a protected or current
state.

Claim(scratch-event, action, reason) first resolves the exact snapshot of the
explicitly named event in `Active_scratch(D)`. It then creates a protection
frame followed by a protection-ledger event. The frame alone has no retention
effect. Before that event is published, the adapter requires the planned
protection predecessor still to be the sole protection head and rechecks the
named event remains active. A changed claim head is explicit rather than a
silently forked effective-claim history.

Compaction creates a fresh immutable scratch ledger chain over the selected
existing snapshot references, oldest-to-newest, then publishes a generation
ledger event as the sole activation point. Its manifest binds the source ref
and source head to the replacement ref/activation anchor, so a destination
compact-ref name is not an unaudited string. A pre-activation interruption
leaves the prior scope active. The generation's active anchor must remain in
the sole current replacement chain; ordinary scratch publication may extend
that head after activation. After activation, old source scopes are retired
from scratch interpretation and may be quarantined only through the generation's canonical
candidate list. That list can contain source ledger objects and unretained
snapshots only when no retained checkpoint, effective claim, or live
non-retired ledger target names the snapshot. Quarantine is resumable local
maintenance; explicit prune is irreversible.

For an authored plan `P`, replacement ledger envelopes are immutable and may
be published in source order before activation. Immediately before publishing
`P`'s generation ledger envelope, the adapter must re-evaluate and require the
same active source ref/head, sole generation head, and sole protection head
recorded by `P`. A mismatch is an explicit stale-plan result. Thus an
interruption can leave unreachable durable candidates, but cannot make them
active; a concurrently advanced source or protection history cannot be
silently compacted using stale selection.
