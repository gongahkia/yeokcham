use fastcdc::v2016::{
    AVERAGE_MAX, AVERAGE_MIN, FastCDC, MAXIMUM_MAX, MAXIMUM_MIN, MINIMUM_MAX, MINIMUM_MIN,
    Normalization,
};

use crate::yeokcham_content_id::sha256_content_id;
use crate::{Error, ErrorKind, Result, YeokchamContentId};

/// Validated parameters for the initial FastCDC v2016 boundary function.
///
/// The caller supplies all sizes and the maximum output count. No storage
/// policy threshold or mutable default is selected by this type.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ContentDefinedChunkingParameters {
    minimum_size: usize,
    average_size: usize,
    maximum_size: usize,
    maximum_chunks: usize,
}

impl ContentDefinedChunkingParameters {
    /// Validates parameters for the initial FastCDC v2016 boundary function.
    ///
    /// Sizes must be individually supported by `fastcdc` and ordered from
    /// minimum through maximum. `maximum_chunks` bounds output allocation and
    /// processing work.
    pub fn new(
        minimum_size: usize,
        average_size: usize,
        maximum_size: usize,
        maximum_chunks: usize,
    ) -> Result<Self> {
        if !(MINIMUM_MIN..=MINIMUM_MAX).contains(&minimum_size) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "FastCDC minimum chunk size is invalid",
            ));
        }
        if !(AVERAGE_MIN..=AVERAGE_MAX).contains(&average_size) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "FastCDC average chunk size is invalid",
            ));
        }
        if !(MAXIMUM_MIN..=MAXIMUM_MAX).contains(&maximum_size) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "FastCDC maximum chunk size is invalid",
            ));
        }
        if minimum_size > average_size || average_size > maximum_size {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "FastCDC chunk sizes must be ordered minimum through maximum",
            ));
        }
        if maximum_chunks == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "FastCDC maximum chunk count must not be zero",
            ));
        }
        Ok(Self {
            minimum_size,
            average_size,
            maximum_size,
            maximum_chunks,
        })
    }

    /// Returns the minimum permitted byte length of a non-final chunk.
    pub const fn minimum_size(self) -> usize {
        self.minimum_size
    }

    /// Returns the target average chunk size used by FastCDC.
    pub const fn average_size(self) -> usize {
        self.average_size
    }

    /// Returns the maximum permitted byte length of every chunk.
    pub const fn maximum_size(self) -> usize {
        self.maximum_size
    }

    /// Returns the caller-selected upper bound on emitted chunks.
    pub const fn maximum_chunks(self) -> usize {
        self.maximum_chunks
    }
}

/// A verified range and plaintext content identity emitted by content-defined chunking.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ContentDefinedChunk {
    offset: u64,
    length: usize,
    content_id: YeokchamContentId,
}

impl ContentDefinedChunk {
    /// Returns the zero-based source byte offset of this chunk.
    pub const fn offset(self) -> u64 {
        self.offset
    }

    /// Returns the exact byte length of this chunk.
    pub const fn length(self) -> usize {
        self.length
    }

    /// Returns the exclusive source byte offset immediately after this chunk.
    pub const fn end_offset(self) -> u64 {
        self.offset + self.length as u64
    }

    /// Returns the tagged SHA-256 identity of exactly this chunk's source bytes.
    pub const fn content_id(self) -> YeokchamContentId {
        self.content_id
    }
}

/// Bounded, deterministic FastCDC v2016 content-defined chunking.
///
/// The boundary selector uses the unseeded Gear table and normalization level
/// 1 specified by ADR-0037. Its Gear fingerprint is not exposed or used as a
/// content identity.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ContentDefinedChunker {
    parameters: ContentDefinedChunkingParameters,
}

impl ContentDefinedChunker {
    /// Creates a chunker with validated, explicit FastCDC parameters.
    pub const fn new(parameters: ContentDefinedChunkingParameters) -> Self {
        Self { parameters }
    }

