# TypeScript semantic-sidecar v1 experiment

## Scope

This is a bounded deterministic correctness experiment, not a TypeScript parser
benchmark or a general semantic-replay claim. `paengi_semantic` is a pure,
non-persistent adapter for top-level ASCII-identifier declarations: `function`,
`class`, `interface`, `type`, `const`, `let`, and `var`. It has no parser
dependency and does not read or write repository objects, refs, snapshots, or
working directories.

The separately optional `paengi_typescript_adapter` uses the official
TypeScript Compiler API `5.9.3`, exactly pinned in its checked-in
`package-lock.json`. It requires Node `>=14.17.0`. Setup is one documented,
local `npm ci --ignore-scripts --no-audit --no-fund`; the adapter never invokes
npm, downloads packages at runtime, uses global TypeScript, accesses the
network, executes analysed project code, lifecycle scripts, plugins, or a
language server. `node_modules/` is not checked in.

Protocol v1 is a one-shot bounded request on stdin and JSON response on stdout;
stderr carries process diagnostics. The OCaml-owned boundary invokes Node by
direct argv, capability-detects the handshake, bounds request/stdout/stderr,
and returns semantic-unavailable on absence, timeout, crash, malformed output,
or protocol failure. It supplies a virtual file map collected only from a
verified immutable Paengi snapshot. Ordinary Paengi read, restore,
materialisation, export, verification, releases, and validation do not call or
depend on it.

The exact textual fallback contains the complete expected and replacement file
bytes. It only applies when the input exactly equals its expected source.

The full-parser response is language-neutral. It includes project-relative
declaration/name UTF-8 byte spans, declaration kind, lexical parent path,
export state, syntactic name, declaration-shape and signature digests, alias
evidence where available, diagnostics, and parser/resolution completeness.
TypeScript `Symbol` objects and internal IDs are run-local only;
symbol-derived evidence is not a stable Paengi identity across arbitrary
refactors. Parse damage or incomplete resolution cannot justify Exact or High
semantic confidence.

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

The isolated Compiler API suite additionally uses local `.ts`/`.tsx` requests
for BOM, Unicode, emoji, CRLF, aliases, re-exports, path mapping, unresolved
imports, parser damage, unsupported options, response bounds, and exact
replace-node preconditions. It checks that exact replacement preserves all
bytes outside the selected span, rejects stale preimages, and rejects a
post-replacement parse failure. This is protocol coverage, not the expanded
retargeting dataset or a semantic-versus-contextual-textual comparison.

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
- The Compiler API adapter can apply only an exact-span, exact-preimage
  replace-node request. It reports `exact` only after byte, kind, shape, parse,
  lexical-context, and outside-byte checks; it does not retarget a moved node.
- Contextual textual patching, fair same-fixture semantic/textual metrics,
  adversarial expanded cases, and any persistent sidecar format remain undone.

## Reproduction

```sh
opam exec -- dune exec test/test_semantic.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/semantic_property_test.exe
cd tools/paengi-typescript-adapter && npm ci --ignore-scripts --no-audit --no-fund && npm test
opam exec -- dune exec test/test_typescript_adapter.exe
```
