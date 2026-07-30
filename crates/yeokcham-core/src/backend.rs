use std::{future::Future, pin::Pin};

use crate::{Error, ErrorKind, Result};

const MAXIMUM_KEY_BYTES: usize = 1_024;

/// A sendable future returned by one runtime-neutral backend operation.
pub type BackendFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;

/// One bounded opaque object key accepted by a backend.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct BackendKey(String);

impl BackendKey {
    /// validates and constructs one nonempty opaque object key.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        validate_key(bytes, false)?;
        Ok(Self(String::from_utf8(bytes.to_vec()).map_err(|_| {
            Error::new(ErrorKind::InvalidInput, "backend key is invalid")
        })?))
    }

    /// returns the canonical key bytes for explicit backend operations.
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl std::fmt::Debug for BackendKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BackendKey(<redacted>)")
    }
}

/// One validated prefix for paginated backend listing.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct BackendPrefix(String);

impl BackendPrefix {
    /// validates and constructs one opaque prefix, including the empty root prefix.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        validate_key(bytes, true)?;
        Ok(Self(String::from_utf8(bytes.to_vec()).map_err(|_| {
            Error::new(ErrorKind::InvalidInput, "backend prefix is invalid")
        })?))
    }

    /// returns the canonical prefix bytes for explicit backend operations.
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl std::fmt::Debug for BackendPrefix {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BackendPrefix(<redacted>)")
    }
}

/// An opaque continuation token returned by one backend list page.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct BackendCursor(BackendKey);

impl BackendCursor {
    /// returns the opaque key bytes carried by this backend-specific cursor.
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }

    /// constructs a continuation token from one backend-selected key.
    pub fn from_key(key: BackendKey) -> Self {
        Self(key)
    }

    /// returns the opaque key value carried by this cursor.
    pub const fn key(&self) -> &BackendKey {
        &self.0
    }
}

impl std::fmt::Debug for BackendCursor {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BackendCursor(<redacted>)")
    }
}

/// An inclusive-start, exclusive-end byte range.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BackendByteRange {
    start: u64,
    end_exclusive: u64,
}

impl BackendByteRange {
    /// validates and constructs one byte range.
    pub fn new(start: u64, end_exclusive: u64) -> Result<Self> {
        if start > end_exclusive {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend byte range is invalid",
            ));
        }
        Ok(Self {
            start,
            end_exclusive,
        })
    }

    /// returns the inclusive range start.
    pub const fn start(self) -> u64 {
        self.start
    }

    /// returns the exclusive range end.
    pub const fn end_exclusive(self) -> u64 {
        self.end_exclusive
    }

    /// returns the bounded requested byte length.
    pub const fn len(self) -> u64 {
        self.end_exclusive - self.start
    }

    /// reports whether the range selects no bytes.
    pub const fn is_empty(self) -> bool {
        self.start == self.end_exclusive
    }
}

/// Caller bounds for one backend read result.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BackendReadLimits {
    maximum_bytes: u64,
}

impl BackendReadLimits {
    /// constructs one maximum accepted backend read size.
    pub const fn new(maximum_bytes: u64) -> Self {
        Self { maximum_bytes }
    }

    /// returns the maximum accepted response bytes.
    pub const fn maximum_bytes(self) -> u64 {
        self.maximum_bytes
    }
}

/// One bounded backend read request.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BackendReadRequest {
    range: Option<BackendByteRange>,
    limits: BackendReadLimits,
}

impl BackendReadRequest {
    /// constructs one full-object bounded read request.
    pub const fn full(limits: BackendReadLimits) -> Self {
        Self {
            range: None,
            limits,
        }
    }

    /// constructs one bounded range-read request.
    pub const fn range(range: BackendByteRange, limits: BackendReadLimits) -> Self {
        Self {
            range: Some(range),
            limits,
        }
    }

    /// returns the optional requested byte range.
    pub const fn requested_range(self) -> Option<BackendByteRange> {
        self.range
    }

    /// returns caller read bounds.
    pub const fn limits(self) -> BackendReadLimits {
        self.limits
    }
}

/// Caller bounds for one backend list request.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BackendListLimits {
    maximum_entries: usize,
    maximum_scanned_entries: usize,
}

impl BackendListLimits {
    /// validates bounds for one paginated backend list request.
    pub fn new(maximum_entries: usize, maximum_scanned_entries: usize) -> Result<Self> {
        if maximum_entries == 0 || maximum_scanned_entries < maximum_entries {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend list limits are invalid",
            ));
        }
        Ok(Self {
            maximum_entries,
            maximum_scanned_entries,
        })
    }

    /// returns the maximum entries returned in one page.
    pub const fn maximum_entries(self) -> usize {
        self.maximum_entries
    }

    /// returns the maximum entries inspected to construct one page.
    pub const fn maximum_scanned_entries(self) -> usize {
        self.maximum_scanned_entries
    }
}

/// Immutable metadata returned for one backend object.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BackendObjectMetadata {
    length: u64,
}

impl BackendObjectMetadata {
    /// constructs metadata for one exact immutable object length.
    pub const fn new(length: u64) -> Self {
        Self { length }
    }

    /// returns the exact stored byte length.
    pub const fn length(self) -> u64 {
        self.length
    }
}

/// The outcome of a create-only immutable backend publication.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum BackendPutResult {
    /// The backend created and durably exposed the object.
    Created(BackendObjectMetadata),
    /// The object name already existed and was not modified.
    AlreadyExists(BackendObjectMetadata),
}

/// One backend object entry returned by list.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendListEntry {
    key: BackendKey,
    metadata: BackendObjectMetadata,
}

