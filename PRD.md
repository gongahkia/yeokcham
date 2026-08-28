# Product requirements

## Current milestone: V4 verified signed relay synchronization

V4 serves one developer and small, explicitly trusted teams. Its required
vertical slices are complete only when their model transition, durable format,
failure behaviour, and CLI surface agree.

### Required behaviour

1. Capture exact snapshots on explicit `save`; preserve snapshots for restore;
   compact only unnamed scratch entries under documented retention rules.
2. Keep draft checkpoints, shared revisions, conflict decisions, resolutions,
   and deliveries as distinct algebraic state.
3. Let users inspect and materialise decision candidates outside the live tree;
   resolving must be explicit and must not select a candidate by accident.
4. Sign shared and resolution revisions with an active Ed25519 device bound to
   one immutable authority epoch. The signed record itself must distinguish a
   shared revision from a decision-specific resolution.
5. Support administrator enrolment, revocation, atomic local-device rotation,
   branch-scoped lifecycle actions, explicit authority-fork reconciliation,
   root-phrase-checked device join, and one-time recovery authority rotation.
6. Exchange verified offline package directories. Verify canonical manifest,
   authority closure, signatures, causal parents, and snapshot/object closure
   in staging before importing immutable objects or advancing the state head.
7. Treat a late historical record from a now-revoked signer as review-required;
   accept it only after an administrator records a current-head, exact adoption.
8. Never materialise or otherwise mutate the working tree during join, review,
   package receive, authority update, or adoption.
9. Synchronize already-equivalent replicas through an HTTPS-fronted,
   bearer-authenticated immutable relay. Signed publication feeds reuse the
   verified package closure, preserve feed forks, commit valid receipt and
   local transport bookkeeping together, and report post-receive upload failure
   as partial success.

### Explicit non-goals

No clone/bootstrap, Git bridge, semantic parser or merge, blob GC, durable
`capture=`, immortal restore safety after journal prune, hardware keys,
external signing agent, macOS/WSL watcher, or CI-backed delivery exists in this
milestone. The bundled relay is an untrusted byte courier behind an
operator-managed HTTPS reverse proxy; it is not hosted authority or end-to-end
encrypted transport. These are not partial features.

### Acceptance evidence

Every persistent record is versioned canonical CBOR and has a golden fixture.
Core transitions have unit and generated tests; receipt has corruption,
causality, and no-partial-import tests; lifecycle has two-repository, rotation,
recovery, revocation, branch-selection/reconciliation, and exact-adoption
tests; and transport has canonical-publication, relay-failure, and
two-replica receive-first evidence. The real Linux watcher loop is an
outstanding platform verification, recorded separately rather than claimed from
Darwin.
