use std::fmt;

use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, CompressionAlgorithm, CompressionCodec,
    ContentHashAlgorithm, Error, ErrorKind, GitObject, GitObjectId, GitObjectKind, Result,
    YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKMO";
const VERSION: u16 = 1;
const RECORD_TYPE: u8 = 3;
const CONTENT_DOMAIN: &[u8] = b"yeokcham/metadata-object/v1\0";

/// A canonical uncompressed record containing one verified non-blob Git object.
///
/// Version 1 supports only trees, commits, and annotated tags. It preserves
/// exact Git body bytes and verifies both the Git SHA-1 identity and a
/// domain-separated SHA-256 plaintext identity while decoding.
#[derive(Eq, PartialEq)]
pub struct MetadataObjectRecord {
    kind: GitObjectKind,
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    data: Vec<u8>,
}

impl MetadataObjectRecord {
    /// Creates one record from a verified Git tree, commit, or annotated tag.
    pub fn from_verified_object(object: &GitObject) -> Result<Self> {
        if object.kind() == GitObjectKind::Blob {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "metadata-object record does not accept Git blobs",
            ));
        }
        object.verify_id()?;
        Ok(Self {
            kind: object.kind(),
            git_object_id: object.id(),
            content_id: metadata_object_content_id(object.kind(), object.data())?,
            data: object.data().to_vec(),
        })
    }

    /// Decodes and verifies a caller-bounded canonical metadata-object record.
    ///
    /// maximum_body_bytes bounds the allocation required to own the decoded
    /// Git object body. The encoded record itself must already be bounded.
    pub fn decode(bytes: &[u8], maximum_body_bytes: usize) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object record has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object record version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object record uses unsupported features",
            ));
        }
        if decoder.read_u8()? != RECORD_TYPE {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object record has an invalid type",
            ));
        }
        let kind = metadata_object_kind_from_tag(decoder.read_u8()?)?;
        let compression = CompressionAlgorithm::from_binary_tag(decoder.read_u8()?)?;
        if compression != CompressionAlgorithm::None {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object record compression is unsupported",
            ));
        }
        let algorithm =
            ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "metadata-object record has an invalid content hash algorithm",
                )
            })?;
        if algorithm != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "metadata-object record uses an unsupported content hash",
            ));
        }
        let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
        let content_id = YeokchamContentId::from_digest(algorithm, decoder.read_fixed()?);
        let data = CompressionCodec::new(compression)
            .decompress(decoder.read_byte_string()?, maximum_body_bytes)?;
        decoder.finish()?;
        let record = Self {
            kind,
            git_object_id,
            content_id,
            data,
        };
        record.verify()?;
        Ok(record)
    }

    /// Returns the verified Git object kind.
    pub const fn kind(&self) -> GitObjectKind {
        self.kind
    }

    /// Returns the verified Git object ID.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the verified plaintext content identity.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact decompressed Git object body.
    pub fn data(&self) -> &[u8] {
        &self.data
    }

    /// Returns this record's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_u8(RECORD_TYPE);
        encoder.write_u8(metadata_object_kind_tag(self.kind));
        encoder.write_u8(CompressionAlgorithm::None.binary_tag());
        encoder.write_u8(self.content_id.algorithm().binary_tag());
        encoder.write_fixed(self.git_object_id.as_bytes());
        encoder.write_fixed(self.content_id.digest());
        encoder.write_byte_string(&self.data);
        encoder.into_bytes()
    }

    fn verify(&self) -> Result<()> {
        if self.kind == GitObjectKind::Blob {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object record has an invalid Git object kind",
            ));
        }
        if self.git_object_id != GitObject::recompute_id_for(self.kind, &self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object record Git object ID does not match its bytes",
            ));
        }
        if self.content_id != metadata_object_content_id(self.kind, &self.data)? {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object record content ID does not match its bytes",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for MetadataObjectRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("MetadataObjectRecord")
            .field("kind", &self.kind)
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("data", &"<redacted>")
            .finish()
    }
}

