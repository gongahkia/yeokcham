# ADR-0043: Record explicit storage policy in new blob manifests

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0007 requires adaptive storage policy decisions to be explicit and recorded in manifests. `YKMF` version 1 already records a representation tag, but it does not state that this was the selected policy, and its zero required-feature bits must remain readable forever. The current implementation has whole-blob and tiny-aggregation records only; FastCDC has no persistent chunk record or configured blob-selection thresholds yet.

## Decision drivers

- Make the representation choice durable for each newly written blob.
- Preserve existing immutable zero-feature manifests without reinterpretation.
- Avoid inventing a default size threshold, entropy rule, MIME rule, or chunk policy.
- Keep policy validation consistent with the verified record representation.

## Considered options

### Treat the representation field as the policy record

It tells a resolver which record family to parse but does not explicitly preserve the storage-policy selection required by ADR-0007.

### Add a separate mutable SQLite policy table

SQLite is local acceleration state and cannot be the only recovery copy of a policy decision.

### Add a required manifest feature

An assigned required bit can add a fixed policy tag while old zero-feature manifests remain readable. Readers that do not understand the bit fail closed rather than silently omitting policy data.

## Decision

Assign `YKMF` required feature bit `0` to `storage_policy`. New constructors set the bit and write one policy tag immediately after the representation: `1` `WholeBlob` or `2` `TinyBlobAggregation`. The policy must match the manifest representation. The core API exposes the decision as `BlobStoragePolicyDecision`; manifests created before this decision decode as `None` and retain their zero-feature canonical encoding when re-encoded.

This feature records only the selected current record family. It does not claim an implicit byte threshold or record FastCDC parameters. A future chunked representation must record the chosen algorithm and parameters with a new feature or format version.

## Consequences

Each newly created manifest now carries an explicit, portable policy decision. Old manifests are distinguishable as legacy records without that decision; callers must not infer a missing policy. The field duplicates the currently matching representation deliberately, preventing policy/representation disagreement and giving later policy evolution an explicit format boundary.

## Invariants

- Every new manifest has required feature bit `0` and exactly one recognized policy tag.
- The policy tag exactly matches the referenced whole or tiny record family.
- Unknown required bits fail with `Unsupported`.
- A zero-feature legacy manifest has no policy decision and is re-encoded without one.
- No threshold, entropy estimate, file hint, or chunk parameter is fabricated or inferred.

## Compatibility and migration

`YKMF` version 1 remains readable in both zero-feature legacy and bit-0 policy forms. Existing zero-feature bytes are never rewritten solely to add policy. New manifests use the required feature and are rejected by readers without this ADR's support. Future policy dimensions or chunk parameters require a distinct bit or version and copy-on-write manifests.

## Security and recovery

Policy tags are metadata, not an integrity proof or secret. They are covered by the manifest checksum and validated before use, but unkeyed SHA-256 does not authenticate a hostile backend. Recovery treats a missing legacy policy as unknown, verifies the referenced segment and blob independently, and never relies on SQLite to recover policy metadata.

## Verification

Tests cover policy persistence for whole and tiny manifests, invalid and mismatched policy tags, unsupported feature bits, legacy zero-feature decode/re-encode, bounds, corruption, redacted diagnostics, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
