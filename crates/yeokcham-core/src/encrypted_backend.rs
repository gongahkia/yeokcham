use chacha20poly1305::{
    Key, XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};

use crate::repository_key::DerivedEncryptionKey;
use crate::{
    Backend, BackendByteRange, BackendCursor, BackendFuture, BackendKey, BackendListEntry,
    BackendListLimits, BackendListPage, BackendObjectMetadata, BackendPrefix, BackendPutResult,
    BackendReadLimits, BackendReadRequest, BackendResumablePutStart, BackendUploadSession,
    CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, RepositoryEncryptionKey, Result,
    SegmentId,
};

const ENVELOPE_MAGIC: [u8; 4] = *b"YKCE";
const ENVELOPE_VERSION: u16 = 1;
const ENVELOPE_NONCE_BYTES: usize = 24;
const ENVELOPE_TAG_BYTES: u64 = 16;
const ENVELOPE_HEADER_BYTES: u64 = 46;

/// A backend wrapper that stores authenticated encrypted envelopes.
pub struct EncryptedBackend<B> {
    inner: B,
    key: RepositoryEncryptionKey,
}

impl<B> EncryptedBackend<B> {
    /// Wraps a backend with repository-bound authenticated encryption.
    pub fn new(inner: B, key: RepositoryEncryptionKey) -> Self {
        Self { inner, key }
    }

    /// Returns the encrypted backend's bound repository identity.
    pub const fn repository_id(&self) -> crate::RepositoryId {
        self.key.repository_id()
    }

    /// Returns the wrapped backend after discarding the in-process encryption key.
    pub fn into_inner(self) -> B {
        self.inner
    }
}

impl<B> std::fmt::Debug for EncryptedBackend<B> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("EncryptedBackend(<redacted>)")
    }
}

impl<B: Backend> EncryptedBackend<B> {
    fn encrypt(&self, key: &BackendKey, plaintext: &[u8]) -> Result<Vec<u8>> {
        let binding = EncryptionBinding::from_key(key)?;
        let derived_key = binding.derive_key(&self.key)?;
        let plaintext_length = u64::try_from(plaintext.len())
            .map_err(|_| Error::new(ErrorKind::Unsupported, "encrypted plaintext is too large"))?;
        let mut nonce = [0; ENVELOPE_NONCE_BYTES];
        getrandom::fill(&mut nonce).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "encrypted nonce could not be generated",
                error,
            )
        })?;
        let associated_data = binding.associated_data(self.key.repository_id(), plaintext_length);
        let ciphertext =
            encrypt_bytes(derived_key.as_bytes(), &nonce, &associated_data, plaintext)?;
        encode_envelope(nonce, plaintext_length, &ciphertext)
    }

    fn decrypt(
        &self,
        key: &BackendKey,
        envelope: &[u8],
        maximum_plaintext_bytes: u64,
    ) -> Result<Vec<u8>> {
        let (nonce, plaintext_length, ciphertext) = decode_envelope(envelope)?;
        if plaintext_length > maximum_plaintext_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "encrypted plaintext exceeds the byte limit",
            ));
        }
        let binding = EncryptionBinding::from_key(key)?;
        let derived_key = binding.derive_key(&self.key)?;
        let associated_data = binding.associated_data(self.key.repository_id(), plaintext_length);
        let plaintext =
            decrypt_bytes(derived_key.as_bytes(), &nonce, &associated_data, ciphertext)?;
        if u64::try_from(plaintext.len()).ok() != Some(plaintext_length) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "encrypted plaintext length is invalid",
            ));
        }
        Ok(plaintext)
    }

    fn encrypted_read_limit(maximum_plaintext_bytes: u64) -> Result<u64> {
        maximum_plaintext_bytes
            .checked_add(ENVELOPE_HEADER_BYTES)
            .and_then(|value| value.checked_add(ENVELOPE_TAG_BYTES))
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "encrypted read limit overflows"))
    }

    fn plaintext_metadata<'a>(
        &'a self,
        key: &'a BackendKey,
    ) -> BackendFuture<'a, BackendObjectMetadata> {
        Box::pin(async move {
            let header = self
                .inner
                .get(
                    key,
                    BackendReadRequest::range(
                        BackendByteRange::new(0, ENVELOPE_HEADER_BYTES)?,
                        BackendReadLimits::new(ENVELOPE_HEADER_BYTES),
                    ),
                )
                .await?;
            let plaintext_length = decode_envelope_header(&header)?;
            Ok(BackendObjectMetadata::new(plaintext_length))
        })
    }
}

