# ADR-018 — Fixed object envelope

- Status: Accepted
- Date: 2026-07-29
- Deciders: maintainer (approved 2026-07-29)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-017 defines canonical payload bytes but deliberately leaves object kind, format evolution, payload boundaries, and integrity outside the payload. Architecture requires a fixed outer envelope with object type, format version, payload length, and checksum. The envelope must let a reader reject malformed or corrupt data before passing unverified bytes to the CBOR payload decoder.

ADR-013 and ADR-016 establish SHA-256 behind an abstraction. The persistent algorithm code and exact checksum preimage remain undefined until this decision.

## Decision drivers

- Frame one exact payload without scanning or decoding it first.
- Verify integrity before Profile 1 parsing and schema dispatch.
- Encode header integers independently of OCaml word size and host endianness.
- Give future readers an explicit envelope-version boundary.
- Retain object kind, object-format version, and mandatory-feature state in signed bytes.
- Keep the v1 reader small, fixed-width, and golden-testable.
- Avoid defining content-addressed storage paths, atomic writes, signatures, encryption, or object schemas prematurely.

## Considered options

### Fixed binary header plus Profile 1 payload

- Allows exact length and checksum validation before payload decoding.
- Uses a compact, independently specified header with no runtime encoding dependency.
- Introduces a second, deliberately narrow serialization layer beside CBOR.

### Profile 1 CBOR array or map containing the payload

- Reuses one encoding implementation and can be naturally extensible.
- Requires CBOR parsing before checksum verification, and the outer payload byte-string length duplicates the framing work that a fixed header makes trivial.

### Store integrity only in the content-addressed path

- Avoids a checksum field in each object.
- Cannot validate a copied, streamed, or incorrectly addressed object without external path context and leaves header corruption unchecked until higher layers run.

### Per-object JSON or a new extensible TLV envelope

- Could be human-readable or arbitrarily extensible.
- JSON needs canonicalization and binary wrapping; a general TLV recreates protocol and extension machinery not needed for the first envelope.

## Decision outcome

Use Fixed Object Envelope 1. It is exactly 57 bytes followed by the payload:

| Offset | Size | Field | Rule |
| --- | --- | --- | --- |
| 0 | 4 | magic | ASCII `PENG` |
| 4 | 1 | envelope version | `1` |
| 5 | 1 | object type | unsigned code |
| 6 | 2 | object-format version | unsigned big-endian code |
| 8 | 8 | mandatory-feature mask | unsigned big-endian code |
| 16 | 1 | checksum algorithm | `1` means SHA-256 |
| 17 | 8 | payload length | unsigned big-endian byte count |
| 25 | 32 | checksum | SHA-256 digest |
| 57 | variable | payload | exact Paengi CBOR Profile 1 bytes |

The checksum is SHA-256 over bytes 0 through 24 followed immediately by the payload; it excludes only the checksum field itself. A reader must validate magic, known envelope version, known object type, known checksum algorithm, length arithmetic, exact end-of-input, and checksum before decoding the payload. It must reject unknown mandatory feature bits after ADR-019 defines their registry and before interpreting the payload.

Object type `0` and all unassigned codes are invalid. Version 1 assigns: `1` content, `2` tree, `3` snapshot, `4` scratch event, `5` checkpoint, `6` capsule, `7` capsule revision, `8` release, `9` conflict, `10` validation, `11` resolution, and `12` repository configuration. A future assignment requires an ADR and an updated reader; an older reader rejects it.

Object-format-version values, object-type codes, and mandatory-feature-bit assignments are constrained by this layout but are defined in the following format-version and feature-flags decision. This ADR defines `1` as the persistent code for SHA-256. It does not define object IDs; a later object-store decision must state the content-ID preimage explicitly and may not silently equate it with this checksum.

Git's object model independently demonstrates hashing typed, length-delimited object preimages, while OCI descriptors independently require consumers to verify typed content against its declared size and digest. Paengi does not copy either format: their relevance is the separation of type, length, and integrity from application payload parsing.

## Consequences

- Corruption in the header or payload is detectable from the object bytes alone.
- The payload decoder only receives exactly delimited, checksum-validated bytes.
- Envelope evolution is explicit: a new header interpretation requires a new envelope version, not an ambiguous optional field.
- The header has no free-form extension area. New header fields require a version transition; payload compatibility uses the mandatory-feature mask and object-format version.
- The project maintains a small fixed-width parser, writer, and golden fixtures in addition to the Profile 1 codec.
- The checksum provides integrity detection, not authentication, signing, encryption, or protection when a writer can replace both payload and checksum.

