use std::{fmt, str::FromStr};

use crate::{Error, ErrorKind, Result};

/// Algorithm attached to a Yeokcham plaintext content identity.
///
/// The names emitted by `Display` are the canonical settings and textual-ID
/// names. This type selects an algorithm; it does not hold key material.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[non_exhaustive]
pub enum ContentHashAlgorithm {
    /// HMAC instantiated with SHA-256 and a repository-scoped key.
    HmacSha256,
    /// BLAKE3's keyed mode with a repository-scoped key.
    Blake3Keyed,
    /// Unkeyed SHA-256.
    Sha256,
    /// Unkeyed BLAKE3.
    Blake3,
}

impl ContentHashAlgorithm {
    /// Returns the canonical settings and textual-ID name.
    pub const fn canonical_name(self) -> &'static str {
        match self {
            Self::HmacSha256 => "hmac-sha256",
            Self::Blake3Keyed => "blake3-keyed",
            Self::Sha256 => "sha256",
            Self::Blake3 => "blake3",
        }
    }

    /// Reports whether computing and verifying IDs requires repository key material.
    pub const fn requires_key(self) -> bool {
        matches!(self, Self::HmacSha256 | Self::Blake3Keyed)
    }
}

impl FromStr for ContentHashAlgorithm {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "hmac-sha256" => Ok(Self::HmacSha256),
            "blake3-keyed" => Ok(Self::Blake3Keyed),
            "sha256" => Ok(Self::Sha256),
            "blake3" => Ok(Self::Blake3),
            _ => Err(Error::new(
                ErrorKind::Unsupported,
                "content hash algorithm is not supported",
            )),
        }
    }
}

impl fmt::Display for ContentHashAlgorithm {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.canonical_name())
    }
}

/// Algorithm-tagged plaintext content identity used by Yeokcham storage.
///
/// Values contain a supported algorithm and its complete 32-byte output.
/// Text uses `<algorithm>:<64-lowercase-hex>`. Construction from a digest is
/// structural only; reconstructed content must be rehashed before trust.
/// `Debug` is redacted; `Display` is an explicit metadata disclosure.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct YeokchamContentId {
    algorithm: ContentHashAlgorithm,
    digest: [u8; Self::DIGEST_LENGTH],
}

impl YeokchamContentId {
    /// Number of bytes emitted by every supported content hash algorithm.
    pub const DIGEST_LENGTH: usize = 32;
    /// Number of hexadecimal digits in the digest portion of a textual ID.
    pub const HEX_LENGTH: usize = Self::DIGEST_LENGTH * 2;

    /// Constructs an algorithm-tagged identity from a complete digest.
    pub const fn from_digest(
        algorithm: ContentHashAlgorithm,
        digest: [u8; Self::DIGEST_LENGTH],
    ) -> Self {
        Self { algorithm, digest }
    }

    /// Returns the algorithm attached to this identity.
    pub const fn algorithm(self) -> ContentHashAlgorithm {
        self.algorithm
    }

    /// Returns the complete digest bytes.
    pub const fn digest(&self) -> &[u8; Self::DIGEST_LENGTH] {
        &self.digest
    }

    /// Consumes the identity and returns its algorithm and digest.
    pub const fn into_parts(self) -> (ContentHashAlgorithm, [u8; Self::DIGEST_LENGTH]) {
        (self.algorithm, self.digest)
    }
}

impl FromStr for YeokchamContentId {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        let (algorithm, digest) = value.split_once(':').ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidInput,
                "Yeokcham content ID must include an algorithm tag",
            )
        })?;
        let algorithm = algorithm.parse()?;
        if digest.len() != Self::HEX_LENGTH
            || digest
                .bytes()
                .any(|byte| !byte.is_ascii_digit() && !(b'a'..=b'f').contains(&byte))
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Yeokcham content ID digest must be 64 lowercase hexadecimal digits",
            ));
        }

        let mut bytes = [0; Self::DIGEST_LENGTH];
        hex::decode_to_slice(digest, &mut bytes).map_err(|source| {
            Error::with_source(
                ErrorKind::InvalidInput,
                "Yeokcham content ID digest is not valid hexadecimal",
                source,
            )
        })?;
        Ok(Self::from_digest(algorithm, bytes))
    }
}

