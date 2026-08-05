use std::fmt;

use sha2::{Digest, Sha256};

use crate::metadata_object_record::{metadata_object_kind_from_tag, metadata_object_kind_tag};
use crate::{
    CanonicalDecoder, CanonicalEncoder, ContentHashAlgorithm, Error, ErrorKind, GitObjectId,
    GitObjectKind, MetadataObjectRecord, ReadSegment, RepositoryId, Result, SegmentId,
    YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKOM";
const FOOTER_MAGIC: [u8; 4] = *b"YKOF";
const VERSION: u16 = 1;

/// Immutable metadata binding one non-blob Git object to one segment record.
///
/// The filename is derived from the embedded Git object ID. Version 1 stores
/// no object body, so the body remains in the sealed segment named here.
#[derive(Eq, PartialEq)]
pub struct MetadataObjectManifest {
    repository_id: RepositoryId,
    git_object_id: GitObjectId,
    kind: GitObjectKind,
    content_id: YeokchamContentId,
    plaintext_bytes: u64,
    segment_id: SegmentId,
    segment_checksum: [u8; 32],
}

impl MetadataObjectManifest {
    /// Creates a manifest that references one verified metadata-object record.
    ///
    /// The supplied record must occur exactly in the supplied verified segment.
    pub fn from_metadata_object(
        segment: &ReadSegment,
        record: &MetadataObjectRecord,
    ) -> Result<Self> {
        ensure_metadata_object_record(segment, record)?;
        let plaintext_bytes = u64::try_from(record.data().len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "metadata-object manifest plaintext length is too large",
            )
        })?;
        Ok(Self {
            repository_id: segment.repository_id(),
            git_object_id: record.git_object_id(),
            kind: record.kind(),
            content_id: record.content_id(),
            plaintext_bytes,
            segment_id: segment.segment_id(),
            segment_checksum: segment.checksum(),
        })
    }

    /// Decodes and validates a caller-bounded immutable metadata-object manifest.
    pub fn decode(bytes: &[u8], maximum_plaintext_bytes: u64) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object manifest version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object manifest uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest has an invalid repository ID",
            )
        })?;
        let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
        let kind = metadata_object_kind_from_tag(decoder.read_u8()?)?;
        let algorithm =
            ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "metadata-object manifest has an invalid content hash algorithm",
                )
            })?;
        if algorithm != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object manifest uses an unsupported content hash",
            ));
        }
        let content_id = YeokchamContentId::from_digest(algorithm, decoder.read_fixed()?);
        let plaintext_bytes = decoder.read_u64()?;
        if plaintext_bytes > maximum_plaintext_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object manifest exceeds the plaintext-byte limit",
            ));
        }
        let segment_id = SegmentId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest has an invalid segment ID",
            )
        })?;
        let segment_checksum = decoder.read_fixed()?;
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest has invalid footer magic",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest checksum is truncated",
            )
        })?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest checksum does not match its bytes",
            ));
        }
        Ok(Self {
            repository_id,
            git_object_id,
            kind,
            content_id,
            plaintext_bytes,
            segment_id,
            segment_checksum,
        })
    }

    /// Returns the repository identity this manifest belongs to.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the exact Git object identity named by this manifest.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the exact non-blob Git object kind.
    pub const fn kind(&self) -> GitObjectKind {
        self.kind
    }

    /// Returns the verified domain-separated plaintext content identity.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact Git object body length.
    pub const fn plaintext_bytes(&self) -> u64 {
        self.plaintext_bytes
    }

    /// Returns the immutable segment identity containing the record.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }

    /// Returns the SHA-256 checksum binding the referenced segment bytes.
    pub const fn segment_checksum(&self) -> [u8; 32] {
        self.segment_checksum
    }

    /// Returns this manifest's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.git_object_id.as_bytes());
        encoder.write_u8(metadata_object_kind_tag(self.kind));
        encoder.write_u8(self.content_id.algorithm().binary_tag());
        encoder.write_fixed(self.content_id.digest());
        encoder.write_u64(self.plaintext_bytes);
        encoder.write_fixed(self.segment_id.as_bytes());
        encoder.write_fixed(&self.segment_checksum);
        encoder.write_fixed(&FOOTER_MAGIC);
        let mut bytes = encoder.into_bytes();
        let checksum: [u8; 32] = Sha256::digest(&bytes).into();
        bytes.extend_from_slice(&checksum);
        bytes
    }
}

