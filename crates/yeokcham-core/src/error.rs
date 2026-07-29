use std::error::Error as StdError;
use std::fmt;

use thiserror::Error as ThisError;

type BoxError = Box<dyn StdError + Send + Sync + 'static>;

/// Broad, machine-readable classification for a Yeokcham failure.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[non_exhaustive]
pub enum ErrorKind {
    /// Input failed validation.
    InvalidInput,
    /// The requested format, feature, or operation is unsupported.
    Unsupported,
    /// A requested repository resource does not exist.
    NotFound,
    /// Existing state conflicts with the requested transition.
    Conflict,
    /// Stored or received bytes are malformed or corrupt.
    CorruptData,
    /// A filesystem or stream operation failed.
    Io,
    /// An internal invariant failed without a more specific classification.
    Internal,
}

impl ErrorKind {
    /// Returns the stable, machine-readable code for this classification.
    pub const fn code(self) -> &'static str {
        match self {
            Self::InvalidInput => "invalid_input",
            Self::Unsupported => "unsupported",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::CorruptData => "corrupt_data",
            Self::Io => "io",
            Self::Internal => "internal",
        }
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code())
    }
}

/// A classified Yeokcham failure with a redacted public message.
#[derive(ThisError)]
#[error("{message}")]
pub struct Error {
    kind: ErrorKind,
    message: &'static str,
    #[source]
    source: Option<BoxError>,
}

impl Error {
    /// Creates an error without an underlying source.
    pub const fn new(kind: ErrorKind, message: &'static str) -> Self {
        Self {
            kind,
            message,
            source: None,
        }
    }

    /// Creates an error while retaining an underlying source for explicit inspection.
    pub fn with_source<E>(kind: ErrorKind, message: &'static str, source: E) -> Self
    where
        E: StdError + Send + Sync + 'static,
    {
        Self {
            kind,
            message,
            source: Some(Box::new(source)),
        }
    }

    /// Returns the broad failure classification.
    pub const fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// Returns the stable, machine-readable failure code.
    pub const fn code(&self) -> &'static str {
        self.kind.code()
    }

    /// Returns the redacted message safe for default user-facing output.
    pub const fn public_message(&self) -> &'static str {
        self.message
    }
}

impl fmt::Debug for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Error")
            .field("kind", &self.kind)
            .field("message", &self.message)
            .field("has_source", &self.source.is_some())
            .finish()
    }
}

/// Result type used by Yeokcham core APIs.
pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use std::error::Error as _;

    use super::*;

    #[derive(Debug, ThisError)]
    #[error("secret source detail")]
    struct SensitiveSource;

    #[test]
    fn exposes_structured_kind_and_code() {
        let error = Error::new(ErrorKind::CorruptData, "stored record is corrupt");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(error.code(), "corrupt_data");
        assert_eq!(error.public_message(), "stored record is corrupt");
        assert_eq!(error.to_string(), "stored record is corrupt");
    }

    #[test]
    fn kind_codes_are_stable() {
        let cases = [
            (ErrorKind::InvalidInput, "invalid_input"),
            (ErrorKind::Unsupported, "unsupported"),
            (ErrorKind::NotFound, "not_found"),
            (ErrorKind::Conflict, "conflict"),
            (ErrorKind::CorruptData, "corrupt_data"),
            (ErrorKind::Io, "io"),
            (ErrorKind::Internal, "internal"),
        ];

        for (kind, code) in cases {
            assert_eq!(kind.code(), code);
            assert_eq!(kind.to_string(), code);
        }
    }

    #[test]
    fn default_rendering_redacts_source_details() {
        let error = Error::with_source(ErrorKind::Io, "storage operation failed", SensitiveSource);

        assert_eq!(error.to_string(), "storage operation failed");
        assert!(!format!("{error:?}").contains("secret source detail"));
        assert_eq!(
            error.source().map(ToString::to_string),
            Some("secret source detail".to_owned())
        );
    }

    #[test]
    fn error_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<Error>();
    }
}