## Model and invariant impact

The pure envelope model will contain object type, object-format version, mandatory-feature mask, checksum algorithm, payload bytes, and checksum. The writer constructs the 57-byte header and checksum preimage without I/O. The reader returns either one verified envelope value or an explicit rejection; it must never return an unchecked payload.

Required invariants are:

- Every valid envelope has exactly 57 plus its declared payload-length bytes.
- Header integer widths and byte order are fixed on every host.
- The checksum covers magic, version, type, format version, feature mask, algorithm code, payload length, and payload.
- Unknown envelope versions, object types, checksum algorithms, and later mandatory features are rejected before payload schema interpretation.
- Payload bytes are passed to Profile 1 only after checksum verification succeeds.
- No timestamp, process state, or storage path contributes to envelope bytes.

No scratch, capsule, revision, release, or conflict transition changes.

## Persistent-format and migration impact

No persistent objects exist, so v1 introduces no migration. Existing object files must never be mutated in place. A future envelope version requires a new reader/writer path, retained v1 golden fixtures, and an explicit migration or dual-reader plan. A reader that cannot support the envelope version, checksum algorithm, object type, or mandatory features must fail closed.

## Verification

- Golden fixtures for every header field boundary and checksum preimage.
- Unit tests for fixed offsets, big-endian values, exact bytes, and all header values.
- Generated envelopes proving writer/reader round trips, exact input consumption, and checksum sensitivity to every covered byte.
- Failure tests for every truncation boundary, length overflow or mismatch, trailing byte, unknown magic/version/type/algorithm, header corruption, payload corruption, checksum mismatch, and invalid payload reached only after a valid checksum.
- Property test proving malformed envelopes never invoke the payload decoder; instrument that boundary rather than infer it from a returned error.
- I/O failure injection is not applicable to the pure envelope; object-store write and read adapters require separate failure tests.
- Benchmark header verification and payload hashing with representative object sizes before throughput claims.

## Verification evidence

- 2026-07-29: the 57-byte golden `Snapshot` envelope, including its SHA-256 checksum, passes; its checksum was independently matched by `shasum -a 256` and `openssl dgst -sha256` over the defined preimage.
- 2026-07-29: the retained `test/golden/envelope-v1-snapshot.peng.hex` fixture is loaded as source-controlled data, verifies, decodes, and re-encodes byte-identically in Dune's sandboxed test run.
- 2026-07-29: all registered object-type codes round-trip; code `0` and unassigned code `13` reject.
- 2026-07-29: tests reject every truncated prefix, invalid magic/version/algorithm/type/features, high-bit length, length mismatch, trailing bytes, covered-header corruption, checksum corruption, and payload corruption.
- 2026-07-29: an instrumented payload callback is not invoked for a checksum-invalid envelope and is invoked only after checksum verification on a checksum-valid malformed payload.
- 2026-07-29: 500 generated envelope round trips, 500 generated one-byte corruptions, and 2,000 arbitrary-byte cases pass.
- 2026-07-29: `encoding_property_test.exe` runs 500 Envelope 1 value round trips and 2,000 bounded arbitrary-byte totality/canonical-byte cases from independent stable per-property states derived from printed seed `20260729`; it verifies named valid and malformed local fixtures and explicit zero, boundary, near-limit, and malformed lengths.
- 2026-07-29: `make ci` passes.
- Header-verification benchmarks are not yet run; no performance claim follows from these tests. Bounded deterministic properties and checked-in malformed fixtures provide repository-correctness evidence only; they are not external security analysis.

## CLI and user impact

No CLI behavior exists yet. Future `verify` and storage-inspection commands must expose envelope version, object type, payload length, checksum algorithm, and the exact rejection category.

## References

- [ADR-013 — Hash abstraction](../../DECISIONS.md#adr-013--hash-abstraction)
- [ADR-016 — Initial SHA-256 implementation](016-initial-sha256-implementation.md)
- [ADR-017 — Restricted deterministic CBOR encoding](017-restricted-deterministic-cbor.md)
- [Architecture: persistent encoding requirements](../../ARCHITECTURE.md#42-encoding)
- [Git object storage format](https://git-scm.com/docs/user-manual#object-storage-format)
- [OCI content descriptors](https://github.com/opencontainers/image-spec/blob/main/descriptor.md)
- [FIPS 180-4 — Secure Hash Standard](https://nvlpubs.nist.gov/nistpubs/fips/nist.fips.180-4.pdf)
