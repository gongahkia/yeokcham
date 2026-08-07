# V2 repository format

## Status

This document records the V2-001 vertical slice: an atomic, validated root
boundary for a new repository. It is intentionally narrower than the final V2
encrypted object, identity, and ref protocols, which have their own issues.

## Model

The root is the tuple `(format, objects, refs, locks, journal)` under
`.yeokcham`. `format` is a canonical byte string, not a best-effort capability
list. A repository is openable exactly when all five entries exist with their
required kinds and the format bytes equal the fixture at
`test/golden/repository-root-v2.format`.

The root format is:

```text
yeokcham-repository-root 2
root-layout-version 2
required-directory objects
required-directory refs
required-directory locks
required-directory journal
```

## Invariants

- Under the current single-initializer contract, `init` constructs the complete
  layout in a private sibling directory, fsyncs it, then atomically renames it
  to `.yeokcham`. Multiprocess initialization semantics are deferred to V2-009.
- `open_repository` and a repeated `init` only validate an existing root; they
  never create a missing directory or format file.
- Missing metadata is `Repository_not_initialized`; a missing required entry is
  `Repository_incomplete`; noncanonical or unknown format bytes are
  `Incompatible_repository_format`.
- Failed staging leaves no accepted root. A stale staging directory is not an
  openable repository and is never repaired implicitly.

## Compatibility boundary

`Yeokcham_store.repository_format` remains the V1 object/ref adapter identifier
while the old prototype objects are still present in the codebase. It is no
longer written to `.yeokcham/format`. This root declaration does **not** claim
that V2 encrypted envelopes, opaque addressing, or an encrypted ref ledger are
implemented; V2-003 through V2-007 replace those adapter-level formats.
