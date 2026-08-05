use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    Backend, BackendCursor, BackendFuture, BackendKey, BackendListLimits, BackendListPage,
    BackendObjectMetadata, BackendPrefix, BackendPutResult, BackendReadRequest,
    BackendResumablePutStart, BackendUploadSession, Error, ErrorKind, Result,
};

const CACHE_DIRECTORY: &str = "objects";
const MAGIC: [u8; 4] = *b"YKCC";
const VERSION: u16 = 1;
const HEADER_BYTES: usize = 4 + 2 + 8 + 32;

/// Point-in-time counters for ciphertext cache reads.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CiphertextCacheMetrics {
    hits: u64,
    misses: u64,
    stores: u64,
}

impl CiphertextCacheMetrics {
    /// Returns successful validated local reads.
    pub const fn hits(self) -> u64 {
        self.hits
    }

    /// Returns reads delegated to the wrapped backend.
    pub const fn misses(self) -> u64 {
        self.misses
    }

    /// Returns completed local cache publications.
    pub const fn stores(self) -> u64 {
        self.stores
    }
}

/// A private on-disk cache for immutable encrypted segment and index objects.
///
/// The cache key is SHA-256 of the opaque backend key. It stores a local
/// checksum and length before each payload, rejects symbolic links, and treats
/// malformed data as a cache miss. It is not encryption; place it beneath
/// [`crate::EncryptedBackend`] so cached payloads remain ciphertext.
pub struct CiphertextCache {
    root: PathBuf,
    hits: AtomicU64,
    misses: AtomicU64,
    stores: AtomicU64,
}

impl CiphertextCache {
    /// Creates or opens an empty private cache root.
    pub fn create(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        ensure_private_directory(root)?;
        ensure_private_directory(&root.join(CACHE_DIRECTORY))?;
        Ok(Self {
            root: root.to_path_buf(),
            hits: AtomicU64::new(0),
            misses: AtomicU64::new(0),
            stores: AtomicU64::new(0),
        })
    }

    /// Returns the cache root for local administration.
    pub fn path(&self) -> &Path {
        &self.root
    }

    /// Returns non-transactional cache read counters.
    pub fn metrics(&self) -> CiphertextCacheMetrics {
        CiphertextCacheMetrics {
            hits: self.hits.load(Ordering::Relaxed),
            misses: self.misses.load(Ordering::Relaxed),
            stores: self.stores.load(Ordering::Relaxed),
        }
    }

    fn get(&self, key: &BackendKey, maximum_bytes: u64) -> Option<Vec<u8>> {
        let path = self.path_for(key);
        let result = read_record(&path, maximum_bytes).ok().flatten();
        match result {
            Some(bytes) => {
                saturating_increment(&self.hits);
                Some(bytes)
            }
            None => {
                saturating_increment(&self.misses);
                let _ = remove_file_if_present(&path);
                None
            }
        }
    }

    fn put(&self, key: &BackendKey, bytes: &[u8]) {
        if write_record(&self.path_for(key), bytes).is_ok() {
            saturating_increment(&self.stores);
        }
    }

    fn path_for(&self, key: &BackendKey) -> PathBuf {
        let digest = Sha256::digest(key.as_bytes());
        self.root.join(CACHE_DIRECTORY).join(hex::encode(digest))
    }
}

impl std::fmt::Debug for CiphertextCache {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CiphertextCache(<redacted>)")
    }
}

/// A backend wrapper that caches full encrypted segment and index reads.
///
/// This wrapper intentionally does not cache range reads or other backend
/// namespaces. The wrapped backend remains authoritative; cache errors never
/// prevent an immutable backend read from succeeding.
pub struct CachedBackend<B> {
    inner: B,
    cache: CiphertextCache,
}

impl<B> CachedBackend<B> {
    /// Wraps a backend with one caller-owned ciphertext cache.
    pub fn new(inner: B, cache: CiphertextCache) -> Self {
        Self { inner, cache }
    }

    /// Returns non-transactional cache metrics.
    pub fn cache_metrics(&self) -> CiphertextCacheMetrics {
        self.cache.metrics()
    }

    /// Returns the cache root for explicit local administration.
    pub fn cache_path(&self) -> &Path {
        self.cache.path()
    }

    /// Returns the wrapped backend and local cache.
    pub fn into_parts(self) -> (B, CiphertextCache) {
        (self.inner, self.cache)
    }
}

impl<B> std::fmt::Debug for CachedBackend<B> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CachedBackend(<redacted>)")
    }
}

