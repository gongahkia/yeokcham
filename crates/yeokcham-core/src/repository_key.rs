use chacha20poly1305::{
    Key, XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{BackendKey, Error, ErrorKind, RepositoryId, Result, SegmentId};

const MASTER_KEY_BYTES: usize = 32;
const DOMAIN_SEPARATOR: &[u8] = b"yeokcham/";
const SEGMENT_PURPOSE: &[u8] = b"segment-encryption/v1\0";
const METADATA_PURPOSE: &[u8] = b"metadata-encryption/v1\0";
const BACKEND_OBJECT_PURPOSE: &[u8] = b"backend-object-encryption/v1\0";
const DRIVE_OBJECT_NAMING_PURPOSE: &[u8] = b"drive-object-naming/v1\0";
const DRIVE_OBJECT_NAME_PURPOSE: &[u8] = b"yeokcham/drive-object-name/v1\0";
const DRIVE_OBJECT_CAPSULE_PURPOSE: &[u8] = b"yeokcham/drive-object-capsule/v1\0";
const DRIVE_OBJECT_CAPSULE_MAGIC: [u8; 4] = *b"YKDO";
const DRIVE_OBJECT_CAPSULE_VERSION: u16 = 1;
const DRIVE_OBJECT_CAPSULE_NONCE_BYTES: usize = 24;
const DRIVE_OBJECT_CAPSULE_FIXED_BYTES: usize = 4 + 2 + 2 + DRIVE_OBJECT_CAPSULE_NONCE_BYTES;
const DRIVE_OBJECT_CAPSULE_TAG_BYTES: usize = 16;

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

    /// Derives a repository-bound key for opaque Google Drive object names.
    pub fn derive_drive_object_naming_key(&self) -> Result<DriveObjectNamingKey> {
        Ok(DriveObjectNamingKey(
            self.derive(DRIVE_OBJECT_NAMING_PURPOSE, b"")?.0,
        ))
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

/// One repository-bound key that maps backend keys to opaque Drive object names.
pub struct DriveObjectNamingKey(Zeroizing<[u8; MASTER_KEY_BYTES]>);

impl DriveObjectNamingKey {
    /// Maps one validated backend key to its fixed-length opaque Drive object name.
    pub fn object_name(&self, key: &BackendKey) -> Result<DriveObjectName> {
        let hkdf = Hkdf::<Sha256>::new(Some(&*self.0), key.as_bytes());
        let mut name = [0; MASTER_KEY_BYTES];
        hkdf.expand(DRIVE_OBJECT_NAME_PURPOSE, &mut name)
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive object name derivation failed"))?;
        Ok(DriveObjectName(hex::encode(name)))
    }

    pub(crate) fn seal_backend_key(
        &self,
        key: &BackendKey,
        name: &DriveObjectName,
    ) -> Result<Vec<u8>> {
        let key_length = u16::try_from(key.as_bytes().len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "Drive backend key exceeds the capsule limit",
            )
        })?;
        let mut nonce = [0; DRIVE_OBJECT_CAPSULE_NONCE_BYTES];
        getrandom::fill(&mut nonce).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Drive object capsule nonce could not be generated",
                error,
            )
        })?;
        let capsule_key = self.capsule_key()?;
        let ciphertext = XChaCha20Poly1305::new(&Key::from(capsule_key))
            .encrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: key.as_bytes(),
                    aad: name.as_str().as_bytes(),
                },
            )
            .map_err(|_| {
                Error::new(
                    ErrorKind::Internal,
                    "Drive object capsule encryption failed",
                )
            })?;
        let mut capsule = Vec::with_capacity(
            DRIVE_OBJECT_CAPSULE_FIXED_BYTES
                .checked_add(ciphertext.len())
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "Drive object capsule exceeds the byte limit",
                    )
                })?,
        );
        capsule.extend_from_slice(&DRIVE_OBJECT_CAPSULE_MAGIC);
        capsule.extend_from_slice(&DRIVE_OBJECT_CAPSULE_VERSION.to_be_bytes());
        capsule.extend_from_slice(&key_length.to_be_bytes());
        capsule.extend_from_slice(&nonce);
        capsule.extend_from_slice(&ciphertext);
        Ok(capsule)
    }

    pub(crate) fn open_backend_key(
        &self,
        capsule: &[u8],
        name: &DriveObjectName,
    ) -> Result<BackendKey> {
        let (key_length, nonce, ciphertext) = parse_drive_object_capsule(capsule)?;
        let capsule_key = self.capsule_key()?;
        let nonce: [u8; DRIVE_OBJECT_CAPSULE_NONCE_BYTES] = nonce.try_into().map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule nonce is invalid",
            )
        })?;
        let plaintext = XChaCha20Poly1305::new(&Key::from(capsule_key))
            .decrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: ciphertext,
                    aad: name.as_str().as_bytes(),
                },
            )
            .map_err(|_| Error::new(ErrorKind::CorruptData, "Drive object capsule is invalid"))?;
        if plaintext.len() != key_length {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule length is invalid",
            ));
        }
        BackendKey::from_bytes(&plaintext).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule key is invalid",
            )
        })
    }

    pub(crate) fn capsule_length(prefix: &[u8]) -> Result<usize> {
        let (key_length, _, _) = parse_drive_object_capsule_prefix(prefix)?;
        DRIVE_OBJECT_CAPSULE_FIXED_BYTES
            .checked_add(key_length)
            .and_then(|value| value.checked_add(DRIVE_OBJECT_CAPSULE_TAG_BYTES))
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "Drive object capsule length is invalid",
                )
            })
    }

    fn capsule_key(&self) -> Result<[u8; MASTER_KEY_BYTES]> {
        let hkdf = Hkdf::<Sha256>::from_prk(&*self.0).map_err(|_| {
            Error::new(
                ErrorKind::Internal,
                "Drive object capsule key derivation failed",
            )
        })?;
        let mut key = [0; MASTER_KEY_BYTES];
        hkdf.expand(DRIVE_OBJECT_CAPSULE_PURPOSE, &mut key)
            .map_err(|_| {
                Error::new(
                    ErrorKind::Internal,
                    "Drive object capsule key derivation failed",
                )
            })?;
        Ok(key)
    }
}

