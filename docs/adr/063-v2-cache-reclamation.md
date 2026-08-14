# ADR-063 — V2 local cache reclamation from complete reachable roots

- Status: Accepted
- Date: 2026-08-12
- Deciders: maintainer (approved 2026-08-12)
- Supersedes: None
- Superseded by: None
- Governing issue: [#144](https://github.com/gongahkia/yeokcham/issues/144)
- Related decisions: ADR-045, ADR-048, ADR-049, ADR-054, ADR-056, ADR-058,
  ADR-059, ADR-061, ADR-062

## Context and problem statement

ADR-058 safely reclaims only retired scratch-generation candidates. V2 now has
visible capsule, workspace, attempt, release, validation, and restore domains,
so that narrow candidate list cannot safely enforce an encrypted local-object
cache budget. Deleting from the opaque namespace based on one domain or an
unverified index could make an active immutable object unavailable.

The repository already has authenticated typed frames, signed causal ledger
events, local restore journals, exact opaque-object sizes, resumable
no-overwrite quarantine moves, and a strict V2 root classifier. It has no
complete cross-domain liveness model or publication barrier. Cache state must
stay local maintenance metadata: it must neither define canonical history nor
alter logical identity.

## Decision drivers

- Reclaim only objects proven unreachable from every active local history and
  recovery root.
- Reject incomplete, corrupt, divergent, or concurrently changing root state
  instead of guessing a safe deletion set.
- Make quota selection deterministic from authenticated stored bytes.
- Preserve a recoverable, inspectable quarantine interval before irreversible
  deletion.
- Keep cache accounting and progress outside canonical encrypted history.

## Considered options

### Extend the scratch-generation cleanup list to every object

Scratch generations own only retired scratch scopes. Treating their manifests
as authority for capsules, workspaces, releases, or restore state would conflate
scratch retention with independent immutable histories. It is rejected.

### Trust a rebuildable object index or object age

An index can be absent or stale, and opaque-object creation order is not a
liveness relation. Either can select an active object for removal. It is
rejected.

### Permanently delete each non-root object after one scan

A crash or later root publication would provide no recovery interval. It is
rejected.

### Complete authenticated mark, guarded quarantine, explicit prune

Authenticate the complete local inventory, derive roots from recognised signed
V2 scopes and recovery journals, traverse typed physical links, and retain the
resulting closure. Persist one local immutable reclamation manifest, move only
its candidates to no-overwrite quarantine under a publication barrier, and
require a later explicit prune. This is selected.

## Decision outcome

ADR-063 adds a pure `Yeokcham_v2_reclamation` core and a local reclamation
adapter. The core receives an authenticated object inventory, verified ledger
events, and verified recovery-journal records. It produces either an explicit
incomplete-root error or a canonical mark result.

Recognised live roots are:

- the active scratch scope, its generation and protection histories, and every
  effective protection target for the bootstrap device;
- each sole current capsule and workspace binding scope;
- every visible expected-absent workspace-attempt and release binding scope;
- unfinished restore-journal safety and target snapshots; and
- staged object references from validated V2 publication transactions.

Every root ledger event retains its predecessor chain and target. Typed frames
then retain their exact direct physical links and expected frame kinds: snapshots, capsule records and
revision ancestry, workspace records/revisions/attempts/conflicts/resolutions,
validation evidence, releases and their parent closures. A scratch-generation
manifest's cleanup candidates are audit data, not liveness edges; its active
scope is selected only by the verified current generation relation. Unknown
ledger scope spellings, divergent heads, missing or duplicate event mappings,
wrong frame types, malformed local journals, unknown mandatory features, or a
missing direct link make reachability incomplete and reject cleanup.

For a configured nonnegative cache budget, exact encrypted regular-file lengths
are summed once per opaque reference. The marked set is always retained. If it
already exceeds the budget, planning reports the exact required overrun and
moves nothing. Otherwise unmarked objects are selected in ascending opaque
reference order until the planned cache total fits the budget. Object age,
plaintext semantics, and logical IDs do not participate in eviction ordering.

The adapter stores one canonical versioned local manifest at:

```text
.yeokcham/reclamation/<plan-id>/manifest.cbor
```

`plan-id` is the domain-separated SHA-256 of the canonical manifest body. The
manifest contains its schema version and mandatory features, configured budget,
the canonical root-set digest, canonical marked references, canonical candidate
`(opaque-ref, frame-kind, stored-bytes)` entries, and the reported byte totals.
It is local maintenance
state, not a typed V2 object, ledger event, logical identity, or visibility
source. Its directory name is the existing quarantine generation name.

All V2 high-level publication operations take a shared local publication guard
for their complete immutable-write-to-binding interval. This is the persistent
fixed regular file `.yeokcham/locks/cache-reclamation.lock`, held with an
advisory shared lock; it is not a record of ownership or history. This includes
scratch, capsule, workspace, attempt, release, restore-journal, and
transaction-journal mutations. Reclamation takes that guard exclusively for
marking and for every quarantine or prune step. It recomputes the authenticated
root digest while holding the guard and rejects a stale manifest before moving
or permanently removing any candidate. Thus supported concurrent publication
either completes before planning or waits; it cannot silently make a planned
candidate live. The low-level object and ledger stores remain create-only
primitives rather than independent visibility authorities; a caller that
assembles a root from them must use the publication guard.

Quarantine uses ADR-058's authenticated no-overwrite hard-link then unlink
protocol at `.yeokcham/quarantine/<plan-id>/<opaque-ref>`. Destination presence
is the only progress cursor, so interruption and retry are idempotent. The
quarantine is the explicit recovery window: no timer auto-prunes it. Permanent
deletion is a separate explicit operation under the exclusive guard, after a
fresh complete mark and matching manifest digest; it never deletes a live
namespace object or replaces a quarantine entry.

## Consequences

- A complete V2 cache scan becomes conservative: any unrecognised or malformed
  local authority blocks reclamation until corrected outside this adapter.
- Older scratch-only quarantine remains valid; it is not reinterpreted as an
  ADR-063 manifest.
- Unbound immutable objects may be evicted after quarantine, while every
  visible history and in-progress recovery source remains available.
- V2 publication adapters gain a local coordination dependency but no new
  logical-history field, ref, or identity input.
- Prune remains intentionally irreversible after its explicit recovery window.

## Model and invariant impact

```text
roots(I) = active_scratch(I) union active_bindings(I) union recovery_roots(I)
mark(I)  = transitive_physical_closure(roots(I))
candidate(I, B) = unmarked(I) selected by opaque-ref order until bytes <= B

reclaimable(o) => o notin mark(I)
quarantine_or_prune(P, I) => digest(roots(I)) = P.root_digest
```

1. Every marked reference has an authenticated typed frame and every direct
   physical link has the expected frame kind and logical identity.
2. A missing, ambiguous, divergent, malformed, or unknown local root prevents
   a reclamation plan and never becomes an empty root set.
3. Active scratch, effective pins, capsule, workspace, attempt, release, and
   unfinished recovery roots are never candidates.
4. A plan is deterministic for equal authenticated inventory, root state, and
   budget; required retained bytes may exceed the budget without eviction.
5. A changed root digest rejects quarantine and prune before an object move or
   deletion.
6. Quarantine is idempotently resumable; permanent prune is separate and has
   no rollback claim.
7. Reclamation manifests, guards, measured bytes, and quarantine progress do
   not alter canonical V2 objects, refs, logical identities, or verification.

## Persistent-format and migration impact

The `cache-reclamation-v1` manifest is a strict canonical CBOR local file with
schema version 1 and mandatory features 0. ADR-047's V2 root layout gains the
optional `.yeokcham/reclamation` directory, whose structural layout validator accepts only
lowercase-hex plan directories containing the fixed `manifest.cbor` entry and
temporary publication names. Its V2 lock-directory validator accepts only the
fixed `cache-reclamation.lock` regular file and its temporary creation names;
V2 detection distinguishes it from historical V1 lock state. Its decoder
rejects noncanonical bytes, unsupported versions/features, duplicate or
unsorted candidates, negative sizes, invalid frame kinds, mismatched plan IDs,
and paths outside its fixed directory grammar. Goldens cover the manifest bytes
and all existing V2 object-frame bytes remain unchanged.

The local guard and quarantine directories are not canonical V2 records. No
V1 format is read or migrated. The approved V2 development policy has no user
repositories before this issue set closes.

## Verification

- Unit tests cover root classification, typed direct-link extraction,
  deterministic quota selection, required-budget overrun, strict manifest
  decoding, stale roots, and unsupported/corrupt metadata.
- Seeded generated tests permute inventories, root order, frame links, and
  budgets; equal valid inputs must produce equal marks and candidates, and no
  generated marked object may become a candidate.
- Durable tests cover active/pinned/capsule/workspace/attempt/release/recovery
  preservation, interruption before and after every quarantine/prune candidate,
  reopen/retry, manifest collision, and concurrent publication rejection.
- Golden fixtures cover `cache-reclamation-v1`; old object and journal goldens
  remain byte-identical.
- No benchmark is required because this decision makes no throughput or
  latency claim; exact object-byte accounting is verified functionally.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

This slice adds no automatic deletion, semantic policy, or history rewrite.
Future local commands may expose dry-run accounting, quarantine resume,
manifest inspection, and an explicitly confirmed permanent prune. They must
show the exact required-budget overrun and the recovery-window state.
