# ADR-017 — Restricted deterministic CBOR encoding

- Status: Accepted
- Date: 2026-07-29
- Deciders: maintainer (approved 2026-07-29)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-012 requires a versioned portable encoding whose bytes are deterministic and testable outside OCaml. Those bytes will feed content identities, so accepting multiple byte representations for one value would make object identity representation-dependent. Paengi also needs exact arbitrary bytes for paths and content metadata, forward-compatible record schemas, and bounded handling of malformed repository data.

RFC 8949 defines core deterministic CBOR requirements: preferred shortest serialization, definite-length items, and bytewise lexical ordering of deterministically encoded map keys. It leaves duplicate-key handling, accepted data types, UTF-8 validation, and resource limits to the application profile.

The available OCaml packages do not implement the required profile as a strict boundary:

- `cbor` 0.5 targets RFC 7049, represents integers with architecture-sized OCaml `int`, emits maps in caller order, always emits 64-bit floats, accepts indefinite-length items, and does not enforce duplicate or deterministic map keys.
- `cborl` 0.1.0 targets RFC 8949 and supports large integers, but emits maps in caller order, exposes indefinite-length forms, does not enforce this profile, and is AGPL-3.0-or-later while Paengi is MIT.
- `data-encoding` 1.0.1 provides mature binary combinators under MIT, but its binary layout is library-specific rather than an independently specified CBOR profile and adds a materially broader dependency graph.

## Decision drivers

- Produce exactly one byte sequence for every persistable model value.
- Preserve arbitrary bytes without Unicode or JSON conversion.
- Keep schemas implementable and inspectable outside OCaml.
- Reject non-deterministic, ambiguous, unsupported, truncated, or trailing input.
- Bound decoder depth, arithmetic, allocation, and collection work on malformed input.
- Avoid a runtime dependency that still requires a second strict parser or substantial validation layer.
- Keep the first format small enough to validate exhaustively before persistent objects exist.

## Considered options

### Local restricted RFC 8949 deterministic profile

- Uses a published standard and official vectors while exposing only Paengi's required subset.
- Can reject unsupported forms before allocating from input-declared lengths.
- Adds strict parser code that requires malformed-input fixtures, bounded deterministic generated-input properties, and independent interoperability evidence.

### `cbor` 0.5 behind a strict adapter

- MIT, small, pure OCaml, and compatible with OCaml 5.5.0.
- Its `int` range, caller-ordered maps, permissive decoder, recursive unbounded parsing, and allocation from declared collection lengths require replacing or defending much of the decoder.

### `cborl` 0.1.0 behind a strict adapter

- Uses RFC 8949 and arbitrary-precision integers.
- Its license changes distribution constraints, its latest package is 0.1.0 from 2022, and deterministic ordering and strict-profile validation remain application work.

### `data-encoding` 1.0.1

- Provides typed combinators, binary readers and writers, tests, and an MIT license.
- Its binary format is coupled to library-specific combinator semantics, has a broader dependency surface, and provides less independent format interoperability than restricted CBOR plus CDDL schemas.

### Deterministic JSON or a new Paengi TLV format

- JSON has broad tooling; a custom TLV could be very small.
- JSON needs an additional canonicalization profile and base encoding for arbitrary bytes. A new TLV would require a new wire specification, independent tooling, and original test vectors without gaining CBOR's existing data model.

## Decision outcome

Define Paengi CBOR Profile 1 as a local implementation of RFC 8949 core deterministic encoding with this restricted data model:

- Signed integers in the OCaml `int64` range, encoded with CBOR major types 0 and 1.
- Exact byte strings, valid UTF-8 text strings, definite-length arrays, maps, booleans, and null.
- Persistent records represented as maps whose field keys are unique non-negative integers in the `int64` range.
- Ordered collections represented as arrays. Unordered model collections must be sorted by their model-defined canonical key before encoding.
- File bytes and filesystem path components represented as byte strings. Text strings are only for fields whose model requires human-readable UTF-8; no Unicode normalization is performed.
- No floating-point values, tags, bignums, undefined, other simple values, or indefinite-length items.

The encoder uses minimal integer and length heads and sorts map entries by bytewise lexical order of each encoded key. The decoder accepts exactly one complete Profile 1 item and rejects non-minimal heads, unsupported forms, invalid UTF-8 text, duplicate or non-increasing map keys, truncation, trailing bytes, arithmetic overflow, lengths exceeding remaining input, and nesting deeper than 64 items. It must check bounds before allocation and use an explicit work budget derived from the bounded input length.

Implement the profile inside Paengi rather than depending on a generic CBOR runtime. Document each persistent record in CDDL plus the profile's additional semantic constraints. The following object-envelope and feature-version ADRs will define payload boundaries, object tags, format negotiation, and checksums; this ADR does not define them.

## Consequences

- Canonical payload bytes follow a public standard and can be inspected by generic CBOR tools that support the subset.
- Numeric field keys keep records compact and leave explicit key space for compatible extensions.
- The accepted data model cannot represent floats, arbitrary CBOR tags, integers outside `int64`, or invalid UTF-8 as text; exact byte strings remain available.
- Paengi owns a small parser and its correctness maintenance.
- A generic CBOR library may be adopted later only if a new ADR demonstrates byte-for-byte Profile 1 compatibility and equivalent strict-decoder behavior.

