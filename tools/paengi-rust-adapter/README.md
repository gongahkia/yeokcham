# Paengi Rust adapter

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
`target/release/paengi-rust-adapter`. Paengi never invokes Cargo, `rustc`, a
shell, the network, project code, build scripts, macro expansion, Cargo
configuration, or the source-project filesystem while analysing. `target/` is
intentionally untracked.

## Protocol v1

`handshake` request:

```json
{"protocolVersion":1,"operation":"handshake"}
```

`analyze` accepts a 64-character immutable Paengi snapshot ID and sorted,
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
They do not contain module paths, resolved names/types, macro expansion,
semantic identity, rewrite authority, or a behavioural-equivalence claim.

Hard limits: 4 MiB request/response and source file, 64 KiB stderr, 5 s parent
wall-clock, 4,096 files/items/diagnostics, 4 KiB safe paths and names. Invalid
input, bounds, unavailable executable, timeout, crash, malformed response, and
parser damage are structured outcomes at the OCaml boundary; exact byte/text
operations remain independent.

The checked-in `testdata/*-v1-*.json` files are exact protocol golden fixtures.
Run `cargo test --locked`; project `make test` and `make property-test` build
the optional helper explicitly before their adapter coverage.
