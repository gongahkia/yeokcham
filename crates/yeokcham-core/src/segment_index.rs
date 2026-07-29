use std::fmt;

use sha2::{Digest, Sha256};

use crate::segment_writer::REQUIRED_FEATURE_METADATA_OBJECT;
use crate::{
    CanonicalDecoder, CanonicalEncoder, CompressionAlgorithm, ContentHashAlgorithm, Error,
    ErrorKind, ReadSegment, RepositoryId, Result, SegmentId, SegmentRecordKind, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKIX";
const FOOTER_MAGIC: [u8; 4] = *b"YKIF";
const VERSION: u16 = 1;

/// One content-identity lookup entry in a [`SegmentIndex`].
#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub struct SegmentIndexEntry {
    content_id: YeokchamContentId,
    kind: SegmentRecordKind,
    compression: CompressionAlgorithm,
    payload_offset: u64,
    plaintext_bytes: u64,
    stored_bytes: u64,
}

impl SegmentIndexEntry {
    /// Returns the full tagged content identity used as this entry's lookup key.
    pub const fn content_id(self) -> YeokchamContentId {
        self.content_id
    }
    /// Returns the indexed record family.
    pub const fn kind(self) -> SegmentRecordKind {
        self.kind
    }
    /// Returns the indexed compression method.
    pub const fn compression(self) -> CompressionAlgorithm {
        self.compression
    }
    /// Returns the stored payload's zero-based segment offset.
    pub const fn payload_offset(self) -> u64 {
        self.payload_offset
    }
    /// Returns the payload's uncompressed length.
    pub const fn plaintext_bytes(self) -> u64 {
        self.plaintext_bytes
    }
    /// Returns the payload's stored length.
    pub const fn stored_bytes(self) -> u64 {
        self.stored_bytes
    }
}

impl fmt::Debug for SegmentIndexEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SegmentIndexEntry")
            .field("content_id", &self.content_id)
            .field("kind", &self.kind)
            .field("compression", &self.compression)
            .field("payload_offset", &self.payload_offset)
            .field("plaintext_bytes", &self.plaintext_bytes)
            .field("stored_bytes", &self.stored_bytes)
            .finish()
    }
}

/// A canonical, rebuildable lookup index for one verified immutable segment.
#[derive(Eq, PartialEq)]
pub struct SegmentIndex {
    repository_id: RepositoryId,
    segment_id: SegmentId,
    segment_checksum: [u8; 32],
    entries: Vec<SegmentIndexEntry>,
    total_plaintext_bytes: u64,
    total_stored_bytes: u64,
}

impl SegmentIndex {
    /// Builds a sorted index from one fully verified segment reader result.
    pub fn from_segment(segment: &ReadSegment) -> Result<Self> {
        if segment.records().len() != segment.locations().len() {
            return Err(Error::new(
                ErrorKind::Internal,
                "verified segment record locations are inconsistent",
            ));
        }
        let mut entries = Vec::new();
        for (record, location) in segment.records().iter().zip(segment.locations()) {
            if record.kind() != location.kind() || record.content_id() != location.content_id() {
                return Err(Error::new(
                    ErrorKind::Internal,
                    "verified segment record metadata is inconsistent",
                ));
            }
            entries.push(SegmentIndexEntry {
                content_id: location.content_id(),
                kind: location.kind(),
                compression: location.compression(),
                payload_offset: location.payload_offset(),
                plaintext_bytes: location.plaintext_bytes(),
                stored_bytes: location.stored_bytes(),
            });
        }
        entries.sort_by_key(|entry| entry.content_id);
        if entries
            .windows(2)
            .any(|pair| pair[0].content_id == pair[1].content_id)
        {
            return Err(Error::new(
                ErrorKind::Conflict,
                "segment contains duplicate content identities",
            ));
        }
        Ok(Self {
            repository_id: segment.repository_id(),
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
            entries,
            total_plaintext_bytes: segment.total_plaintext_bytes(),
            total_stored_bytes: segment.total_stored_bytes(),
        })
    }

