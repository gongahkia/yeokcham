use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

use uuid::Uuid;

use crate::{
    Backend, BackendByteRange, BackendCursor, BackendFuture, BackendKey, BackendListEntry,
    BackendListLimits, BackendListPage, BackendObjectMetadata, BackendPrefix, BackendPutResult,
    BackendReadRequest, BackendResumablePutStart, BackendUploadSession, Error, ErrorKind, Result,
};

const UPLOAD_DIRECTORY: &str = ".yeokcham-uploads";
const STAGING_SUFFIX: &str = ".partial";

/// A local filesystem implementation of the immutable backend contract.
pub struct FilesystemBackend {
    root: PathBuf,
}

impl FilesystemBackend {
    /// creates or validates one backend root and its private upload directory.
    pub fn create(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        match fs::symlink_metadata(root) {
            Ok(_) => validate_directory(root)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                fs::create_dir(root)
                    .map_err(|error| io_error(error, "backend root could not be created"))?;
                sync_directory(root)?;
            }
            Err(error) => {
                return Err(io_error(error, "backend root could not be inspected"));
            }
        }
        Self::ensure_upload_directory(root)?;
        Self::open(root)
    }

    /// opens one validated filesystem backend root.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        validate_directory(root)?;
        validate_directory(&root.join(UPLOAD_DIRECTORY))?;
        Ok(Self {
            root: root.to_path_buf(),
        })
    }

    /// returns the backend root for explicit local administration.
    pub fn path(&self) -> &Path {
        &self.root
    }

    fn ensure_upload_directory(root: &Path) -> Result<()> {
        let uploads = root.join(UPLOAD_DIRECTORY);
        match fs::create_dir(&uploads) {
            Ok(()) => sync_directory(root),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                validate_directory(&uploads)
            }
            Err(error) => Err(io_error(
                error,
                "backend upload directory could not be created",
            )),
        }
    }

    fn put_if_absent_sync(&self, key: &BackendKey, data: &[u8]) -> Result<BackendPutResult> {
        let destination = self.object_path(key)?;
        self.ensure_object_parent(key)?;
        match object_metadata(&destination) {
            Ok(metadata) => return Ok(BackendPutResult::AlreadyExists(metadata)),
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let parent = destination
            .parent()
            .ok_or_else(|| Error::new(ErrorKind::Internal, "backend object path has no parent"))?;
        let (mut staging, staging_path) = create_staging_file(parent)?;
        if let Err(error) = staging.write_all(data) {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(error, "backend staging file could not be written"));
        }
        if let Err(error) = staging.sync_all() {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "backend staging file could not be synchronized",
            ));
        }
        drop(staging);
        match fs::hard_link(&staging_path, &destination) {
            Ok(()) => {
                sync_directory(parent)?;
                let _ = fs::remove_file(&staging_path);
                let _ = sync_directory(parent);
                Ok(BackendPutResult::Created(BackendObjectMetadata::new(
                    u64::try_from(data.len()).map_err(|_| {
                        Error::new(ErrorKind::Unsupported, "backend object is too large")
                    })?,
                )))
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&staging_path);
                object_metadata(&destination).map(BackendPutResult::AlreadyExists)
            }
            Err(error) => {
                let _ = fs::remove_file(&staging_path);
                Err(io_error(error, "backend object could not be published"))
            }
        }
    }

    fn get_sync(&self, key: &BackendKey, request: BackendReadRequest) -> Result<Vec<u8>> {
        self.validate_existing_parent(key)?;
        let path = self.object_path(key)?;
        let metadata = object_metadata(&path)?;
        let range = resolve_range(metadata.length(), request.requested_range())?;
        if range.len() > request.limits().maximum_bytes() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "backend read exceeds the byte limit",
            ));
        }
        let length = usize::try_from(range.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "backend read exceeds the byte limit",
            )
        })?;
        let mut file = File::open(&path)
            .map_err(|error| io_error(error, "backend object could not be opened"))?;
        file.seek(SeekFrom::Start(range.start()))
            .map_err(|error| io_error(error, "backend object could not be read"))?;
        let mut bytes = vec![0; length];
        file.read_exact(&mut bytes).map_err(|error| {
            if error.kind() == io::ErrorKind::UnexpectedEof {
                Error::new(
                    ErrorKind::CorruptData,
                    "backend object changed while being read",
                )
            } else {
                io_error(error, "backend object could not be read")
            }
        })?;
        if object_metadata(&path)? != metadata {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "backend object changed while being read",
            ));
        }
        Ok(bytes)
    }

    fn head_sync(&self, key: &BackendKey) -> Result<BackendObjectMetadata> {
        self.validate_existing_parent(key)?;
        object_metadata(&self.object_path(key)?)
    }

    fn list_sync(
        &self,
        prefix: &BackendPrefix,
        cursor: Option<&BackendCursor>,
        limits: BackendListLimits,
    ) -> Result<BackendListPage> {
        self.validate_upload_directory()?;
        let mut entries = BTreeMap::new();
        let mut pending = vec![self.root.clone()];
        let mut scanned = 0_usize;
        while let Some(directory) = pending.pop() {
            validate_directory(&directory)?;
            for entry in fs::read_dir(&directory)
                .map_err(|error| io_error(error, "backend directory could not be listed"))?
            {
                scanned = scanned.checked_add(1).ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "backend list scan exceeds the entry limit",
                    )
                })?;
                if scanned > limits.maximum_scanned_entries() {
                    return Err(Error::new(
                        ErrorKind::Unsupported,
                        "backend list scan exceeds the entry limit",
                    ));
                }
                let entry = entry
                    .map_err(|error| io_error(error, "backend directory could not be listed"))?;
                let path = entry.path();
                let name = entry.file_name();
                if directory == self.root && name == UPLOAD_DIRECTORY {
                    continue;
                }
                if is_staging_name(&name) {
                    continue;
                }
                let metadata = fs::symlink_metadata(&path)
                    .map_err(|error| io_error(error, "backend entry could not be inspected"))?;
                if metadata.file_type().is_symlink() {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "backend contains a symbolic link",
                    ));
                }
                if metadata.is_dir() {
                    pending.push(path);
                    continue;
                }
                if !metadata.is_file() {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "backend contains an invalid entry",
                    ));
                }
                let relative = path.strip_prefix(&self.root).map_err(|_| {
                    Error::new(ErrorKind::Internal, "backend entry escapes its root")
                })?;
                let key = relative
                    .to_str()
                    .ok_or_else(|| Error::new(ErrorKind::CorruptData, "backend key is invalid"))?;
                let key = BackendKey::from_bytes(key.as_bytes())
                    .map_err(|_| Error::new(ErrorKind::CorruptData, "backend key is invalid"))?;
                if key.as_bytes().starts_with(prefix.as_bytes()) {
                    entries.insert(key, BackendObjectMetadata::new(metadata.len()));
                }
            }
        }
        let cursor = cursor.map(BackendCursor::key);
        let mut page_entries: Vec<_> = entries
            .into_iter()
            .filter(|(key, _)| cursor.is_none_or(|cursor| key > cursor))
            .map(|(key, metadata)| BackendListEntry::new(key, metadata))
            .collect();
        let next_cursor = if page_entries.len() > limits.maximum_entries() {
            page_entries.truncate(limits.maximum_entries());
            page_entries
                .last()
                .map(|entry| BackendCursor::from_key(entry.key().clone()))
        } else {
            None
        };
        Ok(BackendListPage::new(page_entries, next_cursor))
    }

    fn delete_sync(&self, key: &BackendKey) -> Result<()> {
        self.validate_existing_parent(key)?;
        let path = self.object_path(key)?;
        object_metadata(&path)?;
        fs::remove_file(&path)
            .map_err(|error| io_error(error, "backend object could not be deleted"))?;
        let parent = path
            .parent()
            .ok_or_else(|| Error::new(ErrorKind::Internal, "backend object path has no parent"))?;
        sync_directory(parent)
    }

    fn start_resumable_sync(
        &self,
        key: &BackendKey,
        total_length: u64,
    ) -> Result<BackendResumablePutStart> {
        self.validate_upload_directory()?;
        self.ensure_object_parent(key)?;
        let destination = self.object_path(key)?;
        match object_metadata(&destination) {
            Ok(metadata) => return Ok(BackendResumablePutStart::AlreadyExists(metadata)),
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let id = Uuid::new_v4().into_bytes();
        let path = self.upload_path(id);
        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .map_err(|error| io_error(error, "backend upload session could not be created"))?;
        file.sync_all()
            .map_err(|error| io_error(error, "backend upload session could not be synchronized"))?;
        sync_directory(&self.root.join(UPLOAD_DIRECTORY))?;
        Ok(BackendResumablePutStart::Started(
            BackendUploadSession::new(key.clone(), id, total_length),
        ))
    }

    fn write_resumable_sync(
        &self,
        session: &BackendUploadSession,
        offset: u64,
        data: &[u8],
    ) -> Result<()> {
        self.validate_upload_directory()?;
        let end = offset
            .checked_add(u64::try_from(data.len()).map_err(|_| {
                Error::new(
                    ErrorKind::Unsupported,
                    "backend resumable write is too large",
                )
            })?)
            .ok_or_else(|| {
                Error::new(ErrorKind::InvalidInput, "backend resumable range overflows")
            })?;
        if end > session.total_length() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend resumable write exceeds its total length",
            ));
        }
        let path = self.upload_path(session.id());
        let metadata = object_metadata(&path)?;
        if metadata.length() != offset {
            return Err(Error::new(
                ErrorKind::Conflict,
                "backend resumable write is not contiguous",
            ));
        }
        let mut file = OpenOptions::new()
            .write(true)
            .open(&path)
            .map_err(|error| io_error(error, "backend upload session could not be opened"))?;
        file.seek(SeekFrom::Start(offset))
            .map_err(|error| io_error(error, "backend upload session could not be written"))?;
        file.write_all(data)
            .map_err(|error| io_error(error, "backend upload session could not be written"))?;
        file.sync_all()
            .map_err(|error| io_error(error, "backend upload session could not be synchronized"))?;
        if object_metadata(&path)?.length() != end {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "backend upload session changed while being written",
            ));
        }
        Ok(())
    }

    fn complete_resumable_sync(&self, session: &BackendUploadSession) -> Result<BackendPutResult> {
        self.validate_upload_directory()?;
        let destination = self.object_path(session.key())?;
        self.ensure_object_parent(session.key())?;
        let staging_path = self.upload_path(session.id());
        let metadata = match object_metadata(&staging_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                return object_metadata(&destination).map(BackendPutResult::AlreadyExists);
            }
            Err(error) => return Err(error),
        };
        if metadata.length() != session.total_length() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "backend resumable upload is incomplete",
            ));
        }
        let parent = destination
            .parent()
            .ok_or_else(|| Error::new(ErrorKind::Internal, "backend object path has no parent"))?;
        match fs::hard_link(&staging_path, &destination) {
            Ok(()) => {
                sync_directory(parent)?;
                let _ = fs::remove_file(&staging_path);
                let _ = sync_directory(&self.root.join(UPLOAD_DIRECTORY));
                Ok(BackendPutResult::Created(metadata))
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&staging_path);
                let _ = sync_directory(&self.root.join(UPLOAD_DIRECTORY));
                object_metadata(&destination).map(BackendPutResult::AlreadyExists)
            }
            Err(error) => Err(io_error(
                error,
                "backend resumable upload could not be published",
            )),
        }
    }

    fn abort_resumable_sync(&self, session: &BackendUploadSession) -> Result<()> {
        self.validate_upload_directory()?;
        let path = self.upload_path(session.id());
        match fs::remove_file(&path) {
            Ok(()) => sync_directory(&self.root.join(UPLOAD_DIRECTORY)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(io_error(
                error,
                "backend upload session could not be removed",
            )),
        }
    }

    fn object_path(&self, key: &BackendKey) -> Result<PathBuf> {
        if key.as_bytes().split(|byte| *byte == b'/').next() == Some(UPLOAD_DIRECTORY.as_bytes()) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend key uses a reserved prefix",
            ));
        }
        if key
            .as_bytes()
            .split(|byte| *byte == b'/')
            .next_back()
            .is_some_and(is_staging_bytes)
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "backend key uses a reserved filename",
            ));
        }
        let key = std::str::from_utf8(key.as_bytes())
            .map_err(|_| Error::new(ErrorKind::InvalidInput, "backend key is invalid"))?;
        Ok(self.root.join(key))
    }

    fn ensure_object_parent(&self, key: &BackendKey) -> Result<()> {
        let mut directory = self.root.clone();
        let components: Vec<_> = key.as_bytes().split(|byte| *byte == b'/').collect();
        for component in &components[..components.len().saturating_sub(1)] {
            let component = std::str::from_utf8(component)
                .map_err(|_| Error::new(ErrorKind::InvalidInput, "backend key is invalid"))?;
            let child = directory.join(component);
            match fs::create_dir(&child) {
                Ok(()) => sync_directory(&directory)?,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    validate_directory(&child)?;
                }
                Err(error) => {
                    return Err(io_error(
                        error,
                        "backend object directory could not be created",
                    ));
                }
            }
            directory = child;
        }
        Ok(())
    }

    fn validate_existing_parent(&self, key: &BackendKey) -> Result<()> {
        let mut directory = self.root.clone();
        validate_directory(&directory)?;
        let components: Vec<_> = key.as_bytes().split(|byte| *byte == b'/').collect();
        for component in &components[..components.len().saturating_sub(1)] {
            let component = std::str::from_utf8(component)
                .map_err(|_| Error::new(ErrorKind::InvalidInput, "backend key is invalid"))?;
            directory.push(component);
            match fs::symlink_metadata(&directory) {
                Ok(_) => validate_directory(&directory)?,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    return Err(Error::new(
                        ErrorKind::NotFound,
                        "backend object does not exist",
                    ));
                }
                Err(error) => {
                    return Err(io_error(
                        error,
                        "backend object directory could not be inspected",
                    ));
                }
            }
        }
        Ok(())
    }

    fn upload_path(&self, id: [u8; 16]) -> PathBuf {
        self.root
            .join(UPLOAD_DIRECTORY)
            .join(format!("{}{}", hex::encode(id), STAGING_SUFFIX))
    }

    fn validate_upload_directory(&self) -> Result<()> {
        validate_directory(&self.root.join(UPLOAD_DIRECTORY))
    }
}

