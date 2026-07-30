use std::fmt;

use crate::{Error, ErrorKind, Result};

/// Supported version of a Yeokcham persistent repository format.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RepositoryFormatVersion(u16);

impl RepositoryFormatVersion {
    /// First Yeokcham persistent repository format version.
    pub const V1: Self = Self(1);

    /// Ref-journal repository format version.
    pub const V2: Self = Self(2);

    /// Validates a raw persistent repository format version.
    pub fn from_raw(raw: u16) -> Result<Self> {
        match raw {
            1 => Ok(Self::V1),
            2 => Ok(Self::V2),
            _ => Err(Error::new(
                ErrorKind::Unsupported,
                "repository format version is not supported",
            )),
        }
    }

    /// Returns the raw persistent repository format version.
    pub const fn as_u16(self) -> u16 {
        self.0
    }
}

impl fmt::Display for RepositoryFormatVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

/// Required and optional feature bits carried by a repository format record.
///
/// Readers reject unknown required bits. They retain unknown optional bits so
/// a read-modify-write path cannot silently erase forward-compatible metadata.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RepositoryFeatureFlags {
    required: u64,
    optional: u64,
}

impl RepositoryFeatureFlags {
    /// Empty feature flags for the initial format.
    pub const EMPTY: Self = Self {
        required: 0,
        optional: 0,
    };

    /// Validates required bits and preserves optional bits exactly.
    pub fn from_bits(required: u64, optional: u64) -> Result<Self> {
        if required != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "repository requires unsupported feature flags",
            ));
        }
        Ok(Self { required, optional })
    }

    /// Returns required feature bits.
    pub const fn required_bits(self) -> u64 {
        self.required
    }

    /// Returns optional feature bits, including unknown preserved bits.
    pub const fn optional_bits(self) -> u64 {
        self.optional
    }

    /// Reports whether this record declares no feature bits.
    pub const fn is_empty(self) -> bool {
        self.required == 0 && self.optional == 0
    }
}

/// Validated repository-format compatibility declaration.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RepositoryFormat {
    version: RepositoryFormatVersion,
    features: RepositoryFeatureFlags,
}

impl RepositoryFormat {
    /// Initial repository format with no feature flags.
    pub const fn initial() -> Self {
        Self {
            version: RepositoryFormatVersion::V1,
            features: RepositoryFeatureFlags::EMPTY,
        }
    }

    /// Validates raw persistent format fields.
    pub fn from_raw(version: u16, required_features: u64, optional_features: u64) -> Result<Self> {
        Ok(Self {
            version: RepositoryFormatVersion::from_raw(version)?,
            features: RepositoryFeatureFlags::from_bits(required_features, optional_features)?,
        })
    }

    /// Returns the validated format version.
    pub const fn version(self) -> RepositoryFormatVersion {
        self.version
    }

    /// Returns this format with a caller-selected supported version.
    pub const fn with_version(self, version: RepositoryFormatVersion) -> Self {
        Self {
            version,
            features: self.features,
        }
    }

    /// Returns validated feature flags.
    pub const fn features(self) -> RepositoryFeatureFlags {
        self.features
    }
}

impl Default for RepositoryFormat {
    fn default() -> Self {
        Self::initial()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_format_is_v1_without_features() {
        let format = RepositoryFormat::initial();

        assert_eq!(format.version(), RepositoryFormatVersion::V1);
        assert_eq!(format.version().as_u16(), 1);
        assert_eq!(format.version().to_string(), "1");
        assert!(format.features().is_empty());
        assert_eq!(format, RepositoryFormat::default());
    }

    #[test]
    fn rejects_unknown_format_versions() {
        for version in [0, 3, u16::MAX] {
            let error = RepositoryFormatVersion::from_raw(version)
                .expect_err("unsupported version must fail");

            assert_eq!(error.kind(), ErrorKind::Unsupported);
            assert_eq!(
                error.public_message(),
                "repository format version is not supported"
            );
        }
    }

    #[test]
    fn rejects_unknown_required_feature_bits() {
        let error =
            RepositoryFeatureFlags::from_bits(1, 0).expect_err("unknown required bits must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "repository requires unsupported feature flags"
        );
    }

    #[test]
    fn preserves_unknown_optional_feature_bits() {
        let flags = RepositoryFeatureFlags::from_bits(0, 1_u64 << 63)
            .expect("optional bits must be retained");
        let format =
            RepositoryFormat::from_raw(1, 0, 1_u64 << 63).expect("valid format with optional bits");

        assert!(!flags.is_empty());
        assert_eq!(flags.required_bits(), 0);
        assert_eq!(flags.optional_bits(), 1_u64 << 63);
        assert_eq!(format.features(), flags);
    }

    #[test]
    fn format_validation_rejects_unsupported_components() {
        let version_error =
            RepositoryFormat::from_raw(3, 0, 0).expect_err("unsupported version must fail");
        let feature_error = RepositoryFormat::from_raw(1, 1, 0)
            .expect_err("unsupported required features must fail");

        assert_eq!(version_error.kind(), ErrorKind::Unsupported);
        assert_eq!(feature_error.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn format_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RepositoryFormatVersion>();
        assert_send_sync::<RepositoryFeatureFlags>();
        assert_send_sync::<RepositoryFormat>();
    }
}
