use std::fmt;

use sha2::{Digest, Sha256};

use crate::yeokcham_content_id::sha256_content_id;
use crate::{
    CanonicalDecoder, CanonicalEncoder, ContentHashAlgorithm, Error, ErrorKind, GitObject,
    GitObjectId, GitObjectKind, RepositoryId, Result, SegmentId, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKCB";
const FOOTER_MAGIC: [u8; 4] = *b"YKCF";
const VERSION: u16 = 1;
const REFERENCE_BYTES: usize = 89;

/// One immutable location for a verified plaintext chunk.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ChunkReference {
    content_id: YeokchamContentId,
    plaintext_bytes: u64,
    segment_id: SegmentId,
    segment_checksum: [u8; 32],
}

impl ChunkReference {
    /// Creates one bounded chunk reference.
    pub fn new(
        content_id: YeokchamContentId,
        plaintext_bytes: u64,
        segment_id: SegmentId,
        segment_checksum: [u8; 32],
    ) -> Result<Self> {
        if content_id.algorithm() != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk reference uses an unsupported content hash",
            ));
        }
        if plaintext_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "chunk reference requires nonzero plaintext bytes",
            ));
        }
        Ok(Self {
            content_id,
            plaintext_bytes,
            segment_id,
            segment_checksum,
        })
    }

    /// Returns the verified plaintext chunk identity.
    pub const fn content_id(self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact plaintext chunk length.
    pub const fn plaintext_bytes(self) -> u64 {
        self.plaintext_bytes
    }

    /// Returns the immutable segment containing the chunk record.
    pub const fn segment_id(self) -> SegmentId {
        self.segment_id
    }

    /// Returns the expected checksum of the immutable chunk segment.
    pub const fn segment_checksum(self) -> [u8; 32] {
        self.segment_checksum
    }
}

/// A verified chunked representation of one Git blob.
///
/// The record binds the complete blob identities and ordered chunk locations.
/// Each referenced chunk is verified while reconstruction resolves it.
#[derive(Eq, PartialEq)]
pub struct ChunkedBlobRecord {
    repository_id: RepositoryId,
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    plaintext_bytes: u64,
    chunks: Vec<ChunkReference>,
}

impl ChunkedBlobRecord {
    /// Creates one record from a verified Git blob and its ordered chunk locations.
    pub fn from_verified_blob(
        repository_id: RepositoryId,
        object: &GitObject,
        chunks: Vec<ChunkReference>,
    ) -> Result<Self> {
        if object.kind() != GitObjectKind::Blob {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "chunked-blob record requires a Git blob",
            ));
        }
        object.verify_id()?;
        let plaintext_bytes = u64::try_from(object.data().len())
            .map_err(|_| Error::new(ErrorKind::Unsupported, "chunked-blob body is too large"))?;
        let record = Self {
            repository_id,
            git_object_id: object.id(),
            content_id: sha256_content_id(object.data()),
            plaintext_bytes,
            chunks,
        };
        record.verify_structure()?;
        Ok(record)
    }

    /// Decodes and validates one bounded canonical chunked-blob record.
    pub fn decode(bytes: &[u8], maximum_chunks: usize) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunked-blob record version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunked-blob record uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has an invalid repository ID",
            )
        })?;
        let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
        let content_id = read_content_id(&mut decoder)?;
        let plaintext_bytes = decoder.read_u64()?;
        let count = usize::try_from(decoder.read_u32()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has an invalid chunk count",
            )
        })?;
        if count == 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has no chunks",
            ));
        }
        if count > maximum_chunks {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunked-blob record exceeds the chunk limit",
            ));
        }
        let remaining = bytes.len().saturating_sub(decoder.consumed_len());
        if count > remaining / REFERENCE_BYTES {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record is truncated",
            ));
        }
        let mut chunks = Vec::new();
        for _ in 0..count {
            let content_id = read_content_id(&mut decoder)?;
            let plaintext_bytes = decoder.read_u64()?;
            let segment_id = SegmentId::from_bytes(decoder.read_fixed()?).map_err(|_| {
                Error::new(
                    ErrorKind::CorruptData,
                    "chunked-blob record has an invalid segment ID",
                )
            })?;
            let segment_checksum = decoder.read_fixed()?;
            chunks.push(ChunkReference::new(
                content_id,
                plaintext_bytes,
                segment_id,
                segment_checksum,
            )?);
        }
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has invalid footer magic",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record checksum is truncated",
            )
        })?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record checksum does not match its bytes",
            ));
        }
        let record = Self {
            repository_id,
            git_object_id,
            content_id,
            plaintext_bytes,
            chunks,
        };
        record.verify_structure()?;
        Ok(record)
    }

    /// Returns the repository identity that owns every referenced segment.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the final Git blob ID verified after reconstruction.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the SHA-256 identity of the complete blob body.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact complete blob-body length.
    pub const fn plaintext_bytes(&self) -> u64 {
        self.plaintext_bytes
    }

    /// Returns ordered immutable locations for every blob chunk.
    pub fn chunks(&self) -> &[ChunkReference] {
        &self.chunks
    }

    /// Returns this record's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.git_object_id.as_bytes());
        write_content_id(&mut encoder, self.content_id);
        encoder.write_u64(self.plaintext_bytes);
        encoder.write_u32(u32::try_from(self.chunks.len()).expect("validated chunk count"));
        for chunk in &self.chunks {
            write_content_id(&mut encoder, chunk.content_id);
            encoder.write_u64(chunk.plaintext_bytes);
            encoder.write_fixed(chunk.segment_id.as_bytes());
            encoder.write_fixed(&chunk.segment_checksum);
        }
        encoder.write_fixed(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(encoder.as_bytes()).into();
        encoder.write_fixed(&checksum);
        encoder.into_bytes()
    }

    fn verify_structure(&self) -> Result<()> {
        if self.content_id.algorithm() != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunked-blob record uses an unsupported content hash",
            ));
        }
        if self.chunks.is_empty() || u32::try_from(self.chunks.len()).is_err() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record has an invalid chunk count",
            ));
        }
        let total = self.chunks.iter().try_fold(0u64, |total, chunk| {
            total.checked_add(chunk.plaintext_bytes()).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "chunked-blob record plaintext length is invalid",
                )
            })
        })?;
        if total != self.plaintext_bytes {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunked-blob record plaintext length does not match chunks",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for ChunkedBlobRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ChunkedBlobRecord")
            .field("repository_id", &self.repository_id)
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("plaintext_bytes", &self.plaintext_bytes)
            .field("chunk_count", &self.chunks.len())
            .field("chunks", &"<redacted>")
            .finish()
    }
}

