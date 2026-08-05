use std::fmt;

use sha2::{Digest, Sha256};

use crate::segment_writer::{FOOTER_MAGIC, MAGIC, REQUIRED_FEATURE_METADATA_OBJECT, VERSION};
use crate::{
    CanonicalDecoder, ChunkRecord, ChunkedBlobRecord, CompressionAlgorithm, ContentHashAlgorithm,
    Error, ErrorKind, MetadataObjectRecord, RepositoryId, Result, SegmentId, SegmentRecordKind,
    TinyBlobAggregation, WholeBlobRecord, YeokchamContentId,
};

/// Caller-selected bounds for decoding one immutable segment.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SegmentReadLimits {
    maximum_records: usize,
    maximum_total_plaintext_bytes: u64,
    maximum_total_stored_bytes: usize,
    maximum_whole_blob_body_bytes: usize,
    maximum_tiny_blob_entries: usize,
    maximum_tiny_blob_body_bytes: usize,
}

/// Verified byte location and metadata for one record inside a segment.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SegmentRecordLocation {
    kind: SegmentRecordKind,
    content_id: YeokchamContentId,
    compression: CompressionAlgorithm,
    payload_offset: u64,
    plaintext_bytes: u64,
    stored_bytes: u64,
}

impl SegmentRecordLocation {
    /// Returns the payload family at this location.
    pub const fn kind(self) -> SegmentRecordKind {
        self.kind
    }

    /// Returns the verified plaintext content identity at this location.
    pub const fn content_id(self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the compression method declared for this payload.
    pub const fn compression(self) -> CompressionAlgorithm {
        self.compression
    }

    /// Returns the zero-based segment byte offset of the stored payload.
    pub const fn payload_offset(self) -> u64 {
        self.payload_offset
    }

    /// Returns the uncompressed payload length.
    pub const fn plaintext_bytes(self) -> u64 {
        self.plaintext_bytes
    }

    /// Returns the stored payload length.
    pub const fn stored_bytes(self) -> u64 {
        self.stored_bytes
    }
}

impl SegmentReadLimits {
    /// Validates bounds for one segment and its nested records.
    pub fn new(
        maximum_records: usize,
        maximum_total_plaintext_bytes: u64,
        maximum_total_stored_bytes: usize,
        maximum_whole_blob_body_bytes: usize,
        maximum_tiny_blob_entries: usize,
        maximum_tiny_blob_body_bytes: usize,
    ) -> Result<Self> {
        if maximum_records == 0 || u32::try_from(maximum_records).is_err() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment record limit is invalid",
            ));
        }
        if maximum_total_stored_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment stored-byte limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_records,
            maximum_total_plaintext_bytes,
            maximum_total_stored_bytes,
            maximum_whole_blob_body_bytes,
            maximum_tiny_blob_entries,
            maximum_tiny_blob_body_bytes,
        })
    }

    /// Returns the maximum outer record count.
    pub const fn maximum_records(self) -> usize {
        self.maximum_records
    }

    /// Returns the maximum aggregate plaintext payload length.
    pub const fn maximum_total_plaintext_bytes(self) -> u64 {
        self.maximum_total_plaintext_bytes
    }

    /// Returns the maximum aggregate stored payload length.
    pub const fn maximum_total_stored_bytes(self) -> usize {
        self.maximum_total_stored_bytes
    }

    /// Returns the maximum nested whole-blob body length.
    pub const fn maximum_whole_blob_body_bytes(self) -> usize {
        self.maximum_whole_blob_body_bytes
    }

    /// Returns the maximum entry count for one nested tiny-blob aggregation.
    pub const fn maximum_tiny_blob_entries(self) -> usize {
        self.maximum_tiny_blob_entries
    }

    /// Returns the maximum body bytes for one nested tiny-blob aggregation.
    pub const fn maximum_tiny_blob_body_bytes(self) -> usize {
        self.maximum_tiny_blob_body_bytes
    }
}

/// One independently verified nested record read from a segment.
#[derive(Eq, PartialEq)]
pub enum ReadSegmentRecord {
    /// A verified whole-blob record.
    WholeBlob(WholeBlobRecord),
    /// A verified tiny-blob aggregation.
    TinyBlobAggregation(TinyBlobAggregation),
    /// A verified non-blob Git object record.
    MetadataObject(MetadataObjectRecord),
    /// A verified independently addressed chunk record.
    Chunk(ChunkRecord),
    /// A structurally verified chunked-blob descriptor record.
    ChunkedBlob(ChunkedBlobRecord),
}

