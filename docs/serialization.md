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
