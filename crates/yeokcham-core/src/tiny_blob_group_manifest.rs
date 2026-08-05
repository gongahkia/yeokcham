use std::fmt;

use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, ContentHashAlgorithm, Error, ErrorKind, GitObjectId,
    MAX_TINY_BLOB_AGGREGATION_ENTRIES, ManifestId, ReadSegment, RepositoryId, Result, SegmentId,
    TinyBlobAggregation, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKTG";
const FOOTER_MAGIC: [u8; 4] = *b"YKTF";
const VERSION: u16 = 1;

/// Immutable compact mapping for every entry in one tiny-blob aggregation.
///
/// One `YKTG` file replaces the per-object `YKMF` files for a bounded tiny
/// aggregation. Its entries are sorted by Git object ID and its checksum
/// protects the complete mapping before segment reconstruction begins.
#[derive(Eq, PartialEq)]
pub struct TinyBlobGroupManifest {
    repository_id: RepositoryId,
    manifest_id: ManifestId,
    segment_id: SegmentId,
    segment_checksum: [u8; 32],
    record_content_id: YeokchamContentId,
    entries: Vec<TinyBlobGroupManifestEntry>,
}

/// One exact Git blob selected from a [`TinyBlobGroupManifest`].
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct TinyBlobGroupManifestEntry {
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    plaintext_bytes: u64,
}

impl TinyBlobGroupManifest {
    /// Creates a compact manifest for a verified tiny-blob aggregation record.
    pub fn from_tiny_blob_aggregation(
        manifest_id: ManifestId,
        segment: &ReadSegment,
        aggregation: &TinyBlobAggregation,
    ) -> Result<Self> {
        let matching_records = segment
            .records()
            .iter()
            .filter(|candidate| {
                candidate
                    .as_tiny_blob_aggregation()
                    .is_some_and(|stored| stored == aggregation)
            })
            .count();
        if matching_records != 1 {
            return Err(Error::new(
                ErrorKind::NotFound,
                "verified segment does not contain exactly one tiny-blob aggregation",
            ));
        }
        let mut entries = Vec::with_capacity(aggregation.entries().len());
        for entry in aggregation.entries() {
            entries.push(TinyBlobGroupManifestEntry {
                git_object_id: entry.git_object_id(),
                content_id: entry.content_id(),
                plaintext_bytes: u64::try_from(entry.data().len()).map_err(|_| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "tiny-blob entry plaintext length is too large",
                    )
                })?,
            });
        }
        Ok(Self {
            repository_id: segment.repository_id(),
            manifest_id,
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
            record_content_id: aggregation.content_id(),
            entries,
        })
    }

    /// Decodes a caller-bounded version-1 compact tiny-blob mapping.
    pub fn decode(bytes: &[u8], maximum_plaintext_bytes: u64) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob group manifest version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob group manifest uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has an invalid repository ID",
            )
        })?;
        let manifest_id = ManifestId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has an invalid manifest ID",
            )
        })?;
        let segment_id = SegmentId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has an invalid segment ID",
            )
        })?;
        let segment_checksum = decoder.read_fixed()?;
        let record_content_id = read_sha256_content_id(&mut decoder)?;
        let entry_count = usize::try_from(decoder.read_u32()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest entry count is invalid",
            )
        })?;
        if entry_count == 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has no entries",
            ));
        }
        if entry_count > MAX_TINY_BLOB_AGGREGATION_ENTRIES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob group manifest has too many entries",
            ));
        }
        let mut entries = Vec::with_capacity(entry_count);
        let mut prior = None;
        for _ in 0..entry_count {
            let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
            if prior.is_some_and(|previous| previous >= git_object_id) {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "tiny-blob group manifest entries are not strictly sorted",
                ));
            }
            prior = Some(git_object_id);
            let content_id = read_sha256_content_id(&mut decoder)?;
            let plaintext_bytes = decoder.read_u64()?;
            if plaintext_bytes > maximum_plaintext_bytes {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "tiny-blob group manifest exceeds the plaintext-byte limit",
                ));
            }
            entries.push(TinyBlobGroupManifestEntry {
                git_object_id,
                content_id,
                plaintext_bytes,
            });
        }
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest has invalid footer magic",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest checksum is truncated",
            )
        })?;
        let actual: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob group manifest checksum does not match its bytes",
            ));
        }
        Ok(Self {
            repository_id,
            manifest_id,
            segment_id,
            segment_checksum,
            record_content_id,
            entries,
        })
    }

    /// Returns the repository identity of the referenced segment.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns this group's immutable manifest identity.
    pub const fn manifest_id(&self) -> ManifestId {
        self.manifest_id
    }

    /// Returns the sealed segment holding the aggregation record.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }

    /// Returns the checksum of the exact sealed segment.
    pub const fn segment_checksum(&self) -> [u8; 32] {
        self.segment_checksum
    }

    /// Returns the aggregation record's content identity.
    pub const fn record_content_id(&self) -> YeokchamContentId {
        self.record_content_id
    }

    /// Returns entries sorted by distinct Git object ID.
    pub fn entries(&self) -> &[TinyBlobGroupManifestEntry] {
        &self.entries
    }

    /// Returns one entry by its Git object ID.
    pub fn entry(&self, git_object_id: GitObjectId) -> Option<TinyBlobGroupManifestEntry> {
        self.entries
            .binary_search_by_key(&git_object_id, TinyBlobGroupManifestEntry::git_object_id)
            .ok()
            .map(|index| self.entries[index])
    }

    /// Returns this compact manifest's canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.manifest_id.as_bytes());
        encoder.write_fixed(self.segment_id.as_bytes());
        encoder.write_fixed(&self.segment_checksum);
        write_content_id(&mut encoder, self.record_content_id);
        encoder.write_u32(self.entries.len().try_into().expect("bounded entry count"));
        for entry in &self.entries {
            encoder.write_fixed(entry.git_object_id.as_bytes());
            write_content_id(&mut encoder, entry.content_id);
            encoder.write_u64(entry.plaintext_bytes);
        }
        encoder.write_fixed(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(encoder.as_bytes()).into();
        encoder.write_fixed(&checksum);
        encoder.into_bytes()
    }
}