impl fmt::Display for YeokchamContentId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}:", self.algorithm)?;
        for byte in self.digest {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for YeokchamContentId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("YeokchamContentId(<redacted>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn algorithms_use_canonical_names() {
        let cases = [
            (ContentHashAlgorithm::HmacSha256, "hmac-sha256"),
            (ContentHashAlgorithm::Blake3Keyed, "blake3-keyed"),
            (ContentHashAlgorithm::Sha256, "sha256"),
            (ContentHashAlgorithm::Blake3, "blake3"),
        ];

        for (algorithm, name) in cases {
            assert_eq!(algorithm.canonical_name(), name);
            assert_eq!(algorithm.to_string(), name);
            assert_eq!(
                name.parse::<ContentHashAlgorithm>().expect("known name"),
                algorithm
            );
        }
    }

    #[test]
    fn classifies_keyed_algorithms() {
        assert!(ContentHashAlgorithm::HmacSha256.requires_key());
        assert!(ContentHashAlgorithm::Blake3Keyed.requires_key());
        assert!(!ContentHashAlgorithm::Sha256.requires_key());
        assert!(!ContentHashAlgorithm::Blake3.requires_key());
    }

    #[test]
    fn canonical_text_and_parts_round_trip_for_every_algorithm() {
        let algorithms = [
            ContentHashAlgorithm::HmacSha256,
            ContentHashAlgorithm::Blake3Keyed,
            ContentHashAlgorithm::Sha256,
            ContentHashAlgorithm::Blake3,
        ];

        for algorithm in algorithms {
            let text = format!("{}:{DIGEST}", algorithm.canonical_name());
            let id: YeokchamContentId = text.parse().expect("valid content ID");
            let (parsed_algorithm, digest) = id.into_parts();

            assert_eq!(id.to_string(), text);
            assert_eq!(parsed_algorithm, algorithm);
            assert_eq!(id.algorithm(), algorithm);
            assert_eq!(id.digest(), &digest);
            assert_eq!(digest.len(), YeokchamContentId::DIGEST_LENGTH);
        }
    }

    #[test]
    fn rejects_unknown_algorithm() {
        let value = format!("sha3-256:{DIGEST}");
        let error = value
            .parse::<YeokchamContentId>()
            .expect_err("unknown algorithm must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "content hash algorithm is not supported"
        );
    }

    #[test]
    fn rejects_missing_tag_and_invalid_digest() {
        let uppercase = format!("sha256:{}", DIGEST.to_uppercase());
        let invalid = format!("sha256:{}g", &DIGEST[..DIGEST.len() - 1]);
        let short = format!("sha256:{}", &DIGEST[..DIGEST.len() - 2]);

        let missing_tag = DIGEST
            .parse::<YeokchamContentId>()
            .expect_err("missing tag must fail");
        assert_eq!(missing_tag.kind(), ErrorKind::InvalidInput);
        assert_eq!(
            missing_tag.public_message(),
            "Yeokcham content ID must include an algorithm tag"
        );

        for value in [uppercase, invalid, short] {
            let error = value
                .parse::<YeokchamContentId>()
                .expect_err("invalid digest must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(
                error.public_message(),
                "Yeokcham content ID digest must be 64 lowercase hexadecimal digits"
            );
        }
    }

    #[test]
    fn algorithm_is_part_of_identity() {
        let digest = [7; YeokchamContentId::DIGEST_LENGTH];
        let sha256 = YeokchamContentId::from_digest(ContentHashAlgorithm::Sha256, digest);
        let blake3 = YeokchamContentId::from_digest(ContentHashAlgorithm::Blake3, digest);

        assert_ne!(sha256, blake3);
    }

    #[test]
    fn debug_is_redacted_and_display_is_explicit() {
        let text = format!("sha256:{DIGEST}");
        let id: YeokchamContentId = text.parse().expect("valid content ID");

        assert_eq!(format!("{id:?}"), "YeokchamContentId(<redacted>)");
        assert_eq!(format!("{id}"), text);
    }

    #[test]
    fn content_id_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<ContentHashAlgorithm>();
        assert_send_sync::<YeokchamContentId>();
    }
}