impl<B: Backend> Backend for CachedBackend<B> {
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        self.inner.put_if_absent(key, data)
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move {
            if request.requested_range().is_none() && cacheable(key) {
                if let Some(bytes) = self.cache.get(key, request.limits().maximum_bytes()) {
                    return Ok(bytes);
                }
                let bytes = self.inner.get(key, request).await?;
                self.cache.put(key, &bytes);
                return Ok(bytes);
            }
            self.inner.get(key, request).await
        })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        self.inner.head(key)
    }
    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        self.inner.list(prefix, cursor, limits)
    }
    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        self.inner.delete(key)
    }
    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        self.inner.start_resumable_put_if_absent(key, total_length)
    }
    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        self.inner.write_resumable(session, offset, data)
    }
    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        self.inner.complete_resumable(session)
    }
    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        self.inner.abort_resumable(session)
    }
}

fn cacheable(key: &BackendKey) -> bool {
    matches!(
        key.as_bytes().split(|byte| *byte == b'/').next(),
        Some(b"segments" | b"indexes")
    )
}

fn read_record(path: &Path, maximum_bytes: u64) -> Result<Option<Vec<u8>>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => metadata,
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(
                error,
                "ciphertext cache record could not be inspected",
            ));
        }
    };
    let maximum_record = u64::try_from(HEADER_BYTES)
        .unwrap_or(u64::MAX)
        .checked_add(maximum_bytes)
        .ok_or_else(|| {
            Error::new(
                ErrorKind::Unsupported,
                "ciphertext cache read bound overflows",
            )
        })?;
    if metadata.len() < HEADER_BYTES as u64 || metadata.len() > maximum_record {
        return Ok(None);
    }
    let mut file = File::open(path)
        .map_err(|error| io_error(error, "ciphertext cache record could not be read"))?;
    let mut header = [0; HEADER_BYTES];
    file.read_exact(&mut header).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "ciphertext cache record is truncated",
        )
    })?;
    if header[..4] != MAGIC
        || u16::from_be_bytes(header[4..6].try_into().expect("fixed slice")) != VERSION
    {
        return Ok(None);
    }
    let length = u64::from_be_bytes(header[6..14].try_into().expect("fixed slice"));
    if length > maximum_bytes || metadata.len() != (HEADER_BYTES as u64).saturating_add(length) {
        return Ok(None);
    }
    let length = usize::try_from(length).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "ciphertext cache record exceeds addressable memory",
        )
    })?;
    let mut bytes = vec![0; length];
    file.read_exact(&mut bytes).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "ciphertext cache record is truncated",
        )
    })?;
    let checksum: [u8; 32] = Sha256::digest(&bytes).into();
    if checksum != header[14..46] {
        return Ok(None);
    }
    Ok(Some(bytes))
}

fn write_record(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::new(ErrorKind::Internal, "ciphertext cache record has no parent"))?;
    ensure_private_directory(parent)?;
    let mut encoded = Vec::with_capacity(HEADER_BYTES.saturating_add(bytes.len()));
    encoded.extend_from_slice(&MAGIC);
    encoded.extend_from_slice(&VERSION.to_be_bytes());
    encoded.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
    encoded.extend_from_slice(&Sha256::digest(bytes));
    encoded.extend_from_slice(bytes);
    let staging = parent.join(format!(
        ".{}-{}.partial",
        path.file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Error::new(
                ErrorKind::Internal,
                "ciphertext cache record name is invalid"
            ))?,
        Uuid::new_v4()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staging)
        .map_err(|error| io_error(error, "ciphertext cache record could not be created"))?;
    file.write_all(&encoded)
        .and_then(|_| file.sync_all())
        .map_err(|error| io_error(error, "ciphertext cache record could not be written"))?;
    drop(file);
    match fs::hard_link(&staging, path) {
        Ok(()) => {
            sync_directory(parent)?;
            let _ = fs::remove_file(&staging);
            let _ = sync_directory(parent);
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let _ = fs::remove_file(&staging);
            Ok(())
        }
        Err(error) => {
            let _ = fs::remove_file(&staging);
            Err(io_error(
                error,
                "ciphertext cache record could not be published",
            ))
        }
    }
}