    /// Decodes one caller-bounded canonical index.
    pub fn decode(
        bytes: &[u8],
        maximum_entries: usize,
        maximum_total_stored_bytes: u64,
    ) -> Result<Self> {
        let mut d = CanonicalDecoder::new(bytes);
        if d.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index has invalid magic",
            ));
        }
        if d.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment index version is unsupported",
            ));
        }
        let required_features = d.read_u64()?;
        if required_features & !REQUIRED_FEATURE_METADATA_OBJECT != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment index uses unsupported features",
            ));
        }
        if d.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment index uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(d.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "segment index has an invalid repository ID",
            )
        })?;
        let segment_id = SegmentId::from_bytes(d.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "segment index has an invalid segment ID",
            )
        })?;
        let segment_checksum = d.read_fixed()?;
        let count = usize::try_from(d.read_u32()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "segment index entry count is invalid",
            )
        })?;
        if count == 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index has no entries",
            ));
        }
        if count > maximum_entries {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment index exceeds the entry limit",
            ));
        }
        let mut entries = Vec::new();
        let mut total_plaintext_bytes = 0u64;
        let mut total_stored_bytes = 0u64;
        let mut has_metadata_object_entry = false;
        for _ in 0..count {
            let algorithm =
                ContentHashAlgorithm::from_binary_tag(d.read_u8()?).ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "segment index has an invalid content hash algorithm",
                    )
                })?;
            let content_id = YeokchamContentId::from_digest(algorithm, d.read_fixed()?);
            let kind = SegmentRecordKind::from_binary_tag(d.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "segment index has an invalid record type",
                )
            })?;
            let compression = CompressionAlgorithm::from_binary_tag(d.read_u8()?)?;
            if compression != CompressionAlgorithm::None {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "segment index compression is unsupported",
                ));
            }
            let payload_offset = d.read_u64()?;
            let plaintext_bytes = d.read_u64()?;
            let stored_bytes = d.read_u64()?;
            if plaintext_bytes != stored_bytes {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "segment index uncompressed lengths do not match",
                ));
            }
            if kind == SegmentRecordKind::MetadataObject {
                if required_features & REQUIRED_FEATURE_METADATA_OBJECT == 0 {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "segment index metadata-object entry lacks its required feature",
                    ));
                }
                has_metadata_object_entry = true;
            }
            total_plaintext_bytes = total_plaintext_bytes
                .checked_add(plaintext_bytes)
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "segment index plaintext total is invalid",
                    )
                })?;
            total_stored_bytes = total_stored_bytes
                .checked_add(stored_bytes)
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "segment index stored total is invalid",
                    )
                })?;
            if total_stored_bytes > maximum_total_stored_bytes {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "segment index exceeds the stored-byte limit",
                ));
            }
            entries.push(SegmentIndexEntry {
                content_id,
                kind,
                compression,
                payload_offset,
                plaintext_bytes,
                stored_bytes,
            });
        }
        if required_features & REQUIRED_FEATURE_METADATA_OBJECT != 0 && !has_metadata_object_entry {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index metadata-object feature has no matching entry",
            ));
        }
        if d.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index has invalid footer magic",
            ));
        }
        let footer_plaintext_bytes = d.read_u64()?;
        let footer_stored_bytes = d.read_u64()?;
        let checksum = d.read_fixed::<32>()?;
        d.finish()?;
        if footer_plaintext_bytes != total_plaintext_bytes
            || footer_stored_bytes != total_stored_bytes
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index footer totals do not match entries",
            ));
        }
        if entries
            .windows(2)
            .any(|pair| pair[0].content_id >= pair[1].content_id)
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index entries are not strictly sorted",
            ));
        }
        let prefix_length = bytes.len().checked_sub(32).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "segment index checksum is truncated",
            )
        })?;
        let actual: [u8; 32] = Sha256::digest(&bytes[..prefix_length]).into();
        if checksum != actual {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment index checksum does not match its bytes",
            ));
        }
        Ok(Self {
            repository_id,
            segment_id,
            segment_checksum,
            entries,
            total_plaintext_bytes,
            total_stored_bytes,
        })
    }

    /// Returns this index's bound repository identity.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }
    /// Returns this index's bound segment identity.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }
    /// Returns the checksum of the exact segment indexed by this value.
    pub const fn segment_checksum(&self) -> [u8; 32] {
        self.segment_checksum
    }
    /// Returns entries sorted by tagged content identity.
    pub fn entries(&self) -> &[SegmentIndexEntry] {
        &self.entries
    }
    /// Looks up one exact tagged content identity.
    pub fn lookup(&self, id: YeokchamContentId) -> Option<SegmentIndexEntry> {
        self.entries
            .binary_search_by_key(&id, |entry| entry.content_id)
            .ok()
            .map(|index| self.entries[index])
    }
    /// Returns this index's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut e = CanonicalEncoder::new();
        e.write_fixed(&MAGIC);
        e.write_u16(VERSION);
        e.write_u64(required_features_for_entries(&self.entries));
        e.write_u64(0);
        e.write_fixed(self.repository_id.as_bytes());
        e.write_fixed(self.segment_id.as_bytes());
        e.write_fixed(&self.segment_checksum);
        e.write_u32(self.entries.len() as u32);
        for entry in &self.entries {
            e.write_u8(entry.content_id.algorithm().binary_tag());
            e.write_fixed(entry.content_id.digest());
            e.write_u8(entry.kind.binary_tag());
            e.write_u8(entry.compression.binary_tag());
            e.write_u64(entry.payload_offset);
            e.write_u64(entry.plaintext_bytes);
            e.write_u64(entry.stored_bytes);
        }
        e.write_fixed(&FOOTER_MAGIC);
        e.write_u64(self.total_plaintext_bytes);
        e.write_u64(self.total_stored_bytes);
        let checksum: [u8; 32] = Sha256::digest(e.as_bytes()).into();
        e.write_fixed(&checksum);
        e.into_bytes()
    }
}

