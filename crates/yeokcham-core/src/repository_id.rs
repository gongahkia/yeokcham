use std::{fmt, str::FromStr};

use uuid::{Uuid, Variant, Version};

use crate::{Error, ErrorKind, Result};

/// Opaque, stable identity for a Yeokcham repository.
///
/// Values are RFC 9562 UUIDv4 identifiers stored as 16 bytes. Text input must
/// use the lowercase hyphenated form. `Debug` is redacted; `Display` is an
/// explicit metadata disclosure.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RepositoryId([u8; 16]);

impl RepositoryId {
    /// Generates an RFC 9562 UUIDv4 repository identity.
    pub fn generate() -> Self {
        Self(Uuid::new_v4().into_bytes())
    }

    /// Validates and constructs an identity from its 16-byte representation.
    pub fn from_bytes(bytes: [u8; 16]) -> Result<Self> {
        let uuid = Uuid::from_bytes(bytes);
        if uuid.get_variant() != Variant::RFC4122 || uuid.get_version() != Some(Version::Random) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "repository ID is not an RFC 9562 UUIDv4",
            ));
        }
        Ok(Self(bytes))
    }

    /// Returns the validated 16-byte representation.
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Consumes the identity and returns its validated 16-byte representation.
    pub const fn into_bytes(self) -> [u8; 16] {
        self.0
    }
}

impl FromStr for RepositoryId {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        let uuid = Uuid::parse_str(value).map_err(|source| {
            Error::with_source(
                ErrorKind::InvalidInput,
                "repository ID is not a UUID",
                source,
            )
        })?;
        if uuid.hyphenated().to_string() != value {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "repository ID is not in canonical lowercase hyphenated form",
            ));
        }
        Self::from_bytes(uuid.into_bytes())
    }
}

impl fmt::Display for RepositoryId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        Uuid::from_bytes(self.0).hyphenated().fmt(formatter)
    }
}

impl fmt::Debug for RepositoryId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RepositoryId(<redacted>)")
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as _;

    use super::*;

    const CANONICAL: &str = "550e8400-e29b-41d4-a716-446655440000";

    #[test]
    fn generated_id_is_rfc_uuid_v4() {
        let id = RepositoryId::generate();
        let uuid = Uuid::from_bytes(id.into_bytes());

        assert_eq!(uuid.get_variant(), Variant::RFC4122);
        assert_eq!(uuid.get_version(), Some(Version::Random));
    }

    #[test]
    fn canonical_text_round_trips() {
        let id: RepositoryId = CANONICAL.parse().expect("valid repository ID");

        assert_eq!(id.to_string(), CANONICAL);
        assert_eq!(
            RepositoryId::from_bytes(id.into_bytes()).expect("valid bytes"),
            id
        );
        assert_eq!(id.as_bytes(), &id.into_bytes());
    }

    #[test]
    fn rejects_noncanonical_text() {
        for value in [
            "550E8400-E29B-41D4-A716-446655440000",
            "550e8400e29b41d4a716446655440000",
            "{550e8400-e29b-41d4-a716-446655440000}",
        ] {
            let error = value
                .parse::<RepositoryId>()
                .expect_err("noncanonical form must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(
                error.public_message(),
                "repository ID is not in canonical lowercase hyphenated form"
            );
        }
    }

    #[test]
    fn rejects_wrong_version_and_variant() {
        let valid: RepositoryId = CANONICAL.parse().expect("valid repository ID");
        let mut wrong_version = valid.into_bytes();
        wrong_version[6] = (wrong_version[6] & 0x0f) | 0x70;
        let mut wrong_variant = valid.into_bytes();
        wrong_variant[8] &= 0x3f;

        for bytes in [[0; 16], wrong_version, wrong_variant] {
            let error = RepositoryId::from_bytes(bytes).expect_err("invalid UUID must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(
                error.public_message(),
                "repository ID is not an RFC 9562 UUIDv4"
            );
        }
    }

    #[test]
    fn malformed_text_retains_source_without_default_disclosure() {
        let error = "not-a-uuid"
            .parse::<RepositoryId>()
            .expect_err("malformed UUID must fail");

        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert_eq!(error.to_string(), "repository ID is not a UUID");
        assert!(error.source().is_some());
        assert!(!format!("{error:?}").contains("not-a-uuid"));
    }

    #[test]
    fn debug_is_redacted_and_display_is_explicit() {
        let id: RepositoryId = CANONICAL.parse().expect("valid repository ID");

        assert_eq!(format!("{id:?}"), "RepositoryId(<redacted>)");
        assert_eq!(format!("{id}"), CANONICAL);
    }

    #[test]
    fn repository_id_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RepositoryId>();
    }
}
