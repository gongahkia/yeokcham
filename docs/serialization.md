# Canonical binary serialization

This policy applies to every persistent Yeokcham record and replaces ad hoc `serde` or native-memory encodings.

## Primitive encodings

- All unsigned integers use their stated fixed width in big-endian order.
- Fixed-size identifiers use their raw validated bytes with no length prefix.
- Variable byte strings use an unsigned big-endian `u64` byte length followed by exact bytes.
- Ref names are byte strings, not UTF-8 text.
- No floats, booleans, nulls, native pointers, platform widths, varints, compression, or implicit default values are permitted.

## Record layout

Every record begins with fixed fields in this order:

1. Four-byte ASCII magic identifying the record family.
2. Unsigned `u16` schema version.
3. Unsigned `u64` required feature bits.
4. Unsigned `u64` optional feature bits.
5. Record-specific fields in documented fixed order.

Record schemas may use a fixed ordered sequence of fields or an ordered repeated sequence. They must not use maps, unordered sets, omitted defaults, duplicate singular fields, or trailing bytes. Unknown required features fail with `Unsupported`; unknown optional features are preserved by metadata rewrite paths.

## Decoder rules

- Decode only from a caller-bounded record slice.
- Reject truncation, length overflow, invalid typed fields, duplicate singular fields, invalid ordering, and trailing bytes as `CorruptData`.
- Validate IDs, ref names, lengths, counts, checksums, and required-feature bits before trust.
- Readers do not normalize, repair, or silently skip malformed bytes.

## Encrypted backend envelope version 1

`YKCE` wraps one complete backend object after chunking/compression and before encrypted backend storage. Its fields are:

1. Magic `YKCE`.
2. Schema version `1`.
3. Raw 24-byte XChaCha20-Poly1305 nonce.
4. `u64` plaintext byte length.
5. A length-delimited ciphertext whose exact byte length is plaintext length plus the 16-byte authentication tag.

The external backend key is not encoded again. The caller constructs associated data from the magic/version, repository UUID, selected segment/metadata/backend-object domain, external key, canonical segment UUID when applicable, and plaintext length. Readers receive a caller byte limit, reject invalid magic/version, truncated fields, a ciphertext length inconsistent with the tag, and trailing bytes before attempting AEAD authentication. The fixed header is 46 bytes and carries public length information; callers must not trust it as authenticated metadata until complete envelope authentication succeeds. Version 1 encrypts complete objects and rejects range/resumable operations; a streaming layout requires a new format version.

## Recovery-key export version 1

`YKRK` is one portable passphrase-encrypted 32-byte repository master key. Its fields are:

1. Magic `YKRK`.
2. Schema version `1`.
3. One-byte KDF algorithm tag `1` for Argon2id v0x13.
4. One-byte AEAD algorithm tag `1` for XChaCha20-Poly1305.
5. Raw 16-byte repository UUIDv4.
6. Argon2 `u32` memory KiB `65536`, iterations `3`, and lanes `4`.
7. Raw 16-byte random salt.
8. Raw 24-byte random nonce.
9. A length-delimited 48-byte ciphertext: encrypted 32-byte master key plus 16-byte authentication tag.

Readers reject unsupported format, algorithm, parameters, invalid UUID, ciphertext length, truncation, and trailing bytes before passphrase derivation. Associated data exactly encodes every preceding cleartext field. The caller supplies a nonempty passphrase separately; no passphrase bytes are serialized.

## Encrypted repository recovery manifest version 1

`YKRM` records one immutable canonical repository-file snapshot after its file objects are acknowledged through `EncryptedBackend`. Its fields are:

1. Magic `YKRM`.
2. Schema version `1`.
3. Raw 16-byte repository UUIDv4.
4. `u32` file count.
5. Entries strictly ascending by safe relative backend key: length-delimited key bytes, `u64` plaintext file length, and raw 32-byte SHA-256 checksum.
6. Raw 32-byte SHA-256 checksum of every prior `YKRM` byte.

