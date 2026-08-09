# V2 repository format

## Status

This document records the V2-001 root slice and the V2-010 explicit legacy
archive/cutover boundary. It is intentionally narrower than the final V2
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
longer written to `.yeokcham/format`. The public CLI classifies a metadata root
before `init` or any V2-facing command:

- an empty workspace may receive only this V2 root;
- a historical V1 root or the prior V2-marker/V1-data hybrid must be archived
  with `yeokcham archive --name <archive-name>`;
- mixed, incomplete, symlink-containing, and unknown roots refuse without
  repair or overwrite;
- `yeokcham reset --archive <archive-name> --confirm-v2-reset` initializes an
  empty V2 root only after it verifies the independently recoverable archive.

The archive is a same-parent rename of the legacy `.yeokcham` tree. Its sibling
`<archive-name>.legacy-archive-manifest-v1` is canonical CBOR:

```text
manifest = [1, entries]
entry    = [kind, path-components, mode, size, sha256-digest]
kind     = 0  ; directory, size 0 and empty digest
         / 1  ; regular file, raw 32-byte SHA-256 digest
```

Entries are sorted by raw relative path components; paths, modes, sizes, and
digests are re-inventoried after relocation before the manifest is published.
A durable same-parent `.pending` manifest permits explicit resumption after a
failure between relocation and manifest publication. Neither manifest is a V2
object, ref, ledger event, or authority over V1 history.

Old V1 CLI workflows are deliberately refused for V2 roots until their V2
transitions exist. This root declaration does **not** claim that V2 encrypted
envelopes, opaque addressing, or an encrypted ref ledger are implemented;
V2-003 through V2-007 replace those adapter-level formats.