impl<B: Backend> Backend for EncryptedBackend<B> {
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move {
            let envelope = self.encrypt(key, data)?;
            match self.inner.put_if_absent(key, &envelope).await? {
                BackendPutResult::Created(_) => Ok(BackendPutResult::Created(
                    BackendObjectMetadata::new(u64::try_from(data.len()).map_err(|_| {
                        Error::new(ErrorKind::Unsupported, "encrypted plaintext is too large")
                    })?),
                )),
                BackendPutResult::AlreadyExists(_) => Ok(BackendPutResult::AlreadyExists(
                    self.plaintext_metadata(key).await?,
                )),
            }
        })
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move {
            if request.requested_range().is_some() {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "encrypted backend does not support range reads",
                ));
            }
            let encrypted_limit = Self::encrypted_read_limit(request.limits().maximum_bytes())?;
            let envelope = self
                .inner
                .get(
                    key,
                    BackendReadRequest::full(BackendReadLimits::new(encrypted_limit)),
                )
                .await?;
            self.decrypt(key, &envelope, request.limits().maximum_bytes())
        })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        self.plaintext_metadata(key)
    }

    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        Box::pin(async move {
            let page = self.inner.list(prefix, cursor, limits).await?;
            let mut entries = Vec::with_capacity(page.entries().len());
            for entry in page.entries() {
                let metadata = self.plaintext_metadata(entry.key()).await?;
                entries.push(BackendListEntry::new(entry.key().clone(), metadata));
            }
            Ok(BackendListPage::new(entries, page.next_cursor().cloned()))
        })
    }

    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.inner.delete(key).await })
    }

    fn start_resumable_put_if_absent<'a>(
        &'a self,
        _: &'a BackendKey,
        _: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        Box::pin(async {
            Err(Error::new(
                ErrorKind::Unsupported,
                "encrypted backend does not support resumable uploads",
            ))
        })
    }

    fn write_resumable<'a>(
        &'a self,
        _: &'a BackendUploadSession,
        _: u64,
        _: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        Box::pin(async {
            Err(Error::new(
                ErrorKind::Unsupported,
                "encrypted backend does not support resumable uploads",
            ))
        })
    }

    fn complete_resumable<'a>(
        &'a self,
        _: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async {
            Err(Error::new(
                ErrorKind::Unsupported,
                "encrypted backend does not support resumable uploads",
            ))
        })
    }

    fn abort_resumable<'a>(&'a self, _: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        Box::pin(async {
            Err(Error::new(
                ErrorKind::Unsupported,
                "encrypted backend does not support resumable uploads",
            ))
        })
    }
}

enum EncryptionBinding<'a> {
    Segment { key: &'a BackendKey, id: SegmentId },
    Metadata(&'a BackendKey),
    BackendObject(&'a BackendKey),
}

impl<'a> EncryptionBinding<'a> {
    fn from_key(key: &'a BackendKey) -> Result<Self> {
        let mut components = key.as_bytes().split(|byte| *byte == b'/');
        let first = components.next().unwrap_or_default();
        let second = components.next();
        if first == b"segments" && components.next().is_none() {
            if let Some(segment) = second
                .and_then(|segment| std::str::from_utf8(segment).ok())
                .and_then(|segment| segment.parse().ok())
            {
                return Ok(Self::Segment { key, id: segment });
            }
        }
        if matches!(first, b"indexes" | b"manifests" | b"refs" | b"format") {
            return Ok(Self::Metadata(key));
        }
        Ok(Self::BackendObject(key))
    }

    fn derive_key(&self, repository_key: &RepositoryEncryptionKey) -> Result<DerivedEncryptionKey> {
        match self {
            Self::Segment { id, .. } => repository_key.derive_segment_key(*id),
            Self::Metadata(key) => repository_key.derive_metadata_key(key),
            Self::BackendObject(key) => repository_key.derive_backend_object_key(key),
        }
    }

    fn associated_data(
        &self,
        repository_id: crate::RepositoryId,
        plaintext_length: u64,
    ) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&ENVELOPE_MAGIC);
        encoder.write_u16(ENVELOPE_VERSION);
        encoder.write_fixed(repository_id.as_bytes());
        match self {
            Self::Segment { key, id } => {
                encoder.write_u8(1);
                encoder.write_byte_string(key.as_bytes());
                encoder.write_fixed(id.as_bytes());
            }
            Self::Metadata(key) => {
                encoder.write_u8(2);
                encoder.write_byte_string(key.as_bytes());
            }
            Self::BackendObject(key) => {
                encoder.write_u8(3);
                encoder.write_byte_string(key.as_bytes());
            }
        }
        encoder.write_u64(plaintext_length);
        encoder.into_bytes()
    }
}