SQLite `metadata.sqlite3` and recognized interrupted staging names are excluded. Every other source and manifest path must be a canonical repository file name. The manifest is itself an encrypted backend object at `recovery/<repository-id>/manifest`; each file uses `recovery/<repository-id>/files/<relative-key>`. Readers apply caller file/count/total/manifest limits, reject unsorted paths, duplicate paths, noncanonical names, malformed UUIDs, invalid checksum, and trailing bytes, decrypt each named file, verify its exact length/checksum, then use ordinary repository validation and object identity checks.

## Evolution

Each new record family documents its magic, schema version, field order, limits, and feature effects before implementation. Incompatible changes require a new schema version or required feature bit and a copy-on-write migration. Existing records retain their original encoding forever.

## Whole-blob record version 1

The `YKWB` record stores one exact, verified Git blob body before segment framing exists. Its fields are:

1. Magic `YKWB`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Record type `1` for whole blob.
6. Compression method `0` for no compression.
7. One-byte plaintext-content-hash algorithm tag.
8. Raw 20-byte SHA-1 Git blob ID.
9. Raw 32-byte plaintext content digest.
10. `u64` body byte length followed by the exact body bytes.

Content-hash tags are `1` HMAC-SHA-256, `2` keyed BLAKE3, `3` SHA-256, and `4` BLAKE3. Version 1 writes and verifies only tag `3`; it rejects the other reserved tags until their key/configuration and implementation contracts exist. Callers bound the encoded record and supply a maximum decoded body length before the parser allocates. The decoder rejects nonzero feature bits, foreign record types, compression modes, malformed tags, length mismatch/truncation, trailing bytes, and mismatched Git or content IDs.

## Tiny-blob aggregation record version 1

The `YKTA` record groups at least one and at most 4,096 distinct verified Git blobs. Its fields are:

1. Magic `YKTA`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Record type `2` for tiny-blob aggregation.
6. Compression method `0` for no compression.
7. One-byte aggregate content-hash algorithm tag (`3`, SHA-256).
8. Raw 32-byte aggregate content digest.
9. Unsigned `u32` entry count.
10. Entries, strictly ascending by raw 20-byte Git blob ID: Git ID, one-byte content-hash tag (`3`), raw 32-byte entry digest, `u64` body length, and exact body bytes.

Each entry content ID is SHA-256 of its raw blob body. The aggregate content ID is SHA-256 over the domain separator `yeokcham/tiny-blob-aggregation/v1\0`, entry count, and each canonical entry field in order. The fixed maximum controls record metadata growth but does not choose a tiny-blob byte threshold; storage policy does that later. Decoders receive caller bounds for entry count and cumulative body bytes and verify every entry, strict order, and aggregate ID before trust.

## Chunk record version 1

`YKCK` stores one nonempty plaintext content-defined chunk before segment framing.
Its fields are magic `YKCK`, schema version `1`, zero required and optional
feature bitsets, a one-byte content-hash tag (`3`, SHA-256), the raw 32-byte
content digest, and one length-delimited exact body. The digest is SHA-256 of
the body. Decoders bound the body before allocation and reject empty bodies,
unsupported algorithms or features, identity mismatches, and trailing bytes.

## Chunked-blob descriptor version 1

`YKCB` binds one complete verified Git blob to its ordered immutable chunks:

1. Magic `YKCB`, schema version `1`, and zero required and optional feature bitsets.
2. Raw repository UUIDv4 and raw 20-byte Git SHA-1 blob ID.
3. One SHA-256 content identity for the complete raw blob body and its `u64` byte length.
4. A nonzero `u32` chunk count.
5. Exactly that many ordered references: a SHA-256 chunk identity, `u64` chunk length, raw segment UUIDv4, and raw 32-byte segment checksum.
6. Footer magic `YKCF` and a raw SHA-256 checksum over every preceding byte.

The sum of chunk lengths must equal the complete body length. A descriptor does
not duplicate chunk bytes. Resolution fully verifies every named `YKSG` and
`YKCK`, reconstructs the ordered bytes, then verifies the complete content and
canonical Git blob IDs. The decoder bounds the reference count and rejects
zero-length chunks, invalid identities, arithmetic overflow, checksum failure,
and trailing bytes.

