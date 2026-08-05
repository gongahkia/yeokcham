use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    Key, XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use zeroize::Zeroizing;

use crate::{
    CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, RepositoryEncryptionKey, RepositoryId,
    Result,
};

const EXPORT_MAGIC: [u8; 4] = *b"YKRK";
const EXPORT_VERSION: u16 = 1;
const KDF_ALGORITHM: u8 = 1;
const AEAD_ALGORITHM: u8 = 1;
const SALT_BYTES: usize = 16;
const NONCE_BYTES: usize = 24;
const MASTER_KEY_BYTES: usize = 32;
const AEAD_TAG_BYTES: usize = 16;
const CIPHERTEXT_BYTES: usize = MASTER_KEY_BYTES + AEAD_TAG_BYTES;
const MAXIMUM_PASSPHRASE_BYTES: usize = 1_024;
const ARGON_MEMORY_KIB: u32 = 65_536;
const ARGON_ITERATIONS: u32 = 3;
const ARGON_LANES: u32 = 4;

/// One opaque passphrase-encrypted repository-key recovery export.
pub struct RepositoryKeyExport(Zeroizing<Vec<u8>>);

impl RepositoryKeyExport {
    /// Validates and takes ownership of one encoded recovery export.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self> {
        decode_export(&bytes)?;
        Ok(Self(Zeroizing::new(bytes)))
    }

    /// Returns the exact versioned recovery-export bytes for explicit storage.
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl std::fmt::Debug for RepositoryKeyExport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("RepositoryKeyExport(<redacted>)")
    }
}

impl RepositoryEncryptionKey {
    /// Exports this repository key using a nonempty Argon2id-protected passphrase.
    pub fn export_with_passphrase(&self, passphrase: &[u8]) -> Result<RepositoryKeyExport> {
        validate_passphrase(passphrase)?;
        let mut salt = [0; SALT_BYTES];
        let mut nonce = [0; NONCE_BYTES];
        getrandom::fill(&mut salt).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "recovery export salt could not be generated",
                error,
            )
        })?;
        getrandom::fill(&mut nonce).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "recovery export nonce could not be generated",
                error,
            )
        })?;
        let wrapping_key = derive_wrapping_key(passphrase, &salt)?;
        let associated_data = export_associated_data(self.repository_id(), &salt, &nonce);
        let ciphertext =
            encrypt_master_key(&wrapping_key, &nonce, &associated_data, self.master_bytes())?;
        let bytes = encode_export(self.repository_id(), salt, nonce, &ciphertext)?;
        Ok(RepositoryKeyExport(Zeroizing::new(bytes)))
    }

    /// Imports one repository key after validating and authenticating its recovery export.
    pub fn import_with_passphrase(export: &RepositoryKeyExport, passphrase: &[u8]) -> Result<Self> {
        validate_passphrase(passphrase)?;
        let parsed = decode_export(export.as_bytes())?;
        let wrapping_key = derive_wrapping_key(passphrase, &parsed.salt)?;
        let associated_data =
            export_associated_data(parsed.repository_id, &parsed.salt, &parsed.nonce);
        let master = decrypt_master_key(
            &wrapping_key,
            &parsed.nonce,
            &associated_data,
            parsed.ciphertext,
        )?;
        Ok(Self::from_master_bytes(parsed.repository_id, master))
    }
}

struct ParsedExport<'a> {
    repository_id: RepositoryId,
    salt: [u8; SALT_BYTES],
    nonce: [u8; NONCE_BYTES],
    ciphertext: &'a [u8],
}

fn validate_passphrase(passphrase: &[u8]) -> Result<()> {
    if passphrase.is_empty() || passphrase.len() > MAXIMUM_PASSPHRASE_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "recovery export passphrase is invalid",
        ));
    }
    Ok(())
}

fn derive_wrapping_key(
    passphrase: &[u8],
    salt: &[u8; SALT_BYTES],
) -> Result<Zeroizing<[u8; MASTER_KEY_BYTES]>> {
    let params = Params::new(
        ARGON_MEMORY_KIB,
        ARGON_ITERATIONS,
        ARGON_LANES,
        Some(MASTER_KEY_BYTES),
    )
    .map_err(|_| {
        Error::new(
            ErrorKind::Internal,
            "recovery export KDF parameters are invalid",
        )
    })?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0; MASTER_KEY_BYTES]);
    argon2
        .hash_password_into(passphrase, salt, &mut *key)
        .map_err(|_| Error::new(ErrorKind::Internal, "recovery export key derivation failed"))?;
    Ok(key)
}

fn encode_export(
    repository_id: RepositoryId,
    salt: [u8; SALT_BYTES],
    nonce: [u8; NONCE_BYTES],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    if ciphertext.len() != CIPHERTEXT_BYTES {
        return Err(Error::new(
            ErrorKind::Internal,
            "recovery export ciphertext length is invalid",
        ));
    }
    let mut encoder = CanonicalEncoder::new();
    encoder.write_fixed(&EXPORT_MAGIC);
    encoder.write_u16(EXPORT_VERSION);
    encoder.write_u8(KDF_ALGORITHM);
    encoder.write_u8(AEAD_ALGORITHM);
    encoder.write_fixed(repository_id.as_bytes());
    encoder.write_u32(ARGON_MEMORY_KIB);
    encoder.write_u32(ARGON_ITERATIONS);
    encoder.write_u32(ARGON_LANES);
    encoder.write_fixed(&salt);
    encoder.write_fixed(&nonce);
    encoder.write_byte_string(ciphertext);
    Ok(encoder.into_bytes())
}

