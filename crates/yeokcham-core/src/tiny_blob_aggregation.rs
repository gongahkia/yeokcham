use std::fmt;

use sha2::{Digest, Sha256};

use crate::yeokcham_content_id::sha256_content_id;
use crate::{
    CanonicalDecoder, CanonicalEncoder, ContentHashAlgorithm, Error, ErrorKind, GitObject,
    GitObjectId, GitObjectKind, Result, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKTA";
const VERSION: u16 = 1;
const RECORD_TYPE: u8 = 2;
const COMPRESSION_NONE: u8 = 0;
const CONTENT_DOMAIN: &[u8] = b"yeokcham/tiny-blob-aggregation/v1\0";

/// Largest number of distinct blobs permitted in one aggregation record.
pub const MAX_TINY_BLOB_AGGREGATION_ENTRIES: usize = 4096;

/// One verified blob stored in a [`TinyBlobAggregation`].
#[derive(Eq, PartialEq)]
pub struct TinyBlobEntry {
    git_object_id: GitObjectId,
    content_id: YeokchamContentId,
    data: Vec<u8>,
}

impl TinyBlobEntry {
    /// Returns the verified Git blob ID.
    pub const fn git_object_id(&self) -> GitObjectId {
        self.git_object_id
    }

    /// Returns the verified plaintext content ID.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the exact Git blob body bytes.
    pub fn data(&self) -> &[u8] {
        &self.data
    }

    fn from_verified_blob(object: &GitObject) -> Result<Self> {
        if object.kind() != GitObjectKind::Blob {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "tiny-blob aggregation requires Git blobs",
            ));
        }
        object.verify_id()?;
        Ok(Self {
            git_object_id: object.id(),
            content_id: sha256_content_id(object.data()),
            data: object.data().to_vec(),
        })
    }

    fn verify(&self) -> Result<()> {
        if self.git_object_id != GitObject::recompute_id_for(GitObjectKind::Blob, &self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob entry Git object ID does not match its bytes",
            ));
        }
        if self.content_id != sha256_content_id(&self.data) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob entry content ID does not match its bytes",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for TinyBlobEntry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TinyBlobEntry")
            .field("git_object_id", &self.git_object_id)
            .field("content_id", &self.content_id)
            .field("data", &"<redacted>")
            .finish()
    }
}

/// A canonical no-compression record aggregating distinct verified Git blobs.
///
/// Entries sort strictly by Git object ID, so a logical aggregation has one
/// byte encoding. Version 1 writes unkeyed SHA-256 IDs for each blob and for
/// the domain-separated aggregate entry sequence.
#[derive(Eq, PartialEq)]
pub struct TinyBlobAggregation {
    content_id: YeokchamContentId,
    entries: Vec<TinyBlobEntry>,
}