fn remove_file_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(
            error,
            "ciphertext cache record could not be removed",
        )),
    }
}
fn ensure_private_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_symlink() && metadata.is_dir() => Ok(()),
        Ok(_) => Err(Error::new(
            ErrorKind::CorruptData,
            "ciphertext cache path is not a directory",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder
                .create(path)
                .map_err(|error| io_error(error, "ciphertext cache directory could not be created"))
        }
        Err(error) => Err(io_error(
            error,
            "ciphertext cache path could not be inspected",
        )),
    }
}
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            io_error(
                error,
                "ciphertext cache directory could not be synchronized",
            )
        })
}
fn io_error(error: io::Error, message: &'static str) -> Error {
    if error.kind() == io::ErrorKind::NotFound {
        Error::new(ErrorKind::NotFound, message)
    } else {
        Error::with_source(ErrorKind::Io, message, error)
    }
}
fn saturating_increment(value: &AtomicU64) {
    let _ = value.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_add(1))
    });
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

    use super::*;
    use crate::{BackendReadLimits, EncryptedBackend, FilesystemBackend, RepositoryEncryptionKey};

    static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "yeokcham-ciphertext-cache-{sequence}-{}",
                Uuid::new_v4()
            ));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct NoopWake;
    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        let mut future = std::pin::pin!(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("ciphertext cache future unexpectedly yielded"),
        }
    }

    fn key(path: &[u8]) -> BackendKey {
        BackendKey::from_bytes(path).expect("cache key")
    }

    #[test]
    fn validates_cached_segment_bytes_and_refetches_corruption() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<CachedBackend<FilesystemBackend>>();
        let directory = TestDirectory::new();
        let backend_root = directory.path().join("backend");
        let key = key(b"segments/1b2f4d99-d439-4fb7-a782-b719d42ac0c7");
        let cache = CiphertextCache::create(directory.path().join("cache")).expect("cache");
        let cache_path = cache.path_for(&key);
        let backend = CachedBackend::new(
            FilesystemBackend::create(&backend_root).expect("backend"),
            cache,
        );
        block_on(backend.put_if_absent(&key, b"ciphertext")).expect("put");
        assert_eq!(
            block_on(backend.get(&key, BackendReadRequest::full(BackendReadLimits::new(64))))
                .expect("first read"),
            b"ciphertext"
        );
        assert_eq!(
            backend.cache_metrics(),
            CiphertextCacheMetrics {
                hits: 0,
                misses: 1,
                stores: 1
            }
        );
        fs::write(&cache_path, b"corrupt cache").expect("corrupt cache");
        assert_eq!(
            block_on(backend.get(&key, BackendReadRequest::full(BackendReadLimits::new(64))))
                .expect("refetch"),
            b"ciphertext"
        );
        assert_eq!(backend.cache_metrics().misses(), 2);
        assert_eq!(backend.cache_metrics().stores(), 2);
        assert_eq!(
            block_on(backend.get(&key, BackendReadRequest::full(BackendReadLimits::new(64))))
                .expect("cache hit"),
            b"ciphertext"
        );
        assert_eq!(backend.cache_metrics().hits(), 1);
    }

    #[test]
    fn caches_ciphertext_only_beneath_encrypted_backend_and_skips_metadata() {
        let directory = TestDirectory::new();
        let backend_root = directory.path().join("backend");
        let cache = CiphertextCache::create(directory.path().join("cache")).expect("cache");
        let cache_root = cache.path().to_path_buf();
        let segment = key(b"segments/1b2f4d99-d439-4fb7-a782-b719d42ac0c7");
        let metadata = key(b"manifests/objects/a");
        let repository_id = "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID");
        let backend = EncryptedBackend::new(
            CachedBackend::new(
                FilesystemBackend::create(&backend_root).expect("backend"),
                cache,
            ),
            RepositoryEncryptionKey::from_master_bytes(repository_id, [3; 32]),
        );
        let plaintext = b"plaintext must not enter ciphertext cache";
        block_on(backend.put_if_absent(&segment, plaintext)).expect("put segment");
        assert_eq!(
            block_on(backend.get(
                &segment,
                BackendReadRequest::full(BackendReadLimits::new(128))
            ))
            .expect("get segment"),
            plaintext
        );
        let cache_bytes = fs::read_dir(cache_root.join(CACHE_DIRECTORY))
            .expect("cache entries")
            .flat_map(|entry| fs::read(entry.expect("cache entry").path()).expect("cache bytes"))
            .collect::<Vec<_>>();
        assert!(
            !cache_bytes
                .windows(plaintext.len())
                .any(|bytes| bytes == plaintext)
        );
        block_on(backend.put_if_absent(&metadata, b"metadata")).expect("put metadata");
        assert_eq!(
            block_on(backend.get(
                &metadata,
                BackendReadRequest::full(BackendReadLimits::new(64))
            ))
            .expect("get metadata"),
            b"metadata"
        );
        assert_eq!(
            fs::read_dir(cache_root.join(CACHE_DIRECTORY))
                .expect("cache entries")
                .count(),
            1
        );
    }
}
