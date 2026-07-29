use std::fmt;

use crate::GitObjectId;

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
    fn object_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<GitObject>();
        assert_send_sync::<GitObjectKind>();
    }
}