fn required_features_for_entries(entries: &[SegmentIndexEntry]) -> u64 {
    if entries
        .iter()
        .any(|entry| entry.kind == SegmentRecordKind::MetadataObject)
    {
        REQUIRED_FEATURE_METADATA_OBJECT
    } else {
        0
    }
}

impl fmt::Debug for SegmentIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SegmentIndex")
            .field("repository_id", &self.repository_id)
            .field("segment_id", &self.segment_id)
            .field("entry_count", &self.entries.len())
            .field("segment_checksum", &"<redacted>")
            .field("entries", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use sha2::{Digest, Sha256};
    use uuid::Uuid;

    use super::*;
    use crate::{
        GitObject, GitObjectId, GitObjectKind, SegmentReadLimits, SegmentReader, SegmentRecord,
        SegmentWriteLimits, SegmentWriter, MetadataObjectRecord, WholeBlobRecord,
    };

    const HEADER_BYTES: usize = 90;
    const ENTRY_BYTES: usize = 59;

    fn whole_blob(data: &[u8]) -> SegmentRecord {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Blob,
            data.to_vec(),
        );
        let object = GitObject::new(
            provisional.recompute_id(),
            GitObjectKind::Blob,
            data.to_vec(),
        );
        SegmentRecord::from_whole_blob(
            &WholeBlobRecord::from_verified_blob(&object).expect("whole blob"),
        )
        .expect("segment record")
    }

    fn metadata_object(data: &[u8]) -> SegmentRecord {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Commit,
            data.to_vec(),
        );
        let object = GitObject::new(
            provisional.recompute_id(),
            GitObjectKind::Commit,
            data.to_vec(),
        );
        SegmentRecord::from_metadata_object(
            &MetadataObjectRecord::from_verified_object(&object).expect("metadata object"),
        )
        .expect("segment record")
    }

    fn index(records: Vec<SegmentRecord>) -> (SegmentIndex, [u8; 32]) {
        let maximum_stored_bytes = records.iter().map(SegmentRecord::stored_len).sum();
        let record_count = records.len();
        let directory = std::env::temp_dir().join(format!("yeokcham-index-{}", Uuid::new_v4()));
        fs::create_dir(&directory).expect("directory");
        let mut writer = SegmentWriter::new(
            "550e8400-e29b-41d4-a716-446655440000"
                .parse()
                .expect("repository ID"),
            "6ba7b814-9dad-41d1-80b4-00c04fd430c8"
                .parse()
                .expect("segment ID"),
            SegmentWriteLimits::new(record_count, maximum_stored_bytes).expect("limits"),
        );
        for record in records {
            writer.add(record).expect("add");
        }
        let path = directory.join("segment");
        writer.seal_to(&path).expect("seal");
        let bytes = fs::read(path).expect("segment bytes");
        let segment = SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(
                record_count,
                maximum_stored_bytes,
                usize::try_from(maximum_stored_bytes).expect("stored bytes"),
                1024,
                1024,
                1024,
            )
            .expect("limits"),
        )
        .expect("segment");
        let checksum = segment.checksum();
        let _ = fs::remove_dir_all(&directory);
        (
            SegmentIndex::from_segment(&segment).expect("index"),
            checksum,
        )
    }

    #[test]
    fn round_trips_canonical_lookup_index() {
        let (index, _) = index(vec![whole_blob(&[])]);
        let encoded = index.encode();
        let decoded = SegmentIndex::decode(&encoded, 1, 85).expect("decode");

        assert_eq!(decoded, index);
        assert_eq!(decoded.entries().len(), 1);
        assert_eq!(
            decoded.lookup(decoded.entries()[0].content_id()),
            Some(decoded.entries()[0])
        );
        assert_eq!(decoded.entries()[0].payload_offset(), 109);
        assert_eq!(decoded.entries()[0].stored_bytes(), 85);
    }

    #[test]
    fn rejects_index_limits_and_corruption() {
        let encoded = index(vec![whole_blob(&[])]).0.encode();
        let limited = SegmentIndex::decode(&encoded, 0, 85).expect_err("entry limit");
        let mut footer_totals = encoded.clone();
        let footer_total_offset = footer_totals.len() - 48;
        footer_totals[footer_total_offset] ^= 1;
        let footer_totals = SegmentIndex::decode(&footer_totals, 1, 85).expect_err("footer totals");
        let mut corrupt = encoded.clone();
        let final_byte = corrupt.len() - 1;
        corrupt[final_byte] ^= 1;
        let corrupt = SegmentIndex::decode(&corrupt, 1, 85).expect_err("checksum");
        let mut trailing = encoded;
        trailing.push(0);
        let trailing = SegmentIndex::decode(&trailing, 1, 85).expect_err("trailing");

        assert_eq!(limited.kind(), ErrorKind::Unsupported);
        assert_eq!(footer_totals.kind(), ErrorKind::CorruptData);
        assert_eq!(corrupt.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn rejects_duplicate_or_out_of_order_content_id_entries() {
        let (index, _) = index(vec![whole_blob(&[]), whole_blob(b"x")]);
        let mut encoded = index.encode();
        let first_content_id = encoded[HEADER_BYTES..HEADER_BYTES + 33].to_vec();
        encoded[HEADER_BYTES + ENTRY_BYTES..HEADER_BYTES + ENTRY_BYTES + 33]
            .copy_from_slice(&first_content_id);

        let error = SegmentIndex::decode(&encoded, 2, 171).expect_err("duplicate entries");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            error.public_message(),
            "segment index entries are not strictly sorted"
        );
    }

    #[test]
    fn binds_verified_segment_checksum_and_redacts_diagnostics() {
        let (index, segment_checksum) = index(vec![whole_blob(&[])]);
        let encoded = index.encode();
        let diagnostic = format!("{index:?}");

        assert_eq!(index.segment_checksum(), segment_checksum);
        assert_eq!(&encoded[54..86], segment_checksum);
        assert!(diagnostic.contains("<redacted>"));
        assert!(!diagnostic.contains("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    }

    #[test]
    fn metadata_object_entries_require_the_segment_feature() {
        let (index, _) = index(vec![metadata_object(b"tree \0commit")]);
        let encoded = index.encode();
        assert_eq!(
            u64::from_be_bytes(encoded[6..14].try_into().expect("required features")),
            REQUIRED_FEATURE_METADATA_OBJECT
        );
        let decoded = SegmentIndex::decode(&encoded, 1, 1024).expect("decode index");
        assert_eq!(decoded.entries()[0].kind(), SegmentRecordKind::MetadataObject);

        let mut missing_feature = encoded;
        missing_feature[6..14].copy_from_slice(&0u64.to_be_bytes());
        let checksum_offset = missing_feature.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&missing_feature[..checksum_offset]).into();
        missing_feature[checksum_offset..].copy_from_slice(&checksum);
        let error =
            SegmentIndex::decode(&missing_feature, 1, 1024).expect_err("missing required feature");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn index_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<SegmentIndex>();
        assert_send_sync::<SegmentIndexEntry>();
    }
}
