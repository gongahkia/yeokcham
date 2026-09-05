# ADR-100 — V1 scoped verification and conservative sourced repair

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: HEALTH-001
- Depends on: ADR-090 durable restore proofs, ADR-091 local recoverable
  garbage collection, ADR-098 explicit projection workspace, and ADR-099 V2
  relay transfer

## Context

An immutable-object repository can be damaged by a missing object, corrupt
local durable record, interrupted temporary operation, or a locally retained
invalid copy. Existing commands correctly refuse the particular closure they
need, but they do not provide one read-only diagnosis or a narrow, auditable
way to restore an exact missing byte sequence from a user-named source.

Health must not turn observed bytes into a merge decision, infer a source,
rewrite a divergent immutable object, or block unrelated work. In particular,
repair is neither package receipt nor a relay receipt: it cannot advance a
project-state head, select authority, import a package closure, create a
revision, or materialise ordinary source files.

## Current milestone and vertical slice

HEALTH-001 adds pure health values and transition decisions before filesystem,
package, GC, backup, or relay adapters:

```text
verify(closure, read_object) -> damage list
plan(damage, explicit_source, candidates, now) -> repair_plan
eligible(plan, selection, current_damage, reread_candidate, now)
  -> publish_exact_object | refuse
```

The public surface is `verify`, `repair plan`, `repair apply`, and `repair
defer`. `verify` is read-only. A plan only enumerates candidates from one
explicit source; it has no preferred candidate. `repair apply` requires a
candidate ID plus the exact plan digest printed by the plan. `repair defer`
performs no repair and leaves every unrelated command available.

## Decision

### Damage is typed, stable, and closure-scoped

`damage-v1` has these stable machine codes:

| Code | Meaning |
| --- | --- |
| `missing-object` | a named immutable object is absent from its expected local path |
| `malformed-envelope` | present bytes cannot decode as a bounded canonical envelope |
| `canonical-id-mismatch` | present canonical bytes do not match the object ID/path that names them |
| `dangling-reference` | a decoded record names an object that is absent or unusable |
| `unreadable-durable-record` | a local durable record cannot be read, decoded, version-checked, or canonically re-encoded |
| `restore-proof-mismatch` | a restore proof, its filename, or either named exact closure is inconsistent |
| `unreachable-temporary-state` | an incomplete restore, GC, transfer, or repair temporary state cannot be safely resumed or inspected |

Every `Damage` includes a stable affected-root/closure description, the exact
object or record identifier when one is available, and the operations blocked
by that closure. The list is sorted canonically. Verification may report more
than one independent damage and does not collapse a conflict into an I/O
failure. It reads through narrow adapters only and creates no repository file,
object, quarantine, plan, journal, relay session, or ordinary source file.

Damage is local to its closure. A broken restore proof may block its proof
inspection and a compaction requiring it, but it does not block `status`, a
save in an intact draft, inspection of intact history, or another repository.
No command treats a clean `verify` result as a release, delivery, authority,
or availability assertion.

### Candidate provenance and selection remain explicit

`Repair_source` is exactly one of a named local GC quarantine transaction, an
offline package path, a configured relay alias, a bootstrap artifact, or an
operator-supplied backup path. A source contributes a `Repair_candidate` only
after its bytes have passed the existing bounded canonical envelope and
object-ID verification and, where the source format has one, its existing
package/bootstrap/relay closure verification. A candidate records the source
kind and stable locator, its claimed object ID, recomputed byte ID, and enough
source-format identity to audit why it was offered.

Candidates are sorted, duplicate-free, and never silently ranked. A divergent,
malformed, unavailable, unauthenticated, incomplete, wrong-repository, or
wrong-ID source produces a refusal or a non-eligible candidate; it never
becomes a local object. Repair does not synthesise bytes and cannot repair a
damaged project-state record by copying an unverified replacement state.

