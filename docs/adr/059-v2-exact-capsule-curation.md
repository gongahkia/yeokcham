# ADR-059 — V2 exact capsule curation and initial bindings

- Status: Accepted
- Date: 2026-08-10
- Deciders: maintainer (approved V2-01 client-neutral continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#140](https://github.com/gongahkia/yeokcham/issues/140)
- Related issues: [#137](https://github.com/gongahkia/yeokcham/issues/137), [#139](https://github.com/gongahkia/yeokcham/issues/139), [#141](https://github.com/gongahkia/yeokcham/issues/141)

## Context and problem statement

V2 has encrypted exact scratch snapshots and causal events, but no durable
intent-history record. V1 capsule objects and mutable refs cannot be reused:
they are a different persistent format and authority model. The first V2
capsule must retain exact selected transitions and both range boundaries without
claiming to know the user's intent.

## Decision drivers

- Deterministic, direct exact replay from a declared base.
- No inferred move, semantic edit, feature, or user grouping.
- Stable capsule identity distinct from revision and opaque object identity.
- Boundary snapshots protected before a capsule is visible.
- No mutable file, plaintext index, platform dependency, or V1 reuse.

## Considered options

### Infer moves or semantic edits

Matching bytes across paths do not prove a user intended a move. This would
turn a proposal into an unearned intent claim, so it is rejected.

### Store only a whole-snapshot replacement

This makes a subset replayable but loses the selected exact operation evidence
that later conflict and workspace work must inspect. It is rejected.

### Deterministic structural transitions with immutable records

The selected design derives exact operations, accepts an explicit selection,
and persists a complete immutable initial revision. It is selected.

## Decision outcome

`Yeokcham_v2_capsule.propose(from, to)` compares exact snapshots in canonical
path order. It deletes removed or type-replaced roots, creates directories
shallowest-first, modifies same-file content and mode, then creates files.
`Create_directory` represents empty directories. It emits no `Move_path` and
makes no semantic or intent statement. Success requires `apply(from, O) = to`.

Selection is a strictly ascending nonempty list of proposal indices. It either
replays from the exact source or returns the original proposal index and exact
transition error. A selected subset has its own expected-result snapshot and
does not need to equal the range target.

ADR-054 object-frame v1 adds:

```text
kind = ... | 4 Capsule | 5 Capsule_revision
capsule-v1 = [1, capsule-id, title, description, created-at, features]
snapshot-link-v1 = [logical-snapshot-id, snapshot-opaque-ref]
source-boundary-v1 = [source-snapshot-link, target-snapshot-link]
capsule-revision-v1 = [
  1, capsule-id, revision-id, capsule-opaque-ref,
  declared-base-link, expected-result-link,
  [* canonical-operation-bytes], source-boundary-v1, features
]
```

All IDs and opaque references are 32 bytes. Revision ID is SHA-256 over a
domain-separated canonical preimage of capsule ID, logical base/result IDs,
ordered operation bytes, and ordered boundary logical IDs. It excludes physical
references and presentation metadata; those remain mandatory verification links.

The initial visible binding is one signed ADR-048 event in
`capsule-<lowercase capsule-id hex>`, targeting the revision object. Resolution
authenticates the binding, Capsule, revision, and all linked snapshots, then
replays the revision. Missing targets, wrong frame kinds, corrupt links, replay
mismatch, and divergent binding heads are explicit errors; no winner is chosen.

Creation first requires the named source event to be an ancestor of the target
event in the sole active scratch scope. It create-only publishes the Capsule,
any selected-result snapshot, and Capsule_revision. It then publishes two
ADR-058 `Protect` claims for the source and target boundary snapshots, each
using `Capsule_boundary(revision-opaque-ref)`. Only after both claims does it
publish the visible binding. An interruption before binding leaves no visible
capsule, though immutable unreachable objects or extra safe pins may remain.

## Consequences

- Curation is client- and OS-neutral; it has no watcher, UI, macOS, Linux, or
  hosted-service dependency.
- A partial selection remains an exact independently stored snapshot result.
- Compaction may retire the original scratch ledger range, but protected linked
  snapshot bytes remain recoverable through the capsule.
- Initial revisions have no parent/provenance, split/combine, or concurrent
  update protocol; V2-019 must extend rather than mutate these records.

## Model and invariant impact

```text
proposal(S, T) -> O where apply(S, O) = T
select(S, O, I) -> R | explicit transition conflict
visible(C) => replay(revision(C).base, operations) = revision(C).result
visible(C) => protected(boundary.source) and protected(boundary.target)
```

1. A proposal never denotes inferred intent.
2. Full replay includes exact bytes, modes, symlinks, and empty directories.
3. A selected revision replays directly or reports an explicit conflict.
4. A visible binding resolves to matching immutable Capsule and revision records.
5. Linked snapshot IDs match decrypted snapshot bytes.
6. Both source boundary snapshot references are protected before visibility.

## Persistent-format and migration impact

Frame kinds 4 and 5 have strict canonical decoders and fixed goldens.
`Create_directory` is exact-operation tag 5. Existing V2 snapshot, ledger,
protection, generation, envelope, and address bytes are unchanged. The fixed
unknown-kind fixture moves from code 4 to code 6 because 4 is now assigned.

There is no old V2 capsule reader, migration, or V1 reuse. The approved
development policy has no user repositories before the V2 issue set closes.

## Verification

- Unit tests cover exact replay, empty directories, no inferred move, invalid
  dependent selections, codecs, durable creation, and interruption/retry.
- Seeded generated tests vary bytes and modes in pure and persisted paths.
- A compaction test proves protected source boundaries resolve after the
  original scratch range is retired.
- Object-frame golden fixtures cover Capsule and Capsule_revision.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

No top-level command is added here. V2-011 owns client/service delivery; a
future client supplies metadata, selected indexes, source events, and fresh
nonces. The adapter returns structural operations and explicit conflicts only.