impl TinyBlobAggregation {
    /// Creates an aggregation from distinct verified Git blobs.
    ///
    /// The constructor sorts entries by Git object ID and rejects empty or
    /// duplicate input. Storage policy selects which already-read blobs are
    /// tiny; this representation deliberately has no implicit byte threshold.
    pub fn from_verified_blobs(objects: &[GitObject]) -> Result<Self> {
        if objects.is_empty() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "tiny-blob aggregation requires at least one blob",
            ));
        }
        if objects.len() > MAX_TINY_BLOB_AGGREGATION_ENTRIES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation has too many entries",
            ));
        }
        let mut entries = Vec::with_capacity(objects.len());
        for object in objects {
            entries.push(TinyBlobEntry::from_verified_blob(object)?);
        }
        entries.sort_by_key(|entry| entry.git_object_id);
        if entries
            .windows(2)
            .any(|pair| pair[0].git_object_id == pair[1].git_object_id)
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "tiny-blob aggregation contains duplicate Git object IDs",
            ));
        }
        let content_id = aggregate_content_id(&entries)?;
        Ok(Self {
            content_id,
            entries,
        })
    }

    /// Decodes and verifies a caller-bounded aggregation record.
    ///
    /// `maximum_entries` and `maximum_total_body_bytes` limit work and body
    /// allocation in addition to the fixed format entry limit. `bytes` must
    /// already be bounded by the caller before decoding starts.
    pub fn decode(
        bytes: &[u8],
        maximum_entries: usize,
        maximum_total_body_bytes: usize,
    ) -> Result<Self> {
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation uses unsupported features",
            ));
        }
        if decoder.read_u8()? != RECORD_TYPE {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation has an invalid type",
            ));
        }
        if decoder.read_u8()? != COMPRESSION_NONE {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation compression is unsupported",
            ));
        }
        ensure_sha256_algorithm(decoder.read_u8()?)?;
        let content_id =
            YeokchamContentId::from_digest(ContentHashAlgorithm::Sha256, decoder.read_fixed()?);
        let entry_count = usize::try_from(decoder.read_u32()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation entry count is invalid",
            )
        })?;
        if entry_count == 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation has no entries",
            ));
        }
        if entry_count > MAX_TINY_BLOB_AGGREGATION_ENTRIES || entry_count > maximum_entries {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation has too many entries",
            ));
        }

        let mut entries = Vec::new();
        let mut total_body_bytes = 0usize;
        for _ in 0..entry_count {
            let git_object_id = GitObjectId::from_bytes(decoder.read_fixed()?);
            ensure_sha256_algorithm(decoder.read_u8()?)?;
            let entry_content_id =
                YeokchamContentId::from_digest(ContentHashAlgorithm::Sha256, decoder.read_fixed()?);
            let data = decoder.read_byte_string()?;
            total_body_bytes = total_body_bytes.checked_add(data.len()).ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "tiny-blob aggregation body length is invalid",
                )
            })?;
            if total_body_bytes > maximum_total_body_bytes {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "tiny-blob aggregation exceeds the decode limit",
                ));
            }
            entries.push(TinyBlobEntry {
                git_object_id,
                content_id: entry_content_id,
                data: data.to_vec(),
            });
        }
        decoder.finish()?;
        let aggregation = Self {
            content_id,
            entries,
        };
        aggregation.verify()?;
        Ok(aggregation)
    }

    /// Returns the verified content ID of the canonical aggregate entry sequence.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns distinct entries sorted by Git object ID.
    pub fn entries(&self) -> &[TinyBlobEntry] {
        &self.entries
    }

    /// Returns this aggregation's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_u8(RECORD_TYPE);
        encoder.write_u8(COMPRESSION_NONE);
        encoder.write_u8(self.content_id.algorithm().binary_tag());
        encoder.write_fixed(self.content_id.digest());
        encoder.write_u32(self.entries.len() as u32);
        for entry in &self.entries {
            encoder.write_fixed(entry.git_object_id.as_bytes());
            encoder.write_u8(entry.content_id.algorithm().binary_tag());
            encoder.write_fixed(entry.content_id.digest());
            encoder.write_byte_string(&entry.data);
        }
        encoder.into_bytes()
    }

    fn verify(&self) -> Result<()> {
        if self.entries.is_empty() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation has no entries",
            ));
        }
        if self.entries.len() > MAX_TINY_BLOB_AGGREGATION_ENTRIES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation has too many entries",
            ));
        }
        for entry in &self.entries {
            entry.verify()?;
        }
        if self
            .entries
            .windows(2)
            .any(|pair| pair[0].git_object_id >= pair[1].git_object_id)
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation entries are not strictly ordered",
            ));
        }
        if self.content_id != aggregate_content_id(&self.entries)? {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "tiny-blob aggregation content ID does not match its bytes",
            ));
        }
        Ok(())
    }
}

fn ensure_sha256_algorithm(tag: u8) -> Result<()> {
    let algorithm = ContentHashAlgorithm::from_binary_tag(tag).ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "tiny-blob aggregation has an invalid content hash algorithm",
        )
    })?;
    if algorithm != ContentHashAlgorithm::Sha256 {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "tiny-blob aggregation uses an unsupported content hash",
        ));
    }
    Ok(())
}