For a local bootstrap source, the locator is an existing package directory
containing a regular `bootstrap-basis-v1.cbor` sibling of the existing
`manifest.cbor` and `objects/` entries. The basis remains its existing signed
canonical Bootstrap record and the package remains its existing canonical
package format; this source layout adds no object, package, or history record.
The adapter verifies the basis against the target's collaborative repository
identity and rechecks that its manifest digest names the exact package artifact
from which it reads a candidate.

### Repair plans bind approval to a current diagnosis

Because `repair apply` is intentionally a separate process, plans are local
create-only `repair-plan-v1` records below `.yeokcham/repair-plans/`. They are
outside project state, packages, bootstrap bases, relay data, authority,
checkpoint/capsule/revision/release history, and ordinary source trees. The
canonical plan records its repository identity, creation/expiry values, exact
state-head identity, sorted damage snapshot, one named source, sorted
candidates with byte/provenance identities, and its SHA-256 plan digest/ID.
Unknown mandatory fields, unknown versions, malformed identifiers, duplicate
entries, expired values, and noncanonical encodings refuse decoding.

`Selection` consists of the named plan ID, selected candidate ID, and the
exact plan digest. Before any write, apply reopens the plan, confirms expiry,
re-verifies the source candidate bytes and provenance, re-runs the affected
closure diagnosis, and confirms that the destination is still missing. A
changed state head, changed damage, vanished source, changed candidate bytes,
expired plan, mismatched approval, or a now-present divergent destination
refuses and requires a fresh plan. Approval is therefore bound to exact
observed bytes rather than a mutable filename, relay listing, or candidate
ordering.

### The only repair publication is add-if-still-missing

An eligible exact missing object is copied to a same-filesystem temporary file,
fsynced, revalidated for canonical bytes and object ID, and atomically linked
or renamed into the object store only if that path remains absent. The adapter
fsyncs the containing directory. It never overwrites an object. If an invalid
existing local copy must be preserved for evidence, it is moved through the
existing GC quarantine discipline before any new object can be published; a
collision or interrupted move is a refusal, never a replacement. A write
interruption leaves only an inspectable temporary file or quarantine evidence,
not a claimed repaired object.

Plans, candidates, verification reports, and outcomes are structured values.
Text and versioned JSON render the same values without raw payloads, bearer
credentials, private material, source contents, or ordinary source paths.
They are reports, not authority or intent records. CLI-001 may consolidate
their rendering under its shared envelope, but it must preserve this schema
version and error-code boundary.

## Consequences

The milestone reuses the existing immutable object store, package verifier,
bootstrap verifier, relay client, restore-proof reader, and GC quarantine
mechanics through small read-only adapters. It introduces no alternate object
or package format and no automatic repair loop. `verify` and planning never
contact a relay unless the caller explicitly names a configured relay source;
neither can write an ordinary source file. Applying a plan changes only the
single named missing immutable object or explicitly records/preserves
quarantine evidence.

Some damage can correctly have no repair candidate. The user can defer it and
continue unrelated work; the outcome remains a typed report rather than a
false claim of recovery.

## Verification required before HEALTH-001 completion

- canonical golden fixtures for every damage code and `repair-plan-v1`, plus
  malformed, noncanonical, unsupported-version, and unknown-feature refusals;
- generated missing/corrupt closure cases that prove stable sorted diagnosis
  and byte-for-byte no-write verification;
- source journeys for GC quarantine, offline package, configured relay,
  bootstrap artifact, and backup, including multiple candidates, disagreement,
  disappearance, stale approval/expiry, write interruption, and defer;
- tests that invalid or mismatched bytes never become visible and that source
  and destination ordinary worktrees stay unchanged through verify, planning,
  and every refusal; and
- focused tests followed by `make ci`.

## References

- [ADR-090 durable restore proofs](090-v1-durable-restore-proofs.md)
- [ADR-091 local recoverable garbage collection](091-v1-local-recoverable-garbage-collection.md)
- [ADR-098 explicit projection workspace](098-v1-explicit-projection-workspace.md)
- [ADR-099 V2 compressed resumable relay transfer](099-v2-compressed-resumable-relay-transfer.md)
