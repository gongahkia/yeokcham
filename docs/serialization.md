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

The `YKSG` segment container holds one or more already-verified `YKWB` or `YKTA` payloads. Its fields are:

1. Magic `YKSG`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte segment UUIDv4.
7. Unsigned `u32` record count.
8. That many records, in writer insertion order: one-byte record type (`1` whole blob, `2` tiny-blob aggregation), one-byte content-hash tag, raw 32-byte content digest, one-byte compression method (`0`, none), `u64` plaintext length, `u64` stored length, then the exact stored payload bytes.
9. Footer magic `YKSF`.
10. `u64` aggregate plaintext length.
11. `u64` aggregate stored length.
12. Raw 32-byte SHA-256 checksum of every preceding segment byte, including the footer fields through aggregate stored length.

Version 1 writes uncompressed payloads, so each record's plaintext and stored lengths match, and both footer totals match. The checksum detects corruption but is not authentication; later encryption/authentication requires a new format version or required feature. Writers stage a complete file, synchronize it, then create the final path without replacement. `SegmentReader` validates header identities, counts, types, tags, lengths, totals, nested records, checksum, and trailing bytes under caller limits before returning typed records. Indexes and manifests are defined separately.

## Segment index version 1

The `YKIX` index is rebuildable metadata for one verified `YKSG` segment. It contains magic, version, zero feature bits, raw repository and segment UUIDv4 values, the raw 32-byte bound segment checksum, and a `u32` entry count. Entries sort strictly by tagged content identity and contain its tag/digest, record type, compression method, payload offset, plaintext length, and stored length. The `YKIF` footer stores aggregate plaintext/stored lengths followed by a SHA-256 checksum over every preceding index byte. Readers validate the bound identities, limits, strict order, totals, checksum, and trailing bytes before lookup. An index never replaces segment verification.

## Blob manifest version 1

The `YKMF` manifest is immutable metadata for exactly one Git SHA-1 blob representation. Its fields are:

1. Magic `YKMF`.
2. Schema version `1`.
3. Required feature bits `0`.
4. Optional feature bits `0`.
5. Raw 16-byte repository UUIDv4.
6. Raw 16-byte manifest UUIDv4.
7. Raw 20-byte Git SHA-1 blob ID.
8. One-byte full-blob content-hash tag (`3`, SHA-256) and raw 32-byte digest.
9. `u64` exact blob-body length.
10. One-byte representation: `1` whole blob or `2` tiny-blob aggregation.
11. Raw 16-byte sealed segment UUIDv4.
12. Raw 32-byte SHA-256 checksum of that exact segment.
13. One-byte outer-record content-hash tag (`3`, SHA-256) and raw 32-byte digest. For whole blobs this equals the full-blob content ID; for tiny aggregations it identifies the enclosing aggregation.
14. Footer magic `YKBF`.
15. Raw 32-byte SHA-256 checksum over every preceding manifest byte.

The manifest itself contains no blob body or payload offset. Resolution first verifies a segment with the stated repository ID, segment ID, and checksum; it then locates the stated outer record and verifies the selected Git blob, content ID, and length. Version 1 has exactly one record reference and supports only the current whole-blob and tiny-aggregation records. Chunk lists, other record families, compression, encryption, and multiple records require a new version or required feature.
