use std::{fmt, str::FromStr};

use crate::{Error, ErrorKind, Result};

/// Full SHA-1 object identity at the Git compatibility boundary.
///
/// Values contain exactly 20 digest bytes. Text input must use 40 lowercase
/// hexadecimal digits; abbreviated object names are lookup expressions, not
/// object identities. `Debug` is redacted; `Display` is an explicit metadata
/// disclosure.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct GitObjectId([u8; Self::BYTE_LENGTH]);

impl GitObjectId {
    /// Number of bytes in a supported Git object identity.
    pub const BYTE_LENGTH: usize = 20;
    /// Number of hexadecimal digits in a supported Git object identity.
    pub const HEX_LENGTH: usize = Self::BYTE_LENGTH * 2;

    /// Constructs an identity from its complete SHA-1 digest.
    pub const fn from_bytes(bytes: [u8; Self::BYTE_LENGTH]) -> Self {
        Self(bytes)
    }

    /// Returns the complete SHA-1 digest.
    pub const fn as_bytes(&self) -> &[u8; Self::BYTE_LENGTH] {
        &self.0
    }

    /// Consumes the identity and returns the complete SHA-1 digest.
    pub const fn into_bytes(self) -> [u8; Self::BYTE_LENGTH] {
        self.0
    }
}

impl FromStr for GitObjectId {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "SHA-256 Git object IDs are not supported",
            ));
        }
        if value.len() != Self::HEX_LENGTH
            || value
                .bytes()
                .any(|byte| !byte.is_ascii_digit() && !(b'a'..=b'f').contains(&byte))
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Git object ID must be 40 lowercase hexadecimal digits",
            ));
        }

        let mut bytes = [0; Self::BYTE_LENGTH];
        hex::decode_to_slice(value, &mut bytes).map_err(|source| {
            Error::with_source(
                ErrorKind::InvalidInput,
                "Git object ID is not valid hexadecimal",
                source,
            )
        })?;
        Ok(Self(bytes))
    }
}

impl fmt::Display for GitObjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for GitObjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GitObjectId(<redacted>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY_BLOB_ID: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    #[test]
    fn canonical_text_and_bytes_round_trip() {
        let id: GitObjectId = EMPTY_BLOB_ID.parse().expect("valid SHA-1 object ID");

        assert_eq!(id.to_string(), EMPTY_BLOB_ID);
        assert_eq!(GitObjectId::from_bytes(id.into_bytes()), id);
        assert_eq!(id.as_bytes(), &id.into_bytes());
        assert_eq!(id.as_bytes().len(), GitObjectId::BYTE_LENGTH);
        assert_eq!(id.to_string().len(), GitObjectId::HEX_LENGTH);
    }

    #[test]
    fn rejects_noncanonical_or_incomplete_text() {
        for value in [
            "E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391",
            "e69de29",
            "g69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
            " e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        ] {
            let error = value
                .parse::<GitObjectId>()
                .expect_err("invalid object ID must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(
                error.public_message(),
                "Git object ID must be 40 lowercase hexadecimal digits"
            );
        }
    }

    #[test]
    fn rejects_sha256_as_unsupported() {
        let error = "473a0f4c3be8a93681a267c76a77662a3e757c1b4dc98dcb61ec80c30d407fb7"
            .parse::<GitObjectId>()
            .expect_err("SHA-256 object ID must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "SHA-256 Git object IDs are not supported"
        );
    }

    #[test]
    fn debug_is_redacted_and_display_is_explicit() {
        let id: GitObjectId = EMPTY_BLOB_ID.parse().expect("valid SHA-1 object ID");

        assert_eq!(format!("{id:?}"), "GitObjectId(<redacted>)");
        assert_eq!(format!("{id}"), EMPTY_BLOB_ID);
    }

    #[test]
    fn value_semantics_use_digest_bytes() {
        let first = GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]);
        let mut next_bytes = [0; GitObjectId::BYTE_LENGTH];
        next_bytes[GitObjectId::BYTE_LENGTH - 1] = 1;
        let next = GitObjectId::from_bytes(next_bytes);

        assert_eq!(first, first);
        assert!(first < next);
    }

    #[test]
    fn git_object_id_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<GitObjectId>();
    }
}