## Segment record version 1

The `YKSG` segment container holds one or more already-verified `YKWB`, `YKTA`, `YKMO`, `YKCK`, or `YKCB` payloads. Its fields are:

1. Magic `YKSG`.
2. Schema version `1`.
3. Required feature bits. Bit `0` permits metadata-object records with type `3` and is set if and only if the segment contains at least one such record. No optional bits are supported.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte segment UUIDv4.
7. Unsigned `u32` record count.
8. That many records, in writer insertion order: one-byte record type (`1` whole blob, `2` tiny-blob aggregation, `3` metadata object, `4` chunk, or `5` chunked-blob descriptor), one-byte content-hash tag, raw 32-byte content digest, one-byte compression method (`0`, none), `u64` plaintext length, `u64` stored length, then the exact stored payload bytes.
9. Footer magic `YKSF`.
10. `u64` aggregate plaintext length.
11. `u64` aggregate stored length.
12. Raw 32-byte SHA-256 checksum of every preceding segment byte, including the footer fields through aggregate stored length.

Version 1 writes uncompressed payloads, so each record's plaintext and stored lengths match, and both footer totals match. The checksum detects corruption but is not authentication; later encryption/authentication requires a new format version or required feature. Writers stage a complete file, synchronize it, then create the final path without replacement. `SegmentReader` validates header identities, feature-to-record consistency, counts, types, tags, lengths, totals, nested records, checksum, and trailing bytes under caller limits before returning typed records. Indexes and manifests are defined separately.

## Segment index version 1

The `YKIX` index is rebuildable metadata for one verified `YKSG` segment. It contains magic, version, matching required feature bits, raw repository and segment UUIDv4 values, the raw 32-byte bound segment checksum, and a `u32` entry count. Entries sort strictly by tagged content identity and contain its tag/digest, record type, compression method, payload offset, plaintext length, and stored length. Required bit `0` permits type-`3` metadata-object entries and must match the associated segment. The `YKIF` footer stores aggregate plaintext/stored lengths followed by a SHA-256 checksum over every preceding index byte. Readers validate the bound identities, feature-to-entry consistency, limits, strict order, totals, checksum, and trailing bytes before lookup. An index never replaces segment verification.

Published local indexes use `indexes/<lowercase-segment-uuid>.ykix`. A writer accepts only the canonical index rebuilt from a verified matching segment, writes and synchronizes a same-directory `.<segment-uuid>.partial`, creates the final file by hard link without replacement, synchronizes the directory, and removes staging. Repeating identical bytes is idempotent; other bytes for the same segment ID conflict. Verification ignores only recognized staging names, checks each index under caller file, entry, record, and stored-byte limits, then rebuilds it from the independently decoded sealed segment before accepting it.

## Blob manifest versions 1 and 2

The `YKMF` manifest is immutable metadata for exactly one Git SHA-1 blob representation. Both versions share these fields:

1. Magic `YKMF`.
2. Schema version: `1` for whole-blob or tiny-aggregation representations, `2` for a chunked-blob descriptor.
3. Required feature bits. Bit `0` records an explicit storage-policy selection. Bit `1` is the version-2 chunked-blob feature.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte manifest UUIDv4.
7. Raw 20-byte Git SHA-1 blob ID.
8. One-byte full-blob content-hash tag (`3`, SHA-256) and raw 32-byte digest.
9. `u64` exact blob-body length.
10. One-byte representation: `1` whole blob, `2` tiny-blob aggregation, or `3` chunked blob.
11. When required feature bit `0` is set, one-byte storage policy: `1` whole blob, `2` tiny-blob aggregation, or `3` chunked blob. It must match the representation.
12. Raw 16-byte sealed segment UUIDv4.
13. Raw 32-byte SHA-256 checksum of that exact segment.
14. One-byte outer-record content-hash tag (`3`, SHA-256) and raw 32-byte digest. For whole blobs this equals the full-blob content ID; for tiny aggregations it identifies the enclosing aggregation.
15. Footer magic `YKBF`.
16. Raw 32-byte SHA-256 checksum over every preceding manifest byte.

