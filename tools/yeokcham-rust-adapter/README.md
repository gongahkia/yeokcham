# Yeokcham Rust adapter

This optional helper analyses bounded Rust syntax from a supplied virtual file
map. It reads one protocol-v1 JSON request from stdin and writes one JSON
response to stdout. Stdout is protocol-only; diagnostics use bounded stderr.

Dependencies are pinned in `Cargo.lock`: `tree-sitter 0.26.11` and
`tree-sitter-rust 0.24.2`, including their resolved transitive/build graph.
Build locally once with a Rust toolchain, Cargo, and C compiler:

```sh
cargo build --locked --release
```

The resulting optional executable is
`target/release/yeokcham-rust-adapter`. Yeokcham never invokes Cargo, `rustc`, a
shell, the network, project code, build scripts, macro expansion, Cargo
configuration, or the source-project filesystem while analysing. `target/` is
intentionally untracked.

## Protocol v1

`handshake` request:

```json
{"protocolVersion":1,"operation":"handshake"}
```

`analyze` accepts a 64-character immutable Yeokcham snapshot ID and sorted,
unique safe project-relative `.rs` paths. `contentsHex` represents exact source
bytes; the helper rejects invalid UTF-8 rather than transforming it.

```json
{
  "protocolVersion":1,
  "operation":"analyze",
  "snapshotId":"<64 lowercase hex chars>",
  "files":[{"path":"src/lib.rs","contentsHex":"..."}]
}
```

Results contain only transient top-level Tree-sitter item kinds, optional
syntactic names, UTF-8 byte spans, parser completeness, and parser diagnostics.

`resolve-module-paths` adds a sorted, unique, nonempty `rootFiles` selection.
Each root must be an exact supplied source path; it names an anonymous virtual
root, never a Cargo crate/package. The helper resolves only inline modules and
an un-attributed external `mod name;` with the standard snapshot-map candidates
`<child-base>/name.rs` and `<child-base>/name/mod.rs`.

```json
{"protocolVersion":1,"operation":"resolve-module-paths","snapshotId":"<64 lowercase hex chars>","rootFiles":["src/lib.rs"],"files":[{"path":"src/lib.rs","contentsHex":"..."}]}
```

Its transient result contains `moduleFacts`, `itemPathFacts`,
`unreachableSources`, `parserComplete`, and `modulePathsComplete`. Attributes
including `path`, `cfg`, `cfg_attr`, macro attributes, ambiguous/missing
candidates, parser damage, macro definitions/invocations, `impl`, and `use`
receive explicit statuses; no incomplete fact grants operation authority. It does not infer
roots, resolve names/types/imports, expand macros, persist evidence, provide
rewrite authority, or claim behavioural equivalence.

`inspect-fallback` accepts the same snapshot ID and sorted virtual source map
as `analyze`.

```json
{"protocolVersion":1,"operation":"inspect-fallback","snapshotId":"<64 lowercase hex chars>","files":[{"path":"src/lib.rs","contentsHex":"..."}]}
```

Its transient assessment contains `parserComplete`,
`textualFallbackRequired`, and canonically ordered `fallbackFacts`. Each fact
contains an exact source path, half-open UTF-8 byte span, syntax kind, and the
fixed `textual-fallback-required` status. The helper reports macro definitions,
macro invocations at any syntax location, outer attributes, and parser damage.
It does not expand macros, resolve attributes/names/types, generate items or
modules, mutate source bytes, persist evidence, or authorize a semantic rewrite.

Hard limits: 4 MiB request/response and source file, 64 KiB stderr, 5 s parent
wall-clock, 4,096 files/items/diagnostics/module facts/fallback facts, depth 256, 4 KiB safe
paths and names. Invalid
input, bounds, unavailable executable, timeout, crash, malformed response, and
parser damage are structured outcomes at the OCaml boundary; exact byte/text
operations remain independent.

The checked-in `testdata/*-v1-*.json` files are exact protocol golden fixtures.
Run `cargo test --locked`; project `make test` and `make property-test` build
the optional helper explicitly before their adapter coverage.

For the complete supported-syntax, macro, fallback, failure, rename/move, and
cross-language comparison boundary, see
[`rust-semantic-sidecar-limitations-v1.md`](../../docs/experiments/rust-semantic-sidecar-limitations-v1.md).
