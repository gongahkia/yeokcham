# Yeokcham repository format

This is the normative local-repository layout and compatibility contract for
the currently supported Yeokcham formats. It complements the byte-level record
definitions in [`serialization.md`](serialization.md). A repository is
trustworthy only after the normal bounded verification path validates this
layout, every referenced immutable record, and every reconstructed Git object.

## Compatibility

`format/repository.bin` is the `YKRB` bootstrap record. It is exactly 38 bytes:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `YKRB` |
| 4 | 2 | format version, big-endian `u16` |
| 6 | 8 | required feature flags, big-endian `u64` |
| 14 | 8 | optional feature flags, big-endian `u64` |
| 22 | 16 | raw RFC 9562 UUIDv4 repository ID |

The implementation accepts only zero required flags, preserves optional flags,
and rejects an unsupported bootstrap version before returning a handle.

| Version | Meaning | Writer behaviour |
| --- | --- | --- |
| 1 | Initial immutable-object and optional `YKRF` snapshot layout. | `create` writes V1. |
| 2 | V1 layout plus checked append-only `YKRE` local ref journals. | The first `sync` or accepted local push upgrades only the bootstrap after immutable objects are verified. |

`yeokcham migrate <source-v1-repo> <destination-v2-repo>` is the supported
rollback-preserving V1-to-V2 migration. It fully verifies and scans the V1
source before creating the absent destination, copies only canonical recovery
files, writes a V2 bootstrap last, and fully verifies the destination. It
never writes the source. A failed migration can leave an incomplete destination
which must be explicitly discarded before retrying; it is safe to restart but
does not resume an existing destination. SQLite and recognized staging files
are not copied. An older V1-only reader rejects V2. `LocalRepository::migrate`
only opens and validates a repository. A future format change must allocate a
version or required feature, use copy-on-write publication, verify the
successor, retain a readable rollback source until finalisation, and document
interrupted recovery.

## Layout

`create` requires an absent root and an existing parent. It creates the
required directories, writes and synchronizes the bootstrap last, then reopens
the result. A directory without a valid bootstrap contains no acknowledged Git
state. Every owned path below is a real directory or regular file; symlinks and
unexpected final names fail verification.

```text
<repository>/
  format/repository.bin                 # required YKRB bootstrap
  segments/<segment-uuid>               # immutable YKSG
  indexes/<segment-uuid>.ykix           # rebuildable YKIX
  manifests/blobs/<manifest-uuid>.ykmf  # immutable YKMF
  manifests/tiny-groups/<uuid>.yktg     # optional immutable YKTG
  manifests/objects/<git-sha1>.ykom     # optional immutable YKOM
  manifests/refs/<snapshot-uuid>.ykrf   # optional immutable YKRF
  journals/refs/<event>.ykre            # V2 immutable YKRE events
  mirrors/github.ykgm                   # optional checked YKGM policy
```

The following directories are required even when empty: `format`, `segments`,
`indexes`, `manifests`, `manifests/blobs`, `manifests/generations`, `journals`,
`journals/refs`, `summaries`, and `summaries/current`. `manifests/tiny-groups`,
`manifests/objects`, `manifests/refs`, and `mirrors` are created on their first
publication and otherwise remain absent. `manifests/generations` and
`summaries/current` are reserved in the current layout and contain no accepted
V1/V2 canonical records.

All UUID filenames are lowercase canonical UUIDv4 text. The `YKOM` filename is
the lowercase 40-hex Git SHA-1 ID. A journal filename is exactly
`<20-decimal-sequence>-<device-uuid>-<64-hex-event-sha256>.ykre`; every component
must match the decoded event. Final filenames bind the record identity and are
not advisory metadata.

Publication uses a regular same-directory staging file, data synchronization,
create-without-replacement finalization where applicable, and directory
synchronization. Recognized `.partial` staging names may remain after an
interruption and are ignored; any other unexpected entry is corrupt. Immutable
final records are idempotent only when their exact bytes already exist.

## Canonical and disposable state

Canonical recovery data is the bootstrap plus final recognized segments,
indexes, manifests, snapshots, journals, and optional mirror policy. SQLite is
not a resolver or recovery dependency. The encrypted recovery manifest (`YKRM`)
admits only these canonical names, excludes `metadata.sqlite3` and recognized
staging files, and rejects all other source paths.

The following are explicitly disposable and must not be relied upon for
recovery:

- `metadata.sqlite3` (SQLite application ID `YKMD`), local coordination metadata;
- `cache/`, including ref-state-keyed C Git snapshot packs and their last-used
  markers;
- process-memory decrypted chunk/object caches;
- `YKCC` ciphertext-cache entries, `YKFC` daemon file-metadata snapshots, and
  `YKDP` daemon protocol messages.

Deleting or corrupting disposable data can cause rebuild work but cannot alter
the verified canonical Git graph. `YKCE`, `YKRK`, `YKRM`, `YKDO`, and `YKDR`
are backend, recovery, or remote-replication records, not files required below
the local repository root; their byte contracts are also specified in
[`serialization.md`](serialization.md).

## Object and ref resolution

`YKMF`, `YKTG`, and `YKOM` bind a repository ID, immutable segment ID, and
segment checksum. Resolution first fully validates that exact `YKSG`, then its
nested record, then the representation-specific identity and final Git object
ID. `YKIX` can accelerate lookup only after the matching segment has been
verified and is always rebuildable.

The current repository accepts either one initial `YKRF` snapshot without a
journal or one complete checked `YKRE` journal continuation rooted in that
state. It never selects an order-dependent journal branch. A journal event must
bind the expected predecessor state and its filename identity; V2 events also
verify their embedded Ed25519 signature. Remote device authorization is a
separate root-pinned `YKDR` protocol and does not authorize the local V1 helper
writer.

`mirrors/github.ykgm` is optional, token-free local policy state. It is included
only in encrypted recovery snapshots, is not required for Git export, and a
missing mirror policy is not an error. Its corruption fails closed instead of
changing refs or contacting GitHub.

## Reader requirements

Readers must bound directory scans, file reads, entries, aggregate bytes, and
decoded bodies before allocation. They reject nonregular files, symlinks,
truncation, trailing bytes, malformed names, unknown required semantics,
checksum failures, and incompatible version/feature combinations. Checksum
success alone never establishes Git-object trust: the final reconstructed
canonical Git header and SHA-1 object ID remain mandatory verification.

## Implementation and verification status

The supported writer/reader is the locked Yeokcham source at this revision.
Per-family normal, bounds, malformed-input, checksum, and signature tests live
with the codecs in `yeokcham-core`; repository integration tests exercise
import, verification, export, restart, crash boundaries, and `git fsck`. The
next roadmap item, old-format fixtures, will add independently retained sample
repositories for each supported historical reader path.