impl std::fmt::Debug for DriveObjectNamingKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveObjectNamingKey(<redacted>)")
    }
}

/// One fixed-length opaque Google Drive file name.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DriveObjectName(String);

impl DriveObjectName {
    /// Returns the opaque ASCII object name for a Drive API request.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn from_remote_name(name: &str) -> Result<Self> {
        if name.len() != MASTER_KEY_BYTES * 2
            || !name.bytes().all(|byte| {
                byte.is_ascii_digit() || (byte.is_ascii_lowercase() && byte.is_ascii_hexdigit())
            })
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object name is invalid",
            ));
        }
        Ok(Self(name.to_owned()))
    }
}

impl std::fmt::Debug for DriveObjectName {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveObjectName(<redacted>)")
    }
}

fn parse_drive_object_capsule(capsule: &[u8]) -> Result<(usize, &[u8], &[u8])> {
    let (key_length, nonce, ciphertext) = parse_drive_object_capsule_prefix(capsule)?;
    let expected_length = DRIVE_OBJECT_CAPSULE_FIXED_BYTES
        .checked_add(key_length)
        .and_then(|value| value.checked_add(DRIVE_OBJECT_CAPSULE_TAG_BYTES))
        .ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule length is invalid",
            )
        })?;
    if capsule.len() != expected_length
        || ciphertext.len() != key_length + DRIVE_OBJECT_CAPSULE_TAG_BYTES
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "Drive object capsule length is invalid",
        ));
    }
    Ok((key_length, nonce, ciphertext))
}

fn parse_drive_object_capsule_prefix(prefix: &[u8]) -> Result<(usize, &[u8], &[u8])> {
    if prefix.len() < DRIVE_OBJECT_CAPSULE_FIXED_BYTES
        || prefix[..4] != DRIVE_OBJECT_CAPSULE_MAGIC
        || u16::from_be_bytes([prefix[4], prefix[5]]) != DRIVE_OBJECT_CAPSULE_VERSION
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "Drive object capsule is invalid",
        ));
    }
    let key_length = usize::from(u16::from_be_bytes([prefix[6], prefix[7]]));
    if key_length == 0 || key_length > 1_024 {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "Drive object capsule key length is invalid",
        ));
    }
    let nonce = &prefix[8..DRIVE_OBJECT_CAPSULE_FIXED_BYTES];
    let ciphertext = &prefix[DRIVE_OBJECT_CAPSULE_FIXED_BYTES..];
    Ok((key_length, nonce, ciphertext))
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

    #[test]
    fn derives_fixed_length_opaque_drive_object_names() {
        let key =
            RepositoryEncryptionKey::from_master_bytes(repository_id(), [7; MASTER_KEY_BYTES]);
        let repeated = key
            .derive_drive_object_naming_key()
            .expect("first naming key");
        let naming = key
            .derive_drive_object_naming_key()
            .expect("second naming key");
        let first = BackendKey::from_bytes(b"segments/a").expect("first backend key");
        let second = BackendKey::from_bytes(b"segments/b").expect("second backend key");
        let first_name = naming.object_name(&first).expect("first name");

        assert_eq!(first_name.as_str().len(), 64);
        assert!(
            first_name
                .as_str()
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        );
        assert_eq!(
            first_name.as_str(),
            repeated.object_name(&first).expect("same name").as_str()
        );
        assert_ne!(
            first_name.as_str(),
            naming.object_name(&second).expect("second name").as_str()
        );
        assert!(!first_name.as_str().contains("segments"));
        assert_eq!(format!("{naming:?}"), "DriveObjectNamingKey(<redacted>)");
        assert_eq!(format!("{first_name:?}"), "DriveObjectName(<redacted>)");
    }

    #[test]
    fn authenticates_drive_object_key_capsules() {
        let key =
            RepositoryEncryptionKey::from_master_bytes(repository_id(), [7; MASTER_KEY_BYTES]);
        let naming = key.derive_drive_object_naming_key().expect("naming key");
        let backend_key = BackendKey::from_bytes(b"segments/opaque-record").expect("backend key");
        let name = naming.object_name(&backend_key).expect("object name");
        let mut capsule = naming
            .seal_backend_key(&backend_key, &name)
            .expect("key capsule");
        assert_eq!(
            DriveObjectNamingKey::capsule_length(&capsule[..DRIVE_OBJECT_CAPSULE_FIXED_BYTES])
                .expect("capsule length"),
            capsule.len(),
        );
        assert_eq!(
            naming
                .open_backend_key(&capsule, &name)
                .expect("open capsule"),
            backend_key,
        );
        *capsule.last_mut().expect("capsule byte") ^= 1;
        assert_eq!(
            naming
                .open_backend_key(&capsule, &name)
                .expect_err("tampered capsule")
                .kind(),
            ErrorKind::CorruptData,
        );
    }
}