fn read_content_id(decoder: &mut CanonicalDecoder<'_>) -> Result<YeokchamContentId> {
    let algorithm = ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "chunked-blob record has an invalid content hash algorithm",
        )
    })?;
    if algorithm != ContentHashAlgorithm::Sha256 {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "chunked-blob record uses an unsupported content hash",
        ));
    }
    Ok(YeokchamContentId::from_digest(
        algorithm,
        decoder.read_fixed()?,
    ))
}

fn write_content_id(encoder: &mut CanonicalEncoder, content_id: YeokchamContentId) {
    encoder.write_u8(content_id.algorithm().binary_tag());
    encoder.write_fixed(content_id.digest());
}

#[cfg(test)]
mod tests {
    use super::*;

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

    fn reference(data: &[u8]) -> ChunkReference {
        ChunkReference::new(
            sha256_content_id(data),
            data.len() as u64,
            "6ba7b814-9dad-41d1-80b4-00c04fd430c8"
                .parse()
                .expect("segment ID"),
            [7; 32],
        )
        .expect("reference")
    }

    #[test]
    fn round_trips_canonical_chunk_references() {
        let record = ChunkedBlobRecord::from_verified_blob(
            "550e8400-e29b-41d4-a716-446655440000"
                .parse()
                .expect("repository ID"),
            &verified_blob(b"firstsecond"),
            vec![reference(b"first"), reference(b"second")],
        )
        .expect("record");
        let encoded = record.encode();
        let decoded = ChunkedBlobRecord::decode(&encoded, 2).expect("decode");

        assert_eq!(decoded, record);
        assert_eq!(decoded.chunks().len(), 2);
        assert!(!format!("{decoded:?}").contains("first"));
    }

    #[test]
    fn rejects_invalid_reference_count_and_checksum() {
        let object = verified_blob(b"body");
        let repository_id = "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID");
        assert_eq!(
            ChunkedBlobRecord::from_verified_blob(repository_id, &object, Vec::new())
                .expect_err("empty chunks")
                .kind(),
            ErrorKind::CorruptData
        );
        let record =
            ChunkedBlobRecord::from_verified_blob(repository_id, &object, vec![reference(b"body")])
                .expect("record");
        let mut encoded = record.encode();
        *encoded.last_mut().expect("checksum") ^= 1;
        assert_eq!(
            ChunkedBlobRecord::decode(&encoded, 1)
                .expect_err("checksum")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            ChunkedBlobRecord::decode(&record.encode(), 0)
                .expect_err("chunk limit")
                .kind(),
            ErrorKind::Unsupported
        );
    }
}
