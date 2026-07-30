use std::fmt;

use crate::yeokcham_content_id::sha256_content_id;
use crate::{
    CanonicalDecoder, CanonicalEncoder, ContentHashAlgorithm, Error, ErrorKind, Result,
    YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKCK";
const VERSION: u16 = 1;

/// One independently verified plaintext content-defined chunk.
#[derive(Eq, PartialEq)]
pub struct ChunkRecord {
    content_id: YeokchamContentId,
    data: Vec<u8>,
}

impl ChunkRecord {
    /// Creates a chunk record after deriving its unkeyed SHA-256 identity.
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.is_empty() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "chunk record requires nonempty bytes",
            ));
        }
        Ok(Self {
            content_id: sha256_content_id(data),
            data: data.to_vec(),
        })
    }

    /// Decodes and verifies one bounded canonical chunk record.
    pub fn decode(bytes: &[u8], maximum_body_bytes: usize) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunk record has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk record version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk record uses unsupported features",
            ));
        }
        let algorithm =
            ContentHashAlgorithm::from_binary_tag(decoder.read_u8()?).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "chunk record has an invalid content hash algorithm",
                )
            })?;
        if algorithm != ContentHashAlgorithm::Sha256 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk record uses an unsupported content hash",
            ));
        }
        let content_id = YeokchamContentId::from_digest(algorithm, decoder.read_fixed()?);
        let data = decoder.read_byte_string()?;
        if data.len() > maximum_body_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk record exceeds the body-byte limit",
            ));
        }
        let record = Self {
            content_id,
            data: data.to_vec(),
        };
        decoder.finish()?;
        record.verify()?;
        Ok(record)
    }

    /// Returns the verified SHA-256 identity of the exact chunk bytes.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact plaintext chunk bytes.
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
        encoder.write_u8(self.content_id.algorithm().binary_tag());
        encoder.write_fixed(self.content_id.digest());
        encoder.write_byte_string(&self.data);
        encoder.into_bytes()
    }

    fn verify(&self) -> Result<()> {
        if self.data.is_empty() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunk record has empty bytes",
            ));
        }
        if self.content_id != sha256_content_id(&self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "chunk record content ID does not match its bytes",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for ChunkRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ChunkRecord")
            .field("content_id", &self.content_id)
            .field("data", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_exact_binary_chunk_bytes() {
        let record = ChunkRecord::from_bytes(b"\0private chunk\xff\n").expect("chunk");
        let encoded = record.encode();
        let decoded = ChunkRecord::decode(&encoded, 64).expect("decode");

        assert_eq!(decoded, record);
        assert_eq!(decoded.data(), b"\0private chunk\xff\n");
        assert!(!format!("{decoded:?}").contains("private chunk"));
    }

    #[test]
    fn rejects_empty_corrupt_and_oversized_chunks() {
        assert_eq!(
            ChunkRecord::from_bytes(&[])
                .expect_err("empty chunk")
                .kind(),
            ErrorKind::InvalidInput
        );
        let record = ChunkRecord::from_bytes(b"body").expect("chunk");
        let mut corrupt = record.encode();
        *corrupt.last_mut().expect("data") ^= 1;

        assert_eq!(
            ChunkRecord::decode(&corrupt, 64)
                .expect_err("corrupt chunk")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            ChunkRecord::decode(&record.encode(), 3)
                .expect_err("oversized chunk")
                .kind(),
            ErrorKind::Unsupported
        );
    }
}
