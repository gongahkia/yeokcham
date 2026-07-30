use std::fmt;

use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, ChunkedBlobRecord, ContentHashAlgorithm, Error, ErrorKind,
    GitObjectId, ManifestId, ReadSegment, RepositoryId, Result, SegmentId, TinyBlobAggregation,
    WholeBlobRecord, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKMF";
const FOOTER_MAGIC: [u8; 4] = *b"YKBF";
const VERSION_V1: u16 = 1;
const VERSION_V2: u16 = 2;
const STORAGE_POLICY_FEATURE: u64 = 1;
const CHUNKED_BLOB_FEATURE: u64 = 1 << 1;

/// The verified record family referenced by a [`BlobManifest`].
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[non_exhaustive]
pub enum BlobManifestRepresentation {
    /// One whole-blob record contains the complete blob body.
    WholeBlob,
    /// One tiny-blob aggregation contains the selected blob entry.
    TinyBlobAggregation,
    /// One chunked-blob descriptor references ordered chunk records.
    ChunkedBlob,
}

impl BlobManifestRepresentation {
    const fn binary_tag(self) -> u8 {
        match self {
            Self::WholeBlob => 1,
            Self::TinyBlobAggregation => 2,
            Self::ChunkedBlob => 3,
        }
    }

    const fn from_binary_tag(tag: u8) -> Option<Self> {
        match tag {
            1 => Some(Self::WholeBlob),
            2 => Some(Self::TinyBlobAggregation),
            3 => Some(Self::ChunkedBlob),
            _ => None,
        }
    }
}

/// The explicit storage-policy selection recorded for one blob manifest.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[non_exhaustive]
pub enum BlobStoragePolicyDecision {
    /// Store the blob as one whole-blob record.
    WholeBlob,
    /// Store the blob as one entry in a tiny-blob aggregation.
    TinyBlobAggregation,
    /// Store the blob through a content-defined chunk descriptor.
    ChunkedBlob,
}

impl BlobStoragePolicyDecision {
    const fn binary_tag(self) -> u8 {
        match self {
            Self::WholeBlob => 1,
            Self::TinyBlobAggregation => 2,
            Self::ChunkedBlob => 3,
        }
    }

    const fn from_binary_tag(tag: u8) -> Option<Self> {
        match tag {
            1 => Some(Self::WholeBlob),
            2 => Some(Self::TinyBlobAggregation),
            3 => Some(Self::ChunkedBlob),
            _ => None,
        }
    }

    const fn representation(self) -> BlobManifestRepresentation {
        match self {
            Self::WholeBlob => BlobManifestRepresentation::WholeBlob,
            Self::TinyBlobAggregation => BlobManifestRepresentation::TinyBlobAggregation,
            Self::ChunkedBlob => BlobManifestRepresentation::ChunkedBlob,
        }
    }
}

/// An immutable, checksum-protected reference to one exact Git blob body.
///
/// Version 1 references one verified record in one sealed segment. A whole
/// blob references its body content identity directly; a tiny blob references
/// the aggregation identity and uses the manifest Git ID to select its entry.
#[derive(Eq, PartialEq)]
pub struct BlobManifest {
    repository_id: RepositoryId,
    manifest_id: ManifestId,
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    plaintext_bytes: u64,
    representation: BlobManifestRepresentation,
    storage_policy: Option<BlobStoragePolicyDecision>,
    segment_id: SegmentId,
    segment_checksum: [u8; 32],
    record_content_id: YeokchamContentId,
}

impl BlobManifest {
    /// Creates a manifest for a whole-blob record found in a verified segment.
    pub fn from_whole_blob(
        manifest_id: ManifestId,
        segment: &ReadSegment,
        record: &WholeBlobRecord,
    ) -> Result<Self> {
        let representation = BlobManifestRepresentation::WholeBlob;
        ensure_whole_blob_record(segment, record)?;
        Ok(Self {
            repository_id: segment.repository_id(),
            manifest_id,
            git_object_id: record.git_object_id(),
            content_id: record.content_id(),
            plaintext_bytes: checked_plaintext_bytes(record.data().len())?,
            representation,
            storage_policy: Some(BlobStoragePolicyDecision::WholeBlob),
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
            record_content_id: record.content_id(),
        })
    }