impl ReadSegmentRecord {
    /// Returns the payload family declared by this record.
    pub const fn kind(&self) -> SegmentRecordKind {
        match self {
            Self::WholeBlob(_) => SegmentRecordKind::WholeBlob,
            Self::TinyBlobAggregation(_) => SegmentRecordKind::TinyBlobAggregation,
            Self::MetadataObject(_) => SegmentRecordKind::MetadataObject,
            Self::Chunk(_) => SegmentRecordKind::Chunk,
            Self::ChunkedBlob(_) => SegmentRecordKind::ChunkedBlob,
        }
    }

    /// Returns the verified plaintext content identity for this record.
    pub const fn content_id(&self) -> YeokchamContentId {
        match self {
            Self::WholeBlob(record) => record.content_id(),
            Self::TinyBlobAggregation(record) => record.content_id(),
            Self::MetadataObject(record) => record.content_id(),
            Self::Chunk(record) => record.content_id(),
            Self::ChunkedBlob(record) => record.content_id(),
        }
    }

    /// Returns the whole-blob record when this is that payload family.
    pub const fn as_whole_blob(&self) -> Option<&WholeBlobRecord> {
        match self {
            Self::WholeBlob(record) => Some(record),
            Self::TinyBlobAggregation(_)
            | Self::MetadataObject(_)
            | Self::Chunk(_)
            | Self::ChunkedBlob(_) => None,
        }
    }

    /// Returns the tiny-blob aggregation when this is that payload family.
    pub const fn as_tiny_blob_aggregation(&self) -> Option<&TinyBlobAggregation> {
        match self {
            Self::WholeBlob(_) | Self::Chunk(_) | Self::ChunkedBlob(_) => None,
            Self::TinyBlobAggregation(record) => Some(record),
            Self::MetadataObject(_) => None,
        }
    }

    /// Returns the non-blob Git object record when this is that payload family.
    pub const fn as_metadata_object(&self) -> Option<&MetadataObjectRecord> {
        match self {
            Self::MetadataObject(record) => Some(record),
            Self::WholeBlob(_)
            | Self::TinyBlobAggregation(_)
            | Self::Chunk(_)
            | Self::ChunkedBlob(_) => None,
        }
    }

    /// Returns the chunk record when this is that payload family.
    pub const fn as_chunk(&self) -> Option<&ChunkRecord> {
        match self {
            Self::Chunk(record) => Some(record),
            Self::WholeBlob(_)
            | Self::TinyBlobAggregation(_)
            | Self::MetadataObject(_)
            | Self::ChunkedBlob(_) => None,
        }
    }

    /// Returns the chunked-blob descriptor when this is that payload family.
    pub const fn as_chunked_blob(&self) -> Option<&ChunkedBlobRecord> {
        match self {
            Self::ChunkedBlob(record) => Some(record),
            Self::WholeBlob(_)
            | Self::TinyBlobAggregation(_)
            | Self::MetadataObject(_)
            | Self::Chunk(_) => None,
        }
    }
}

impl fmt::Debug for ReadSegmentRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReadSegmentRecord")
            .field("kind", &self.kind())
            .field("content_id", &self.content_id())
            .field("payload", &"<redacted>")
            .finish()
    }
}

/// A fully parsed and verified immutable segment.
#[derive(Eq, PartialEq)]
pub struct ReadSegment {
    repository_id: RepositoryId,
    segment_id: SegmentId,
    records: Vec<ReadSegmentRecord>,
    locations: Vec<SegmentRecordLocation>,
    total_plaintext_bytes: u64,
    total_stored_bytes: u64,
    checksum: [u8; 32],
}

impl ReadSegment {
    /// Returns the repository identity bound in the segment header.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the segment identity bound in the segment header.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }

    /// Returns verified records in their immutable insertion order.
    pub fn records(&self) -> &[ReadSegmentRecord] {
        &self.records
    }

    /// Consumes this verified segment and returns records in insertion order.
    pub fn into_records(self) -> Vec<ReadSegmentRecord> {
        self.records
    }

    /// Returns verified record locations in the same order as [`records`](Self::records).
    pub fn locations(&self) -> &[SegmentRecordLocation] {
        &self.locations
    }

