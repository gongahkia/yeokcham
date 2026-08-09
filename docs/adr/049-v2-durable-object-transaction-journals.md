# ADR-049 — V2 durable object transaction journals without implicit ref authority

- Status: Proposed
- Date: 2026-08-09
- Deciders: maintainer
- Supersedes: None
- Superseded by: None
- Governing issue: [#128](https://github.com/gongahkia/yeokcham/issues/128)

## Context and problem statement

V2-005 can verify and create-only publish one ADR-045 encrypted ledger
envelope at its ADR-046 opaque address. A higher-level operation will often
need to make a bounded set of such immutable objects durable before it exposes
any later visibility record. A process or filesystem interruption between
those writes must not overwrite an immutable object, make an invalid object
authoritative, or conceal the work needed to resume.

The V2 root reserves `.yeokcham/journal`, but V2 currently has no accepted
mutable ref, current-head, policy, membership, or other visibility-record
format. In particular, ADR-048 represents ref changes as append-only causal
records and deliberately does not select a mutable ref. A transaction journal
that writes or interprets a generic `refs/` file would therefore invent both a
V2 authority model and a recovery rule that later identity/policy work could
not safely inherit.

Current milestone: V2-00 Clean-slate repository foundation. Vertical slice: a
bounded local journal for a set of already encrypted, already verifiable V2
objects. It gives a caller an explicit prepared, committed, recovered, or
resumable state. It does not introduce a V2 ref mutation.

## Decision drivers

- Preserve ADR-045 envelope bytes, ADR-046 opaque addresses, and ADR-048
  cryptographic verification before any object becomes visible.
- Make every post-crash state either an unchanged valid root, a valid immutable
  object prefix, or an explicit journal state that can be resumed safely.
- Keep journal records local recovery metadata rather than history, trust,
  authorization, or ref-selection evidence.
- Bound journal entries, total staged bytes, names, scan work, and recovery
  work.
- Never overwrite an object, silently discard a committed transaction, repair
  corruption, or reuse the V1 ref runtime.

## Considered options

### Use a journal record as a generic mutable V2 ref

- Benefits: appears to give one all-purpose commit point for objects and refs.
- Costs and risks: V2 has not defined a ref-value type, authorization rule,
  conflict rule, or replacement semantics. Treating local recovery metadata as
  a current ref would collapse causal ledger data into a mutable authority and
  make crashes choose a result implicitly.

### Store only object IDs and require a caller to resupply bytes after restart

- Benefits: journal bytes are small and no ciphertext copy is retained.
- Costs and risks: a committed transaction cannot make independent forward
  progress after a crash even though its encrypted candidate bytes were already
  available. The result is detectable but unnecessarily depends on a caller's
  process state.

### Store canonical encrypted candidates with a prepare record and commit marker

- Benefits: recovery can revalidate and complete a bounded immutable object
  set without any plaintext, mutable ref, private key, trust policy, or
  overwrite operation. The commit marker distinguishes discardable preparation
  from a forward-only resumable transaction.
- Costs and risks: the journal temporarily duplicates encrypted object bytes
  and must have strict budgets, canonical names, and corruption handling.

## Decision outcome

Select canonical encrypted candidates with a prepare record and commit marker.
V2-006 is deliberately an **object-publication** transaction. It does not
claim cross-ref atomicity because there is no accepted V2 ref transition to
compose with it. A later V2 operation that defines a typed visibility record
must publish that record only after this transaction has made its referenced
immutable objects durable; a crash may then leave valid unreferenced objects
and the prior visibility state, never a guessed new ref.

`transaction-id` is a distinct opaque 32-byte value supplied by the caller.
The production caller obtains it from an OS CSPRNG; tests may inject a fixed
value. IDs are lowercase-hex encoded only in journal file names and have no
repository-history meaning.

The canonical prepare payload is:

```text
transaction-prepare-v1 = [
  1,
  repository-id,
  transaction-id,
  mandatory-features,
  [* [opaque-object-ref, canonical-encrypted-envelope-bytes]]
]
```

The staged array is strictly ascending by opaque object reference, has no
duplicates, and each entry's address must recompute from its exact outer
envelope under the caller-supplied ADR-046 address key. Its envelope must
strictly decode, decrypt, decode as an ADR-048 ledger record, and verify
against the supplied bounded public-key registry before prepare publication or
recovery can continue. The implementation initially permits at most 64 staged
objects and 128 MiB of aggregate envelope bytes, including CBOR framing.
Unsupported prepare mandatory features reject before an envelope is inspected.

The two local files are:

```text
journal/<64-lowercase-hex-transaction-id>.prepare
journal/<64-lowercase-hex-transaction-id>.commit
```

The prepare file contains exactly canonical `transaction-prepare-v1` bytes. A
commit file contains exactly this canonical CBOR payload:

```text
transaction-commit-v1 = [
  1,
  transaction-id,
  SHA-256("yeokcham:v2:transaction-prepare:1\0" || prepare-bytes)
]
```

Both files are published with private same-directory temporary files, `fsync`,
create-only final links, and directory synchronization. A transaction-ID reuse
is an idempotent retry only when its existing prepare or commit bytes are
identical; a different byte sequence is a typed collision. The prepare must be
durable before the commit file exists. No final object is written before the
commit marker is durable.

On recovery, every recognized journal file is a regular file with an exact
safe name. The adapter reads all prepare records first and rejects duplicate
IDs, stray commits, malformed bytes, unknown mandatory features, a mismatched
commit digest, an invalid candidate, or any unknown journal entry as a typed
corrupt/resumable condition; it does not delete or repair that state. A
prepare without a commit has no visible object side effect and may be removed
idempotently after its exact bytes are read and the journal directory is
synchronized. A matching commit causes recovery to revalidate the full staged
set, publish every object in ascending address order through ADR-048's
create-only adapter, and retain the journal unchanged on any publication
failure. After all objects are durable, removal of either journal file is
non-authoritative cleanup; a crash during cleanup leaves either a completed
valid object set or a recoverable completed journal, and another recovery is
idempotent.

The journal stores only already encrypted envelopes, opaque addresses,
repository identity, random transaction identity, feature bits, and a
prepare-byte digest. It stores no plaintext ref name, target, signer key,
private key, trust decision, authorization decision, current ref, mutable
selection, object-type header, or network state.

## Consequences

- Interrupted committed transactions resume forward with exactly the same
  encrypted candidates; interrupted uncommitted preparations clean up without
  a visible object transition.
- A crash after a committed object prefix can expose valid unreachable
  immutable objects, which are safe retryable data rather than a partial ref
  update.
- Corrupt or unfamiliar journal state remains inspectable and blocks automatic
  cleanup for that entry; no recovery path guesses intent.
- Future typed visibility protocols remain responsible for their own conflict,
  authorization, and publication semantics. They cannot rely on the journal as
  an authority record.
- The initial aggregate budget may require a future explicitly versioned
  transaction format for larger operations.

## Model and invariant impact

V2-006 adds abstract `transaction_id`, `staged_object`, `prepare`, `commit`,
and recovery-result values. Its invariants are:

1. A prepared entry names exactly the opaque address derived from its canonical
   encrypted envelope in the declared repository.
2. Every staged envelope is independently cryptographically valid under the
   caller-supplied key registry before prepare and before recovery publication.
3. Prepare entries are bounded, strictly ordered, unique, and canonical.
4. A commit is valid only for one byte-identical durable prepare record.
5. No object is visible before a durable matching commit marker; every visible
   object is create-only and independently valid.
6. Repeated recovery cannot overwrite an object and reaches the same completed,
   discarded-precommit, blocked-corrupt, or resumable result.
7. Neither prepare nor commit grants trust, authority, ownership, membership,
   ref selection, or history status.

## Persistent-format and migration impact

This adds versioned local recovery metadata, not a canonical repository graph
object or a replacement for V1 state. Both records use the existing canonical
CBOR profile and fail closed on unknown mandatory features. Checked-in golden
fixtures must cover one prepare and its matching commit; fixed malformed,
unknown-feature, reordered, duplicate-address, mismatched-digest, stray-commit,
and unsafe-name inputs must remain checked in. V1 roots and V1 journal/ref
formats are never read or written. Existing V2 roots have an empty reserved
`journal` directory, so no migration is needed; a nonempty unrecognized V2
journal remains a fail-closed recovery condition.

## Verification

- Unit tests cover canonical prepare/commit encoding, exact address and digest
  binding, feature negotiation, input budgets, duplicate/reordered candidates,
  unsafe names, and typed corruption results.
- Generated tests construct bounded candidate sets and injected interruption
  points; reopening must reach an old valid state, a valid immutable prefix/new
  state, or a typed resumable state without ref mutation.
- Persistence-failure tests cover before and after prepare visibility, commit
  visibility, each object link/directory synchronization, and each cleanup
  unlink. They prove no immutable overwrite and idempotent recovery.
- Goldens cover valid prepare/commit records and all fixed invalid categories.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and focused
  recovery tests remain required.

## CLI and user impact

No CLI mutation is added in V2-006. A later inspection command may report a
transaction ID and whether it is prepared, committed/resumable, corrupt, or
cleaned, but it must not claim that a journal selects a ref or proves user
intent. The caller must make any later ref or policy decision through its own
typed V2 transition.
