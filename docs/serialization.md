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

## Segment record version 1

The `YKSG` segment container holds one or more already-verified `YKWB`, `YKTA`, or `YKMO` payloads. Its fields are:

1. Magic `YKSG`.
2. Schema version `1`.
3. Required feature bits. Bit `0` permits metadata-object records with type `3`; segments without that bit contain only the original blob record families.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte segment UUIDv4.
7. Unsigned `u32` record count.
8. That many records, in writer insertion order: one-byte record type (`1` whole blob, `2` tiny-blob aggregation, `3` metadata object), one-byte content-hash tag, raw 32-byte content digest, one-byte compression method (`0`, none), `u64` plaintext length, `u64` stored length, then the exact stored payload bytes.
9. Footer magic `YKSF`.
10. `u64` aggregate plaintext length.
11. `u64` aggregate stored length.
12. Raw 32-byte SHA-256 checksum of every preceding segment byte, including the footer fields through aggregate stored length.

Version 1 writes uncompressed payloads, so each record's plaintext and stored lengths match, and both footer totals match. The checksum detects corruption but is not authentication; later encryption/authentication requires a new format version or required feature. Writers stage a complete file, synchronize it, then create the final path without replacement. `SegmentReader` validates header identities, feature-to-record consistency, counts, types, tags, lengths, totals, nested records, checksum, and trailing bytes under caller limits before returning typed records. Indexes and manifests are defined separately.

## Segment index version 1

The `YKIX` index is rebuildable metadata for one verified `YKSG` segment. It contains magic, version, matching required feature bits, raw repository and segment UUIDv4 values, the raw 32-byte bound segment checksum, and a `u32` entry count. Entries sort strictly by tagged content identity and contain its tag/digest, record type, compression method, payload offset, plaintext length, and stored length. Required bit `0` permits type-`3` metadata-object entries and must match the associated segment. The `YKIF` footer stores aggregate plaintext/stored lengths followed by a SHA-256 checksum over every preceding index byte. Readers validate the bound identities, feature-to-entry consistency, limits, strict order, totals, checksum, and trailing bytes before lookup. An index never replaces segment verification.

Published local indexes use `indexes/<lowercase-segment-uuid>.ykix`. A writer accepts only the canonical index rebuilt from a verified matching segment, writes and synchronizes a same-directory `.<segment-uuid>.partial`, creates the final file by hard link without replacement, synchronizes the directory, and removes staging. Repeating identical bytes is idempotent; other bytes for the same segment ID conflict. Verification ignores only recognized staging names, checks each index under caller file, entry, record, and stored-byte limits, then rebuilds it from the independently decoded sealed segment before accepting it.

## Blob manifest version 1

The `YKMF` manifest is immutable metadata for exactly one Git SHA-1 blob representation. Its fields are:

1. Magic `YKMF`.
2. Schema version `1`.
3. Required feature bits. Bit `0` records an explicit storage-policy selection; new writers set it, while pre-policy version-1 manifests retain `0`.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte manifest UUIDv4.
7. Raw 20-byte Git SHA-1 blob ID.
8. One-byte full-blob content-hash tag (`3`, SHA-256) and raw 32-byte digest.
9. `u64` exact blob-body length.
10. One-byte representation: `1` whole blob or `2` tiny-blob aggregation.
11. When required feature bit `0` is set, one-byte storage policy: `1` whole blob or `2` tiny-blob aggregation. It must match the representation.
12. Raw 16-byte sealed segment UUIDv4.
13. Raw 32-byte SHA-256 checksum of that exact segment.
14. One-byte outer-record content-hash tag (`3`, SHA-256) and raw 32-byte digest. For whole blobs this equals the full-blob content ID; for tiny aggregations it identifies the enclosing aggregation.
15. Footer magic `YKBF`.
16. Raw 32-byte SHA-256 checksum over every preceding manifest byte.

The manifest itself contains no blob body or payload offset. Resolution first verifies a segment with the stated repository ID, segment ID, and checksum; it then locates the stated outer record and verifies the selected Git blob, content ID, and length. Version 1 has exactly one record reference and supports only the current whole-blob and tiny-aggregation records. The policy feature records the selected current representation but no unmeasured threshold; content-defined chunk parameters and other policy inputs require their own later feature or version. Chunk lists, other record families, compression, encryption, and multiple records require a new version or required feature.

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

Version-1 local segments use `segments/<lowercase-segment-uuid>`. A manifest record resolver reads that bounded regular file, performs the complete `YKSG` parse and checksum verification, then requires its repository ID, segment ID, and checksum to equal the manifest. It locates the one typed outer record named by the manifest content ID and verifies the whole blob or selected tiny-aggregation entry against the manifest Git ID, content ID, and length. Indexes are not used to bypass segment verification.

`LocalRepository::reconstruct_blob_bytes` resolves that verified record and copies only the selected raw Git blob body. Whole-blob manifests copy their one body; tiny-aggregation manifests copy the entry named by the manifest Git ID. It returns raw bytes rather than a `GitObject`; final Git-object construction and verification remain an explicit following boundary. Existing segment and record bounds cover the decoded and returned body allocation.

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

The `YKRF` record is an immutable point-in-time recovery bridge for regular Git refs before append-only journal events exist. Its fields are:

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

Published local snapshots use `manifests/refs/<lowercase-snapshot-uuid>.ykrf`; the filename must equal the embedded snapshot ID. The directory is created on first publication. Publication first reconstructs and verifies every regular target and detached `HEAD` target under caller bounds; a symbolic `HEAD` may name an unborn branch. It stages, synchronizes, and hard-links the final file without replacement. Repeating identical publication is idempotent. The current V1 layout accepts exactly one final snapshot: malformed, foreign, duplicate, unexpected, or nonregular entries fail recovery rather than selecting an order-dependent state. Recognized `.<uuid>.partial` staging files are ignored.

Export scans the snapshot under caller directory, file-byte, and reference-entry limits. It writes direct regular-ref files with create-new semantics, then replaces the initialized bare repository's `HEAD` with the preserved symbolic or detached form. All direct targets must already have been exported; no ref is silently dropped or retargeted. This bridge is superseded by the append-only journal design in Milestone 3; it does not represent ref updates or reconciliation.

## Ref events

Both `YKRE` versions begin with magic, a big-endian `u16` schema version, required and optional `u64` feature bitsets, repository UUIDv4, device UUIDv4, sequence, predecessor event SHA-256, expected predecessor ref-state SHA-256, and one canonical complete `GitRefState` using the ref-state encoding above. They end with footer magic `YKRH` and a SHA-256 checksum over every preceding event byte.

V1 has version `1` and zero feature bits. It has no signer or signature and remains the format written by local `sync` and the remote helper.

V2 has version `2`, required feature bit `0` set, and zero optional feature bits. Between the canonical ref state and footer it stores a raw 32-byte Ed25519 public key followed by a raw 64-byte detached Ed25519 signature. The signature covers every byte from `YKRE` through and including that public key, excluding the signature, footer, and checksum. Decoders must check the outer SHA-256 checksum, validate the public key, and verify the signature before materializing the transition. Signature validity alone is not device authorization; key registration, policy, and revocation are separate future formats.