    /// Returns the verified aggregate plaintext payload length.
    pub const fn total_plaintext_bytes(&self) -> u64 {
        self.total_plaintext_bytes
    }

    /// Returns the verified aggregate stored payload length.
    pub const fn total_stored_bytes(&self) -> u64 {
        self.total_stored_bytes
    }

    /// Returns the SHA-256 checksum verified over the segment prefix.
    pub const fn checksum(&self) -> [u8; 32] {
        self.checksum
    }
}

impl fmt::Debug for ReadSegment {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReadSegment")
            .field("repository_id", &self.repository_id)
            .field("segment_id", &self.segment_id)
            .field("record_count", &self.records.len())
            .field("total_plaintext_bytes", &self.total_plaintext_bytes)
            .field("total_stored_bytes", &self.total_stored_bytes)
            .field("checksum", &"<redacted>")
            .field("records", &"<redacted>")
            .finish()
    }
}

/// Parses and verifies bounded `YKSG` version-1 segment bytes.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub struct SegmentReader;

impl SegmentReader {
    /// Decodes one caller-bounded segment and all of its nested records.
    pub fn decode(bytes: &[u8], limits: SegmentReadLimits) -> Result<ReadSegment> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment version is unsupported",
            ));
        }
        let required_features = decoder.read_u64()?;
        if required_features & !REQUIRED_FEATURE_METADATA_OBJECT != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment uses unsupported features",
            ));
        }
        if decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "segment has an invalid repository ID",
            )
        })?;
        let segment_id = SegmentId::from_bytes(decoder.read_fixed()?)
            .map_err(|_| Error::new(ErrorKind::CorruptData, "segment has an invalid segment ID"))?;
        let record_count = usize::try_from(decoder.read_u32()?)
            .map_err(|_| Error::new(ErrorKind::CorruptData, "segment record count is invalid"))?;
        if record_count == 0 {
            return Err(Error::new(ErrorKind::CorruptData, "segment has no records"));
        }
        if record_count > limits.maximum_records {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment exceeds the record limit",
            ));
        }

        let mut records = Vec::new();
        let mut locations = Vec::new();
        let mut total_plaintext_bytes = 0u64;
        let mut total_stored_bytes = 0usize;
        let mut has_metadata_object_record = false;
        for _ in 0..record_count {
            let kind = SegmentRecordKind::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                Error::new(ErrorKind::CorruptData, "segment has an invalid record type")
            })?;
            let algorithm =
                ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "segment has an invalid content hash algorithm",
                    )
                })?;
            let content_id = YeokchamContentId::from_digest(algorithm, decoder.read_fixed()?);
            let compression = CompressionAlgorithm::from_binary_tag(decoder.read_u8()?)?;
            if compression != CompressionAlgorithm::None {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "segment compression is unsupported",
                ));
            }
            let plaintext_bytes = decoder.read_u64()?;
            let stored_bytes = decoder.read_u64()?;
            if plaintext_bytes != stored_bytes {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "segment uncompressed lengths do not match",
                ));
            }
            let stored_bytes_usize = usize::try_from(stored_bytes).map_err(|_| {
                Error::new(ErrorKind::CorruptData, "segment stored length is invalid")
            })?;
            total_plaintext_bytes = total_plaintext_bytes
                .checked_add(plaintext_bytes)
                .ok_or_else(|| {
                    Error::new(ErrorKind::CorruptData, "segment plaintext total is invalid")
                })?;
            if total_plaintext_bytes > limits.maximum_total_plaintext_bytes {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "segment exceeds the plaintext-byte limit",
                ));
            }
            total_stored_bytes = total_stored_bytes
                .checked_add(stored_bytes_usize)
                .ok_or_else(|| {
                    Error::new(ErrorKind::CorruptData, "segment stored total is invalid")
                })?;
            if total_stored_bytes > limits.maximum_total_stored_bytes {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "segment exceeds the stored-byte limit",
                ));
            }
            let payload_offset = u64::try_from(decoder.consumed_len()).map_err(|_| {
                Error::new(ErrorKind::CorruptData, "segment payload offset is invalid")
            })?;
            let payload = decoder.read_raw_bytes(stored_bytes_usize)?;
            let record = decode_record(kind, payload, limits)?;
            if kind == SegmentRecordKind::MetadataObject {
                if required_features & REQUIRED_FEATURE_METADATA_OBJECT == 0 {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "segment metadata-object record lacks its required feature",
                    ));
                }
                has_metadata_object_record = true;
            }
            if record.content_id() != content_id {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "segment record content ID does not match its payload",
                ));
            }
            locations.push(SegmentRecordLocation {
                kind,
                content_id,
                compression,
                payload_offset,
                plaintext_bytes,
                stored_bytes,
            });
            records.push(record);
        }
        if required_features & REQUIRED_FEATURE_METADATA_OBJECT != 0 && !has_metadata_object_record
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment metadata-object feature has no matching record",
            ));
        }

        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment has invalid footer magic",
            ));
        }
        let footer_plaintext_bytes = decoder.read_u64()?;
        let footer_stored_bytes = decoder.read_u64()?;
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        if footer_plaintext_bytes != total_plaintext_bytes
            || footer_stored_bytes
                != u64::try_from(total_stored_bytes).map_err(|_| {
                    Error::new(ErrorKind::CorruptData, "segment stored total is invalid")
                })?
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment footer totals do not match records",
            ));
        }
        let checksum_offset = bytes
            .len()
            .checked_sub(checksum.len())
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "segment checksum is truncated"))?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if actual_checksum != checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment checksum does not match its bytes",
            ));
        }
        Ok(ReadSegment {
            repository_id,
            segment_id,
            records,
            locations,
            total_plaintext_bytes,
            total_stored_bytes: u64::try_from(total_stored_bytes).map_err(|_| {
                Error::new(ErrorKind::CorruptData, "segment stored total is invalid")
            })?,
            checksum,
        })
    }
}

