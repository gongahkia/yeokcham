# ADR-055 — V2 local scratch snapshot publication

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#136](https://github.com/gongahkia/yeokcham/issues/136)
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#147](https://github.com/gongahkia/yeokcham/issues/147)

## Context and problem statement

ADR-053 gives one local device a role-separated capability and a signed public
bootstrap. ADR-054 permits exact snapshots and ledger events to share the
opaque immutable object namespace. V2-014 needs the transition that turns one
exact observed snapshot into a candidate scratch checkpoint without
introducing a mutable head, inferred intent, or a second unencrypted cache.

The causal ledger intentionally represents divergence rather than choosing a
winner. Local scratch publication must preserve that property: it can extend a
single known local head, but it cannot silently decide between divergent heads.

## Decision drivers

- Publish exact bytes, directories, modes, and symlink targets before naming
  them from history.
- Leave every interrupted state either at the prior valid head or with only
  unreachable immutable data.
- Make an unchanged exact scan a no-write outcome.
- Bind the local scratch scope to the signed bootstrap device without claiming
  user identity, authorization, trust, or global ownership.
- Keep nonce generation and working-tree scanning outside the pure causal
  decision boundary.

## Considered options

### A mutable `scratch-head` file

This would introduce a new V2 authoritative ref, replacement rule, crash
protocol, and divergence policy before those concepts are accepted. It is not
selected.

### Store snapshots in a daemon cache and append ledger data later

An unencrypted cache would become a second source of recovery truth and could
lose the exact-address binding. It is not selected.

### Publish an immutable snapshot, then append a causal ledger event

The event is the only candidate-history statement and names one immutable
snapshot object. A crash before it leaves an unreachable snapshot; a crash
after it leaves a complete causal candidate. It is selected.

## Decision outcome

For bootstrap device ID `D`, the only local scratch ledger scope is:

```text
scratch-ref(D) = "scratch-" || lowercase-hex(D)
```

The string is a ledger ref name, not a filesystem path or an authorization
claim. `inspect_scratch` opens every typed object, considers only verified
ledger frames in this scope, and evaluates their causal graph. Its result is
one of:

```text
No_checkpoint
One_checkpoint(event-id, snapshot-object-ref, exact-snapshot)
Divergent_checkpoints(sorted event-id list)
```

A ledger event in this scope must name a target. The target must open as an
ADR-054 `Scratch_snapshot` frame. A missing target, a ledger target, malformed
frame, signature failure, or foreign repository is an explicit failure.

Given a new exact snapshot `S`, publication first inspects this state. If the
sole current snapshot equals `S`, it returns `Unchanged` and writes no object.
If there is no checkpoint or one checkpoint, it seals and create-only publishes
`Scratch_snapshot(S)` using a caller-supplied nonce. It then constructs and
signs a ledger event in `scratch-ref(D)`, with the sole old event ID as its
predecessor when present and the new snapshot opaque object reference as its
target. It frames, seals with a distinct caller-supplied nonce, and create-only
publishes that ledger frame. A divergent state returns a typed conflict before
any new snapshot is written.

The V2 scratch adapter obtains repository ID, device ID, role keys, and signer
only from an already-open ADR-053 bootstrap repository. It receives nonces and
the exact scanned snapshot from its caller; it does not scan a working tree,
choose a clock, generate a key, access Secret Service, or create a mutable
head.

## Consequences

- A failed second publication can leave a valid unreachable snapshot, while the
  prior causal head remains valid and inspectable.
- Retrying with the same two encrypted candidates is idempotent. Retrying after
  a lost caller candidate can create another unreachable snapshot, but cannot
  overwrite a snapshot or move history without a complete signed event.
- A divergent local scratch scope stops automatic publication and becomes an
  explicit conflict for later user-facing resolution.
- The scheduler's existing `Unchanged -> No_checkpoint` decision and this
  exact-snapshot equality rule independently prevent no-change publication.
- Retention, compaction, restore/materialisation, and multi-device policy
  remain later V2-01 work. ADR-057 owns daemon scheduling and passes exact
  scanner results and fresh nonces through this boundary.

## Model and invariant impact

```text
Scratch_state = No_checkpoint
              | One_checkpoint(Event_id, Snapshot_ref, Exact_snapshot)
              | Divergent_checkpoints(sorted Event_id list)
Publish(S, No_checkpoint)       = snapshot(S); ledger(root, snapshot-ref)
Publish(S, One_checkpoint(H,..)) = snapshot(S); ledger(H, snapshot-ref)
Publish(S, Divergent_checkpoints) = conflict
```

1. A published scratch ledger event targets exactly one verified exact snapshot
   object in the same repository.
2. `Unchanged` has no persistent transition.
3. A new ledger event is published only after its target snapshot is durable.
4. No branch is selected when causal evaluation reports divergence.
5. The local device scope is deterministic from a bootstrap-bound public ID but
   does not prove authority beyond the local bootstrap boundary.
6. The two envelopes for one publication use distinct nonces.

## Persistent-format and migration impact

No mutable scratch record is introduced. The durable bytes are only existing
ADR-054 version-1 snapshot and ledger frames carried by ADR-045 envelopes.
The ledger record uses ADR-048's version-1 schema and a deterministic
device-scoped ref name. Tests retain canonical frame/envelope fixtures; no old
raw-ledger plaintext reader or migration exists under the approved no-user-data
development policy.

## Verification

- Unit tests cover initial publication, exact no-change, causal extension,
  divergent-head refusal, wrong target type, and restart inspection.
- Seeded generated traces cover snapshot sequences and prove each visible
  checkpoint reopens to its exact snapshot.
- Persistence-failure tests block the second publication and prove that the old
  head remains valid while the new snapshot is unreachable.
- Existing generic object and causal-ledger goldens cover the persistent bytes;
  no plaintext private material is added.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

The VCS CLI performs no mutation under this decision. ADR-057's `yeokchamd`
may pass an exact scanner result and fresh nonces to this adapter, but it must
surface a divergent scratch result rather than select or overwrite a checkpoint.