impl std::fmt::Debug for FilesystemBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("FilesystemBackend(<redacted>)")
    }
}

impl Backend for FilesystemBackend {
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move { self.put_if_absent_sync(key, data) })
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move { self.get_sync(key, request) })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        Box::pin(async move { self.head_sync(key) })
    }

    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        Box::pin(async move { self.list_sync(prefix, cursor, limits) })
    }

    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.delete_sync(key) })
    }

    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        Box::pin(async move { self.start_resumable_sync(key, total_length) })
    }

    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.write_resumable_sync(session, offset, data) })
    }

    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move { self.complete_resumable_sync(session) })
    }

    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.abort_resumable_sync(session) })
    }
}

fn resolve_range(length: u64, requested: Option<BackendByteRange>) -> Result<BackendByteRange> {
    let range = requested.unwrap_or(BackendByteRange::new(0, length)?);
    if range.end_exclusive() > length {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "backend byte range exceeds the object",
        ));
    }
    Ok(range)
}

fn object_metadata(path: &Path) -> Result<BackendObjectMetadata> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::NotFound, "backend object does not exist")
        } else {
            io_error(error, "backend object could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "backend object is not a regular file",
        ));
    }
    Ok(BackendObjectMetadata::new(metadata.len()))
}

fn validate_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::NotFound, "backend directory does not exist")
        } else {
            io_error(error, "backend directory could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "backend directory is invalid",
        ));
    }
    Ok(())
}