fn aggregate_content_id(entries: &[TinyBlobEntry]) -> Result<YeokchamContentId> {
    let count = u32::try_from(entries.len()).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "tiny-blob aggregation has too many entries",
        )
    })?;
    let mut hasher = Sha256::new();
    hasher.update(CONTENT_DOMAIN);
    hasher.update(count.to_be_bytes());
    for entry in entries {
        let length = u64::try_from(entry.data.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "tiny-blob aggregation body is too large",
            )
        })?;
        hasher.update(entry.git_object_id.as_bytes());
        hasher.update([entry.content_id.algorithm().binary_tag()]);
        hasher.update(entry.content_id.digest());
        hasher.update(length.to_be_bytes());
        hasher.update(&entry.data);
    }
    Ok(YeokchamContentId::from_digest(
        ContentHashAlgorithm::Sha256,
        hasher.finalize().into(),
    ))
}

impl fmt::Debug for TinyBlobAggregation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TinyBlobAggregation")
            .field("content_id", &self.content_id)
            .field("entry_count", &self.entries.len())
            .field("entries", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY_BLOB_ID: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const EMPTY_AGGREGATION_SHA256: [u8; YeokchamContentId::DIGEST_LENGTH] = [
        0xe0, 0x1c, 0xdd, 0xfe, 0x0f, 0xc8, 0xd2, 0x86, 0x7d, 0x40, 0x66, 0xcb, 0xb5, 0x89, 0xdc,
        0xca, 0x5f, 0xd3, 0x0a, 0x45, 0x17, 0xe0, 0x44, 0x0c, 0x02, 0x89, 0xd2, 0x14, 0x8f, 0x98,
        0x33, 0xd1,
    ];
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

    fn verified_object(kind: GitObjectKind, data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            kind,
            data.to_vec(),
        );
        GitObject::new(provisional.recompute_id(), kind, data.to_vec())
    }

    #[test]
    fn encodes_one_canonical_empty_blob_aggregation() {
        let empty = GitObject::new(
            EMPTY_BLOB_ID.parse().expect("empty blob ID"),
            GitObjectKind::Blob,
            Vec::new(),
        );
        let aggregation =
            TinyBlobAggregation::from_verified_blobs(&[empty]).expect("empty blob aggregation");
        let encoded = aggregation.encode();

        assert_eq!(
            aggregation.content_id(),
            YeokchamContentId::from_digest(ContentHashAlgorithm::Sha256, EMPTY_AGGREGATION_SHA256)
        );
        assert_eq!(
            &encoded[..61],
            [
                b'Y', b'K', b'T', b'A', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0,
                3, 0xe0, 0x1c, 0xdd, 0xfe, 0x0f, 0xc8, 0xd2, 0x86, 0x7d, 0x40, 0x66, 0xcb, 0xb5,
                0x89, 0xdc, 0xca, 0x5f, 0xd3, 0x0a, 0x45, 0x17, 0xe0, 0x44, 0x0c, 0x02, 0x89, 0xd2,
                0x14, 0x8f, 0x98, 0x33, 0xd1, 0, 0, 0, 1,
            ]
        );
        assert_eq!(
            &encoded[61..],
            [
                0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43, 0x4b, 0x8b, 0x29, 0xae, 0x77, 0x5a,
                0xd8, 0xc2, 0xe4, 0x8c, 0x53, 0x91, 3, 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c,
                0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64,
                0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55, 0, 0, 0, 0, 0, 0,
                0, 0,
            ]
        );
    }

    #[test]
    fn sorts_entries_and_round_trips_exact_binary_bodies() {
        let first = verified_blob(b"\0private first\xff");
        let second = verified_blob(b"second\n");
        let from_first_order =
            TinyBlobAggregation::from_verified_blobs(&[first, second]).expect("aggregation");
        let first = verified_blob(b"\0private first\xff");
        let second = verified_blob(b"second\n");
        let from_reverse_order =
            TinyBlobAggregation::from_verified_blobs(&[second, first]).expect("aggregation");
        let encoded = from_first_order.encode();
        let decoded = TinyBlobAggregation::decode(&encoded, 2, 64).expect("decode aggregation");

        assert_eq!(from_first_order, from_reverse_order);
        assert_eq!(decoded, from_first_order);
        assert!(
            decoded
                .entries()
                .windows(2)
                .all(|pair| pair[0].git_object_id() < pair[1].git_object_id())
        );
        assert_eq!(
            decoded
                .entries()
                .iter()
                .map(TinyBlobEntry::data)
                .collect::<Vec<_>>(),
            from_first_order
                .entries()
                .iter()
                .map(TinyBlobEntry::data)
                .collect::<Vec<_>>()
        );
        let debug = format!("{decoded:?}");
        assert!(!debug.contains("private first"));
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn rejects_empty_duplicate_non_blob_and_unverified_inputs() {
        let blob = verified_blob(b"body");
        let tree = verified_object(GitObjectKind::Tree, b"tree");
        let altered = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Blob,
            b"altered".to_vec(),
        );

        let empty = TinyBlobAggregation::from_verified_blobs(&[]).expect_err("empty must fail");
        let duplicate = TinyBlobAggregation::from_verified_blobs(&[blob, verified_blob(b"body")])
            .expect_err("duplicates must fail");
        let tree = TinyBlobAggregation::from_verified_blobs(&[tree]).expect_err("tree must fail");
        let altered =
            TinyBlobAggregation::from_verified_blobs(&[altered]).expect_err("altered must fail");

        assert_eq!(empty.kind(), ErrorKind::InvalidInput);
        assert_eq!(duplicate.kind(), ErrorKind::InvalidInput);
        assert_eq!(tree.kind(), ErrorKind::InvalidInput);
        assert_eq!(altered.kind(), ErrorKind::CorruptData);
        assert!(!altered.to_string().contains("altered"));
    }

    #[test]
    fn rejects_corrupt_unsupported_and_out_of_bound_encoded_aggregations() {
        let first = verified_blob(b"first");
        let second = verified_blob(b"second");
        let aggregation =
            TinyBlobAggregation::from_verified_blobs(&[first, second]).expect("aggregation");
        let encoded = aggregation.encode();
        let cases = [
            (0, b'X', ErrorKind::CorruptData),
            (5, 2, ErrorKind::Unsupported),
            (6, 1, ErrorKind::Unsupported),
            (22, 1, ErrorKind::CorruptData),
            (23, 1, ErrorKind::Unsupported),
            (24, 1, ErrorKind::Unsupported),
            (25, encoded[25] ^ 1, ErrorKind::CorruptData),
            (61, encoded[61] ^ 1, ErrorKind::CorruptData),
            (82, encoded[82] ^ 1, ErrorKind::CorruptData),
        ];

        for (offset, replacement, kind) in cases {
            let mut malformed = encoded.clone();
            malformed[offset] = replacement;
            let error = TinyBlobAggregation::decode(&malformed, 2, 64)
                .expect_err("malformed aggregation must fail");
            assert_eq!(error.kind(), kind, "offset {offset}");
            assert!(!error.to_string().contains("first"));
        }
        let mut zero_count = encoded.clone();
        zero_count[60] = 0;
        let zero_count =
            TinyBlobAggregation::decode(&zero_count, 2, 64).expect_err("zero count must fail");
        let truncated = TinyBlobAggregation::decode(&encoded[..encoded.len() - 1], 2, 64)
            .expect_err("truncated aggregation must fail");
        let mut trailing = encoded.clone();
        trailing.push(0);
        let trailing = TinyBlobAggregation::decode(&trailing, 2, 64)
            .expect_err("trailing aggregation must fail");
        let entry_limit =
            TinyBlobAggregation::decode(&encoded, 1, 64).expect_err("entry limit must fail");
        let size_limit =
            TinyBlobAggregation::decode(&encoded, 2, 10).expect_err("body limit must fail");

        assert_eq!(zero_count.kind(), ErrorKind::CorruptData);
        assert_eq!(truncated.kind(), ErrorKind::CorruptData);
        assert_eq!(trailing.kind(), ErrorKind::CorruptData);
        assert_eq!(entry_limit.kind(), ErrorKind::Unsupported);
        assert_eq!(size_limit.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn tiny_blob_aggregation_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<TinyBlobAggregation>();
        assert_send_sync::<TinyBlobEntry>();
    }
}
