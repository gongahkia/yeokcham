# Rust semantic-sidecar limitations v1

## Authority boundary

The Rust helper is a bounded syntax sidecar, not a Rust semantic engine. Exact
snapshot source bytes remain canonical. Every response is transient evidence;
it is not a Yeokcham object, identity, persistent sidecar, semantic operation,
rewrite authority, or behavioural-equivalence claim.

The helper reads only one sorted virtual `.rs` map materialised from a verified
snapshot. It does not read a working tree, Cargo manifest, workspace metadata,
environment configuration, dependencies, build scripts, project code, network,
or language server. It does not invoke Cargo or `rustc` while analysing.

## Supported evidence

`analyze` reports bounded top-level Tree-sitter item facts, UTF-8 byte spans,
and parser diagnostics. `resolve-module-paths` uses only caller-selected virtual
roots, inline modules, and the two standard snapshot-map candidates `foo.rs`
and `foo/mod.rs`. It reports explicit status rather than guessing for missing,
ambiguous, duplicate, unreachable, depth-limited, or parser-damaged input.

This evidence does not resolve crates, packages, imports, names, aliases,
types, trait dispatch, visibility, feature flags, build configuration, or
behaviour. A syntactic path is not a compiler path, symbol identity, or a safe
rename/move target.

## Unsupported syntax and macro behaviour

The sidecar does not expand declarative or procedural macros, resolve macro
scope, run attributes/derives, or identify macro-generated modules, items, or
references. It treats every macro definition and invocation, every outer
attribute, and every parser error/missing node as bounded
`textual-fallback-required` evidence. Attribute handling is intentionally
conservative: even an ordinary built-in attribute may require fallback because
the syntax-only helper does not resolve its meaning.

`#[path]`, `cfg`, `cfg_attr`, macro attributes, nonstandard module layout, and
Cargo-selected roots remain unsupported for module resolution. Invalid UTF-8 is
rejected; parser-damaged Rust is never repaired or reinterpreted. A fallback
fact only explains why an independent exact byte/text path may be appropriate;
it cannot select, create, or authorize that path.

## Failure and fallback behaviour

Unsafe paths, missing/invalid helpers, timeout, crash, malformed protocol,
unsupported encoding, bounds, parser damage, and unsupported syntax become
structured unavailable or incomplete outcomes. They do not become repository
state and do not block `yeokcham_textual_patch` from operating independently on
the same exact bytes. There is no source mutation, persistence, or in-place
replacement in the sidecar.

## Rename/move and comparison limits

The Rust fixture dataset proves only exact textual byte oracles after selected
rename/move-shaped changes. It includes duplicate ambiguity plus macro-heavy
and parser-damaged fallback cases, but it does not implement Rust declaration
rename, reference update, move inference, or automatic semantic application.

The Rust/TypeScript v1 comparison keeps the workloads separate: TypeScript has
its own 40-case semantic/textual experiment, while Rust has six textual/fallback
fixtures and zero semantic retargeting attempts. Its zero Rust
false-confident-semantic count is not a safety result, rate comparison, or
cross-language generalisation. The TypeScript experiment and its limitations
remain unchanged.
