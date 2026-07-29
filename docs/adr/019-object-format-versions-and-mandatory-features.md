# ADR-019 — Object format versions and mandatory features

- Status: Accepted
- Date: 2026-07-29
- Deciders: maintainer (approved 2026-07-29)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Fixed Object Envelope 1 reserves a two-byte object-format version and a 64-bit mandatory-feature mask, but ADR-018 intentionally does not define their values or compatibility rules. Without a registry, a reader could silently interpret a payload using the wrong schema, or a writer could produce bytes that no reader has declared support for.

The compatibility boundary must be narrow. A payload schema change for one object type must not force a new repository-wide format version, while any unknown required semantics must stop interpretation before a payload decoder runs.

## Decision drivers

- Reject bytes whose required semantics are not implemented.
- Keep payload evolution scoped to the affected object type.
- Make every initially written object reproducible without implicit feature state.
- Reserve envelope-version changes for header-layout changes.
- Use a fixed, host-independent registry that is simple to test at every boundary.

## Considered options

### One repository-wide format version

- Gives one obvious compatibility number.
- Forces unrelated object schemas to advance together and turns local evolution into global migration.

### Accept any 16-bit version and let payload decoders decide

- Defers per-schema validation to future code.
- Lets an old reader reach unverified bytes under an unknown schema and makes compatibility accidental.

### Scoped version with a fail-closed mandatory-feature mask

- Limits a schema version to its object type and rejects unknown required semantics before payload interpretation.
- Requires an explicit registry and an ADR for every new bit or supported format version.

### Optional extension area in the envelope

- Could carry arbitrary forward-compatible metadata.
- Makes the fixed header variable, needs another parser and negotiation rules, and does not replace a required-semantics boundary.

## Decision outcome

Use a scoped object-format version plus a fail-closed mandatory-feature registry.

- Object-format version is a `uint16` scoped to `(object type, payload schema)`, not a repository or envelope version.
- In Envelope 1, version `1` is the only supported and writable object-format version for every currently registered object type. `0` is reserved and invalid. Versions `2` through `65535` are unknown and reject.
- The mandatory-feature field is an unsigned 64-bit bitset in Envelope 1. Bit `n` has numeric value `1 << n`, where bit `0` is the least-significant bit. Its existing big-endian wire encoding is defined by ADR-018.
- The initial registry assigns no bits. Version-1 writers set the field to zero; version-1 readers reject every nonzero mask as unsupported.
- A reader validates checksum, object type, object-format version, and mandatory-feature support before it invokes a payload decoder. It returns a typed rejection for an unsupported object-format version or unknown mandatory features.
- A future assignment requires an ADR that states the bit number, name, object-type scope, payload semantics, reader and writer support, migration, test fixtures, and whether old readers must reject. Assigned bits are never reused.
- A future incompatible payload schema increments that object type's object-format version. A future header interpretation increments envelope version. A feature bit is only for independently additive required semantics within an otherwise understood `(object type, object-format version)` schema.

This is the narrowest compatible boundary: Git's repository and bundle formats fail closed when a required unknown extension or capability is present, while its index demonstrates independent format fields. The sources support fail-closed compatibility and independent versioning; they do not prescribe Paengi's bit assignments or scope, which are project decisions.

## Consequences

- A version-1 reader cannot silently parse a later schema or required feature.
- Initial persistent bytes have a single feature-mask value, making fixtures and identity inputs stable.
- Different object types can evolve without a repository-wide version bump.
- Adding a capability has deliberate compatibility, migration, and test cost.
- There is no optional-feature registry in Envelope 1. Metadata that an old reader may safely ignore belongs in an understood payload schema and must not set a mandatory bit.

## Model and invariant impact

The pure envelope model retains `object_format_version : int` and `mandatory_features : int64`; its valid state is constrained by the registry.

Required invariants are:

- `object_format_version = 1` for every Envelope-1 object produced or accepted by the current implementation.
- `mandatory_features = 0L` for every Envelope-1 object produced or accepted by the current implementation.
- Checksum-valid bytes with an unsupported object-format version or feature bit never reach payload decoding.
- An unknown required bit is a data-format rejection, not a process error or a best-effort parse.
- The registry is independent of OCaml integer width and host endianness.

No scratch, capsule, revision, release, or conflict transition changes.

## Persistent-format and migration impact

No objects are persisted yet. Envelope 1 writes and accepts only object-format version `1` and mask `0`. Existing files must never be rewritten in place.

A future reader that adds a `(type, version)` schema must retain version-1 fixtures and support both explicitly, or provide an explicit migration that writes new objects and atomically changes references. A future reader that adds a mandatory bit must reject the bit unless it implements its declared semantics. A header-layout change is an Envelope-2 decision, not a bit or object-format-version change.

## Verification

- Unit tests: writer accepts version `1` and mask `0`, rejects versions `0`, `2`, and `65535`, and rejects nonzero mandatory masks.
- Failure tests: checksum-valid mutations to each unsupported version and to low and high feature bits return their typed rejection without invoking the payload decoder.
- Generated tests: valid version-1 envelopes round-trip for every registered object type; generated nonzero masks and unsupported versions always reject before decoding.
- Golden fixtures: retain the Envelope-1 version-1/mask-zero vector and add fixtures for the rejected version and feature boundaries once the golden-fixture task begins.
- Benchmark: no performance claim. Header validation benchmarks remain required with representative objects before object-store throughput claims.
- I/O failure injection is not applicable to this pure registry; object-store adapters require it separately.

## Verification evidence

- 2026-07-29: the public registry exposes only object-format version `1` and mandatory-feature mask `0`; the writer rejects versions `-1`, `0`, `2`, `65535`, and `65536`, plus low, high non-sign, and high-sign feature bits.
- 2026-07-29: checksum-valid version `2`, bit `0`, and bit `63` envelopes return typed incompatibility errors without invoking an instrumented payload callback.
- 2026-07-29: retained checksum-valid bit-`0` and bit-`63` Envelope-1 fixtures reject at header offset `8` before payload decoding; their prescribed checksum preimages independently match `openssl dgst -sha256` and `shasum -a 256`.
- 2026-07-29: checksum-valid combined failures prove deterministic precedence: object type is checked before object format, and object format before mandatory features.
- 2026-07-29: all 12 registered object types round-trip at version `1` and mask `0`; the retained Envelope-1 golden vector remains byte-identical.
- 2026-07-29: 500 valid-envelope round trips, 500 checksum-valid unsupported-version cases, 500 checksum-valid nonzero-mask cases, 500 single-byte corruptions, and 2,000 arbitrary-byte cases pass.
- 2026-07-29: `make ci` passes, including formatting, Dune lint/build, package lint, all tests, and GitHub Actions workflow lint.
- Header-validation benchmarks and persistent object-store I/O failure tests remain out of scope and unperformed; no performance or storage-recovery claim follows from this decision.

## CLI and user impact

No CLI exists. Future inspection and verification commands must display object-format version and feature mask, and report unsupported versions or mandatory bits as format incompatibility.

## References

- [ADR-018 — Fixed object envelope](018-fixed-object-envelope.md)
- [Git repository format version](https://git-scm.com/docs/repository-version)
- [Git bundle format](https://git-scm.com/docs/bundle-format.html)
- [Git index format](https://git-scm.com/docs/index-format/2.6.7.html)
- [RFC 6709 — Design considerations for protocol extensions](https://www.rfc-editor.org/info/rfc6709/)
- [SQLite database file format](https://sqlite.org/fileformat.html)