fn decode_record(
    kind: SegmentRecordKind,
    payload: &[u8],
    limits: SegmentReadLimits,
) -> Result<ReadSegmentRecord> {
    match kind {
        SegmentRecordKind::WholeBlob => Ok(ReadSegmentRecord::WholeBlob(WholeBlobRecord::decode(
            payload,
            limits.maximum_whole_blob_body_bytes,
        )?)),
        SegmentRecordKind::TinyBlobAggregation => Ok(ReadSegmentRecord::TinyBlobAggregation(
            TinyBlobAggregation::decode(
                payload,
                limits.maximum_tiny_blob_entries,
                limits.maximum_tiny_blob_body_bytes,
            )?,
        )),
        SegmentRecordKind::MetadataObject => Ok(ReadSegmentRecord::MetadataObject(
            MetadataObjectRecord::decode(payload, limits.maximum_whole_blob_body_bytes)?,
        )),
        SegmentRecordKind::Chunk => Ok(ReadSegmentRecord::Chunk(ChunkRecord::decode(
            payload,
            limits.maximum_whole_blob_body_bytes,
        )?)),
        SegmentRecordKind::ChunkedBlob => Ok(ReadSegmentRecord::ChunkedBlob(
            ChunkedBlobRecord::decode(payload, limits.maximum_tiny_blob_entries)?,
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use sha2::{Digest, Sha256};
    use uuid::Uuid;

    use super::*;
    use crate::{
        GitObject, GitObjectId, GitObjectKind, MetadataObjectRecord, SegmentRecord,
        SegmentWriteLimits, SegmentWriter,
    };

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const SEGMENT_ID: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    const EMPTY_BLOB_ID: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-reader-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn limits() -> SegmentReadLimits {
        SegmentReadLimits::new(4, 4_096, 4_096, 4_096, 4_096, 4_096).expect("valid limits")
    }

    fn empty_whole_blob() -> WholeBlobRecord {
        let object = GitObject::new(
            EMPTY_BLOB_ID.parse::<GitObjectId>().expect("empty blob ID"),
            GitObjectKind::Blob,
            Vec::new(),
        );
        WholeBlobRecord::from_verified_blob(&object).expect("whole blob")
    }

    fn verified_blob(data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Blob,
            data.to_vec(),
        );
        GitObject::new(
            provisional.recompute_id(),
            GitObjectKind::Blob,
            data.to_vec(),
        )
    }

    fn writer_bytes_for(record: SegmentRecord) -> (Vec<u8>, [u8; 32]) {
        let directory = TestDirectory::new();
        let destination = directory.0.join("segment");
        let mut writer = SegmentWriter::new(
            REPOSITORY_ID.parse().expect("repository ID"),
            SEGMENT_ID.parse().expect("segment ID"),
            SegmentWriteLimits::new(1, record.stored_len()).expect("write limits"),
        );
        writer.add(record).expect("add record");
        let sealed = writer.seal_to(&destination).expect("seal segment");
        (
            fs::read(destination).expect("read segment"),
            sealed.checksum(),
        )
    }

    fn writer_bytes() -> (Vec<u8>, [u8; 32]) {
        writer_bytes_for(
            SegmentRecord::from_whole_blob(&empty_whole_blob()).expect("segment record"),
        )
    }

    #[test]
    fn reads_a_writer_produced_segment_and_preserves_typed_records() {
        let (bytes, checksum) = writer_bytes();
        let segment = SegmentReader::decode(&bytes, limits()).expect("read segment");

        assert_eq!(segment.repository_id().to_string(), REPOSITORY_ID);
        assert_eq!(segment.segment_id().to_string(), SEGMENT_ID);
        assert_eq!(segment.records().len(), 1);
        assert_eq!(segment.locations().len(), 1);
        assert_eq!(segment.records()[0].kind(), SegmentRecordKind::WholeBlob);
        assert_eq!(
            segment.records()[0].content_id(),
            empty_whole_blob().content_id()
        );
        assert_eq!(
            segment.records()[0]
                .as_whole_blob()
                .expect("whole blob")
                .data(),
            b""
        );
        assert!(segment.records()[0].as_tiny_blob_aggregation().is_none());
        assert_eq!(segment.total_plaintext_bytes(), 85);
        assert_eq!(segment.total_stored_bytes(), 85);
        assert_eq!(segment.checksum(), checksum);
        assert_eq!(segment.locations()[0].payload_offset(), 109);
        assert_eq!(segment.locations()[0].plaintext_bytes(), 85);
        assert_eq!(segment.locations()[0].stored_bytes(), 85);
    }

    #[test]
    fn rejects_invalid_limits_and_caller_limits() {
        for limits in [
            SegmentReadLimits::new(0, 1, 1, 0, 0, 0),
            SegmentReadLimits::new(1, 1, 0, 0, 0, 0),
        ] {
            assert_eq!(
                limits.expect_err("invalid limits").kind(),
                ErrorKind::InvalidInput
            );
        }
        let (bytes, _) = writer_bytes();
        let plaintext_limited = SegmentReadLimits::new(1, 84, 85, 0, 0, 0).expect("limits");
        let stored_limited = SegmentReadLimits::new(1, 85, 84, 0, 0, 0).expect("limits");

        assert_eq!(
            SegmentReader::decode(&bytes, plaintext_limited)
                .expect_err("plaintext limit")
                .kind(),
            ErrorKind::Unsupported
        );
        assert_eq!(
            SegmentReader::decode(&bytes, stored_limited)
                .expect_err("stored limit")
                .kind(),
            ErrorKind::Unsupported
        );
    }

    #[test]
    fn reads_a_writer_produced_tiny_blob_aggregation() {
        let aggregation = TinyBlobAggregation::from_verified_blobs(&[
            verified_blob(b"private tiny body"),
            verified_blob(b"\0\xff"),
        ])
        .expect("aggregation");
        let (bytes, _) = writer_bytes_for(
            SegmentRecord::from_tiny_blob_aggregation(&aggregation).expect("segment record"),
        );
        let segment = SegmentReader::decode(&bytes, limits()).expect("read segment");
        let record = segment.records()[0]
            .as_tiny_blob_aggregation()
            .expect("tiny aggregation");

        assert_eq!(record, &aggregation);
        assert_eq!(record.entries().len(), 2);
        assert_eq!(record.content_id(), aggregation.content_id());
    }

    #[test]
    fn reads_metadata_object_records_only_with_the_required_feature() {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Commit,
            b"tree \0commit\xff".to_vec(),
        );
        let object = GitObject::new(
            provisional.recompute_id(),
            GitObjectKind::Commit,
            provisional.data().to_vec(),
        );
        let metadata =
            MetadataObjectRecord::from_verified_object(&object).expect("metadata record");
        let (bytes, _) = writer_bytes_for(
            SegmentRecord::from_metadata_object(&metadata).expect("segment record"),
        );
        assert_eq!(
            u64::from_be_bytes(bytes[6..14].try_into().expect("required features")),
            REQUIRED_FEATURE_METADATA_OBJECT
        );
        let segment = SegmentReader::decode(&bytes, limits()).expect("read metadata segment");
        let record = segment.records()[0]
            .as_metadata_object()
            .expect("metadata record type");
        assert_eq!(record, &metadata);

        let mut missing_feature = bytes;
        missing_feature[6..14].copy_from_slice(&0u64.to_be_bytes());
        let checksum_offset = missing_feature.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&missing_feature[..checksum_offset]).into();
        missing_feature[checksum_offset..].copy_from_slice(&checksum);
        let error = SegmentReader::decode(&missing_feature, limits())
            .expect_err("missing required feature");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn rejects_corrupt_headers_records_footer_checksum_and_trailing_bytes() {
        let (encoded, _) = writer_bytes();
        let cases = [
            (0, b'X', ErrorKind::CorruptData),
            (5, 2, ErrorKind::Unsupported),
            (6, 1, ErrorKind::Unsupported),
            (28, 0, ErrorKind::CorruptData),
            (58, 0, ErrorKind::CorruptData),
            (59, 0, ErrorKind::CorruptData),
            (92, 1, ErrorKind::Unsupported),
            (194, b'X', ErrorKind::CorruptData),
            (
                encoded.len() - 1,
                encoded[encoded.len() - 1] ^ 1,
                ErrorKind::CorruptData,
            ),
        ];

        for (offset, replacement, kind) in cases {
            let mut malformed = encoded.clone();
            malformed[offset] = replacement;
            let error = SegmentReader::decode(&malformed, limits()).expect_err("malformed segment");
            assert_eq!(error.kind(), kind, "offset {offset}");
        }
        let truncated = SegmentReader::decode(&encoded[..encoded.len() - 1], limits())
            .expect_err("truncated segment");
        let mut trailing = encoded;
        trailing.push(0);
        let trailing = SegmentReader::decode(&trailing, limits()).expect_err("trailing segment");

        assert_eq!(truncated.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn rejects_length_and_nested_content_identity_mismatches() {
        let (encoded, _) = writer_bytes();
        let mut length_mismatch = encoded.clone();
        length_mismatch[108] = 86;
        let mut identity_mismatch = encoded;
        identity_mismatch[60] ^= 1;

        assert_eq!(
            SegmentReader::decode(&length_mismatch, limits())
                .expect_err("length mismatch")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            SegmentReader::decode(&identity_mismatch, limits())
                .expect_err("content identity mismatch")
                .kind(),
            ErrorKind::CorruptData
        );
    }

    #[test]
    fn rejects_payload_tampering_after_recomputing_the_segment_checksum() {
        let record = WholeBlobRecord::from_verified_blob(&verified_blob(b"private payload"))
            .expect("whole blob");
        let (mut encoded, _) =
            writer_bytes_for(SegmentRecord::from_whole_blob(&record).expect("segment record"));
        let segment = SegmentReader::decode(&encoded, limits()).expect("read segment");
        let location = segment.locations()[0];
        let payload_start = usize::try_from(location.payload_offset()).expect("payload offset");
        let payload_len = usize::try_from(location.stored_bytes()).expect("payload length");
        encoded[payload_start + payload_len - 1] ^= 1;
        let checksum_offset = encoded.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&encoded[..checksum_offset]).into();
        encoded[checksum_offset..].copy_from_slice(&checksum);

        assert_eq!(
            SegmentReader::decode(&encoded, limits())
                .expect_err("rechecks nested blob identity")
                .kind(),
            ErrorKind::CorruptData
        );
    }

    #[test]
    fn debug_output_redacts_payloads_and_identifiers() {
        let whole_blob =
            WholeBlobRecord::from_verified_blob(&verified_blob(b"private reader body"))
                .expect("whole blob");
        let (bytes, _) =
            writer_bytes_for(SegmentRecord::from_whole_blob(&whole_blob).expect("segment record"));
        let segment = SegmentReader::decode(&bytes, limits()).expect("read segment");

        assert!(!format!("{segment:?}").contains(REPOSITORY_ID));
        assert!(!format!("{segment:?}").contains(SEGMENT_ID));
        assert!(!format!("{:?}", segment.records()[0]).contains("e69de29"));
        assert!(!format!("{segment:?}").contains("private reader body"));
    }

    #[test]
    fn reader_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<SegmentReadLimits>();
        assert_send_sync::<ReadSegmentRecord>();
        assert_send_sync::<ReadSegment>();
        assert_send_sync::<SegmentReader>();
    }
}
