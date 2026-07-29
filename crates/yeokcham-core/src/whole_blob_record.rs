use std::fmt;

use crate::yeokcham_content_id::sha256_content_id;
use crate::{
    CanonicalDecoder, CanonicalEncoder, CompressionAlgorithm, CompressionCodec,
    ContentHashAlgorithm, Error, ErrorKind, GitObject, GitObjectId, GitObjectKind, Result,
    YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKWB";
const VERSION: u16 = 1;
const RECORD_TYPE: u8 = 1;

/// A canonical uncompressed record containing one verified Git blob body.
///
/// Version 1 writes an unkeyed SHA-256 plaintext content ID and no
/// compression. The record preserves exact blob bytes and verifies both the
/// Git SHA-1 ID and the plaintext content ID while decoding.
#[derive(Eq, PartialEq)]
pub struct WholeBlobRecord {
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    data: Vec<u8>,
}

impl WholeBlobRecord {
    /// Creates one record from a verified Git blob.
    ///
    /// Early repositories write the unkeyed SHA-256 content identity selected
    /// by ADR-0020. Keyed and BLAKE3 identities require later key/configuration
    /// work and are not accepted by this record version.
    pub fn from_verified_blob(object: &GitObject) -> Result<Self> {
        if object.kind() != GitObjectKind::Blob {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "whole-blob record requires a Git blob",
            ));
        }
        object.verify_id()?;
        Ok(Self {
            git_object_id: object.id(),
            content_id: sha256_content_id(object.data()),
            data: object.data().to_vec(),
        })
    }

    /// Decodes and verifies a caller-bounded canonical whole-blob record.
    ///
    /// `maximum_body_bytes` bounds the allocation required to own the decoded
    /// blob. The encoded record itself must already be bounded by the caller.
    pub fn decode(bytes: &[u8], maximum_body_bytes: usize) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "whole-blob record has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "whole-blob record version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "whole-blob record uses unsupported features",
            ));
        }
        if decoder.read_u8()? != RECORD_TYPE {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "whole-blob record has an invalid type",
            ));
        }
        let compression = CompressionAlgorithm::from_binary_tag(decoder.read_u8()?)?;
        if compression != CompressionAlgorithm::None {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "whole-blob record compression is unsupported",
            ));
        }
        let algorithm =
            ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "whole-blob record has an invalid content hash algorithm",
                )
            })?;
        if algorithm != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "whole-blob record uses an unsupported content hash",
            ));
        }
        let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
        let content_id = YeokchamContentId::from_digest(algorithm, decoder.read_fixed()?);
        let data = CompressionCodec::new(compression)
            .decompress(decoder.read_byte_string()?, maximum_body_bytes)?;
        decoder.finish()?;
        let record = Self {
            git_object_id,
            content_id,
            data,
        };
        record.verify()?;
        Ok(record)
    }

    /// Returns the Git blob ID verified by this record.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the tagged plaintext content ID verified by this record.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact decompressed Git blob body.
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
        encoder.write_u8(CompressionAlgorithm::None.binary_tag());
        encoder.write_u8(self.content_id.algorithm().binary_tag());
        encoder.write_fixed(self.git_object_id.as_bytes());
        encoder.write_fixed(self.content_id.digest());
        encoder.write_byte_string(&self.data);
        encoder.into_bytes()
    }

    fn verify(&self) -> Result<()> {
        if self.git_object_id != GitObject::recompute_id_for(GitObjectKind::Blob, &self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "whole-blob record Git object ID does not match its bytes",
            ));
        }
        if self.content_id != sha256_content_id(&self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "whole-blob record content ID does not match its bytes",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for WholeBlobRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WholeBlobRecord")
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("data", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY_BLOB_ID: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const EMPTY_SHA256: [u8; YeokchamContentId::DIGEST_LENGTH] = [
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9,
        0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52,
        0xb8, 0x55,
    ];

    fn verified_object(kind: GitObjectKind, data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            kind,
            data.to_vec(),
        );
        GitObject::new(provisional.recompute_id(), kind, data.to_vec())
    }

    fn empty_blob() -> GitObject {
        GitObject::new(
            EMPTY_BLOB_ID.parse().expect("empty blob ID"),
            GitObjectKind::Blob,
            Vec::new(),
        )
    }

    #[test]
    fn encodes_one_canonical_empty_blob_record() {
        let record = WholeBlobRecord::from_verified_blob(&empty_blob()).expect("record");

        assert_eq!(
            record.encode(),
            [
                b'Y', b'K', b'W', b'B', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0,
                3, 0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43, 0x4b, 0x8b, 0x29, 0xae, 0x77,
                0x5a, 0xd8, 0xc2, 0xe4, 0x8c, 0x53, 0x91, 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c,
                0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64,
                0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55, 0, 0, 0, 0, 0, 0,
                0, 0,
            ]
        );
        assert_eq!(
            record.content_id(),
            YeokchamContentId::from_digest(ContentHashAlgorithm::Sha256, EMPTY_SHA256)
        );
    }

    #[test]
    fn round_trips_exact_binary_blob_bytes_and_redacts_debug() {
        let object = verified_object(GitObjectKind::Blob, b"\0private body\xff\n");
        let record = WholeBlobRecord::from_verified_blob(&object).expect("record");
        let encoded = record.encode();
        let decoded =
            WholeBlobRecord::decode(&encoded, object.data().len()).expect("decode record");

        assert_eq!(decoded, record);
        assert_eq!(decoded.git_object_id(), object.id());
        assert_eq!(
            decoded.content_id().algorithm(),
            ContentHashAlgorithm::Sha256
        );
        assert_eq!(decoded.data(), object.data());
        let debug = format!("{decoded:?}");
        assert!(!debug.contains("private body"));
        assert!(!debug.contains(&object.id().to_string()));
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn rejects_non_blob_and_unverified_inputs() {
        let tree = verified_object(GitObjectKind::Tree, b"tree body");
        let altered = GitObject::new(
            EMPTY_BLOB_ID.parse().expect("empty blob ID"),
            GitObjectKind::Blob,
            b"altered body".to_vec(),
        );

        let tree_error = WholeBlobRecord::from_verified_blob(&tree).expect_err("tree must fail");
        let altered_error =
            WholeBlobRecord::from_verified_blob(&altered).expect_err("altered blob must fail");

        assert_eq!(tree_error.kind(), ErrorKind::InvalidInput);
        assert_eq!(altered_error.kind(), ErrorKind::CorruptData);
        assert!(!altered_error.to_string().contains("altered body"));
    }

    #[test]
    fn rejects_corrupt_unsupported_and_oversized_encoded_records() {
        let record =
            WholeBlobRecord::from_verified_blob(&verified_object(GitObjectKind::Blob, b"body"))
                .expect("record");
        let encoded = record.encode();
        let cases = [
            (0, b'X', ErrorKind::CorruptData),
            (5, 2, ErrorKind::Unsupported),
            (6, 1, ErrorKind::Unsupported),
            (22, 2, ErrorKind::CorruptData),
            (23, 1, ErrorKind::Unsupported),
            (24, 1, ErrorKind::Unsupported),
            (25, encoded[25] ^ 1, ErrorKind::CorruptData),
            (45, encoded[45] ^ 1, ErrorKind::CorruptData),
        ];

        for (offset, replacement, kind) in cases {
            let mut malformed = encoded.clone();
            malformed[offset] = replacement;
            let error = WholeBlobRecord::decode(&malformed, usize::MAX)
                .expect_err("malformed record must fail");
            assert_eq!(error.kind(), kind, "offset {offset}");
            assert!(!error.to_string().contains("body"));
        }
        let truncated = WholeBlobRecord::decode(&encoded[..encoded.len() - 1], usize::MAX)
            .expect_err("truncated record must fail");
        let mut trailing = encoded.clone();
        trailing.push(0);
        let trailing =
            WholeBlobRecord::decode(&trailing, usize::MAX).expect_err("trailing record must fail");
        let limited = WholeBlobRecord::decode(&encoded, record.data().len() - 1)
            .expect_err("record above limit must fail");

        assert_eq!(truncated.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
        assert_eq!(limited.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn whole_blob_records_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<WholeBlobRecord>();
    }
}
