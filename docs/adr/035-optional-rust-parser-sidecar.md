# ADR-035 — Optional Rust parser sidecar

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M9-01 needs an optional Rust parser behind the existing semantic-sidecar
boundary. ADR-003 keeps exact source bytes canonical; ADR-008 requires an
explicit uncertainty outcome; and ADR-015 requires that the completed
TypeScript/textual experiment remain intact. The issue prohibits an
unapproved major parser dependency.

Current milestone: M9 Rust Semantic Sidecar. Vertical slice: analyse Rust
syntax from one verified immutable snapshot through a bounded local helper and
return transient top-level item evidence or a structured unavailable/incomplete
result. It excludes module resolution and paths, name/type resolution, macro
expansion, Cargo workspaces/configuration, `rustc`, build scripts at analysis
time, semantic replay, persistent sidecars, CLI commands, and changes to the
TypeScript or textual experiments.

## Decision drivers

- Preserve arbitrary canonical bytes and independently available textual work.
- Bound helper input, output, elapsed time, files, paths, and item records.
- Do not read a live directory, Cargo project, host dependencies, network, or
  user configuration while analysing a snapshot.
- Pin and inspect a small grammar dependency graph before implementation.
- Return syntax evidence without claiming Rust semantic understanding.

## Considered options

### Extend the dependency-free OCaml semantic experiment

- Keeps the binary dependency graph unchanged.
- Would duplicate a Rust grammar and does not meet M9-01's parser-adapter
  objective.

### Invoke Cargo, rustc, or Rust Analyzer for each analysis

- Can expose project-aware information.
- Depends on mutable workspaces, toolchains, build scripts, macro expansion,
  configuration, and potentially networked dependency resolution; it exceeds
  the bounded syntax slice.

### Local Tree-sitter Rust helper

- `tree-sitter` provides a byte-offset syntax tree and `tree-sitter-rust`
  supplies the Rust grammar; both are sufficient for syntax-only item evidence.
- Requires a separate compiled helper and explicit Cargo lock maintenance, but
  keeps analysis isolated from the source project.

## Decision outcome

Select the local Tree-sitter Rust helper.

M9-01 will add `tools/paengi-rust-adapter` as a separately built Rust binary
and an OCaml boundary analogous to, but independent from,
`paengi_typescript_adapter`. The helper receives exactly one JSON protocol-v1
request on stdin and writes exactly one JSON response on stdout. It is invoked
by direct argv; stdout is protocol-only and bounded stderr is diagnostic-only.
The helper never invokes Cargo at analysis time.

