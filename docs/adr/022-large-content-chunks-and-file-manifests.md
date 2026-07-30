# ADR-022 — Large-content chunks and file manifests

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (benchmark-backed Milestone 1 continuation)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-021 stores a complete file as one Content object. That is byte-correct but bounded by the object-size limit and does not reuse unchanged regions of large evolving files. Milestone 1 needs a minimal immutable large-content representation without changing the existing Content, Tree, Snapshot, or Envelope-1 bytes.

## Decision drivers

- Preserve exact arbitrary bytes as canonical data.
- Keep object identity, semantic full-content identity, chunks, and manifests distinct.
- Make the representation deterministic and independently verifiable.
- Avoid fixed-size insertion-shift amplification.
- Keep v1 decoding and existing golden fixtures valid.

## Considered evidence

`bench/results/large-content-v1.json` is a deterministic, host-specific format-decision experiment. It uses fixed seeds, five repetitions, empty/tiny/boundary/medium/large/low-entropy/high-entropy/gzip-like binary fixtures, local edits, and a 257-byte insertion at the beginning.

On the recorded host, 64 KiB fixed chunks reused zero encoded bytes for the insertion pair. Rolling Buzhash reused 1,031,601 encoded bytes across the same pair. Fixed chunks encoded and decoded high-entropy input faster in that run, but that timing is not a correctness gate or a general performance claim. The insertion result decides the initial algorithm.

## Decision outcome

Files of plaintext length `<= 65536` use existing `Content` v1 exactly, including the empty file and a file of exactly 65536 bytes. Files of greater length use a `File_manifest` object.

Envelope-1 adds object types `Chunk = 13` and `File_manifest = 14`. Their Profile 1 payloads are:

```text
chunk-v1 = [1, plaintext-bytes]

file-manifest-v1 = [
  1,
  total-plaintext-length,
  1,
  64,
  16384,
  65536,
  131072,
  full-content-id,
  [* chunk-ref-v1]
]

chunk-ref-v1 = [chunk-stored-object-id, plaintext-chunk-length]
full-content-id = SHA-256("paengi:content:v1\\000" || complete-plaintext-bytes)
```

All stored-object IDs and `full-content-id` values are exactly 32 raw bytes. Algorithm code `1` is Buzhash-64-v1: a 64-byte rolling window, a fixed algorithm table, a cut at the first matching lower 16 hash bits after 16 KiB, and a forced cut at 128 KiB. The table and all parameters are normative in `paengi_chunking`; a decoder accepts only this exact v1 parameter tuple.

`Tree` v1 and `Snapshot` v1 payloads are unchanged. A Tree v1 file content reference may resolve to either existing `Content` or new `File_manifest`; this explicit extension is limited to the already opaque 32-byte reference field and does not reinterpret old Content objects.

## Consequences

- A semantic `Content` reference remains separate from raw `Chunk`, `File_manifest`, and generic `Stored_object_id` identities in the API.
- A manifest verifies every referenced object is a Chunk, every declared chunk length, ordered chunk boundaries, total length, and `full-content-id` before its contents are accepted.
- Reordered, missing, corrupted, incorrectly typed, malformed, or noncanonical references reject with structured errors.
- No compression is introduced.
- The deterministic 64 KiB cutoff favours simple small-file representation while avoiding a manifest for exactly-boundary-sized content.

## Persistent-format and migration impact

Existing Envelope-1 type codes and all existing Content/Tree/Snapshot/model golden bytes remain unchanged. Old snapshots continue to resolve through Content v1. New manifests are additive immutable objects; migration is optional and occurs only by writing a new snapshot/tree generation that references manifests. Existing objects are never rewritten in place.

Changing the cutoff, rolling table, hash domain, algorithm code, parameters, payload layout, or accepted object types requires a new ADR, a new scoped schema/type version or object type, retained v1 fixtures/readers, and a verified migration generation where needed.

## Verification

- Golden Envelope-1 fixtures for Chunk v1 and File_manifest v1.
- Unit and generated tests for exact inline and manifest round trips, chunk reuse, boundary determinism, insertion resynchronisation, malformed payloads, wrong object types, missing references, corruption, reordering, and interrupted temporary objects.
- The benchmark is rerun after the storage adapter uses these exact types; benchmark timing remains informational only.

## CLI and user impact

No CLI is introduced. Snapshot inspection may later report inline versus manifest representation and the verified full-content identity separately from stored-object IDs.