    /// Returns this chunker's immutable parameters.
    pub const fn parameters(self) -> ContentDefinedChunkingParameters {
        self.parameters
    }

    /// Splits source bytes into verified, contiguous content-defined chunks.
    ///
    /// The returned ranges cover `source` exactly. The caller owns `source`;
    /// this result retains neither source bytes nor the FastCDC Gear values.
    pub fn chunk(&self, source: &[u8]) -> Result<Vec<ContentDefinedChunk>> {
        if source.is_empty() {
            return Ok(Vec::new());
        }
        if source.len().div_ceil(self.parameters.maximum_size) > self.parameters.maximum_chunks {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "chunk input exceeds the configured chunk count limit",
            ));
        }

        let mut chunks = Vec::new();
        let mut expected_offset = 0usize;
        for boundary in FastCDC::with_level(
            source,
            self.parameters.minimum_size,
            self.parameters.average_size,
            self.parameters.maximum_size,
            Normalization::Level1,
        ) {
            if chunks.len() == self.parameters.maximum_chunks {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "chunk input exceeds the configured chunk count limit",
                ));
            }
            let end = boundary
                .offset
                .checked_add(boundary.length)
                .filter(|end| *end <= source.len())
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::Internal,
                        "FastCDC returned an invalid chunk boundary",
                    )
                })?;
            if boundary.offset != expected_offset || boundary.length == 0 {
                return Err(Error::new(
                    ErrorKind::Internal,
                    "FastCDC returned non-contiguous chunk boundaries",
                ));
            }
            if boundary.length > self.parameters.maximum_size
                || (end < source.len() && boundary.length < self.parameters.minimum_size)
            {
                return Err(Error::new(
                    ErrorKind::Internal,
                    "FastCDC returned an invalid chunk size",
                ));
            }
            let offset = u64::try_from(boundary.offset).map_err(|_| {
                Error::new(ErrorKind::Internal, "chunk offset cannot be represented")
            })?;
            chunks.push(ContentDefinedChunk {
                offset,
                length: boundary.length,
                content_id: sha256_content_id(&source[boundary.offset..end]),
            });
            expected_offset = end;
        }
        if expected_offset != source.len() {
            return Err(Error::new(
                ErrorKind::Internal,
                "FastCDC did not cover the complete input",
            ));
        }
        Ok(chunks)
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::ContentHashAlgorithm;

    fn parameters(maximum_chunks: usize) -> ContentDefinedChunkingParameters {
        ContentDefinedChunkingParameters::new(64, 256, 1024, maximum_chunks)
            .expect("valid parameters")
    }

    fn binary_source(length: usize) -> Vec<u8> {
        let mut state = 0xd8e4_2f31_a6b9_c507u64;
        (0..length)
            .map(|_| {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1);
                (state >> 56) as u8
            })
            .collect()
    }

    #[test]
    fn chunks_binary_input_deterministically_with_golden_boundaries() {
        let source = binary_source(3_000);
        let chunker = ContentDefinedChunker::new(parameters(32));
        let first = chunker.chunk(&source).expect("first chunking");
        let second = chunker.chunk(&source).expect("second chunking");
        let layout: Vec<_> = first
            .iter()
            .map(|chunk| (chunk.offset(), chunk.length()))
            .collect();

        assert_eq!(first, second);
        assert_eq!(
            layout,
            vec![
                (0, 65),
                (65, 454),
                (519, 285),
                (804, 110),
                (914, 314),
                (1228, 276),
                (1504, 133),
                (1637, 295),
                (1932, 71),
                (2003, 151),
                (2154, 460),
                (2614, 306),
                (2920, 80),
            ]
        );
    }

    #[test]
    fn chunks_cover_binary_input_and_hash_each_range() {
        let source = binary_source(3_000);
        let chunker = ContentDefinedChunker::new(parameters(32));
        let chunks = chunker.chunk(&source).expect("chunk input");
        let mut expected_offset = 0usize;

        for (index, chunk) in chunks.iter().enumerate() {
            let offset = usize::try_from(chunk.offset()).expect("platform offset");
            let end = offset + chunk.length();

            assert_eq!(offset, expected_offset);
            assert!(chunk.length() <= chunker.parameters().maximum_size());
            if index + 1 < chunks.len() {
                assert!(chunk.length() >= chunker.parameters().minimum_size());
            }
            assert_eq!(
                chunk.content_id(),
                sha256_content_id(&source[offset..end]),
                "chunk identity must bind its exact range"
            );
            assert_eq!(chunk.content_id().algorithm(), ContentHashAlgorithm::Sha256);
            expected_offset = end;
        }
        assert_eq!(expected_offset, source.len());
        assert_eq!(
            chunks.last().map(|chunk| chunk.end_offset()),
            Some(source.len() as u64)
        );
    }

    proptest! {
        #[test]
        fn generated_chunks_cover_reassemble_and_verify_each_range(
            source in prop::collection::vec(any::<u8>(), 0..16_385),
        ) {
            let chunker = ContentDefinedChunker::new(parameters(512));
            let chunks = chunker.chunk(&source).expect("chunk generated input");
            let mut reassembled = Vec::with_capacity(source.len());
            let mut expected_offset = 0usize;

            for chunk in chunks {
                let offset = usize::try_from(chunk.offset()).expect("platform offset");
                let end = offset.checked_add(chunk.length()).expect("chunk end");
                prop_assert_eq!(offset, expected_offset);
                prop_assert!(end <= source.len());
                prop_assert_eq!(
                    chunk.content_id(),
                    sha256_content_id(&source[offset..end]),
                );
                reassembled.extend_from_slice(&source[offset..end]);
                expected_offset = end;
            }

            prop_assert_eq!(expected_offset, source.len());
            prop_assert_eq!(reassembled, source);
        }
    }

    #[test]
    fn empty_input_has_no_chunks() {
        let chunks = ContentDefinedChunker::new(parameters(1))
            .chunk(&[])
            .expect("empty input");

        assert!(chunks.is_empty());
    }

    #[test]
    fn rejects_invalid_parameters() {
        let cases = [
            (63, 256, 1024, 1, "FastCDC minimum chunk size is invalid"),
            (64, 255, 1024, 1, "FastCDC average chunk size is invalid"),
            (64, 256, 1023, 1, "FastCDC maximum chunk size is invalid"),
            (
                512,
                256,
                1024,
                1,
                "FastCDC chunk sizes must be ordered minimum through maximum",
            ),
            (
                64,
                256,
                1024,
                0,
                "FastCDC maximum chunk count must not be zero",
            ),
        ];

        for (minimum, average, maximum, count, message) in cases {
            let error = ContentDefinedChunkingParameters::new(minimum, average, maximum, count)
                .expect_err("invalid parameters must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(error.public_message(), message);
        }
    }

    #[test]
    fn rejects_inputs_that_cannot_fit_the_chunk_limit() {
        let source = b"private source body".repeat(128);
        let error = ContentDefinedChunker::new(parameters(2))
            .chunk(&source)
            .expect_err("preflight limit must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "chunk input exceeds the configured chunk count limit"
        );
        assert!(!error.to_string().contains("private source body"));
    }

    #[test]
    fn rejects_chunk_limit_exhaustion_during_iteration() {
        let source = binary_source(2_000);
        let error = ContentDefinedChunker::new(parameters(2))
            .chunk(&source)
            .expect_err("iteration limit must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "chunk input exceeds the configured chunk count limit"
        );
    }

    #[test]
    fn public_chunk_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<ContentDefinedChunkingParameters>();
        assert_send_sync::<ContentDefinedChunk>();
        assert_send_sync::<ContentDefinedChunker>();
    }
}