The manifest itself contains no blob body or payload offset. Resolution first verifies a segment with the stated repository ID, segment ID, and checksum; it then locates the stated outer record and verifies the selected Git blob, content ID, and length. Version 1 permits representations `1` and `2`, optional bit `0`, and no bit `1`; legacy zero-feature V1 manifests remain readable. Version 2 permits representation `3` only and requires exactly bits `0|1`, including policy tag `3`. Whole and chunked representations require the outer-record content identity to equal the full-blob content identity; a tiny representation instead names its enclosing aggregation. The policy records the selected representation, not an unmeasured threshold. Compression, encryption, multiple outer records, or another representation require a new version or required feature.

Published local blob manifests use the canonical path `manifests/blobs/<lowercase-manifest-uuid>.ykmf`. The path identity must equal the manifest's embedded UUIDv4 identity. Publication writes and synchronizes a same-directory temporary `.<uuid>.partial`, creates the final path by hard link without replacement, synchronizes the directory, and removes the temporary name. A recovery scan ignores only such staging names, treats every other unexpected entry as corrupt, and validates each final file under caller-provided entry, file-byte, and plaintext-byte limits. SQLite is not a manifest resolver or recovery dependency.

## Tiny-blob group manifest version 1

New tiny-blob imports publish one `YKTG` mapping for each bounded `YKTA` aggregation instead of one `YKMF` file per blob. A `YKTG` mapping contains:

1. Magic `YKTG`.
2. Schema version `1`.
3. Required and optional feature bits, both `0`.
4. Raw repository UUIDv4 and raw group-manifest UUIDv4.
5. Raw sealed segment UUIDv4 and its SHA-256 checksum.
6. One-byte aggregate content-hash tag (`3`, SHA-256) and the raw 32-byte `YKTA` content digest.
7. A nonzero `u32` entry count, at most 4,096.
8. Entries strictly ascending by raw 20-byte Git blob ID: Git ID, one-byte content-hash tag (`3`), raw 32-byte body digest, and `u64` body length.
9. Footer magic `YKTF` and a raw SHA-256 checksum over every preceding mapping byte.

Published mappings use `manifests/tiny-groups/<lowercase-manifest-uuid>.yktg`, with a same-directory `.<uuid>.partial` staging name. Readers bound the file and each body length before allocation, reject malformed IDs, unsorted or duplicate entries, unsupported hashes/features, checksum failures, and trailing data, then verify the entire mapping against its one sealed `YKTA` record before accepting any entry. Lookup synthesizes the existing tiny `YKMF` representation only in memory so reconstruction and export retain their verification boundary; no synthetic file is persisted. Legacy per-blob tiny `YKMF` files remain readable. A Git object ID appearing in a legacy manifest and any group mapping, or in two mappings, is a conflict.

Local segments use `segments/<lowercase-segment-uuid>`. A manifest record resolver reads that bounded regular file, performs the complete `YKSG` parse and checksum verification, then requires its repository ID, segment ID, and checksum to equal the manifest. It locates the one typed outer record named by the manifest content ID and verifies the whole blob, selected tiny-aggregation entry, or `YKCB` descriptor against the manifest Git ID, content ID, and length. Indexes are not used to bypass segment verification.

`LocalRepository::reconstruct_blob_bytes` resolves that verified record and copies only the selected raw Git blob body. Whole-blob manifests copy their one body; tiny-aggregation manifests copy the entry named by the manifest Git ID; chunked manifests resolve and verify every descriptor chunk in order. It returns raw bytes rather than a `GitObject`; final Git-object construction and verification remain an explicit following boundary. Existing segment and record bounds cover the decoded and returned body allocation.

`LocalRepository::reconstruct_blob` applies that final boundary: it creates a blob `GitObject` with the manifest Git ID and exact reconstructed body, recomputes canonical `blob <decimal-size>\0<body>` SHA-1 bytes, and returns the object only when the ID matches. This recheck remains required even though version-1 record decoders also validate their local identities; later representations can change their internal reconstruction without weakening the export/recovery boundary.