The initial direct dependencies are `tree-sitter 0.26.11` and
`tree-sitter-rust 0.24.2`. `tree-sitter-rust` also requires
`tree-sitter-language 0.1` and builds its bundled grammar through `cc`; these
transitive/build dependencies remain visible in the committed `Cargo.lock`.
The implementation must use that lockfile with `cargo build --locked`; the
checked-in project does not ship `target/` output. Rust, Cargo, and a C compiler
are explicit setup requirements to build the optional helper, not runtime
requirements for Paengi's byte/text core. The dependency choice is based on
the published [Tree-sitter Parser API](https://docs.rs/tree-sitter/0.26.11/tree_sitter/struct.Parser.html)
and [Rust grammar API](https://docs.rs/tree-sitter-rust/0.24.2/tree_sitter_rust/).

Protocol v1 accepts only a 64-lowercase-hex snapshot ID and a sorted virtual
map of safe project-relative POSIX `.rs` paths to hex-encoded, valid UTF-8
bytes. The map is materialised only from a verified immutable Paengi snapshot;
the helper receives no directory, repository, Cargo manifest, environment
configuration, or dependency path. Invalid UTF-8 is a structured
`unsupported-encoding` result, not a conversion or mutation of source bytes.

The response is transient syntax evidence: snapshot ID, pinned adapter and
grammar versions, parser-completeness flag, bounded parse diagnostics, and
bounded top-level item records. An item record has a safe path, Tree-sitter node
kind, optional syntactic name, and UTF-8 byte spans for the item and name. Item
records are sorted by path then span. They are not semantic identities, module
paths, resolved symbols, types, macro expansions, intent, or evidence of
behavioural equivalence. Error nodes or missing parse trees produce explicit
incompleteness and no automatic operation.

The OCaml boundary defines `Available analysis | Unavailable reason`; reasons
cover a missing executable, request/output/stderr bounds, timeout, abnormal
exit, malformed or incompatible protocol, helper error, unsafe input, invalid
snapshot, and unsupported encoding. Missing, crashed, timed-out, malformed, or
incomplete analysis never changes a snapshot, checkpoint, capsule, revision,
workspace, release, ref, object, validation result, or canonical bytes. The
existing byte/text operation remains callable independently.

Initial hard bounds are: 4 MiB request, 4 MiB response, 64 KiB stderr, 5 s
wall-clock, 4,096 source files, 4 MiB per source file, 4,096 item records, and
4 KiB per safe path. The OCaml parent enforces process bounds; the helper
revalidates all protocol and structural bounds before parsing. The helper uses
no runtime Cargo build, shell, network, `rustc`, project code, macro expansion,
or source-project filesystem read.

## Consequences

- Rust syntax evidence becomes an explicitly installed optional capability.
- Parser availability and completeness are inspectable rather than silently
  inferred from an ambient toolchain.
- The `Cargo.lock` constrains the adapter dependency graph but adds maintenance
  and a C-compiler build requirement.
- Macros, invalid/unsupported source, module relationships, and all semantic
  claims remain deferred or fall back to exact bytes/text.
- The TypeScript adapter, pure semantic experiment, fixture dataset, and
  comparative results remain independent and unmodified in this slice.

## Model and invariant impact

The proposed transient types are a Rust analysis, item evidence, diagnostic,
handshake, configuration, and structured unavailable reason. They are separate
from the TypeScript adapter's types and from every canonical model type.

- Every available analysis names the exact requested snapshot ID.
- Every supplied source comes from that verified snapshot and has safe path,
  valid UTF-8 bytes, and declared Rust language.
- Every returned span is a half-open UTF-8 byte range within its supplied
  source; item ordering is canonical.
- `parser_complete = false` carries no automatic application authority.
- Adapter absence or any failure leaves the byte/text core available and leaves
  repository state unchanged.
- Rust parser facts never become an identity, canonical source, semantic
  operation, or persistent sidecar in M9-01.

## Persistent-format and migration impact

No Paengi object, ref, envelope, schema, mapping, golden persistent bytes, or
migration changes. The versioned helper protocol and committed `Cargo.lock`
are tool artifacts, not Paengi persistent formats. Existing persistent-format
goldens must remain byte-identical. A later persistence proposal requires a
new ADR and format version.

## Verification

Implemented and verified 2026-08-05:

- `cargo fmt --check` and `cargo test --locked` cover exact protocol-v1
  handshake/analysis JSON goldens, pinned versions, UTF-8 name spans, parser
  damage, unsafe paths, and invalid UTF-8.
- Seven focused OCaml tests cover handshake pins, top-level item evidence,
  UTF-8 byte spans, parser incompleteness, verified-snapshot-only input,
  missing helper, timeout, crash, malformed output, bounded stdout/stderr and
  request, unsafe/non-UTF-8 input, and independent textual fallback.
- The seeded generated virtual-map property checks item count, kind, and spans.
  `PROPERTY_TEST_SEED=17 make property-test` completed without failure output;
  its Dune property process was observed through completion.
- `make check` passed after the final change: build/lint/format, Rust unit
  tests, focused adapter tests, persistent-format audit, and comparative
  result-schema validation.

The checked-in `Cargo.lock` and protocol goldens are versioned tool fixtures;
no Paengi persistent golden changed. A parse benchmark remains deferred because
this slice establishes bounded syntax evidence, not a performance claim.

## CLI and user impact

Not applicable in M9-01: no CLI command is added. Library callers may inspect
the exact snapshot, helper/grammar versions, bounded syntax evidence, or a
structured unavailable/incomplete reason. They cannot request a semantic
rewrite, module path, resolved name/type, macro expansion, persistence, or a
claim that Rust code is equivalent.
