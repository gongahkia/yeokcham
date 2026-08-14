# V2 repository format

## Status

This document records the V2-001 root slice, the V2-010 explicit legacy
archive/cutover boundary, V2-005's first encrypted immutable object kind, and
V2-006's local object-publication journal. It is intentionally narrower than
the later identity, authorization, visibility-record, and transport protocols.

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

## Optional MLS epoch records

ADR-072 adds the optional strict namespace
`.yeokcham/mls-epochs/<64-lowercase-hex-epoch-id>.cbor`. A record is canonical
CBOR with this conceptual shape:

```text
[
  1, epoch-id, repository-id, derived-group-id, root-key-id,
  parent-epoch-id-or-null, change-kind, changed-device-id,
  previous-epoch, next-epoch,
  sha256(predecessor-state), sha256(successor-state), sha256(mls-commit),
  canonical-v2-envelope(successor-group-state), mandatory-features,
  "ed25519", root-signature
]
```

`epoch-id` is the domain-separated SHA-256 of the unsigned fields. The
signature is separately domain-separated. `next-epoch` must be exactly one
greater than `previous-epoch`; all commitments are 32 bytes; the envelope's
mandatory features must equal the record's features. The successor group state
is canonical only inside the authenticated envelope and no plaintext MLS state
or secret is included.

The store accepts only final filenames above or a regular private staging name
`.<64-hex>.cbor.stage-<decimal-pid>-<decimal-attempt>`. It publishes via
create-only hard link after file `fsync`, then `fsync`s the directory. Exact
bytes retry idempotently; different bytes, unknown names, non-regular paths,
and divergent or disconnected chains fail closed. Older V2 roots may omit this
optional directory.

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

The private staging name is exactly
`.<60-lowercase-hex-object-leaf>.ledger-<decimal-pid>-<decimal-attempt>` in
the final object shard. A valid V2 root and object enumeration ignore only an
exact regular file with that grammar as a non-authoritative crash remnant; an
otherwise matching non-regular path and every other name fail closed. It is
never a published object and is not removed implicitly.

The fixed inner record, outer envelope, and opaque-address vectors are in
`test/golden/v2-ref-ledger-*.hex`. This establishes cryptographic validity and
causal data only. Key custody, trust, authorization, transactions, candidate
discovery, and transport remain separate issues.

## Durable object-publication journal

V2-006 implements ADR-049 local transaction records under the reserved
`journal` directory. They publish only a bounded set of already encrypted,
cryptographically verifiable ledger envelopes; neither record is a V2 object,
ref, trust decision, authorization decision, or history/visibility selection.

```text
transaction-prepare-v1 = [
  1,
  repository-id,
  transaction-id,
  mandatory-features,
  [* [opaque-object-ref, canonical-encrypted-envelope-bytes]]
]

transaction-commit-v1 = [
  1,
  transaction-id,
  SHA-256("yeokcham:v2:transaction-prepare:1\0" || prepare-bytes)
]
```

`transaction-id` is a distinct 32-byte identity. Both records use canonical
CBOR and exact lowercase-hex names:

```text
journal/<64-hex-transaction-id>.prepare
journal/<64-hex-transaction-id>.commit
```

The prepare stages 1 through 64 entries, strictly ascending by opaque object
reference, with no duplicates and a total encoded prepare size at most 128 MiB.
Before the prepare is made durable and again during recovery, the adapter
decrypts and verifies every candidate, including its opaque address and
Ed25519 signature. The commit binds the exact canonical prepare bytes.
Commit records are independently bounded to 4 KiB.
Unsupported mandatory features, malformed candidates, unknown journal names,
mismatched IDs/digests, and stray commits fail closed without automatic repair.

The store writes a private regular temporary named
`.<final-name>.tmp-<decimal-pid>-<decimal-attempt>` (for example,
`.abcd…prepare.tmp-123-0`), fsyncs it, create-only links the final file, and
synchronizes the journal directory. Such exact private temporary names are
non-authoritative crash remnants: a valid V2 root and recovery scan ignore them
only when they are regular files. They are never interpreted as a prepare or
commit and are not deleted implicitly.

A durable prepare alone is discarded idempotently and has no object side
effect. Once a matching commit exists, recovery revalidates the whole set and
publishes candidates in ascending address order through the V2-005 create-only
adapter. It removes the commit then the prepare only after every object is
durable. A crash or I/O failure can therefore leave a valid immutable object
prefix and the unchanged journal for retry, but cannot overwrite an object or
select a ref.

The fixed valid and invalid format vectors are
`test/golden/v2-transaction-*.hex`.