    /// Creates a manifest for one blob entry in a verified tiny aggregation.
    pub fn from_tiny_blob_aggregation(
        manifest_id: ManifestId,
        segment: &ReadSegment,
        aggregation: &TinyBlobAggregation,
        git_object_id: GitObjectId,
    ) -> Result<Self> {
        let representation = BlobManifestRepresentation::TinyBlobAggregation;
        ensure_tiny_blob_aggregation(segment, aggregation)?;
        let entry = aggregation
            .entries()
            .iter()
            .find(|entry| entry.git_object_id() == git_object_id)
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::NotFound,
                    "tiny-blob aggregation does not contain the manifest blob",
                )
            })?;
        Ok(Self {
            repository_id: segment.repository_id(),
            manifest_id,
            git_object_id,
            content_id: entry.content_id(),
            plaintext_bytes: checked_plaintext_bytes(entry.data().len())?,
            representation,
            storage_policy: Some(BlobStoragePolicyDecision::TinyBlobAggregation),
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
            record_content_id: aggregation.content_id(),
        })
    }

    /// Creates a manifest for a chunked-blob descriptor found in a verified segment.
    pub fn from_chunked_blob(
        manifest_id: ManifestId,
        segment: &ReadSegment,
        record: &ChunkedBlobRecord,
    ) -> Result<Self> {
        let representation = BlobManifestRepresentation::ChunkedBlob;
        ensure_chunked_blob_record(segment, record)?;
        Ok(Self {
            repository_id: segment.repository_id(),
            manifest_id,
            git_object_id: record.git_object_id(),
            content_id: record.content_id(),
            plaintext_bytes: record.plaintext_bytes(),
            representation,
            storage_policy: Some(BlobStoragePolicyDecision::ChunkedBlob),
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
            record_content_id: record.content_id(),
        })
    }

    /// Decodes one caller-bounded version-1 or version-2 blob manifest.
    pub fn decode(bytes: &[u8], maximum_plaintext_bytes: u64) -> Result<Self> {
        let mut d = CanonicalDecoder::new(bytes);
        if d.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest has invalid magic",
            ));
        }
        let version = d.read_u16()?;
        if !matches!(version, VERSION_V1 | VERSION_V2) {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "blob manifest version is unsupported",
            ));
        }
        let required_features = d.read_u64()?;
        if required_features & !(STORAGE_POLICY_FEATURE | CHUNKED_BLOB_FEATURE) != 0
            || d.read_u64()? != 0
        {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "blob manifest uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(d.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "blob manifest has an invalid repository ID",
            )
        })?;
        let manifest_id = ManifestId::from_bytes(d.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "blob manifest has an invalid manifest ID",
            )
        })?;
        let git_object_id = GitObjectId::from_bytes(d.read_fixed()?);
        let content_id = read_sha256_content_id(&mut d)?;
        let plaintext_bytes = d.read_u64()?;
        if plaintext_bytes > maximum_plaintext_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "blob manifest exceeds the plaintext-byte limit",
            ));
        }
        let representation =
            BlobManifestRepresentation::from_binary_tag(d.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "blob manifest has an invalid representation",
                )
            })?;
        if representation == BlobManifestRepresentation::ChunkedBlob {
            if version != VERSION_V2
                || required_features != STORAGE_POLICY_FEATURE | CHUNKED_BLOB_FEATURE
            {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "chunked blob manifest requires version 2 support",
                ));
            }
        } else if version != VERSION_V1 || required_features & CHUNKED_BLOB_FEATURE != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "blob manifest version is unsupported for its representation",
            ));
        }
        let storage_policy = if required_features & STORAGE_POLICY_FEATURE != 0 {
            let policy =
                BlobStoragePolicyDecision::from_binary_tag(d.read_u8()?).ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "blob manifest has an invalid storage policy",
                    )
                })?;
            if policy.representation() != representation {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "blob manifest storage policy does not match its representation",
                ));
            }
            Some(policy)
        } else {
            None
        };
        let segment_id = SegmentId::from_bytes(d.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "blob manifest has an invalid segment ID",
            )
        })?;
        let segment_checksum = d.read_fixed()?;
        let record_content_id = read_sha256_content_id(&mut d)?;
        if matches!(
            representation,
            BlobManifestRepresentation::WholeBlob | BlobManifestRepresentation::ChunkedBlob
        ) && record_content_id != content_id
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "whole-blob manifest record identity does not match blob content",
            ));
        }
        if d.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest has invalid footer magic",
            ));
        }
        let checksum = d.read_fixed::<32>()?;
        d.finish()?;
        let prefix_length = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "blob manifest checksum is truncated",
            )
        })?;
        let actual: [u8; 32] = Sha256::digest(&bytes[..prefix_length]).into();
        if checksum != actual {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest checksum does not match its bytes",
            ));
        }
        Ok(Self {
            repository_id,
            manifest_id,
            git_object_id,
            content_id,
            plaintext_bytes,
            representation,
            storage_policy,
            segment_id,
            segment_checksum,
            record_content_id,
        })
    }

    /// Returns the repository identity of the referenced segment.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns this immutable representation's opaque manifest identity.
    pub const fn manifest_id(&self) -> ManifestId {
        self.manifest_id
    }

    /// Returns the exact Git blob identity reconstructed from this manifest.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the verified plaintext content identity for the selected blob.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact uncompressed Git blob body length.
    pub const fn plaintext_bytes(&self) -> u64 {
        self.plaintext_bytes
    }

    /// Returns the record family that stores the selected blob.
    pub const fn representation(&self) -> BlobManifestRepresentation {
        self.representation
    }

    /// Returns the explicit policy selection, if this manifest records one.
    ///
    /// Zero-feature version-1 manifests created before the storage-policy
    /// feature was introduced remain readable and return `None`.
    pub const fn storage_policy(&self) -> Option<BlobStoragePolicyDecision> {
        self.storage_policy
    }

    /// Returns the sealed segment identity containing the referenced record.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }

    /// Returns the checksum of the exact sealed segment required by this manifest.
    pub const fn segment_checksum(&self) -> [u8; 32] {
        self.segment_checksum
    }

    /// Returns the outer segment record content identity used for lookup.
    pub const fn record_content_id(&self) -> YeokchamContentId {
        self.record_content_id
    }

    /// Returns this manifest's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut e = CanonicalEncoder::new();
        e.write_fixed(&MAGIC);
        let is_chunked = self.representation == BlobManifestRepresentation::ChunkedBlob;
        e.write_u16(if is_chunked { VERSION_V2 } else { VERSION_V1 });
        e.write_u64(match (self.storage_policy.is_some(), is_chunked) {
            (false, false) => 0,
            (true, false) => STORAGE_POLICY_FEATURE,
            (true, true) => STORAGE_POLICY_FEATURE | CHUNKED_BLOB_FEATURE,
            (false, true) => unreachable!("chunked manifests always record their storage policy"),
        });
        e.write_u64(0);
        e.write_fixed(self.repository_id.as_bytes());
        e.write_fixed(self.manifest_id.as_bytes());
        e.write_fixed(self.git_object_id.as_bytes());
        write_content_id(&mut e, self.content_id);
        e.write_u64(self.plaintext_bytes);
        e.write_u8(self.representation.binary_tag());
        if let Some(policy) = self.storage_policy {
            e.write_u8(policy.binary_tag());
        }
        e.write_fixed(self.segment_id.as_bytes());
        e.write_fixed(&self.segment_checksum);
        write_content_id(&mut e, self.record_content_id);
        e.write_fixed(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(e.as_bytes()).into();
        e.write_fixed(&checksum);
        e.into_bytes()
    }
}

