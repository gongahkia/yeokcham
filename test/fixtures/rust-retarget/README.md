# Rust retarget fixtures

`paengi_rust_fixtures` defines the checked-in version-1 virtual source-map
dataset used by `test_rust_retarget_fixtures`.

It covers six bounded cases: rename after unrelated insertion, rename after
within-file move, rename after standard cross-module move, duplicate ambiguity,
macro-heavy fallback, and parser-damaged fallback. Every applicable case has
an exact byte oracle for `paengi_textual_patch`; the duplicate remains a
structured conflict. Macro-heavy and invalid cases remain independently
textual-only: fallback facts do not infer a Rust declaration, move, rename, or
semantic rewrite.