## Metadata-object record version 1

The `YKMO` record stores one exact verified Git tree, commit, or annotated-tag body. Its fields are:

1. Magic `YKMO`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Record type `3`.
6. Git object kind: `2` tree, `3` commit, or `4` tag.
7. Compression method `0` for no compression.
8. One-byte plaintext-content-hash algorithm tag `3` for SHA-256.
9. Raw 20-byte SHA-1 Git object ID.
10. Raw 32-byte plaintext content digest.
11. `u64` body byte length followed by exact body bytes.

The plaintext digest is SHA-256 over the domain `yeokcham/metadata-object/v1\0`, the one-byte object-kind tag, the `u64` body length, and exact body bytes. This keeps non-blob content identities distinct from raw blob-body SHA-256 identities. Decoders reject blobs, feature bits, compression, unsupported hashes, ID mismatches, content mismatches, malformed lengths, and trailing bytes. Caller bounds for nested whole-blob bodies also bound these version-1 metadata-object bodies.

## Metadata-object manifest version 1

The `YKOM` manifest is immutable metadata for one tree, commit, or annotated tag. Its fields are:

1. Magic `YKOM`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 20-byte SHA-1 Git object ID.
7. One-byte Git kind: `2` tree, `3` commit, or `4` tag.
8. One-byte content-hash tag `3` and raw 32-byte metadata-object content digest.
9. `u64` exact object-body length.
10. Raw 16-byte sealed segment UUIDv4.
11. Raw 32-byte SHA-256 checksum of that exact segment.
12. Footer magic `YKOF`.
13. Raw 32-byte SHA-256 checksum over every preceding manifest byte.

Published local metadata-object manifests use `manifests/objects/<lowercase-git-sha1>.ykom`. The objects directory is optional for existing version-1 repositories and is created only on first publication. The filename must equal the embedded Git ID. Publication writes and synchronizes a same-directory temporary file, creates the final path by hard link without replacement, synchronizes the directory, and removes the temporary name. Repeating identical manifest bytes is idempotent; different bytes for the same Git ID conflict.

Metadata-object resolution reads that direct manifest under caller limits, verifies the named segment fully, binds repository ID, segment ID, and segment checksum, then selects the one type-3 record with the manifest content identity. It verifies Git ID, kind, content identity, and length before reconstructing a `GitObject` and recomputing its final canonical Git SHA-1 identity. SQLite is not a metadata-object resolver or recovery dependency.

## Ref snapshot version 1

The `YKRF` record is an immutable point-in-time recovery bridge for regular Git refs and the base state for a later append-only journal. Its fields are:

1. Magic `YKRF`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte snapshot UUIDv4.
7. One-byte `HEAD` state: `1` symbolic followed by a length-prefixed regular `refs/*` name, or `2` detached followed by a raw 20-byte Git SHA-1 ID.
8. `u64` regular-ref count.
9. That many entries, strictly ascending by raw refname bytes: length-prefixed regular `refs/*` name followed by its raw 20-byte Git SHA-1 target.
10. Footer magic `YKRH`.
11. Raw 32-byte SHA-256 checksum over every preceding snapshot byte.

Published local snapshots use `manifests/refs/<lowercase-snapshot-uuid>.ykrf`; the filename must equal the embedded snapshot ID. The directory is created on first publication. Publication first reconstructs and verifies every regular target and detached `HEAD` target under caller bounds; a symbolic `HEAD` may name an unborn branch. It stages, synchronizes, and hard-links the final file without replacement. Repeating identical publication is idempotent. The current local layout accepts exactly one final snapshot as the initial ref state: malformed, foreign, duplicate, unexpected, or nonregular entries fail recovery rather than selecting an order-dependent state. Recognized `.<uuid>.partial` staging files are ignored.

Export scans the snapshot under caller directory, file-byte, and reference-entry limits. It writes direct regular-ref files with create-new semantics, then replaces the initialized bare repository's `HEAD` with the preserved symbolic or detached form. All direct targets must already have been exported; no ref is silently dropped or retargeted. A V2 `YKRE` journal derives successor ref states from this base rather than overwriting it; the snapshot itself does not represent an update or reconciliation decision.

