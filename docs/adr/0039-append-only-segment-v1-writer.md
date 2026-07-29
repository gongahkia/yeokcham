# ADR-0039: Write sealed append-only segments with create-new publication

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Whole-blob and tiny-blob records need an immutable container before indexes and manifests can reference stored bytes. The segment ID is already a preallocated UUIDv4, while the segment checksum must bind the final bytes. A writer must not replace an existing segment path, expose a partial final file, or trust arbitrary payload metadata. Reader, index, manifest, compression beyond `none`, and encryption remain later work items.

## Decision drivers

- Write a simple versioned portable segment format before optimisation.
- Bind each segment to repository and segment identities.
- Preserve typed record metadata required by the future index.
- Publish only sealed bytes under a create-new destination name.
- Bound writer-held records and payload bytes by explicit caller limits.
- Separate accidental-corruption detection from future encryption/authentication.

## Considered options

### One file per record

This avoids container parsing but conflicts with the segment aggregation strategy and gives a backend excessive small objects.

### Mutable file with an in-place directory rewrite

This adds overwrite and crash states before the reader, index, and recovery protocol exist.

### Staged append-only segment with a create-new final link

The writer can calculate a trailing SHA-256 checksum while streaming a complete known-count sequence to a private staging file, synchronize it, then use a same-directory hard link as a no-overwrite final publication step. Rust documents `hard_link` as failing when the destination already exists, and POSIX defines `link()` as creating a new directory entry.

## Decision

Define `YKSG` version 1. A segment contains fixed header fields: magic, version, required/optional feature bits, raw repository UUIDv4, raw segment UUIDv4, and `u32` record count. Every record stores its type, tagged content ID, compression method tag, plaintext length, stored length, and exact stored payload. Version 1 accepts only typed `YKWB` whole-blob and `YKTA` tiny-blob-aggregation payloads, each under the shared `none` codec.

The footer stores magic `YKSF`, total plaintext bytes, total stored bytes, and unkeyed SHA-256 of every preceding header, record, and footer field before the checksum. The checksum detects accidental changes and malformed transport; it is not authentication.

`SegmentWriter` accepts explicit maximum record and stored-byte limits. It rejects empty segments, duplicate content IDs, and additions beyond either bound. `seal_to` writes the complete format to a create-new temporary file in the destination directory, synchronizes it, creates the destination by hard link without overwrite, synchronizes the directory on Unix, and removes the staging name. A pre-existing final destination is a conflict. The writer does not update indexes, manifests, SQLite, or refs.

## Consequences

The next reader can parse a self-contained checksum-protected stream without depending on local SQLite. The writer retains pending records in memory but takes explicit caller limits; a future streaming/staging redesign needs a new ADR if it changes format or publication semantics. A crash may leave an unreferenced staging file or a fully sealed unreferenced final segment. Neither state is acknowledged by refs because indexes, manifests, and ref updates are deferred.

## Invariants

- A final path is created only after a complete segment file is synchronized.
- A writer never replaces a pre-existing final segment path.
- Header repository and segment IDs are raw validated UUIDv4 bytes.
- Record count, lengths, totals, ordering, and payload bytes are bound by the segment checksum.
- Current records use only compression tag `0`; unknown/future tags fail closed in the reader.
- Default diagnostics and `Debug` output do not disclose payload bytes or identifiers.

## Compatibility and migration

`YKSG` version 1 is immutable once written. Magic values, field order, checksum domain, record tags, and footer semantics cannot change in place. New record types, compression, encryption, a directory, or an alternate checksum require a version or required-feature migration. Existing version-1 records and the repository bootstrap remain unchanged.

## Security and recovery

The writer accepts only records constructed from current verified record types; it does not expose an arbitrary-payload constructor. It uses caller-supplied resource bounds, checked counters, `create_new`, and exact staging-path cleanup. SHA-256 integrity is unkeyed and does not authenticate a hostile backend. Future encrypted segments must bind repository ID, segment ID, record type, and version as associated data, then retain a bounded reader and final Git-object verification.

## Verification

Tests assert one complete canonical segment fixture, exact payload preservation, checksum stability, explicit limits, duplicate rejection, destination conflict without replacement, staging cleanup after success, redacted diagnostics/debug output, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
