use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{BackendKey, Error, ErrorKind, RepositoryId, Result, SegmentId};

const MASTER_KEY_BYTES: usize = 32;
const DOMAIN_SEPARATOR: &[u8] = b"yeokcham/";
const SEGMENT_PURPOSE: &[u8] = b"segment-encryption/v1\0";
const METADATA_PURPOSE: &[u8] = b"metadata-encryption/v1\0";
const BACKEND_OBJECT_PURPOSE: &[u8] = b"backend-object-encryption/v1\0";

/// One repository-bound master encryption key held only in process memory.
pub struct RepositoryEncryptionKey {
    repository_id: RepositoryId,
    master: Zeroizing<[u8; MASTER_KEY_BYTES]>,
}

impl RepositoryEncryptionKey {
    /// Generates one new 256-bit master key from the operating-system random source.
    pub fn generate(repository_id: RepositoryId) -> Result<Self> {
        let mut master = Zeroizing::new([0; MASTER_KEY_BYTES]);
        getrandom::fill(&mut *master).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "repository encryption key could not be generated",
                error,
            )
        })?;
        Ok(Self {
            repository_id,
            master,
        })
    }

    /// Returns the repository identity bound to this key.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Derives the unique encryption key for one sealed segment identity.
    pub(crate) fn derive_segment_key(&self, segment_id: SegmentId) -> Result<DerivedEncryptionKey> {
        self.derive(SEGMENT_PURPOSE, segment_id.as_bytes())
    }

    /// Derives the encryption key for one sensitive metadata object key.
    pub(crate) fn derive_metadata_key(&self, key: &BackendKey) -> Result<DerivedEncryptionKey> {
        self.derive(METADATA_PURPOSE, key.as_bytes())
    }

    /// Derives the encryption key for one non-segment backend object key.
    pub(crate) fn derive_backend_object_key(
        &self,
        key: &BackendKey,
    ) -> Result<DerivedEncryptionKey> {
        self.derive(BACKEND_OBJECT_PURPOSE, key.as_bytes())
    }

    fn derive(&self, purpose: &[u8], identity: &[u8]) -> Result<DerivedEncryptionKey> {
        let identity_length = u16::try_from(identity.len()).map_err(|_| {
            Error::new(
                ErrorKind::InvalidInput,
                "encryption key identity is too large",
            )
        })?;
        let mut info = Vec::with_capacity(
            DOMAIN_SEPARATOR.len() + purpose.len() + std::mem::size_of::<u16>() + identity.len(),
        );
        info.extend_from_slice(DOMAIN_SEPARATOR);
        info.extend_from_slice(purpose);
        info.extend_from_slice(&identity_length.to_be_bytes());
        info.extend_from_slice(identity);
        let hkdf = Hkdf::<Sha256>::new(Some(self.repository_id.as_bytes()), &*self.master);
        let mut key = Zeroizing::new([0; MASTER_KEY_BYTES]);
        hkdf.expand(&info, &mut *key).map_err(|_| {
            Error::new(
                ErrorKind::Internal,
                "repository encryption key derivation failed",
            )
        })?;
        Ok(DerivedEncryptionKey(key))
    }

    pub(crate) fn from_master_bytes(
        repository_id: RepositoryId,
        master: [u8; MASTER_KEY_BYTES],
    ) -> Self {
        Self {
            repository_id,
            master: Zeroizing::new(master),
        }
    }

    pub(crate) fn master_bytes(&self) -> &[u8; MASTER_KEY_BYTES] {
        &self.master
    }
}

impl std::fmt::Debug for RepositoryEncryptionKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("RepositoryEncryptionKey(<redacted>)")
    }
}

/// One internal 256-bit subkey derived for a single encryption domain and object.
pub(crate) struct DerivedEncryptionKey(Zeroizing<[u8; MASTER_KEY_BYTES]>);

impl DerivedEncryptionKey {
    pub(crate) fn as_bytes(&self) -> &[u8; MASTER_KEY_BYTES] {
        &self.0
    }
}

impl std::fmt::Debug for DerivedEncryptionKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DerivedEncryptionKey(<redacted>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repository_id() -> RepositoryId {
        "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID")
    }

    fn segment_id() -> SegmentId {
        "1b2f4d99-d439-4fb7-a782-b719d42ac0c7"
            .parse()
            .expect("segment ID")
    }

    #[test]
    fn generated_keys_are_repository_bound_and_redacted() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RepositoryEncryptionKey>();
        let first = RepositoryEncryptionKey::generate(repository_id()).expect("first key");
        let second = RepositoryEncryptionKey::generate(repository_id()).expect("second key");
        assert_eq!(first.repository_id(), repository_id());
        assert_ne!(
            first
                .derive_segment_key(segment_id())
                .expect("first derived")
                .as_bytes(),
            second
                .derive_segment_key(segment_id())
                .expect("second derived")
                .as_bytes()
        );
        assert_eq!(format!("{first:?}"), "RepositoryEncryptionKey(<redacted>)");
    }

    #[test]
    fn hierarchy_is_deterministic_and_domain_separated() {
        let key =
            RepositoryEncryptionKey::from_master_bytes(repository_id(), [7; MASTER_KEY_BYTES]);
        let backend_key = BackendKey::from_bytes(b"manifests/objects/a").expect("backend key");
        let segment = key.derive_segment_key(segment_id()).expect("segment key");
        let repeated = key
            .derive_segment_key(segment_id())
            .expect("repeat segment key");
        let metadata = key.derive_metadata_key(&backend_key).expect("metadata key");
        let object = key
            .derive_backend_object_key(&backend_key)
            .expect("object key");

        assert_eq!(segment.as_bytes(), repeated.as_bytes());
        assert_ne!(segment.as_bytes(), metadata.as_bytes());
        assert_ne!(metadata.as_bytes(), object.as_bytes());
        assert_eq!(format!("{segment:?}"), "DerivedEncryptionKey(<redacted>)");
    }

    #[test]
    fn repository_identity_changes_derived_keys() {
        let master = [9; MASTER_KEY_BYTES];
        let first = RepositoryEncryptionKey::from_master_bytes(repository_id(), master);
        let second = RepositoryEncryptionKey::from_master_bytes(RepositoryId::generate(), master);

        assert_ne!(
            first
                .derive_segment_key(segment_id())
                .expect("first key")
                .as_bytes(),
            second
                .derive_segment_key(segment_id())
                .expect("second key")
                .as_bytes()
        );
    }
}
