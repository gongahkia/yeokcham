# ADR-037 — Rust macro textual fallback

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M9-03 must retain macro-heavy, invalid, and otherwise unsupported Rust source
through exact byte/text fallback. ADR-035 introduced a bounded Tree-sitter
syntax boundary but excludes macro expansion; ADR-036 resolves only
non-attributed standard modules and deliberately defers macro behaviour to this
issue. Rust macro invocations can occur as items, statements, expressions,
patterns, and types, and their resolution/expansion may introduce further
items or ambiguities. Inferring an item path, target, or rewrite from those
facts would violate ADR-003's exact-byte authority and ADR-008's explicit
uncertainty rule.

Current milestone: M9 Rust Semantic Sidecar. Vertical slice: inspect one
verified immutable snapshot virtual map and return bounded transient
textual-fallback-required facts for macro-sensitive or parse-damaged syntax.
It excludes macro expansion, macro/name/type resolution, Cargo or `rustc`,
semantic rewrite/application, source mutation, persistence, CLI, and changes
to the completed TypeScript/textual experiment.

## Decision drivers

- Macro-heavy source bytes must remain independently available to exact textual
  operations even when syntax evidence is incomplete.
- The helper must not claim to identify macro-generated declarations or their
  origins without expansion-time resolution.
- Every outcome must be reproducible from one request's immutable snapshot
  bytes, with no host source/configuration read.
- Fallback evidence must be bounded, canonical, inspectable, and separate from
  Paengi IDs and persistent state.
- Existing `analyze` and `resolve-module-paths` protocol-v1 results must retain
  their established meaning.

## Considered options

### Expand macros with Cargo, `rustc`, or Rust Analyzer

- Can expose expanded syntax for a configured project.
- Requires toolchain/workspace/dependency/build-script/proc-macro state and
  possibly host or network reads; creates a compiler-equivalence claim outside
  this snapshot-only sidecar.

### Ignore macro syntax and rely on callers to notice it

- Leaves the byte/text core independent.
- Loses inspectable evidence of why a semantic path is unavailable and permits
  a caller to mistake partial syntax facts for supported declarations.

### Conservatively report snapshot-local textual fallback facts

- Uses only Tree-sitter syntax and exact supplied bytes, so it is deterministic
  and bounded.
- May over-classify an ordinary built-in attribute, but preserves safety and
  makes no macro-resolution claim.

## Decision outcome

Select conservative snapshot-local textual fallback facts.

M9-03 adds a separate protocol-v1 `inspect-fallback` operation and OCaml
library entry points over the existing sorted virtual `.rs` map. It returns a
transient fallback assessment scoped by the exact requested snapshot ID:
adapter/grammar versions, parser completeness, `textual_fallback_required`,
and canonically ordered fallback facts. A fact has a supplied path, half-open
UTF-8 byte span, syntax kind, and the fixed status
`textual-fallback-required`. It is evidence only; returned bytes are not
rewritten, replaced, or persisted.

The helper recursively inspects every source syntax tree. It emits a fallback
fact for every macro definition, macro invocation at any grammar location, and
outer attribute. Parser error/missing nodes emit `parser-damage` fallback facts.
This intentionally treats attributes conservatively: the syntax-only helper
does not distinguish a harmless built-in attribute from derive, procedural, or
other macro-sensitive behaviour. Macro expansion, macro-use scope, attribute
resolution, generated modules/items, imports, names, types, and compiler
configuration remain unavailable.

`textual_fallback_required` is true when at least one fact exists or parsing is
incomplete. The original verified snapshot source bytes remain the only source
for any independent `paengi_textual_patch` call; a fallback fact neither
creates a text operation nor authorizes one. A macro-free, parser-complete
assessment has no fallback facts and is still not semantic application
authority.

The existing 4 MiB request/response/source, 4,096 file, 4 KiB path/name, 64
KiB stderr, and 5 s parent bounds apply. At most 4,096 fallback facts are
returned; overflow is a structured helper error. Facts sort by path, start/end
byte, then syntax kind. The OCaml boundary validates snapshot ID, source-map
membership, spans, canonical order, status, count, and response consistency
before exposing `Available`; malformed, absent, timed-out, crashed, bounded,
or invalid helper outcomes remain `Unavailable` and do not affect repository
state or exact byte/text availability.

This policy follows the Rust Reference's [macro invocation forms](https://doc.rust-lang.org/reference/macros.html)
and [macro expansion-time resolution](https://doc.rust-lang.org/reference/names/name-resolution.html): invocation
syntax alone cannot prove the item/name/type introduced after iterative macro
resolution.

## Consequences

- Macro-heavy and malformed source produces explicit refusal/fallback evidence
  rather than a fabricated declaration, module path, or semantic result.
- Existing module-path facts remain transient and incomplete where macros or
  attributes prevent supported resolution.
- A caller can inspect why it must use independent exact byte/text behaviour.
- Conservative attribute handling can classify more sources than actual Rust
  macro expansion would affect; this is an explicit M9 safety trade-off.
- The TypeScript adapter, semantic experiment, and persistent contracts remain
  independent and unchanged.

## Model and invariant impact

New transient values are fallback assessment, fallback fact, fallback kind,
and fallback status. They are separate from snapshot, checkpoint, capsule,
revision, workspace, release, conflict, object, ref, and semantic-operation
types.

- Every available assessment names the exact requested snapshot ID.
- Every fallback path/span belongs to one supplied safe UTF-8 source and is a
  valid half-open byte range in that source.
- Facts are strictly canonically ordered and bounded.
- `textual_fallback_required` is true whenever a fact exists or parser
  completeness is false; no fact, assessment, or status is semantic authority.
- A helper failure or incomplete assessment cannot mutate repository state and
  leaves the byte/text core callable with the unchanged snapshot bytes.

## Persistent-format and migration impact

No Paengi object, ref, schema, envelope, mapping, migration, or persistent
golden changes. Protocol-v1 fallback requests/results and exact JSON fixtures
are transient adapter artifacts. Any persistence of macro/fallback evidence or
its use in a canonical operation requires a separate ADR and format version.

## Verification

Required before issue closure:

- Exact protocol goldens for macro definitions, item/statement/expression/
  pattern/type invocations, nested macro token trees, attributes, parser damage,
  mixed UTF-8 source, multi-file ordering, and macro-free complete source.
- Unit tests for snapshot binding, fallback status/completeness invariants,
  canonical order, helper bounds, source/span validation, and independent exact
  textual patch behaviour.
- Failure tests for missing helper, timeout, crash, malformed response,
  stdout/stderr/request/fact limits, invalid UTF-8, unsafe source path, and
  parser damage; none may mutate repository state.
- Seeded generated macro-containing virtual maps proving every reported span is
  within exact source bytes, output ordering is canonical, no fallback fact has
  semantic authority, and a textual operation remains available.
- Focused adapter and fixture tests, comparative result-schema validation,
  `make check`, and `make property-test PROPERTY_TEST_SEED=17`.

## CLI and user impact

Not applicable in M9-03: no CLI command is added. Library callers may inspect
snapshot-scoped fallback facts and then independently choose an exact textual
operation. They cannot expand macros, obtain a generated declaration/module
path, request a semantic rewrite, persist fallback evidence, or claim semantic
equivalence.
