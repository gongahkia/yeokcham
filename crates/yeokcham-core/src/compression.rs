use crate::{Error, ErrorKind, Result};

/// Compression method applied to one stored payload.
///
/// Version 1 recognizes only [`None`](Self::None). New methods require an ADR,
/// a stable binary tag, and bounded decoder semantics before they are added.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[non_exhaustive]
pub enum CompressionAlgorithm {
    /// Payload bytes are stored exactly as plaintext bytes.
    None,
}

impl CompressionAlgorithm {
    pub(crate) const fn binary_tag(self) -> u8 {
        match self {
            Self::None => 0,
        }
    }

    pub(crate) fn from_binary_tag(tag: u8) -> Result<Self> {
        match tag {
            0 => Ok(Self::None),
            _ => Err(Error::new(
                ErrorKind::Unsupported,
                "compression algorithm is unsupported",
            )),
        }
    }
}

/// A bounded codec for one [`CompressionAlgorithm`].
///
/// Decompression always receives a caller-owned plaintext limit before output
/// allocation. The current `none` codec preserves bytes exactly.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct CompressionCodec {
    algorithm: CompressionAlgorithm,
}

impl CompressionCodec {
    /// Creates a codec for one recognized compression algorithm.
    pub const fn new(algorithm: CompressionAlgorithm) -> Self {
        Self { algorithm }
    }

    /// Returns the algorithm selected for this codec.
    pub const fn algorithm(self) -> CompressionAlgorithm {
        self.algorithm
    }

    /// Encodes exact plaintext bytes for storage.
    ///
    /// Version 1's `none` codec returns an exact independent copy. The result
    /// is fallible so future codecs can report their own bounded failures.
    pub fn compress(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        match self.algorithm {
            CompressionAlgorithm::None => Ok(plaintext.to_vec()),
        }
    }

    /// Decodes stored bytes while enforcing a maximum plaintext length.
    ///
    /// The caller must bound the encoded input separately before calling this
    /// method. Version 1's `none` codec checks its output length before copy.
    pub fn decompress(&self, encoded: &[u8], maximum_plaintext_bytes: usize) -> Result<Vec<u8>> {
        match self.algorithm {
            CompressionAlgorithm::None => {
                if encoded.len() > maximum_plaintext_bytes {
                    return Err(Error::new(
                        ErrorKind::Unsupported,
                        "decompressed data exceeds the decode limit",
                    ));
                }
                Ok(encoded.to_vec())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_uses_a_stable_binary_tag() {
        assert_eq!(CompressionAlgorithm::None.binary_tag(), 0);
        assert_eq!(
            CompressionAlgorithm::from_binary_tag(0).expect("none tag"),
            CompressionAlgorithm::None
        );

        let error = CompressionAlgorithm::from_binary_tag(1).expect_err("unknown tag");
        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "compression algorithm is unsupported"
        );
    }

    #[test]
    fn none_codec_round_trips_exact_binary_bytes() {
        let codec = CompressionCodec::new(CompressionAlgorithm::None);
        let plaintext = b"\0private plaintext\xff\n";
        let encoded = codec.compress(plaintext).expect("compress");
        let decoded = codec
            .decompress(&encoded, plaintext.len())
            .expect("decompress");

        assert_eq!(codec.algorithm(), CompressionAlgorithm::None);
        assert_eq!(encoded, plaintext);
        assert_eq!(decoded, plaintext);
    }

    #[test]
    fn none_codec_rejects_output_above_the_limit_without_disclosure() {
        let error = CompressionCodec::new(CompressionAlgorithm::None)
            .decompress(b"private plaintext", 1)
            .expect_err("limit must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "decompressed data exceeds the decode limit"
        );
        assert!(!error.to_string().contains("private plaintext"));
    }

    #[test]
    fn compression_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<CompressionAlgorithm>();
        assert_send_sync::<CompressionCodec>();
    }
}