impl TinyBlobGroupManifestEntry {
    /// Returns the exact Git blob identity selected by this entry.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the verified plaintext content identity.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact Git blob body length.
    pub const fn plaintext_bytes(&self) -> u64 {
        self.plaintext_bytes
    }
}

impl fmt::Debug for TinyBlobGroupManifest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TinyBlobGroupManifest")
            .field("repository_id", &self.repository_id)
            .field("manifest_id", &self.manifest_id)
            .field("segment_id", &self.segment_id)
            .field("segment_checksum", &"<redacted>")
            .field("record_content_id", &self.record_content_id)
            .field("entries", &self.entries.len())
            .finish()
    }
}

impl fmt::Debug for TinyBlobGroupManifestEntry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TinyBlobGroupManifestEntry")
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("plaintext_bytes", &self.plaintext_bytes)
            .finish()
    }
}

fn read_sha256_content_id(decoder: &mut CanonicalDecoder<'_>) -> Result<YeokchamContentId> {
    if ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?)
        != Some(ContentHashAlgorithm::Sha256)
    {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "tiny-blob group manifest content ID hash is unsupported",
        ));
    }
    Ok(YeokchamContentId::from_digest(
        ContentHashAlgorithm::Sha256,
        decoder.read_fixed()?,
    ))
}

fn write_content_id(encoder: &mut CanonicalEncoder, content_id: YeokchamContentId) {
    debug_assert_eq!(content_id.algorithm(), ContentHashAlgorithm::Sha256);
    encoder.write_u8(content_id.algorithm().binary_tag());
    encoder.write_fixed(content_id.digest());
}

#[cfg(test)]
mod tests {
    use super::*;

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const SEGMENT_ID: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    const MANIFEST_ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

    fn manifest() -> TinyBlobGroupManifest {
        TinyBlobGroupManifest {
            repository_id: REPOSITORY_ID.parse().expect("repository ID"),
            manifest_id: MANIFEST_ID.parse().expect("manifest ID"),
            segment_id: SEGMENT_ID.parse().expect("segment ID"),
            segment_checksum: [0x5a; 32],
            record_content_id: YeokchamContentId::from_digest(
                ContentHashAlgorithm::Sha256,
                [1; 32],
            ),
            entries: vec![
                TinyBlobGroupManifestEntry {
                    git_object_id: "1111111111111111111111111111111111111111"
                        .parse()
                        .expect("Git ID"),
                    content_id: YeokchamContentId::from_digest(
                        ContentHashAlgorithm::Sha256,
                        [2; 32],
                    ),
                    plaintext_bytes: 0,
                },
                TinyBlobGroupManifestEntry {
                    git_object_id: "2222222222222222222222222222222222222222"
                        .parse()
                        .expect("Git ID"),
                    content_id: YeokchamContentId::from_digest(
                        ContentHashAlgorithm::Sha256,
                        [3; 32],
                    ),
                    plaintext_bytes: 17,
                },
            ],
        }
    }

    #[test]
    fn round_trips_a_canonical_compact_mapping() {
        let manifest = manifest();
        let encoded = manifest.encode();
        let decoded = TinyBlobGroupManifest::decode(&encoded, 17).expect("decode");

        assert_eq!(&encoded[..6], b"YKTG\0\x01");
        assert_eq!(decoded, manifest);
        assert_eq!(decoded.entries().len(), 2);
        assert_eq!(
            decoded
                .entry(
                    "2222222222222222222222222222222222222222"
                        .parse()
                        .expect("Git ID")
                )
                .expect("entry")
                .plaintext_bytes(),
            17
        );
    }

    #[test]
    fn rejects_malformed_and_limited_mappings() {
        let encoded = manifest().encode();
        let mut invalid_magic = encoded.clone();
        invalid_magic[0] ^= 1;
        let mut invalid_checksum = encoded.clone();
        *invalid_checksum.last_mut().expect("checksum") ^= 1;
        let mut trailing = encoded.clone();
        trailing.push(0);

        let invalid_magic =
            TinyBlobGroupManifest::decode(&invalid_magic, 17).expect_err("invalid magic");
        let invalid_checksum =
            TinyBlobGroupManifest::decode(&invalid_checksum, 17).expect_err("checksum");
        let trailing = TinyBlobGroupManifest::decode(&trailing, 17).expect_err("trailing");
        let too_small = TinyBlobGroupManifest::decode(&encoded, 16).expect_err("size limit");

        assert_eq!(invalid_magic.kind(), ErrorKind::CorruptData);
        assert_eq!(invalid_checksum.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
        assert_eq!(too_small.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<TinyBlobGroupManifest>();
        assert_send_sync::<TinyBlobGroupManifestEntry>();
    }
}
