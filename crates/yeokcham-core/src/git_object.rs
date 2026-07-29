use std::fmt;

use sha1::{Digest, Sha1};

use crate::{Error, ErrorKind, GitObjectId, Result};

/// The Git object type associated with an exact object body.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum GitObjectKind {
    /// An uninterpreted byte sequence.
    Blob,
    /// A directory listing of named object entries.
    Tree,
    /// A history node with a tree and zero or more parents.
    Commit,
    /// An annotated object reference.
    Tag,
}

impl GitObjectKind {
    /// Maps an internal Git-library kind without exposing that dependency publicly.
    pub(crate) const fn from_gix(kind: gix::objs::Kind) -> Self {
        match kind {
            gix::objs::Kind::Blob => Self::Blob,
            gix::objs::Kind::Tree => Self::Tree,
            gix::objs::Kind::Commit => Self::Commit,
            gix::objs::Kind::Tag => Self::Tag,
        }
    }

    const fn canonical_name(self) -> &'static [u8] {
        match self {
            Self::Blob => b"blob",
            Self::Tree => b"tree",
            Self::Commit => b"commit",
            Self::Tag => b"tag",
        }
    }
}

/// A Git object body read from a repository without ID verification.
///
/// `data` is the decompressed Git object body. It does not include the
/// canonical `"<type> <size>\\0"` header used to calculate `id`.
#[derive(Eq, PartialEq)]
pub struct GitObject {
    id: GitObjectId,
    kind: GitObjectKind,
    data: Vec<u8>,
}

impl GitObject {
    /// Returns the requested Git object ID, which has not yet been recomputed.
    pub const fn id(&self) -> GitObjectId {
        self.id
    }

    /// Returns the Git object type.
    pub const fn kind(&self) -> GitObjectKind {
        self.kind
    }

    /// Returns the exact decompressed Git object body.
    pub fn data(&self) -> &[u8] {
        &self.data
    }

    /// Consumes the object and returns its exact decompressed body.
    pub fn into_data(self) -> Vec<u8> {
        self.data
    }

    /// Recomputes the SHA-1 ID from the canonical Git header and body.
    pub fn recompute_id(&self) -> GitObjectId {
        Self::recompute_id_for(self.kind, &self.data)
    }

    /// Recomputes a SHA-1 ID from one Git type and exact object body.
    pub(crate) fn recompute_id_for(kind: GitObjectKind, data: &[u8]) -> GitObjectId {
        let mut hasher = Sha1::new();
        hasher.update(kind.canonical_name());
        hasher.update(b" ");
        hasher.update(data.len().to_string().as_bytes());
        hasher.update([0]);
        hasher.update(data);
        GitObjectId::from_bytes(hasher.finalize().into())
    }

    /// Returns the canonical loose-object header for the exact object body.
    pub(crate) fn loose_header(&self) -> Vec<u8> {
        let mut header = Vec::with_capacity(self.kind.canonical_name().len() + 22);
        header.extend_from_slice(self.kind.canonical_name());
        header.push(b' ');
        header.extend_from_slice(self.data.len().to_string().as_bytes());
        header.push(0);
        header
    }

    /// Verifies that the requested ID equals the canonical SHA-1 ID of this object.
    pub fn verify_id(&self) -> Result<()> {
        if self.id != self.recompute_id() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Git object ID does not match its bytes",
            ));
        }
        Ok(())
    }

    /// Constructs an object from an adapter-read body.
    pub(crate) fn new(id: GitObjectId, kind: GitObjectKind, data: Vec<u8>) -> Self {
        Self { id, kind, data }
    }
}

impl fmt::Debug for GitObject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GitObject")
            .field("id", &self.id)
            .field("kind", &self.kind)
            .field("data", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accessors_preserve_body_and_debug_redacts_it() {
        let id = GitObjectId::from_bytes([7; GitObjectId::BYTE_LENGTH]);
        let object = GitObject::new(id, GitObjectKind::Blob, b"private body".to_vec());

        assert_eq!(object.id(), id);
        assert_eq!(object.kind(), GitObjectKind::Blob);
        assert_eq!(object.data(), b"private body");
        assert_eq!(
            format!("{object:?}"),
            "GitObject { id: GitObjectId(<redacted>), kind: Blob, data: \"<redacted>\" }"
        );
        assert_eq!(object.into_data(), b"private body");
    }

    #[test]
    fn recomputes_and_verifies_canonical_git_object_ids() {
        let empty_blob_id: GitObjectId = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
            .parse()
            .expect("empty blob ID");
        let valid = GitObject::new(empty_blob_id, GitObjectKind::Blob, Vec::new());
        let altered = GitObject::new(empty_blob_id, GitObjectKind::Blob, b"altered body".to_vec());

        assert_eq!(valid.recompute_id(), empty_blob_id);
        valid.verify_id().expect("valid object ID");
        let error = altered.verify_id().expect_err("altered object must fail");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains("altered body"));
        assert!(!error.to_string().contains(&empty_blob_id.to_string()));
    }

    #[test]
    fn emits_the_canonical_loose_object_header() {
        let object = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Tag,
            b"\0body\xff".to_vec(),
        );

        assert_eq!(object.loose_header(), b"tag 6\0");
    }

    #[test]
    fn object_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<GitObject>();
        assert_send_sync::<GitObjectKind>();
    }
}
