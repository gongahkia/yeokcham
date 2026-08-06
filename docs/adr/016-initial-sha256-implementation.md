# ADR-016 — Initial SHA-256 implementation

- Status: Accepted
- Date: 2026-07-29
- Deciders: maintainer (approved 2026-07-29)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-013 permits SHA-256 behind an abstraction. Yeokcham now needs one maintained OCaml implementation that satisfies `Yeokcham_hash.S`, hashes exact bytes incrementally, supports OCaml 5.5.0, and does not couple model types to a library API.

## Decision drivers

- Match the existing persistent-context and raw-digest abstraction.
- Support exact arbitrary bytes, incremental input, and fixed 32-byte output.
- Minimise platform-specific build requirements for the initial prototype.
- Use a maintained package compatible with OCaml 5.5.0.
- Verify against published SHA-256 vectors without claiming formal validation.

## Considered options

### Digestif 1.3.1 with `digestif.ocaml`

- Provides SHA-256, immutable streaming contexts, one-shot hashing, and raw digest conversion.
- Explicit pure-OCaml backend avoids architecture-specific C stubs.
- Current release supports OCaml 4.08 or newer.
- Pure OCaml is slower than Digestif's C backend according to its maintainers.

### Digestif 1.3.1 with `digestif.c`

- Provides the same API and a faster implementation according to its maintainers.
- Adds C compilation and native backend surface before hash throughput has been benchmarked as a bottleneck.

### Mirage-crypto 2.1.0

- Maintained and compatible with OCaml 5.5.0.
- Broader cryptographic package and C-oriented implementation surface than required for content hashing.

### Custom SHA-256 or operating-system process

- Avoids an OCaml package dependency.
- Custom cryptography adds correctness risk; external processes add platform, failure, and I/O complexity.

## Decision outcome

Use SHA-256 through an adapter over Digestif 1.3.1 and explicitly link `digestif.ocaml`. Keep Digestif types private to `yeokcham_hash`. Use Digestif's constant-time equality and non-constant-time ordering; Yeokcham object IDs are public values, not secrets.

## Consequences

- Development and CI gain exact dependencies on Digestif 1.3.1 and its transitive packages.
- The initial implementation has no C backend dependency.
- Hash throughput may be lower than `digestif.c`; benchmark before changing backends.
- A future backend or algorithm change remains isolated behind `Yeokcham_hash.S`.

## Model and invariant impact

No algebraic model type changes. `Yeokcham_hash.Sha256` must expose algorithm name `sha256`, digest size 32, persistent streaming contexts, exact raw digest bytes, equality, and lexical ordering.

## Persistent-format and migration impact

No persistent objects exist yet, so no format version or migration changes. The runtime string `sha256` is not a persistent algorithm tag. The canonical-encoding ADR must define and version the stored algorithm identifier before object bytes are written.

## Verification

- Unit tests for empty, short, multiblock, and million-byte published SHA-256 vectors.
- Unit tests for exact 32-byte raw digest conversion and malformed-length rejection.
- Generated properties equating one-shot, byte, sliced, and variably chunked hashing.
- Existing formatting, lint, package, test, and workflow gates.
- No failure-injection or golden persistent fixture applies because this adapter performs no I/O and defines no stored bytes.
- Record a C-versus-OCaml benchmark only before considering a backend switch.

## CLI and user impact

No CLI behavior exists yet. Future diagnostic output may report `sha256`; stored algorithm identifiers remain a separate format decision.

## Verification evidence

- 2026-07-29: CAVP empty, one-byte, and multiblock vectors plus the million-`a` regression vector pass.
- 2026-07-29: 300 generated one-shot/byte/variable-chunk equivalence cases pass.
- 2026-07-29: 31-byte and 33-byte raw digests are rejected; 32-byte digests round-trip.
- 2026-07-29: a fresh OCaml 5.5.0 switch resolved Digestif 1.3.1, selected `digestif.ocaml`, built, and passed `make ci`.

## References

- [Digestif 1.3.1 package metadata](https://opam.ocaml.org/packages/digestif/)
- [Digestif streaming interface](https://github.com/mirage/digestif/blob/main/src/digestif.mli)
- [Digestif pure-OCaml backend declaration](https://github.com/mirage/digestif/blob/main/src-ocaml/dune)
- [NIST SHA byte-oriented test vectors](https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program/secure-hashing)