pub(crate) fn metadata_object_content_id(
    kind: GitObjectKind,
    data: &[u8],
) -> Result<YeokchamContentId> {
    if kind == GitObjectKind::Blob {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "metadata-object content identity does not accept Git blobs",
        ));
    }
    let length = u64::try_from(data.len())
        .map_err(|_| Error::new(ErrorKind::Unsupported, "metadata-object body is too large"))?;
    let mut hasher = Sha256::new();
    hasher.update(CONTENT_DOMAIN);
    hasher.update([metadata_object_kind_tag(kind)]);
    hasher.update(length.to_be_bytes());
    hasher.update(data);
    Ok(YeokchamContentId::from_digest(
        ContentHashAlgorithm::Sha256,
        hasher.finalize().into(),
    ))
}

pub(crate) const fn metadata_object_kind_tag(kind: GitObjectKind) -> u8 {
    match kind {
        GitObjectKind::Blob => 1,
        GitObjectKind::Tree => 2,
        GitObjectKind::Commit => 3,
        GitObjectKind::Tag => 4,
    }
}

pub(crate) fn metadata_object_kind_from_tag(tag: u8) -> Result<GitObjectKind> {
    match tag {
        2 => Ok(GitObjectKind::Tree),
        3 => Ok(GitObjectKind::Commit),
        4 => Ok(GitObjectKind::Tag),
        _ => Err(Error::new(
            ErrorKind::CorruptData,
            "metadata-object record has an invalid Git object kind",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verified_object(kind: GitObjectKind, data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            kind,
            data.to_vec(),
        );
        GitObject::new(provisional.recompute_id(), kind, data.to_vec())
    }

    #[test]
    fn round_trips_exact_binary_tree_commit_and_tag_bodies() {
        for (kind, body) in [
            (GitObjectKind::Tree, b"100644 file\0\x01\xff".as_slice()),
            (GitObjectKind::Commit, b"tree \0commit\xff\n".as_slice()),
            (GitObjectKind::Tag, b"object \xff\0tag".as_slice()),
        ] {
            let object = verified_object(kind, body);
            let record = MetadataObjectRecord::from_verified_object(&object).expect("record");
            let decoded =
                MetadataObjectRecord::decode(&record.encode(), body.len()).expect("decode");

            assert_eq!(decoded, record);
            assert_eq!(decoded.kind(), kind);
            assert_eq!(decoded.git_object_id(), object.id());
            assert_eq!(decoded.data(), body);
            let debug = format!("{decoded:?}");
            assert!(!debug.contains("commit"));
            assert!(!debug.contains(&object.id().to_string()));
            assert!(debug.contains("<redacted>"));
        }
    }

    #[test]
    fn rejects_blob_and_unverified_inputs() {
        let blob = verified_object(GitObjectKind::Blob, b"body");
        let valid = verified_object(GitObjectKind::Commit, b"commit body");
        let altered = GitObject::new(valid.id(), GitObjectKind::Commit, b"altered body".to_vec());

        let blob_error =
            MetadataObjectRecord::from_verified_object(&blob).expect_err("blob must fail");
        let altered_error =
            MetadataObjectRecord::from_verified_object(&altered).expect_err("altered must fail");
        assert_eq!(blob_error.kind(), ErrorKind::InvalidInput);
        assert_eq!(altered_error.kind(), ErrorKind::CorruptData);
        assert!(!altered_error.to_string().contains("altered body"));
    }

    #[test]
    fn rejects_corrupt_unsupported_and_oversized_encodings() {
        let object = verified_object(GitObjectKind::Tree, b"tree body");
        let record = MetadataObjectRecord::from_verified_object(&object).expect("record");
        let encoded = record.encode();
        let mut invalid_magic = encoded.clone();
        invalid_magic[0] ^= 1;
        let mut invalid_kind = encoded.clone();
        invalid_kind[23] = 1;
        let mut invalid_content_id = encoded.clone();
        invalid_content_id[46] ^= 1;

        let magic = MetadataObjectRecord::decode(&invalid_magic, 64).expect_err("invalid magic");
        let kind = MetadataObjectRecord::decode(&invalid_kind, 64).expect_err("invalid kind");
        let content =
            MetadataObjectRecord::decode(&invalid_content_id, 64).expect_err("invalid content");
        let oversized = MetadataObjectRecord::decode(&encoded, 1).expect_err("oversized body");

        assert_eq!(magic.kind(), ErrorKind::CorruptData);
        assert_eq!(kind.kind(), ErrorKind::CorruptData);
        assert_eq!(content.kind(), ErrorKind::CorruptData);
        assert_eq!(oversized.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn record_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<MetadataObjectRecord>();
    }
}