fn encode_envelope(
    nonce: [u8; ENVELOPE_NONCE_BYTES],
    plaintext_length: u64,
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    let ciphertext_length = u64::try_from(ciphertext.len())
        .map_err(|_| Error::new(ErrorKind::Unsupported, "encrypted ciphertext is too large"))?;
    if ciphertext_length
        != plaintext_length
            .checked_add(ENVELOPE_TAG_BYTES)
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "encrypted ciphertext length overflows",
                )
            })?
    {
        return Err(Error::new(
            ErrorKind::Internal,
            "encrypted ciphertext length is invalid",
        ));
    }
    let mut encoder = CanonicalEncoder::new();
    encoder.write_fixed(&ENVELOPE_MAGIC);
    encoder.write_u16(ENVELOPE_VERSION);
    encoder.write_fixed(&nonce);
    encoder.write_u64(plaintext_length);
    encoder.write_byte_string(ciphertext);
    Ok(encoder.into_bytes())
}

fn decode_envelope(bytes: &[u8]) -> Result<([u8; ENVELOPE_NONCE_BYTES], u64, &[u8])> {
    let mut decoder = CanonicalDecoder::new(bytes);
    let magic = decoder.read_fixed::<4>()?;
    let version = decoder.read_u16()?;
    let nonce = decoder.read_fixed::<ENVELOPE_NONCE_BYTES>()?;
    let plaintext_length = decoder.read_u64()?;
    let ciphertext = decoder.read_byte_string()?;
    decoder.finish()?;
    if magic != ENVELOPE_MAGIC || version != ENVELOPE_VERSION {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "encrypted envelope format is not supported",
        ));
    }
    let ciphertext_length = u64::try_from(ciphertext.len()).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "encrypted ciphertext length is invalid",
        )
    })?;
    if ciphertext_length
        != plaintext_length
            .checked_add(ENVELOPE_TAG_BYTES)
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "encrypted plaintext length is invalid",
                )
            })?
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "encrypted ciphertext length is invalid",
        ));
    }
    Ok((nonce, plaintext_length, ciphertext))
}

fn decode_envelope_header(bytes: &[u8]) -> Result<u64> {
    if bytes.len() != ENVELOPE_HEADER_BYTES as usize {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "encrypted envelope header is invalid",
        ));
    }
    let mut decoder = CanonicalDecoder::new(bytes);
    let magic = decoder.read_fixed::<4>()?;
    let version = decoder.read_u16()?;
    let _nonce = decoder.read_fixed::<ENVELOPE_NONCE_BYTES>()?;
    let plaintext_length = decoder.read_u64()?;
    let ciphertext_length = decoder.read_u64()?;
    decoder.finish()?;
    if magic != ENVELOPE_MAGIC || version != ENVELOPE_VERSION {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "encrypted envelope format is not supported",
        ));
    }
    if ciphertext_length
        != plaintext_length
            .checked_add(ENVELOPE_TAG_BYTES)
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "encrypted plaintext length is invalid",
                )
            })?
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "encrypted ciphertext length is invalid",
        ));
    }
    Ok(plaintext_length)
}

fn encrypt_bytes(
    key: &[u8; 32],
    nonce: &[u8; ENVELOPE_NONCE_BYTES],
    associated_data: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    XChaCha20Poly1305::new(&Key::from(*key))
        .encrypt(
            &XNonce::from(*nonce),
            Payload {
                msg: plaintext,
                aad: associated_data,
            },
        )
        .map_err(|_| Error::new(ErrorKind::Internal, "encrypted payload could not be sealed"))
}

fn decrypt_bytes(
    key: &[u8; 32],
    nonce: &[u8; ENVELOPE_NONCE_BYTES],
    associated_data: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    XChaCha20Poly1305::new(&Key::from(*key))
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
                "encrypted payload authentication failed",
            )
        })
}

