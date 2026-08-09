# V2 repository format

## Status

This document records the V2-001 root slice, the V2-010 explicit legacy
archive/cutover boundary, and V2-005's first encrypted immutable object kind.
It is intentionally narrower than the later identity, authorization,
transaction, and transport protocols.

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
transitions exist.

## Encrypted immutable ledger objects

V2-005 stores one ADR-048 `ref-ledger-event-v1` plaintext only inside an
ADR-045 canonical encrypted envelope. Its 32-byte ADR-046 opaque address is
the object name, sharded as `objects/<2 hex>/<2 hex>/<60 hex>`. The raw outer
envelope is the sole object-file content; no plaintext ref name, target, event
kind, signer ID, mutable current ref, or ledger index is present on disk.

Before publication, the adapter decrypts the candidate envelope, strictly
decodes its canonical ledger record, recomputes the opaque address, and
verifies its Ed25519 signature against the caller-supplied key registry. It
fsyncs each newly needed shard's parent, fsyncs a private sibling temporary
file, create-only links the final path, and fsyncs the final directory before
removing the temporary link. A byte-identical existing object is an idempotent
retry; different bytes at the same opaque address are a collision error.
Rejected inputs and blocked publication leave no accepted object or mutable-ref
change.

The fixed inner record, outer envelope, and opaque-address vectors are in
`test/golden/v2-ref-ledger-*.hex`. This establishes cryptographic validity and
causal data only. Key custody, trust, authorization, transactions, candidate
discovery, and transport remain separate issues.