impl fmt::Debug for MetadataObjectManifest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("MetadataObjectManifest")
            .field("repository_id", &self.repository_id)
            .field("git_object_id", &self.git_object_id)
            .field("kind", &self.kind)
            .field("content_id", &self.content_id)
            .field("plaintext_bytes", &self.plaintext_bytes)
            .field("segment_id", &self.segment_id)
            .field("segment_checksum", &"<redacted>")
            .finish()
    }
}

fn ensure_metadata_object_record(
    segment: &ReadSegment,
    record: &MetadataObjectRecord,
) -> Result<()> {
    if segment.records().iter().any(|candidate| {
        candidate
            .as_metadata_object()
            .is_some_and(|stored| stored == record)
    }) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorKind::InvalidInput,
            "metadata-object manifest record is absent from the segment",
        ))
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use uuid::Uuid;

    use super::*;
    use crate::{GitObject, SegmentReadLimits, SegmentRecord, SegmentWriteLimits, SegmentWriter};

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const SEGMENT_ID: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("yeokcham-metadata-manifest-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn verified_object(kind: GitObjectKind, data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            kind,
            data.to_vec(),
        );
        GitObject::new(provisional.recompute_id(), kind, data.to_vec())
    }

    fn decoded_segment(record: &MetadataObjectRecord) -> ReadSegment {
        let directory = TestDirectory::new();
        let destination = directory.0.join("segment");
        let segment_record = SegmentRecord::from_metadata_object(record).expect("segment record");
        let mut writer = SegmentWriter::new(
            REPOSITORY_ID.parse().expect("repository ID"),
            SEGMENT_ID.parse().expect("segment ID"),
            SegmentWriteLimits::new(1, segment_record.stored_len()).expect("write limits"),
        );
        writer.add(segment_record).expect("add record");
        writer.seal_to(&destination).expect("seal segment");
        let bytes = fs::read(destination).expect("read segment");
        crate::SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(1, 4_096, 4_096, 4_096, 1, 1).expect("read limits"),
        )
        .expect("decode segment")
    }

    #[test]
    fn round_trips_canonical_commit_tree_and_tag_manifests() {
        for (kind, body) in [
            (GitObjectKind::Tree, b"tree body".as_slice()),
            (GitObjectKind::Commit, b"commit\0body".as_slice()),
            (GitObjectKind::Tag, b"tag\xffbody".as_slice()),
        ] {
            let record = MetadataObjectRecord::from_verified_object(&verified_object(kind, body))
                .expect("record");
            let manifest =
                MetadataObjectManifest::from_metadata_object(&decoded_segment(&record), &record)
                    .expect("manifest");
            let decoded =
                MetadataObjectManifest::decode(&manifest.encode(), 4_096).expect("decode manifest");

            assert_eq!(decoded, manifest);
            assert_eq!(decoded.git_object_id(), record.git_object_id());
            assert_eq!(decoded.kind(), kind);
            assert_eq!(decoded.content_id(), record.content_id());
            assert_eq!(decoded.plaintext_bytes(), body.len() as u64);
            let debug = format!("{decoded:?}");
            assert!(!debug.contains("commit"));
            assert!(!debug.contains(&record.git_object_id().to_string()));
            assert!(debug.contains("<redacted>"));
        }
    }

    #[test]
    fn rejects_missing_limited_and_corrupt_manifests() {
        let record = MetadataObjectRecord::from_verified_object(&verified_object(
            GitObjectKind::Commit,
            b"private manifest body",
        ))
        .expect("record");
        let segment = decoded_segment(&record);
        let manifest =
            MetadataObjectManifest::from_metadata_object(&segment, &record).expect("manifest");
        let encoded = manifest.encode();
        let unrelated = MetadataObjectRecord::from_verified_object(&verified_object(
            GitObjectKind::Tag,
            b"unrelated",
        ))
        .expect("unrelated record");
        let absent = MetadataObjectManifest::from_metadata_object(&segment, &unrelated)
            .expect_err("absent record");
        let limited = MetadataObjectManifest::decode(&encoded, 1).expect_err("limited decode");
        let mut corrupt = encoded;
        let final_byte = corrupt.len() - 1;
        corrupt[final_byte] ^= 1;
        let corrupt =
            MetadataObjectManifest::decode(&corrupt, 4_096).expect_err("corrupt checksum");

        assert_eq!(absent.kind(), ErrorKind::InvalidInput);
        assert_eq!(limited.kind(), ErrorKind::Unsupported);
        assert_eq!(corrupt.kind(), ErrorKind::CorruptData);
        assert!(!corrupt.to_string().contains("private manifest body"));
    }

    #[test]
    fn manifest_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<MetadataObjectManifest>();
    }
}
