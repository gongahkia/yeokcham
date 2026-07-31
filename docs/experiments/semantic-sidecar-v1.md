# TypeScript semantic-sidecar v1 experiment

## Scope

This is a bounded deterministic correctness experiment, not a TypeScript parser
benchmark or a general semantic-replay claim. `paengi_semantic` is a pure,
non-persistent adapter for top-level ASCII-identifier declarations: `function`,
`class`, `interface`, `type`, `const`, `let`, and `var`. It has no parser
dependency and does not read or write repository objects, refs, snapshots, or
working directories.

The exact textual fallback contains the complete expected and replacement file
bytes. It only applies when the input exactly equals its expected source.

## Inputs

Checked-in fixtures under `test/fixtures/semantic/` cover:

- declaration rename;
- declaration move;
- declaration replacement;
- whitespace/trailing-comma retargeting;
- duplicate exact declaration fingerprints;
- low-similarity candidates; and
- unterminated string parse failure.

Focused tests also cover a changed string literal under the same declaration
name. String literals participate in the adapter's normalized signature, so it
does not receive exact confidence.

## Results

| Case | Exact-text fallback baseline | Semantic result |
| --- | --- | --- |
| Rename onto formatting-only target | Rejects source mismatch | Correct declaration-name rewrite, exact confidence |
| Duplicate exact fingerprints | Rejects source mismatch | Structured `ambiguous-anchor` conflict |
| Same structure, different name | Rejects source mismatch | Structured `manual-review-required` outcome |
| Low token similarity | Rejects source mismatch | Structured `low-confidence-anchor` conflict |
| Invalid source | No transform | Parser error; no proposal |
| Move or replacement proposal | No transform | Proposal only; automatic application requires review |

The defined formatting-retarget workload improves from `0/1` baseline
applications to `1/1` correct automatic declaration-name rewrites. This is a
fixture result only; it is not a general success rate.

Automatic applications observed: `1`. Observed false-confident applications:
`0`. Safe non-applications/conflicts observed: `5`. The generated suite adds
100 formatting variants and 100 duplicate-anchor cases with seed `17`; it
observed no automatic duplicate application. These counts are too small to
estimate a false-confidence rate.

## Failure examples and limitations

- TypeScript grammar coverage is deliberately incomplete: Unicode identifiers,
  decorators, namespaces, enums, JSX, template interpolation semantics, and
  many declaration forms remain unsupported research work.
- Parse failure and unsupported source produce no semantic proposal; normal
  byte-based workflows remain available.
- A structural or high token-similarity match is never automatically applied.
- Move and replacement proposals are inspection-only in this slice.
- Even the narrow automatic rename rewrites only the located declaration name;
  it does not claim to rename references or prove program behaviour.

## Reproduction

```sh
opam exec -- dune exec test/test_semantic.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/semantic_property_test.exe
```
