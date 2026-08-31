# Product requirements

## Current milestone: V4 verified receipt, explicit relay bootstrap, advisory runtime, durable restore proofs, local recoverable collection, exact decision-proposal assistance, optional external-LSP observations, and explicit local device custody

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
10. Bootstrap a new enrolled replica only from an explicit immutable signed
    basis ID. Verify the complete closure and independently compared root phrase
    before importing shared history into a fresh local draft; source scratch,
    credentials, aliases, and working-tree bytes never transfer.
11. Limit relay storage access with operator-managed repository-scoped read and
    write secrets. Rotation, revocation, and expiry remain relay-local policy;
    they never grant V4 authority or change receipt semantics.
12. Render read-only terminal views of current V4 work and the separate
    authority-epoch DAG. The views must expose decisions and concurrent heads,
    report unavailable historical relationships rather than inventing them, and
    never change state or materialise the working tree.
13. On Linux, manage one private disposable background runtime per repository.
    It may perform debounced exact scratch capture; transport work is only an
    explicit `daemon sync` request through the existing receive-first boundary.
    Runtime loss, remote failure, and duplicate-start refusal must not change
    the working tree or add a new authority, history, or project-state model.
14. An explicit in-place restore must preserve both its previous and target
    snapshot as a local durable recovery proof until the user explicitly
    forgets that proof. Compaction must validate and explain that root before
    changing the state head.
15. Collect only local immutable bytes outside the closure of the current V4
    state and every retained checkpoint. Collection must first provide a
    deterministic explanation, then quarantine candidates in a recoverable
    local transaction. It may unlink only after an explicit, revalidated purge;
    relay, package, transport, authority, project history, and working-tree
    state must remain untouched.
16. For a pair of revisions in an open decision, show a parser-free,
    byte-exact proposal that selects only entries already present in the base
    or a named candidate and explicitly refuses every ambiguous path.  A
    proposal is local convenience information: it cannot resolve a decision,
    record acceptance, select a delivery, or mutate the live working tree.
17. Permit an explicitly selected SSH-agent key or PKCS#11 Ed25519 key to
    supply a local signing capability without changing the canonical signed
    record, device ID, authority rules, or persistent project format. Provider
    absence, denial, key mismatch, and rotation failure must remain explicit.
18. Optionally obtain bounded language facts from one explicitly configured
    external LSP server over disposable named snapshots. Those facts are local
    review evidence only: they cannot become canonical source, select a
    candidate, resolve a decision, write a worktree, or enter V4 state,
    package, relay, bootstrap, authority, or delivery data.

### Explicit non-goals

No general clone, Git bridge or interchange, in-process semantic parser or
merge, automatic or remote GC,
durable command metadata, macOS watcher, WSL support, or CI-backed delivery exists in this
milestone. The bundled relay is an untrusted byte courier behind an
operator-managed HTTPS reverse proxy; it is not hosted authority or end-to-end
encrypted transport. No online coordinator, quorum, or witness service can
select or gate V4 authority. These are not partial features.

### Acceptance evidence

Every persistent record is versioned canonical CBOR and has a golden fixture.
Core transitions have unit and generated tests; receipt has corruption,
causality, and no-partial-import tests; lifecycle has two-repository, rotation,
recovery, revocation, branch-selection/reconciliation, and exact-adoption
tests; and transport has canonical-publication, relay-failure, and
two-replica receive-first evidence. Collection has canonical transaction,
closure, corruption, interrupted-quarantine/purge, and explicit CLI journey
evidence. The real Linux watcher loop is an
outstanding platform verification, recorded separately rather than claimed from
Darwin.

Custody coverage must preserve canonical signed-record fixtures across native
and opaque capabilities; prove no private bytes escape a non-exportable
provider; and exercise user denial, unavailable/locked provider, mismatched
public key, and interrupted rotation without a state or working-tree write.