fn ensure_whole_blob_record(segment: &ReadSegment, record: &WholeBlobRecord) -> Result<()> {
    if segment.records().iter().any(|candidate| {
        candidate
            .as_whole_blob()
            .is_some_and(|stored| stored == record)
    }) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorKind::NotFound,
            "verified segment does not contain the manifest record",
        ))
    }
}

fn ensure_tiny_blob_aggregation(
    segment: &ReadSegment,
    aggregation: &TinyBlobAggregation,
) -> Result<()> {
    if segment.records().iter().any(|candidate| {
        candidate
            .as_tiny_blob_aggregation()
            .is_some_and(|stored| stored == aggregation)
    }) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorKind::NotFound,
            "verified segment does not contain the manifest record",
        ))
    }
}

fn ensure_chunked_blob_record(segment: &ReadSegment, record: &ChunkedBlobRecord) -> Result<()> {
    if record.repository_id() != segment.repository_id() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "chunked-blob record belongs to a different repository",
        ));
    }
    if segment.records().iter().any(|candidate| {
        candidate
            .as_chunked_blob()
            .is_some_and(|stored| stored == record)
    }) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorKind::NotFound,
            "verified segment does not contain the manifest record",
        ))
    }
}

fn checked_plaintext_bytes(length: usize) -> Result<u64> {
    u64::try_from(length).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "blob manifest plaintext length is too large",
        )
    })
}