## Canonical Git ref state

`YKRF` snapshots and `YKRE` events embed one complete `GitRefState` without a
wrapper magic. It is a one-byte `HEAD` tag followed by either a length-delimited
regular `refs/*` name (`1`, symbolic) or a raw 20-byte Git SHA-1 ID (`2`,
detached), then a `u64` ref count and that many strictly raw-byte-ascending
entries of a length-delimited regular `refs/*` name and raw 20-byte target.
The state identity is SHA-256 of exactly these bytes. A symbolic `HEAD` may name
an unborn regular ref; no other ref kind is accepted.

## Ref events

Both `YKRE` versions begin with magic, a big-endian `u16` schema version,
required and optional `u64` feature bitsets, repository UUIDv4, device UUIDv4,
sequence, predecessor event SHA-256, expected predecessor ref-state SHA-256,
and one canonical complete ref state. They end with footer magic `YKRH` and a
SHA-256 checksum over every preceding event byte.

V1 has version `1` and zero feature bits. It has no signer or signature and
remains the format written by local `sync` and the remote helper. V2 has version
`2`, required feature bit `0` set, and zero optional feature bits. Between the
ref state and footer it stores a raw 32-byte Ed25519 public key followed by a
raw 64-byte detached signature. The signature covers every byte from `YKRE`
through and including that public key, excluding the signature, footer, and
checksum. Decoders verify the outer checksum, public key, and signature before
materializing the transition. Signature validity alone is not device
authorization.

Local events are immutable files at
`journals/refs/<20-decimal-sequence>-<device-uuid>-<64-hex-event-sha256>.ykre`.
The filename sequence, device ID, and SHA-256 event identity must equal the
decoded record. V2 events are eligible for remote authorization only after a
separate root-pinned device registry accepts their signer.

## Remote device registry version 1

`YKDR` is an immutable remote-only root-authorized device-registry event. It is
fixed-width and contains magic `YKDR`, version `1`, zero feature flags,
repository UUIDv4, positive `u64` sequence, prior event SHA-256, device UUIDv4,
and one change tag. Tag `1` registers a raw 32-byte Ed25519 verifying key and
requires zero `u64`/32-byte revocation padding. Tag `2` revokes a device and
requires zero key padding followed by its accepted `u64` sequence and 32-byte
event identity; zero is valid only with the all-zero event identity. The record
then stores a raw 64-byte root signature, footer `YKDH`, and SHA-256 checksum.
The signature covers the prefix through the change fields, excluding signature,
footer, and checksum. The operator supplies the root key out of band; the
backend cannot establish trust.

## GitHub mirror policy version 1

The optional `mirrors/github.ykgm` `YKGM` record has version `1` and zero
feature flags. It stores repository UUIDv4; length-delimited UTF-8 GitHub owner
and repository names; one direction tag; one force-update-policy tag; a sorted,
unique `u32` publication-rule sequence; and a sorted, unique `u32` checkpoint
map. Rule tags are `1` heads, `2` tags, or `3` followed by one exact standard
branch/tag refname. Each checkpoint contains its local refname, local object
ID, remote refname, remote object ID, and `u64` observed Unix seconds. It ends
with footer `YKGE` and a SHA-256 checksum. The record is bounded to 1 MiB, at
most 128 rules and 2,048 checkpoints, binds all checkpoint refs to selected
rules, and contains no credential.

## Drive object capsule version 1

`YKDO` is a physical Google Drive file prefix, not a local repository file. A
Drive object has a deterministic 64-hex opaque provider name and begins with
magic `YKDO`, version `1`, a big-endian `u16` logical-key length, a fresh raw
24-byte XChaCha20-Poly1305 nonce, and ciphertext of that logical key plus its
16-byte authentication tag. The provider name is associated data. The rest of
the Drive file is the wrapped backend object, normally a complete `YKCE`
envelope. Readers authenticate and validate the capsule before treating a
provider file as a logical backend key.