## Trade-off summary

The local profile removes reliance on a permissive generic decoder and keeps the accepted wire surface small, but transfers parser correctness, resource-bound enforcement, interoperability testing, and future parser maintenance to Paengi. Restricting values and map keys makes exhaustive boundary testing practical, but unsupported CBOR values require a future profile and migration rather than an in-place extension. The implementation must therefore remain isolated, pure, bounded, and independently testable; adoption of Profile 1 does not establish the absence of decoder defects.

## Model and invariant impact

The encoding layer defines a pure restricted value algebra with integer, bytes, validated text, array, numeric-key map, boolean, and null cases. Map construction rejects duplicate keys and makes input order semantically irrelevant.

Required invariants are:

- Encoding is total for valid Profile 1 values and deterministic across process, host endianness, and OCaml runtime architecture.
- Successful decoding consumes the entire input and returns one valid Profile 1 value.
- Decoding an encoded value returns the same value.
- Re-encoding any successfully decoded bytes returns those exact bytes.
- Invalid UTF-8 is representable only as a byte string, never as text.
- Map order cannot change model meaning or encoded bytes.
- Decoder work and allocation are bounded by input length and the fixed nesting limit.

No scratch, capsule, revision, release, or conflict transition changes.

## Persistent-format and migration impact

No persistent repository objects exist, so no migration or rollback is required. Profile 1 is a payload rule, not a CBOR tag or self-described CBOR prefix. The next ADRs must assign the outer format version, mandatory feature semantics, payload length, object type, hash algorithm identifier, and integrity fields before any bytes are persisted.

Future changes that alter accepted values or canonical bytes require a new profile or object-format version and readers for retained old-format fixtures. Existing bytes must never be silently reinterpreted under a changed profile.

## Verification

- Unit tests from RFC 8949 Appendix A for supported value types and reachable head-width boundaries.
- Golden fixtures for each Paengi record schema, retained after later format versions are added.
- Generated encode/decode round trips, re-encoding stability, map permutation invariance, integer boundaries, arbitrary bytes, and valid UTF-8.
- Failure tests for every unsupported major or simple type, non-minimal head, indefinite form, invalid UTF-8, duplicate or unsorted map key, truncation point, trailing byte, overflow, impossible length, exhausted work budget, and depth 65.
- Differential fixture checks with an independent RFC 8949 implementation, recording its name and version.
- Bounded deterministic generated-input properties of the decoder, including totality and canonical-byte checks, before persistent input is treated as trustworthy.
- Encoder and decoder throughput and allocation baselines on representative tree and snapshot fixtures; no throughput claim is made by this ADR.
- I/O failure injection is not applicable to the pure codec. Envelope and object-store writes require separate failure tests.

## Verification evidence

- 2026-07-29: RFC 8949 integer, byte string, text, array, map, boolean, and null vectors pass, including signed 64-bit boundaries.
- 2026-07-29: constructors reject invalid UTF-8, negative or duplicate map keys, and nesting 65; decoder rejects non-minimal, indefinite, unsupported, unordered, truncated, overflowing, impossible-length, trailing, and work-limited inputs.
- 2026-07-29: 500 generated value round trips, 300 map-permutation cases, and 2,000 arbitrary-byte decoder cases pass.
- 2026-07-29: `cbor2` 6.1.3 independently produced the same canonical bytes for 16 Profile 1 vectors.
- 2026-07-29: source-controlled `test/golden/profile1-v1-composite.cbor.hex` covers binary bytes, valid Unicode text, signed 64-bit boundaries, arrays, ordered numeric-key maps, booleans, and null; it decodes and re-encodes byte-identically in Dune's sandboxed test run.
- 2026-07-29: `make ci` passes.
- Encoder/decoder benchmarks are not yet run; they remain explicit TODO work before performance claims. Bounded deterministic properties and checked-in malformed fixtures provide repository-correctness evidence only; they are not external security analysis.

## CLI and user impact

No CLI behavior exists yet. Future `verify` and storage-inspection commands must report profile, offset, and rejection reason without treating malformed bytes as a process-only error.

## References

- [RFC 8949 — Concise Binary Object Representation](https://www.rfc-editor.org/rfc/rfc8949.html)
- [RFC 8610 — Concise Data Definition Language](https://www.rfc-editor.org/rfc/rfc8610.html)
- [`cbor` 0.5 package metadata](https://opam.ocaml.org/packages/cbor/)
- [`cbor` 0.5 released interface](https://github.com/ygrek/ocaml-cbor/blob/0.5/src/CBOR.mli)
- [`cbor` 0.5 released implementation](https://github.com/ygrek/ocaml-cbor/blob/0.5/src/CBOR.ml)
- [`cborl` 0.1.0 package metadata](https://opam.ocaml.org/packages/cborl/)
- [`data-encoding` 1.0.1 package metadata](https://opam.ocaml.org/packages/data-encoding/)