impl BackendListEntry {
    /// constructs one object entry.
    pub fn new(key: BackendKey, metadata: BackendObjectMetadata) -> Self {
        Self { key, metadata }
    }

    /// returns the object key.
    pub const fn key(&self) -> &BackendKey {
        &self.key
    }

    /// returns immutable object metadata.
    pub const fn metadata(&self) -> BackendObjectMetadata {
        self.metadata
    }
}

/// One bounded backend list page.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendListPage {
    entries: Vec<BackendListEntry>,
    next_cursor: Option<BackendCursor>,
}

impl BackendListPage {
    /// constructs one bounded list page.
    pub fn new(entries: Vec<BackendListEntry>, next_cursor: Option<BackendCursor>) -> Self {
        Self {
            entries,
            next_cursor,
        }
    }

    /// returns page entries in backend-selected order.
    pub fn entries(&self) -> &[BackendListEntry] {
        &self.entries
    }

    /// returns the opaque continuation token, if more entries are available.
    pub const fn next_cursor(&self) -> Option<&BackendCursor> {
        self.next_cursor.as_ref()
    }
}

/// An opaque resumable-put session issued by one backend.
#[derive(Clone, Eq, Hash, PartialEq)]
pub struct BackendUploadSession {
    key: BackendKey,
    id: [u8; 16],
    total_length: u64,
}

impl BackendUploadSession {
    /// constructs one backend-owned resumable-put session.
    pub fn new(key: BackendKey, id: [u8; 16], total_length: u64) -> Self {
        Self {
            key,
            id,
            total_length,
        }
    }

    /// returns the immutable destination key.
    pub const fn key(&self) -> &BackendKey {
        &self.key
    }

    /// returns the expected final byte length.
    pub const fn total_length(&self) -> u64 {
        self.total_length
    }

    /// returns the opaque backend session identifier.
    pub const fn id(&self) -> [u8; 16] {
        self.id
    }
}

impl std::fmt::Debug for BackendUploadSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BackendUploadSession(<redacted>)")
    }
}

/// The outcome of opening a resumable immutable backend publication.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BackendResumablePutStart {
    /// A new private resumable session was created.
    Started(BackendUploadSession),
    /// The destination already existed and was not modified.
    AlreadyExists(BackendObjectMetadata),
}

/// A runtime-neutral, object-safe immutable backend interface.
///
/// Backends must not replace an existing object through `put_if_absent` or a
/// resumable completion. `delete` is maintenance-only and callers must never
/// use it to advance refs or replace recovery data. List ordering and
/// cross-object visibility are backend-specific and not part of this contract.
pub trait Backend: Send + Sync {
    /// creates one immutable object only if its key is absent.
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult>;

    /// reads one bounded full object or exact byte range.
    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>>;

    /// returns immutable metadata without reading object bytes.
    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata>;

    /// lists one bounded page under a prefix.
    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage>;

    /// removes one object only for explicit maintenance workflows.
    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()>;

    /// creates one private resumable immutable publication session.
    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart>;

    /// writes one contiguous resumable range at its caller-declared offset.
    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()>;

    /// durably publishes a complete resumable object without replacement.
    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult>;

    /// abandons one private resumable session without touching its destination.
    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()>;
}

fn validate_key(bytes: &[u8], allow_empty: bool) -> Result<()> {
    if bytes.len() > MAXIMUM_KEY_BYTES || (!allow_empty && bytes.is_empty()) {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "backend key is invalid",
        ));
    }
    if bytes.is_empty() {
        return Ok(());
    }
    if bytes[0] == b'/' {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "backend key is invalid",
        ));
    }
    let mut components = bytes.split(|byte| *byte == b'/').peekable();
    while let Some(component) = components.next() {
        if component.is_empty()
            && !(allow_empty && components.peek().is_none() && bytes.ends_with(b"/"))
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend key is invalid",
            ));
        }
        if component == b"." || component == b".." {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend key is invalid",
            ));
        }
        if !component.iter().all(|byte| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || matches!(*byte, b'-' | b'_' | b'.')
        }) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend key is invalid",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_and_prefixes_are_bounded_and_path_safe() {
        let key = BackendKey::from_bytes(b"segments/abc-123.yksg").expect("key");
        assert_eq!(key.as_bytes(), b"segments/abc-123.yksg");
        assert!(BackendPrefix::from_bytes(b"segments/").is_ok());
        assert!(BackendPrefix::from_bytes(b"").is_ok());
        for invalid in [b"".as_slice(), b"/root", b"a//b", b"a/../b", b"A", b"a b"] {
            assert_eq!(
                BackendKey::from_bytes(invalid)
                    .expect_err("invalid key")
                    .kind(),
                ErrorKind::InvalidInput
            );
        }
    }

    #[test]
    fn ranges_and_list_limits_are_validated() {
        assert_eq!(
            BackendByteRange::new(2, 1)
                .expect_err("backwards range")
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            BackendListLimits::new(0, 1).expect_err("empty page").kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            BackendListLimits::new(2, 1)
                .expect_err("unbounded scan")
                .kind(),
            ErrorKind::InvalidInput
        );
    }

    #[test]
    fn backend_trait_is_dyn_compatible_and_secrets_are_redacted() {
        fn assert_dyn_compatible(_: &dyn Backend) {}

        let key = BackendKey::from_bytes(b"segments/abc").expect("key");
        let session = BackendUploadSession::new(key.clone(), [7; 16], 8);
        assert_eq!(format!("{key:?}"), "BackendKey(<redacted>)");
        assert_eq!(format!("{session:?}"), "BackendUploadSession(<redacted>)");
        let _ = assert_dyn_compatible;
    }
}
