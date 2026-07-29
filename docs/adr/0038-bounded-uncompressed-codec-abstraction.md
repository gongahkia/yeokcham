# ADR-0038: Use a bounded uncompressed codec abstraction first

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Whole-blob and tiny-blob records already reserve compression method tag `0` for uncompressed bytes. Segment records need a uniform codec interface, but no storage-policy benchmark has selected a compressed format or level. A decoder will eventually receive untrusted compressed records, so accepting a codec before defining output and working-memory limits would weaken recovery safety.

## Decision drivers

- Give records one stable, typed compression-method boundary now.
- Preserve exact bytes and prevent unbounded decompression output.
- Avoid making a codec or level a permanent format choice without benchmarks.
- Keep the first implementation dependency-free and usable by the segment slice.
- Require explicit versioning before a stored compressed representation is introduced.

## Considered options

### Add Zstandard now

Zstandard has a published format in [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html), but its frames can request decoder memory through their window size and require explicit resource controls. Selecting it now would also make a codec and level part of the persistent format without policy evidence.

### Add DEFLATE now

DEFLATE has a stable [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951/), but adding another format before the segment writer and policy engine creates the same unmeasured permanent choice.

### Define a typed `none` codec and defer compressed formats

This centralizes the existing tag, makes every decompression call caller-bounded, and preserves a narrow extension point without committing new on-disk bytes.

## Decision

Introduce `CompressionAlgorithm` and `CompressionCodec`. Version 1 recognizes only `none`, with stable binary tag `0`. Compression and decompression through this codec copy bytes exactly. `decompress` takes a caller-supplied maximum plaintext length and rejects larger input before allocating the output. Unknown method tags are unsupported and fail closed.

Existing `YKWB` and `YKTA` records use this shared tag definition; their version-1 decoders continue to accept only `none`. No default compressed method, compression level, dictionary, parallelism, policy threshold, or automatic fallback is introduced.

Any compressed codec requires a new ADR before implementation. Its record schema must identify the codec and any settings needed for deterministic recovery, decoder output must be bounded, method-specific working-memory limits must be explicit, and compression choice must be recorded by the later storage policy/manifest work.

## Consequences

Segment code can depend on one typed codec API immediately, while all current records retain byte-for-byte encodings. The first implementation does not reduce storage size; that is intentional and has no performance claim. Consumers must handle a fallible codec API even for `none`, which permits future bounded codecs without changing the caller contract.

## Invariants

- A recognized compression method has one stable binary tag.
- `none` compression and decompression return exactly the supplied byte sequence.
- Decompression never allocates above its caller-provided plaintext limit.
- Unknown compression tags and future settings are not guessed, repaired, or silently treated as `none`.
- Existing version-1 records only encode and accept tag `0`.

## Compatibility and migration

This refactors the interpretation of the existing version-1 tag `0` without changing bytes, schema versions, repository bootstrap, or SQLite metadata. A later compressed record needs a versioned record/schema feature and copy-on-write migration; historical uncompressed records remain readable as `none` forever.

## Security and recovery

No compressed input is accepted in this slice, eliminating decompression expansion and codec working-memory risks for current records. The `decompress` output limit establishes the mandatory API boundary for future hostile inputs. Compression is neither encryption nor integrity protection; later record verification and final Git-object verification remain required.

## Verification

Tests assert stable tag handling, exact binary round trips, output-limit rejection before a copy, unknown-tag rejection, default diagnostic redaction, existing-record canonical-byte preservation, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