#[cfg(test)]
mod tests {
    use std::{
        future::Future,
        path::{Path, PathBuf},
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Context, Poll, Wake, Waker},
    };

    use uuid::Uuid;

    use super::*;
    use crate::FilesystemBackend;

    static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "yeokcham-encrypted-backend-test-{}-{sequence}",
                Uuid::new_v4()
            ));
            std::fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct NoopWake;

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("encrypted backend future unexpectedly yielded"),
        }
    }

    fn repository_id() -> crate::RepositoryId {
        "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID")
    }

    #[test]
    fn encrypts_filesystem_objects_and_rejects_tampering_or_wrong_keys() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<EncryptedBackend<FilesystemBackend>>();
        let directory = TestDirectory::new();
        let physical_root = directory.path().join("backend");
        let key = BackendKey::from_bytes(b"manifests/objects/a").expect("backend key");
        let plaintext = b"fixture plaintext must not reach the filesystem";
        let encryption_key = RepositoryEncryptionKey::generate(repository_id()).expect("key");
        let wrong_key = RepositoryEncryptionKey::generate(repository_id()).expect("wrong key");
        let backend = EncryptedBackend::new(
            FilesystemBackend::create(&physical_root).expect("filesystem backend"),
            encryption_key,
        );

        assert_eq!(
            block_on(backend.put_if_absent(&key, plaintext)).expect("put"),
            BackendPutResult::Created(BackendObjectMetadata::new(plaintext.len() as u64))
        );
        let stored = std::fs::read(physical_root.join("manifests/objects/a")).expect("ciphertext");
        assert!(
            !stored
                .windows(plaintext.len())
                .any(|bytes| bytes == plaintext)
        );
        assert_eq!(
            block_on(backend.get(
                &key,
                BackendReadRequest::full(BackendReadLimits::new(plaintext.len() as u64))
            ))
            .expect("decrypt"),
            plaintext
        );
        assert_eq!(
            block_on(backend.head(&key)).expect("head").length(),
            plaintext.len() as u64
        );
        assert_eq!(
            block_on(backend.get(
                &key,
                BackendReadRequest::range(
                    BackendByteRange::new(0, 1).expect("range"),
                    BackendReadLimits::new(1)
                )
            ))
            .expect_err("range unsupported")
            .kind(),
            ErrorKind::Unsupported
        );

        let mut tampered = stored;
        *tampered.last_mut().expect("ciphertext byte") ^= 1;
        std::fs::write(physical_root.join("manifests/objects/a"), tampered).expect("tamper");
        assert_eq!(
            block_on(backend.get(
                &key,
                BackendReadRequest::full(BackendReadLimits::new(plaintext.len() as u64))
            ))
            .expect_err("tampering")
            .kind(),
            ErrorKind::CorruptData
        );

        let wrong_backend = EncryptedBackend::new(
            FilesystemBackend::open(&physical_root).expect("filesystem reopen"),
            wrong_key,
        );
        assert_eq!(
            block_on(wrong_backend.get(
                &key,
                BackendReadRequest::full(BackendReadLimits::new(plaintext.len() as u64))
            ))
            .expect_err("wrong key")
            .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(format!("{backend:?}"), "EncryptedBackend(<redacted>)");
    }

    #[test]
    fn binds_segment_metadata_and_object_domains() {
        let key = RepositoryEncryptionKey::from_master_bytes(repository_id(), [5; 32]);
        let segment = BackendKey::from_bytes(b"segments/1b2f4d99-d439-4fb7-a782-b719d42ac0c7")
            .expect("segment");
        let metadata = BackendKey::from_bytes(b"manifests/objects/a").expect("metadata");
        let object = BackendKey::from_bytes(b"objects/a").expect("object");
        let plaintext = b"binding";
        let nonce = [3; ENVELOPE_NONCE_BYTES];
        let segment_binding = EncryptionBinding::from_key(&segment).expect("segment binding");
        let metadata_binding = EncryptionBinding::from_key(&metadata).expect("metadata binding");
        let object_binding = EncryptionBinding::from_key(&object).expect("object binding");
        let ciphertext = encrypt_bytes(
            segment_binding
                .derive_key(&key)
                .expect("segment key")
                .as_bytes(),
            &nonce,
            &segment_binding.associated_data(repository_id(), plaintext.len() as u64),
            plaintext,
        )
        .expect("encrypt");

        assert_eq!(
            decrypt_bytes(
                segment_binding
                    .derive_key(&key)
                    .expect("segment key")
                    .as_bytes(),
                &nonce,
                &segment_binding.associated_data(repository_id(), plaintext.len() as u64),
                &ciphertext,
            )
            .expect("decrypt"),
            plaintext
        );
        for binding in [&metadata_binding, &object_binding] {
            assert_eq!(
                decrypt_bytes(
                    binding.derive_key(&key).expect("key").as_bytes(),
                    &nonce,
                    &binding.associated_data(repository_id(), plaintext.len() as u64),
                    &ciphertext,
                )
                .expect_err("domain mismatch")
                .kind(),
                ErrorKind::CorruptData
            );
        }
    }
}