fn create_staging_file(parent: &Path) -> Result<(File, PathBuf)> {
    for _ in 0..16 {
        let path = parent.join(format!(".{}{}", Uuid::new_v4(), STAGING_SUFFIX));
        match OpenOptions::new().create_new(true).write(true).open(&path) {
            Ok(file) => return Ok((file, path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(error, "backend staging file could not be created"));
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "backend staging path could not be allocated",
    ))
}

fn is_staging_name(name: &OsStr) -> bool {
    name.to_str()
        .is_some_and(|name| is_staging_bytes(name.as_bytes()))
}

fn is_staging_bytes(bytes: &[u8]) -> bool {
    bytes
        .strip_prefix(b".")
        .and_then(|name| name.strip_suffix(STAGING_SUFFIX.as_bytes()))
        .is_some_and(|id| std::str::from_utf8(id).is_ok_and(|id| id.parse::<Uuid>().is_ok()))
}

fn io_error(error: io::Error, message: &'static str) -> Error {
    Error::with_source(ErrorKind::Io, message, error)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .map_err(|error| io_error(error, "backend directory could not be synchronized"))?
        .sync_all()
        .map_err(|error| io_error(error, "backend directory could not be synchronized"))
}

#[cfg(not(unix))]
fn sync_directory(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        future::Future,
        path::Path,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Context, Poll, Wake, Waker},
    };

    use super::*;

    static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "yeokcham-backend-test-{}-{sequence}",
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
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("filesystem backend future unexpectedly yielded"),
        }
    }

    fn key(bytes: &[u8]) -> BackendKey {
        BackendKey::from_bytes(bytes).expect("key")
    }

    #[test]
    fn stores_reads_lists_and_deletes_immutable_objects() {
        let directory = TestDirectory::new();
        let backend = FilesystemBackend::create(directory.path().join("backend")).expect("create");
        let first = key(b"segments/a");
        let second = key(b"segments/b");
        let index = key(b"indexes/a");

        assert_eq!(
            block_on(backend.put_if_absent(&first, b"abcdef")).expect("put"),
            BackendPutResult::Created(BackendObjectMetadata::new(6))
        );
        assert_eq!(
            block_on(backend.put_if_absent(&first, b"changed")).expect("repeat"),
            BackendPutResult::AlreadyExists(BackendObjectMetadata::new(6))
        );
        block_on(backend.put_if_absent(&second, b"b")).expect("second");
        block_on(backend.put_if_absent(&index, b"i")).expect("index");
        assert_eq!(
            block_on(backend.get(
                &first,
                BackendReadRequest::range(
                    BackendByteRange::new(2, 5).expect("range"),
                    crate::BackendReadLimits::new(3)
                )
            ))
            .expect("range read"),
            b"cde"
        );
        assert_eq!(
            block_on(backend.get(
                &first,
                BackendReadRequest::full(crate::BackendReadLimits::new(5))
            ))
            .expect_err("read limit")
            .kind(),
            ErrorKind::Unsupported
        );
        assert_eq!(
            block_on(backend.get(
                &first,
                BackendReadRequest::range(
                    BackendByteRange::new(0, 7).expect("range"),
                    crate::BackendReadLimits::new(7)
                )
            ))
            .expect_err("out of bounds range")
            .kind(),
            ErrorKind::InvalidInput
        );

        let prefix = BackendPrefix::from_bytes(b"segments/").expect("prefix");
        let first_page =
            block_on(backend.list(&prefix, None, BackendListLimits::new(1, 8).expect("limits")))
                .expect("first page");
        assert_eq!(first_page.entries().len(), 1);
        let second_page = block_on(backend.list(
            &prefix,
            first_page.next_cursor(),
            BackendListLimits::new(1, 8).expect("limits"),
        ))
        .expect("second page");
        assert_eq!(second_page.entries().len(), 1);
        assert!(second_page.next_cursor().is_none());
        assert_ne!(
            first_page.entries()[0].key(),
            second_page.entries()[0].key()
        );

        block_on(backend.delete(&first)).expect("delete");
        assert_eq!(
            block_on(backend.head(&first))
                .expect_err("deleted object")
                .kind(),
            ErrorKind::NotFound
        );
        assert_eq!(
            block_on(backend.put_if_absent(&key(b".yeokcham-uploads/a"), b"x"))
                .expect_err("reserved directory")
                .kind(),
            ErrorKind::InvalidInput
        );
    }

    #[test]
    fn resumes_and_idempotently_completes_immutable_uploads() {
        let directory = TestDirectory::new();
        let backend = FilesystemBackend::create(directory.path().join("backend")).expect("create");
        let key = key(b"segments/resumed");
        let session = match block_on(backend.start_resumable_put_if_absent(&key, 6)).expect("start")
        {
            BackendResumablePutStart::Started(session) => session,
            BackendResumablePutStart::AlreadyExists(_) => panic!("unexpected object"),
        };
        block_on(backend.write_resumable(&session, 0, b"abc")).expect("first write");
        assert_eq!(
            block_on(backend.complete_resumable(&session))
                .expect_err("incomplete upload")
                .kind(),
            ErrorKind::Conflict
        );
        assert_eq!(
            block_on(backend.write_resumable(&session, 0, b"abc"))
                .expect_err("noncontiguous retry")
                .kind(),
            ErrorKind::Conflict
        );
        block_on(backend.write_resumable(&session, 3, b"def")).expect("second write");
        assert_eq!(
            block_on(backend.complete_resumable(&session)).expect("complete"),
            BackendPutResult::Created(BackendObjectMetadata::new(6))
        );
        assert_eq!(
            block_on(backend.complete_resumable(&session)).expect("retry complete"),
            BackendPutResult::AlreadyExists(BackendObjectMetadata::new(6))
        );
        assert_eq!(
            block_on(backend.get(
                &key,
                BackendReadRequest::full(crate::BackendReadLimits::new(6))
            ))
            .expect("read complete"),
            b"abcdef"
        );
    }

    #[test]
    fn rejects_symlinked_roots_and_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<FilesystemBackend>();
        let directory = TestDirectory::new();
        let root = directory.path().join("backend");
        FilesystemBackend::create(&root).expect("create");
        assert_eq!(
            format!("{:?}", FilesystemBackend::open(root).expect("open")),
            "FilesystemBackend(<redacted>)"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            let link = directory.path().join("backend-link");
            symlink(directory.path().join("backend"), &link).expect("create symlink");
            assert_eq!(
                FilesystemBackend::open(link)
                    .expect_err("symlink root")
                    .kind(),
                ErrorKind::CorruptData
            );
        }
    }
}