fn read_sha256_content_id(d: &mut CanonicalDecoder<'_>) -> Result<YeokchamContentId> {
    let algorithm = ContentHashAlgorithm::from_binary_tag(d.read_u8()?).ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "blob manifest has an invalid content hash algorithm",
        )
    })?;
    if algorithm != ContentHashAlgorithm::Sha256 {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "blob manifest uses an unsupported content hash",
        ));
    }
    Ok(YeokchamContentId::from_digest(algorithm, d.read_fixed()?))
}

fn write_content_id(e: &mut CanonicalEncoder, content_id: YeokchamContentId) {
    e.write_u8(content_id.algorithm().binary_tag());
    e.write_fixed(content_id.digest());
}

impl fmt::Debug for BlobManifest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlobManifest")
            .field("repository_id", &self.repository_id)
            .field("manifest_id", &self.manifest_id)
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("plaintext_bytes", &self.plaintext_bytes)
            .field("representation", &self.representation)
            .field("storage_policy", &self.storage_policy)
            .field("segment_id", &self.segment_id)
            .field("segment_checksum", &"<redacted>")
            .field("record_content_id", &self.record_content_id)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use sha2::{Digest, Sha256};
    use uuid::Uuid;

    use super::*;
    use crate::{
        GitObject, GitObjectKind, SegmentReadLimits, SegmentReader, SegmentRecord,
        SegmentWriteLimits, SegmentWriter,
    };

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const SEGMENT_ID: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    const MANIFEST_ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";
    const HEADER_BYTES: usize = 198;
    const POLICY_OFFSET: usize = 116;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-manifest-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("directory");
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
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

    fn segment(records: Vec<SegmentRecord>) -> ReadSegment {
        let record_count = records.len();
        let maximum_stored_bytes = records.iter().map(SegmentRecord::stored_len).sum();
        let directory = TestDirectory::new();
        let path = directory.0.join("segment");
        let mut writer = SegmentWriter::new(
            REPOSITORY_ID.parse().expect("repository ID"),
            SEGMENT_ID.parse().expect("segment ID"),
            SegmentWriteLimits::new(record_count, maximum_stored_bytes).expect("limits"),
        );
        for record in records {
            writer.add(record).expect("record");
        }
        writer.seal_to(&path).expect("seal");
        let bytes = fs::read(path).expect("read");
        SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(
                record_count,
                maximum_stored_bytes,
                usize::try_from(maximum_stored_bytes).expect("stored bytes"),
                4_096,
                4_096,
                4_096,
            )
            .expect("limits"),
        )
        .expect("segment")
    }

    fn whole_manifest() -> BlobManifest {
        let object = verified_blob(b"\0private blob\xff\n");
        let record = WholeBlobRecord::from_verified_blob(&object).expect("whole record");
        let segment = segment(vec![
            SegmentRecord::from_whole_blob(&record).expect("segment record"),
        ]);
        BlobManifest::from_whole_blob(MANIFEST_ID.parse().expect("manifest ID"), &segment, &record)
            .expect("manifest")
    }

    #[test]
    fn round_trips_a_canonical_whole_blob_manifest() {
        let manifest = whole_manifest();
        let encoded = manifest.encode();
        let decoded = BlobManifest::decode(&encoded, 4_096).expect("decode");

        assert_eq!(encoded.len(), HEADER_BYTES + 36);
        assert_eq!(&encoded[..6], b"YKMF\0\x01");
        assert_eq!(decoded, manifest);
        assert_eq!(
            decoded.representation(),
            BlobManifestRepresentation::WholeBlob
        );
        assert_eq!(
            decoded.storage_policy(),
            Some(BlobStoragePolicyDecision::WholeBlob)
        );
        assert_eq!(decoded.record_content_id(), decoded.content_id());
        assert_eq!(decoded.segment_id().to_string(), SEGMENT_ID);
        assert_eq!(decoded.repository_id().to_string(), REPOSITORY_ID);
    }

    #[test]
    fn references_one_verified_tiny_blob_entry() {
        let first = verified_blob(b"first");
        let selected = verified_blob(b"\0selected\xff");
        let selected_id = selected.id();
        let selected_length = selected.data().len() as u64;
        let aggregation =
            TinyBlobAggregation::from_verified_blobs(&[first, selected]).expect("aggregation");
        let segment = segment(vec![
            SegmentRecord::from_tiny_blob_aggregation(&aggregation).expect("segment record"),
        ]);
        let manifest = BlobManifest::from_tiny_blob_aggregation(
            MANIFEST_ID.parse().expect("manifest ID"),
            &segment,
            &aggregation,
            selected_id,
        )
        .expect("manifest");

        assert_eq!(
            manifest.representation(),
            BlobManifestRepresentation::TinyBlobAggregation
        );
        assert_eq!(manifest.git_object_id(), selected_id);
        assert_eq!(manifest.plaintext_bytes(), selected_length);
        assert_eq!(
            manifest.storage_policy(),
            Some(BlobStoragePolicyDecision::TinyBlobAggregation)
        );
        assert_eq!(manifest.record_content_id(), aggregation.content_id());
        assert_eq!(
            BlobManifest::decode(&manifest.encode(), 4_096).expect("decode"),
            manifest
        );
    }

    #[test]
    fn rejects_missing_segment_records_and_tiny_entries() {
        let object = verified_blob(b"whole");
        let record = WholeBlobRecord::from_verified_blob(&object).expect("whole record");
        let unrelated = segment(vec![
            SegmentRecord::from_whole_blob(
                &WholeBlobRecord::from_verified_blob(&verified_blob(b"other")).expect("record"),
            )
            .expect("segment record"),
        ]);
        let missing_record = BlobManifest::from_whole_blob(
            MANIFEST_ID.parse().expect("manifest ID"),
            &unrelated,
            &record,
        )
        .expect_err("missing record");

        let aggregation = TinyBlobAggregation::from_verified_blobs(&[verified_blob(b"tiny")])
            .expect("aggregation");
        let tiny_segment = segment(vec![
            SegmentRecord::from_tiny_blob_aggregation(&aggregation).expect("segment record"),
        ]);
        let missing_entry = BlobManifest::from_tiny_blob_aggregation(
            MANIFEST_ID.parse().expect("manifest ID"),
            &tiny_segment,
            &aggregation,
            object.id(),
        )
        .expect_err("missing entry");

        assert_eq!(missing_record.kind(), ErrorKind::NotFound);
        assert_eq!(missing_entry.kind(), ErrorKind::NotFound);
    }

    #[test]
    fn rejects_malformed_limited_and_corrupt_encodings() {
        let encoded = whole_manifest().encode();
        let mut invalid_magic = encoded.clone();
        invalid_magic[0] ^= 1;
        let mut unsupported_version = encoded.clone();
        unsupported_version[5] = 2;
        let mut unsupported_features = encoded.clone();
        unsupported_features[6] = 1;
        let mut exceeded_limit = encoded.clone();
        exceeded_limit[107..115].copy_from_slice(&u64::MAX.to_be_bytes());
        let mut invalid_representation = encoded.clone();
        invalid_representation[115] = 0;
        let mut invalid_policy = encoded.clone();
        invalid_policy[POLICY_OFFSET] = 0;
        let mut mismatched_policy = encoded.clone();
        mismatched_policy[POLICY_OFFSET] = 2;
        let mut unsupported_content_hash = encoded.clone();
        unsupported_content_hash[74] = 1;
        let mut mismatched_whole_record = encoded.clone();
        mismatched_whole_record[166] ^= 1;
        let mut invalid_footer = encoded.clone();
        invalid_footer[HEADER_BYTES] ^= 1;
        let mut invalid_checksum = encoded.clone();
        let final_byte = invalid_checksum.len() - 1;
        invalid_checksum[final_byte] ^= 1;
        let mut trailing = encoded;
        trailing.push(0);

        let invalid_magic = BlobManifest::decode(&invalid_magic, 4_096).expect_err("magic");
        let unsupported_version =
            BlobManifest::decode(&unsupported_version, 4_096).expect_err("version");
        let unsupported_features =
            BlobManifest::decode(&unsupported_features, 4_096).expect_err("features");
        let exceeded_limit = BlobManifest::decode(&exceeded_limit, 4_096).expect_err("limit");
        let invalid_representation =
            BlobManifest::decode(&invalid_representation, 4_096).expect_err("representation");
        let invalid_policy = BlobManifest::decode(&invalid_policy, 4_096).expect_err("policy");
        let mismatched_policy =
            BlobManifest::decode(&mismatched_policy, 4_096).expect_err("mismatched policy");
        let unsupported_content_hash =
            BlobManifest::decode(&unsupported_content_hash, 4_096).expect_err("content hash");
        let mismatched_whole_record =
            BlobManifest::decode(&mismatched_whole_record, 4_096).expect_err("record ID");
        let invalid_footer = BlobManifest::decode(&invalid_footer, 4_096).expect_err("footer");
        let invalid_checksum =
            BlobManifest::decode(&invalid_checksum, 4_096).expect_err("checksum");
        let trailing = BlobManifest::decode(&trailing, 4_096).expect_err("trailing");

        assert_eq!(invalid_magic.kind(), ErrorKind::CorruptData);
        assert_eq!(unsupported_version.kind(), ErrorKind::Unsupported);
        assert_eq!(unsupported_features.kind(), ErrorKind::Unsupported);
        assert_eq!(exceeded_limit.kind(), ErrorKind::Unsupported);
        assert_eq!(invalid_representation.kind(), ErrorKind::CorruptData);
        assert_eq!(invalid_policy.kind(), ErrorKind::CorruptData);
        assert_eq!(mismatched_policy.kind(), ErrorKind::CorruptData);
        assert_eq!(unsupported_content_hash.kind(), ErrorKind::Unsupported);
        assert_eq!(mismatched_whole_record.kind(), ErrorKind::CorruptData);
        assert_eq!(invalid_footer.kind(), ErrorKind::CorruptData);
        assert_eq!(invalid_checksum.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn preserves_legacy_zero_feature_manifests_without_a_policy() {
        let mut encoded = whole_manifest().encode();
        encoded[6..14].copy_from_slice(&0u64.to_be_bytes());
        encoded.remove(POLICY_OFFSET);
        let checksum_offset = encoded.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&encoded[..checksum_offset]).into();
        encoded[checksum_offset..].copy_from_slice(&checksum);

        let decoded = BlobManifest::decode(&encoded, 4_096).expect("legacy manifest");

        assert_eq!(decoded.storage_policy(), None);
        assert_eq!(decoded.encode(), encoded);
    }

    #[test]
    fn redacts_manifest_diagnostics_and_is_send_sync() {
        let manifest = whole_manifest();
        let diagnostic = format!("{manifest:?}");

        assert!(diagnostic.contains("<redacted>"));
        assert!(!diagnostic.contains("private blob"));
        assert!(!diagnostic.contains(&manifest.git_object_id().to_string()));

        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<BlobManifest>();
        assert_send_sync::<BlobManifestRepresentation>();
        assert_send_sync::<BlobStoragePolicyDecision>();
    }
}
