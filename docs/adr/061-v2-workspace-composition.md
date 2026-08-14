# ADR-061 — V2 deterministic workspaces and explicit conflict records

- Status: Accepted
- Date: 2026-08-12
- Deciders: maintainer (delegated V2-020 implementation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#142](https://github.com/gongahkia/yeokcham/issues/142)
- Related decisions: ADR-006, ADR-007, ADR-026, ADR-048, ADR-054, ADR-059

## Context and problem statement

V2 has exact authenticated scratch snapshots and durable capsule revisions, but
has no V2 workspace, attempt, conflict, or resolution state. The V1 workspace
objects cannot be reused: their object identity, encryption, reference, and
authority formats predate the V2 cutover. A V2 workspace must compose exact
immutable revision links without selecting a hidden order, guessing an edit, or
turning a local conflict into a process-only failure.

## Decision drivers

- The same verified inputs must derive the same order, result, and conflict set.
- An operation conflict must remain inspectable while unrelated operations run.
- A user action must name one exact conflict and never imply a replacement.
- All durable objects must use ADR-054 typed encrypted frames and canonical
  records.
- A mutable workspace head may select an immutable revision only through an
  authenticated ADR-048 causal ledger binding.

## Considered options

### Reuse V1 workspace records

V1 records have a separate envelope, stored-object, and mutable-ref model. A
bridge would make V1 bytes authoritative in a V2 root and weaken the explicit
cutover boundary, so it is rejected.

### Stop composition at the first failed operation

Stopping discards information about independent later operations and makes a
conflict a process failure. It is rejected.

### Store a mutable resolved flag or inferred replacement

A mutable flag loses resolution history, while a guessed replacement claims an
intent the user did not state. Both are rejected.

### Canonical immutable workspace records with skip-only resolutions

The selected design stores immutable records, canonicalises selected revision
links and precedence, and permits only an explicit `Skip_operation` resolution
of the exact revision-link/operation-index conflict. It is selected.

## Decision outcome

The pure workspace core accepts verified V2 capsule revision links and explicit
precedence edges. It rejects duplicate capsules, duplicate revisions, malformed
links, unknown precedence endpoints, duplicate precedence, and cycles. Its
topological tie-breaker is capsule revision identity. It applies each exact
operation separately. A rejected operation yields a typed conflict; only later
operations whose paths overlap an existing conflict are blocked. Disjoint
operations continue deterministically.

ADR-054 frame v1 adds these canonical payload kinds:

```text
kind = ... | 6 Workspace | 7 Workspace_revision | 8 Workspace_attempt
           | 9 Conflict | 10 Resolution
```

Every record starts with its own schema version and ends with mandatory feature
bits. A Workspace has stable metadata. A Workspace_revision names its workspace,
optional immutable parent, exact base snapshot link, selected immutable capsule
revision links, canonical precedence and resolved order, and immutable
resolution bindings. A Workspace_attempt names one revision, its exact base and
result snapshot links, ordered selected links, outcomes, and Conflict object
links. A Conflict names the exact workspace/revision/attempt, capsule revision
link, operation index, paths, and typed transition failure. A Resolution names
the exact Conflict link and a skip-only action.

The visible workspace head is one signed ADR-048 causal event in
`workspace-<lowercase workspace-id hex>`, targeting a Workspace_revision frame.
An attempt has a distinct expected-absent signed binding in
`workspace-attempt-<workspace-id hex>-<attempt-id hex>`. Conflicts and
resolutions are reachable from their immutable attempt/revision records rather
than receiving mutable status refs. A resolution creates a new immutable
workspace revision and advances the workspace head causally after all named
objects are durable.

## Consequences

- V2 workspace composition is client-, watcher-, and platform-neutral.
- A partial attempt is durable evidence, not a failed mutable transaction.
- A conflict does not prevent unrelated capsule operations, subsequent attempts,
  inspection, or an explicit resolution.
- Resolution does not edit bytes, choose a winner, or make a semantic claim.
- V1 workspace objects and refs remain outside V2 repository truth.

## Model and invariant impact

```text
same(selected, precedence, base, resolutions) => same(order, snapshot, conflicts)
conflict(r, i) => r and i name one immutable selected operation
active_resolution(c) => workspace_revision binds immutable Resolution(c, Skip_operation)
visible_workspace(w) => verified immutable revision and direct attempt replay
```

1. Each selected capsule and revision occurs at most once in a workspace revision.
2. Stored resolved order recomputes from selected links and precedence.
3. Every applied outcome is byte-exact; every failed operation is explicit.
4. A blocked operation overlaps an earlier conflict; unrelated paths continue.
5. A resolution can only skip the exact operation named by its conflict.
6. Frame decoders reject unknown mandatory features, malformed links, and
   noncanonical ordering.

## Persistent-format and migration impact

Frame tags 6 through 10 are new V2 frame kinds. Existing tags 0 through 5 and
their canonical bytes do not change. The old unknown-kind golden moves from tag
6 to tag 11, and goldens cover every new frame kind. V2 does not migrate or
read V1 workspace records. The approved V2 development policy has no user
repositories before this issue set closes.

## Verification

- Focused pure tests cover canonical ordering, duplicate/malformed inputs,
  localized conflict continuation, and skip-only resolution.
- Seeded generated tests prove selected-input permutation preserves order and
  resulting snapshot.
- Durable tests cover authenticated resolution, reopen, interruption before
  binding, malformed frames, and stale workspace-head updates.
- Golden fixtures cover every new object frame and the shifted unknown-kind
  rejection.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

No top-level command is added in this issue. The V2 local service/client layer
will later expose workspace inspection and explicit actions. This decision only
provides client-neutral model and durable adapter operations.