fn decode_export(bytes: &[u8]) -> Result<ParsedExport<'_>> {
    let mut decoder = CanonicalDecoder::new(bytes);
    let magic = decoder.read_fixed::<4>()?;
    let version = decoder.read_u16()?;
    let kdf_algorithm = decoder.read_u8()?;
    let aead_algorithm = decoder.read_u8()?;
    let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?)?;
    let memory_kib = decoder.read_u32()?;
    let iterations = decoder.read_u32()?;
    let lanes = decoder.read_u32()?;
    let salt = decoder.read_fixed::<SALT_BYTES>()?;
    let nonce = decoder.read_fixed::<NONCE_BYTES>()?;
    let ciphertext = decoder.read_byte_string()?;
    decoder.finish()?;
    if magic != EXPORT_MAGIC || version != EXPORT_VERSION {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "recovery export format is not supported",
        ));
    }
    if kdf_algorithm != KDF_ALGORITHM || aead_algorithm != AEAD_ALGORITHM {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "recovery export algorithm is not supported",
        ));
    }
    if memory_kib != ARGON_MEMORY_KIB || iterations != ARGON_ITERATIONS || lanes != ARGON_LANES {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "recovery export KDF parameters are not supported",
        ));
    }
    if ciphertext.len() != CIPHERTEXT_BYTES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "recovery export ciphertext length is invalid",
        ));
    }
    Ok(ParsedExport {
        repository_id,
        salt,
        nonce,
        ciphertext,
    })
}

fn export_associated_data(
    repository_id: RepositoryId,
    salt: &[u8; SALT_BYTES],
    nonce: &[u8; NONCE_BYTES],
) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.write_fixed(&EXPORT_MAGIC);
    encoder.write_u16(EXPORT_VERSION);
    encoder.write_u8(KDF_ALGORITHM);
    encoder.write_u8(AEAD_ALGORITHM);
    encoder.write_fixed(repository_id.as_bytes());
    encoder.write_u32(ARGON_MEMORY_KIB);
    encoder.write_u32(ARGON_ITERATIONS);
    encoder.write_u32(ARGON_LANES);
    encoder.write_fixed(salt);
    encoder.write_fixed(nonce);
    encoder.into_bytes()
}

fn encrypt_master_key(
    wrapping_key: &[u8; MASTER_KEY_BYTES],
    nonce: &[u8; NONCE_BYTES],
    associated_data: &[u8],
    master_key: &[u8; MASTER_KEY_BYTES],
) -> Result<Vec<u8>> {
    XChaCha20Poly1305::new(&Key::from(*wrapping_key))
        .encrypt(
            &XNonce::from(*nonce),
            Payload {
                msg: master_key,
                aad: associated_data,
            },
        )
        .map_err(|_| Error::new(ErrorKind::Internal, "recovery export could not be sealed"))
}

fn decrypt_master_key(
    wrapping_key: &[u8; MASTER_KEY_BYTES],
    nonce: &[u8; NONCE_BYTES],
    associated_data: &[u8],
    ciphertext: &[u8],
) -> Result<[u8; MASTER_KEY_BYTES]> {
    let plaintext = XChaCha20Poly1305::new(&Key::from(*wrapping_key))
        .decrypt(
            &XNonce::from(*nonce),
            Payload {
                msg: ciphertext,
                aad: associated_data,
            },
        )
        .map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "recovery export authentication failed",
            )
        })?;
    plaintext.try_into().map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "recovery export plaintext length is invalid",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SegmentId;

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
    fn exports_imports_and_redacts_repository_keys() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RepositoryKeyExport>();
        let key = RepositoryEncryptionKey::generate(repository_id()).expect("key");
        let export = key
            .export_with_passphrase(b"test passphrase")
            .expect("export");
        assert!(
            !export
                .as_bytes()
                .windows(32)
                .any(|bytes| bytes == key.master_bytes())
        );
        let imported = RepositoryEncryptionKey::import_with_passphrase(&export, b"test passphrase")
            .expect("import");
        assert_eq!(imported.repository_id(), repository_id());
        assert_eq!(
            imported
                .derive_segment_key(segment_id())
                .expect("imported key")
                .as_bytes(),
            key.derive_segment_key(segment_id())
                .expect("original key")
                .as_bytes()
        );
        assert_eq!(format!("{export:?}"), "RepositoryKeyExport(<redacted>)");
    }

    #[test]
    fn rejects_wrong_passphrases_tampering_and_invalid_passphrases() {
        let key = RepositoryEncryptionKey::generate(repository_id()).expect("key");
        let export = key
            .export_with_passphrase(b"test passphrase")
            .expect("export");
        assert_eq!(
            RepositoryEncryptionKey::import_with_passphrase(&export, b"wrong passphrase")
                .expect_err("wrong passphrase")
                .kind(),
            ErrorKind::CorruptData
        );
        let mut tampered = export.as_bytes().to_vec();
        *tampered.last_mut().expect("ciphertext") ^= 1;
        let tampered = RepositoryKeyExport::from_bytes(tampered).expect("structure");
        assert_eq!(
            RepositoryEncryptionKey::import_with_passphrase(&tampered, b"test passphrase")
                .expect_err("tampering")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            key.export_with_passphrase(b"")
                .expect_err("empty passphrase")
                .kind(),
            ErrorKind::InvalidInput
        );
    }
}
