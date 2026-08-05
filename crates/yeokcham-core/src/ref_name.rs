use std::{fmt, str::FromStr};

use crate::{Error, ErrorKind, Result};

/// Byte-preserving Git reference name validated without normalization.
///
/// Values follow `git check-ref-format`'s default rules: they contain a slash
/// and no refspec, branch-shorthand, or one-level exceptions. Valid names may
/// contain non-UTF-8 bytes. `Debug` is redacted; access bytes explicitly with
/// `as_bytes` when a caller has an approved disclosure or persistence path.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RefName(Box<[u8]>);

impl RefName {
    /// Validates and copies exact Git refname bytes without normalization.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        Self::try_from(bytes.to_vec())
    }

    /// Returns the exact validated Git refname bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// Consumes the refname and returns its exact validated bytes.
    pub fn into_bytes(self) -> Vec<u8> {
        self.0.into_vec()
    }
}

impl TryFrom<Vec<u8>> for RefName {
    type Error = Error;

    fn try_from(bytes: Vec<u8>) -> Result<Self> {
        if !is_valid_git_refname(&bytes) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "ref name is not a valid Git refname",
            ));
        }
        Ok(Self(bytes.into_boxed_slice()))
    }
}

impl FromStr for RefName {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        Self::from_bytes(value.as_bytes())
    }
}

impl fmt::Debug for RefName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RefName(<redacted>)")
    }
}

fn is_valid_git_refname(bytes: &[u8]) -> bool {
    if bytes.is_empty()
        || !bytes.contains(&b'/')
        || bytes.starts_with(b"/")
        || bytes.ends_with(b"/")
        || bytes
            .windows(2)
            .any(|window| matches!(window, b"//" | b".." | b"@{"))
        || bytes.ends_with(b".")
        || bytes == b"@"
        || bytes.iter().any(|byte| {
            *byte < 0x20
                || *byte == 0x7f
                || matches!(
                    *byte,
                    b' ' | b'~' | b'^' | b':' | b'?' | b'*' | b'[' | b'\\'
                )
        })
    {
        return false;
    }

    bytes
        .split(|byte| *byte == b'/')
        .all(|component| !component.starts_with(b".") && !component.ends_with(b".lock"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_git_refnames_and_preserves_exact_bytes() {
        let cases: &[&[u8]] = &[
            b"refs/heads/main",
            b"refs/tags/v1.0",
            b"custom/namespace",
            b"refs/heads/release-2026",
            b"refs/heads/\xff",
        ];

        for bytes in cases {
            let name = RefName::from_bytes(bytes).expect("valid Git refname");

            assert_eq!(name.as_bytes(), *bytes);
            assert_eq!(name.clone().into_bytes(), *bytes);
            assert_eq!(
                RefName::try_from(bytes.to_vec()).expect("valid bytes"),
                name
            );
        }
    }

    #[test]
    fn parses_utf8_git_refnames() {
        let name: RefName = "refs/heads/feature/one".parse().expect("valid Git refname");

        assert_eq!(name.as_bytes(), b"refs/heads/feature/one");
    }

    #[test]
    fn rejects_git_refname_rule_violations_without_normalizing() {
        let cases: &[&[u8]] = &[
            b"",
            b"HEAD",
            b"/refs/heads/main",
            b"refs/heads/main/",
            b"refs//heads/main",
            b"refs/.heads/main",
            b"refs/heads/main.lock",
            b"refs/heads/a..b",
            b"refs/heads/a b",
            b"refs/heads/a~b",
            b"refs/heads/a^b",
            b"refs/heads/a:b",
            b"refs/heads/a?b",
            b"refs/heads/a*b",
            b"refs/heads/a[b",
            b"refs/heads/a@{b",
            b"refs/heads/a\\b",
            b"refs/heads/a.",
            b"refs/heads/a\x1f",
            b"refs/heads/a\x7f",
        ];

        for bytes in cases {
            let error = RefName::from_bytes(bytes).expect_err("invalid refname must fail");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
            assert_eq!(
                error.public_message(),
                "ref name is not a valid Git refname"
            );
        }
    }

    #[test]
    fn default_errors_and_debug_redact_refnames() {
        let error = RefName::from_bytes(b"refs/heads/private branch")
            .expect_err("invalid refname must fail");
        let name: RefName = "refs/heads/private".parse().expect("valid Git refname");

        assert!(!error.to_string().contains("private branch"));
        assert_eq!(format!("{name:?}"), "RefName(<redacted>)");
    }

    #[test]
    fn ref_name_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RefName>();
    }
}
