# ADR-0027: Store the V1 repository bootstrap as canonical binary

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The repository-format architecture needs a minimal local bootstrap that permits creation, reopening, and format compatibility checks before Git objects, SQLite, encryption, or remote backends exist. The earlier conceptual `repository.json` name conflicts with ADR-0026's canonical binary policy for persistent records.

## Decision drivers

- A fresh repository must have an opaque stable identity and an explicit format declaration.
- The first record must be bounded and safe to parse from hostile local storage.
- Repository initialization must not acknowledge a usable repository before its bootstrap is durable.
- V1 must provide a migration API without pretending an earlier persisted format exists.

## Considered options

### JSON bootstrap

Human-readable JSON is convenient, but it conflicts with the canonical binary policy and would need separate ordering, Unicode, and number rules.

### SQLite-only bootstrap

SQLite is intentionally local coordination metadata rather than the canonical recoverable repository format. It is deferred until object metadata is needed.

### Small canonical binary bootstrap

A single bounded binary file directly stores the repository ID, version, and feature flags using the established canonical encoder. It has one byte sequence and no dependencies beyond the core crate.

## Decision

V1 repositories use `format/repository.bin`. Its canonical record has magic `YKRB`, format version, required and optional `u64` feature bits, and a raw 16-byte UUIDv4 repository ID. The complete V1 record is 38 bytes.

`LocalRepository::create` only accepts a nonexistent root whose parent exists. It creates the fixed empty layout, creates and syncs the bootstrap last, syncs the containing directories on Unix, and reopens it for validation. `LocalRepository::open` rejects missing, non-directory, and symlinked owned layout entries; it bounds the bootstrap at 4096 bytes before parsing.

`LocalRepository::migrate` is a validated no-op for V1. Later migrations must be copy-on-write, verifiable, resumable, and retain the earlier bootstrap until finalization.

## Consequences

The architecture's conceptual `format/repository.json` path becomes `format/repository.bin`. The initial local state is inspectable with a documented binary layout but does not expose source content or key material. The core crate gains standard-library filesystem I/O but no cloud-backend dependency.

## Invariants

- A successful open has a validated V1 bootstrap and complete fixed empty layout.
- A bootstrap has one canonical byte sequence for its fields.
- Unknown required semantics fail with `Unsupported`.
- Unsupported optional flags remain observable and are not rewritten by V1 migration.
- No repository handle is returned before bootstrap write and validation finish.

## Compatibility and migration

V1 has no predecessor. Current migration does not change V1 bytes. Every later version or required feature must define its own reader, writer, compatibility fixture, copy-on-write transition, interruption recovery, and rollback boundary before it is accepted.

## Security and recovery

Bootstrap reads are bounded, use checked canonical decoding, and reject symlinked owned paths rather than following them. Default errors do not disclose filesystem paths. A partially initialized root without a valid bootstrap is rejected; because V1 initialization contains no Git data, cleanup is an explicit operator action rather than automatic deletion.

## Verification

Unit tests assert the exact bootstrap bytes; create, reopen, and no-op migration; missing and existing roots; incomplete layout; malformed bootstrap variants; unsupported version and required features; unknown optional feature retention; and symlink rejection on Unix. MSRV and stable CI run the suite.
