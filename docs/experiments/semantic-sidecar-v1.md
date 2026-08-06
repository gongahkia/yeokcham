# TypeScript semantic-sidecar v1 experiment

## Scope

This is a bounded deterministic correctness experiment, not a TypeScript parser
benchmark or a general semantic-replay claim. `yeokcham_semantic` is a pure,
non-persistent adapter for top-level ASCII-identifier declarations: `function`,
`class`, `interface`, `type`, `const`, `let`, and `var`. It has no parser
dependency and does not read or write repository objects, refs, snapshots, or
working directories.

The separately optional `yeokcham_typescript_adapter` uses the official
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
protocol failure, or the adapter's 4096-declaration response bound. It supplies a virtual file map collected only from a
verified immutable Yeokcham snapshot. Ordinary Yeokcham read, restore,
materialisation, export, verification, releases, and validation do not call or
depend on it.

The exact textual fallback contains the complete expected and replacement file
bytes. It only applies when the input exactly equals its expected source.

## Contextual textual baseline

`yeokcham_textual_patch` is an independent pure baseline for this experiment. It
accepts arbitrary bytes: original byte span, exact expected preimage,
replacement bytes, and before/after byte context. It has no TypeScript compiler,
parser, declaration, symbol, type, syntax-tree, or semantic-confidence input.

Its ordered deterministic stages are: exact preimage at the original span;
unique exact preimage elsewhere; unique complete before/selected/after context;
then caller-requested relaxed nearest context. Relaxation is bounded to
1–64 bytes per side and must be given in strictly descending order. Each stage
applies only a unique candidate; missing or ambiguous candidates are structured
conflicts. The result is an exact byte splice with unchanged prefix/suffix
validation. A contextual textual match does not report semantic `exact`
confidence. It is not weakened or given parser-derived hints for comparison.

The full-parser response is language-neutral. It includes project-relative
declaration/name UTF-8 byte spans, declaration kind, lexical parent path,
export state, syntactic name, declaration-shape and signature digests, alias
evidence where available, diagnostics, and parser/resolution completeness.
TypeScript `Symbol` objects and internal IDs are run-local only;
symbol-derived evidence is not a stable Yeokcham identity across arbitrary
refactors. Parse damage or incomplete resolution cannot justify Exact or High
semantic confidence.

## Evidence-stage semantic retargeting

`yeokcham_semantic_retarget` evaluates explicit candidate evidence in a fixed
order: exact source bytes/span/context; module plus exported-symbol path;
resolved alias or underlying symbol text; kind/overload/signature/type shape;
lexical path; declaration shape/token evidence; and exact textual fallback.
Every candidate retains supporting and contradictory evidence. Parsing,
project-resolution, type-resolution, alias-resolution, selected stage,
confidence, fallback use, and refusal reason are inspectable values.

Compiler-derived names/locations are run-local evidence, not permanent Yeokcham
semantic identities. Exact requires exact bytes, span, and context. High
requires complete parse/resolution/type-resolution plus kind/shape and module
or resolved-symbol evidence. Incomplete analysis, similarity-only evidence,
and fallback cannot automatically apply as High. Equivalent evidence returns a
structured ambiguity.

## Shared fixture dataset v1

`yeokcham_semantic_fixtures` is a checked-in, deterministic version-1 dataset of
40 stable fixture IDs. Every case contains original/authored/retarget project
bytes, operation ID, expected target span or safe-conflict oracle, confidence
ceiling, parser/resolution expectations, and adversarial explanation. Both the
semantic selector and textual baseline receive the same retarget bytes,
operation intent, and oracle. Categories include moves, exports/aliases,
overloads, merged declarations, namespaces, generics, decorators, TSX/JSX,
Unicode/BOM/emoji/CRLF bytes, signature/split/merge damage, path mappings,
ambiguity, already-satisfied changes, and binary textual-only input.

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

`docs/experiments/schema/semantic-retargeting-v1.schema.json` defines the
checked v1 report. `docs/experiments/results/semantic-retargeting-v1.json` is
generated locally from the shared dataset; every per-strategy case records its
oracle, selected file/span, exact-byte correctness, confidence, stage,
completeness, fallback use, candidate count, byte-integrity validation,
classification, host-specific elapsed time, and tool versions. The schema is
validated by `make semantic-experiment` and revalidated by `make check`.

Correct exact application means selected target and produced bytes equal the
oracle at Exact semantic confidence or the textual exact-span stage. A correct
non-exact application is oracle-correct through another allowed stage. A safe
conflict refuses an oracle-permitted/required refusal without modifying bytes;
it is not an application. False confidence is an Exact/High semantic
application with a wrong target, wrong result bytes, outside-span change, or a
required conflict. A false negative is missing, ambiguity, or rejection where
the oracle defines one uniquely applicable target.

| Metric | Semantic | Textual |
| --- | ---: | ---: |
| Cases | 40 | 40 |
| Correct exact applications | 21 | 21 |
| Correct non-exact applications | 9 | 14 |
| Safe conflicts | 3 | 3 |
| False-confident applications | 0 | 0 |
| False negatives | 6 | 1 |
| False applications | 0 | 0 |
| Already satisfied | 0 | 1 |

Semantic confidence distribution is Exact `21`, High `9`, Low `4`, Medium
`1`, Unknown `5`; parser completeness is `34/40`, project/type-resolution
completeness is `33/40`, and no semantic textual-fallback stage was used.
Textual results use `not-semantic` confidence by design. Both strategies are
correct on 32 cases; semantic-only correctness is the lexical-scope
disambiguation case; textual-only correctness is 7 cases:
`already-satisfied-change`, `binary-textual-only`, `changed-function-signature`,
`function-merge`, `function-split`, `parse-damaged-source`, and
`unresolved-imports`. Timings remain host-specific evidence, not a correctness
gate.

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
- The shared dataset is bounded evidence, not a rate estimate for arbitrary
  TypeScript projects. It contains adversarial bytes and safe conflicts, but
  does not claim complete TypeScript grammar or reference-rename coverage.
- Textual matching currently outperforms this bounded semantic selector on the
  seven listed cases; this result is preserved rather than averaged away.
- The v1 report has no known false-confident Exact/High semantic application.
  The gate is only evidence for this checked-in dataset, not a universal safety
  guarantee.

## Reproduction

```sh
opam exec -- dune exec test/test_semantic.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/semantic_property_test.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/semantic_retarget_property_test.exe
opam exec -- dune exec test/test_textual_patch.exe
opam exec -- dune exec test/test_semantic_retarget.exe
opam exec -- dune exec test/test_semantic_fixture_dataset.exe
opam exec -- dune exec test/test_semantic_experiment.exe
cd tools/yeokcham-typescript-adapter && npm ci --ignore-scripts --no-audit --no-fund && npm test
opam exec -- dune exec test/test_typescript_adapter.exe
make semantic-experiment
```
