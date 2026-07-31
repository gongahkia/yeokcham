use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::{
    ffi::{OsStrExt, OsStringExt},
    fs::{OpenOptionsExt, PermissionsExt},
};

use uuid::Uuid;

use crate::{
    CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, FileMetadata, FileMetadataEntry,
    FileMetadataKind, RepositoryId, Result,
};

const MAGIC: [u8; 4] = *b"YKFC";
const VERSION: u16 = 1;
const MAXIMUM_CACHE_BYTES: usize = 64 * 1024 * 1024;
const MAXIMUM_ENTRIES: usize = 100_000;
const MAXIMUM_PATH_BYTES: usize = 4_096;

/// One versioned, atomic, disposable local file-metadata cache.
pub struct FileMetadataCache {
    path: PathBuf,
}

impl FileMetadataCache {
    /// Opens one existing or future cache file beneath an existing private directory.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        validate_cache_parent(path)?;
        match fs::symlink_metadata(path) {
            Ok(metadata) => validate_cache_file(&metadata)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "file metadata cache could not be inspected",
                    error,
                ));
            }
        }
        Ok(Self {
            path: path.to_path_buf(),
        })
    }

    /// Returns the explicit local cache-file path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Atomically replaces this cache with one repository-bound complete snapshot.
    pub fn store(&self, repository_id: RepositoryId, entries: &[FileMetadataEntry]) -> Result<()> {
        let encoded = encode_snapshot(repository_id, entries)?;
        write_atomic(&self.path, &encoded)
    }

    /// Loads and validates the current cached snapshot, or `None` when absent.
    pub fn load(&self) -> Result<Option<(RepositoryId, Vec<FileMetadataEntry>)>> {
        let bytes = match read_cache(&self.path)? {
            Some(bytes) => bytes,
            None => return Ok(None),
        };
        decode_snapshot(&bytes).map(Some)
    }

    /// Removes the disposable cache file without touching any repository data.
    pub fn clear(&self) -> Result<()> {
        match fs::symlink_metadata(&self.path) {
            Ok(metadata) => {
                validate_cache_file(&metadata)?;
                fs::remove_file(&self.path).map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "file metadata cache could not be removed",
                        error,
                    )
                })?;
                sync_parent(&self.path)?;
                Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(Error::with_source(
                ErrorKind::Io,
                "file metadata cache could not be inspected",
                error,
            )),
        }
    }
}

impl std::fmt::Debug for FileMetadataCache {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("FileMetadataCache(<redacted>)")
    }
}

fn encode_snapshot(repository_id: RepositoryId, entries: &[FileMetadataEntry]) -> Result<Vec<u8>> {
    if entries.len() > MAXIMUM_ENTRIES {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "file metadata cache entry limit is exceeded",
        ));
    }
    let mut estimated: usize = 4 + 2 + 16 + 8;
    let mut previous = None;
    for entry in entries {
        validate_relative_path(entry.path())?;
        let path = path_bytes(entry.path())?;
        if previous >= Some(path) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "file metadata cache entries are not sorted and unique",
            ));
        }
        previous = Some(path);
        estimated = estimated
            .checked_add(8 + path.len() + 1 + 8 + 1 + 8 + 4)
            .ok_or_else(|| {
                Error::new(ErrorKind::Unsupported, "file metadata cache is too large")
            })?;
        if estimated > MAXIMUM_CACHE_BYTES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "file metadata cache is too large",
            ));
        }
    }
    let mut encoder = CanonicalEncoder::new();
    encoder.write_fixed(&MAGIC);
    encoder.write_u16(VERSION);
    encoder.write_fixed(repository_id.as_bytes());
    encoder.write_u64(entries.len() as u64);
    for entry in entries {
        let path = path_bytes(entry.path())?;
        encoder.write_byte_string(path);
        encoder.write_u8(metadata_kind_tag(entry.metadata().kind()));
        encoder.write_u64(entry.metadata().length());
        let (before_epoch, seconds, nanoseconds) = encode_time(entry.metadata().modified())?;
        encoder.write_u8(before_epoch);
        encoder.write_u64(seconds);
        encoder.write_u32(nanoseconds);
    }
    Ok(encoder.into_bytes())
}

fn decode_snapshot(bytes: &[u8]) -> Result<(RepositoryId, Vec<FileMetadataEntry>)> {
    if bytes.len() > MAXIMUM_CACHE_BYTES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache exceeds the size limit",
        ));
    }
    let mut decoder = CanonicalDecoder::new(bytes);
    if decoder.read_fixed::<4>()? != MAGIC {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache has an invalid magic value",
        ));
    }
    if decoder.read_u16()? != VERSION {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "file metadata cache version is unsupported",
        ));
    }
    let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|source| {
        Error::with_source(
            ErrorKind::CorruptData,
            "file metadata cache has an invalid repository ID",
            source,
        )
    })?;
    let count = usize::try_from(decoder.read_u64()?).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "file metadata cache entry count is invalid",
        )
    })?;
    if count > MAXIMUM_ENTRIES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache entry limit is exceeded",
        ));
    }
    let mut entries = Vec::with_capacity(count);
    let mut previous = None;
    for _ in 0..count {
        let path = decoder.read_byte_string()?;
        validate_relative_path_bytes(path)?;
        if previous >= Some(path) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "file metadata cache entries are not sorted and unique",
            ));
        }
        previous = Some(path);
        let kind = metadata_kind_from_tag(decoder.read_u8()?)?;
        let length = decoder.read_u64()?;
        let before_epoch = decoder.read_u8()?;
        let seconds = decoder.read_u64()?;
        let nanoseconds = decoder.read_u32()?;
        if nanoseconds >= 1_000_000_000 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "file metadata cache timestamp is invalid",
            ));
        }
        entries.push(FileMetadataEntry::new(
            bytes_to_path(path)?,
            FileMetadata::new(
                kind,
                length,
                decode_time(before_epoch, seconds, nanoseconds)?,
            ),
        ));
    }
    decoder.finish()?;
    Ok((repository_id, entries))
}

fn validate_relative_path(path: &Path) -> Result<()> {
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::Prefix(_)
                    | Component::RootDir
                    | Component::CurDir
                    | Component::ParentDir
            )
        })
    {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "file metadata cache path is invalid",
        ));
    }
    if path_bytes(path)?.len() > MAXIMUM_PATH_BYTES {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "file metadata cache path exceeds the size limit",
        ));
    }
    Ok(())
}

fn validate_relative_path_bytes(bytes: &[u8]) -> Result<()> {
    if bytes.is_empty() || bytes.len() > MAXIMUM_PATH_BYTES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache path is invalid",
        ));
    }
    validate_relative_path(&bytes_to_path(bytes)?).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "file metadata cache path is invalid",
        )
    })
}

fn metadata_kind_tag(kind: FileMetadataKind) -> u8 {
    match kind {
        FileMetadataKind::File => 1,
        FileMetadataKind::Directory => 2,
        FileMetadataKind::Symlink => 3,
    }
}

fn metadata_kind_from_tag(tag: u8) -> Result<FileMetadataKind> {
    match tag {
        1 => Ok(FileMetadataKind::File),
        2 => Ok(FileMetadataKind::Directory),
        3 => Ok(FileMetadataKind::Symlink),
        _ => Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache entry type is invalid",
        )),
    }
}

fn encode_time(time: SystemTime) -> Result<(u8, u64, u32)> {
    match time.duration_since(UNIX_EPOCH) {
        Ok(duration) => Ok((0, duration.as_secs(), duration.subsec_nanos())),
        Err(error) => {
            let duration = error.duration();
            Ok((1, duration.as_secs(), duration.subsec_nanos()))
        }
    }
}

fn decode_time(before_epoch: u8, seconds: u64, nanoseconds: u32) -> Result<SystemTime> {
    let duration = Duration::new(seconds, nanoseconds);
    match before_epoch {
        0 => UNIX_EPOCH.checked_add(duration),
        1 => UNIX_EPOCH.checked_sub(duration),
        _ => None,
    }
    .ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "file metadata cache timestamp is invalid",
        )
    })
}

fn validate_cache_parent(path: &Path) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        Error::new(
            ErrorKind::InvalidInput,
            "file metadata cache path has no parent",
        )
    })?;
    let metadata = fs::symlink_metadata(parent).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "file metadata cache parent could not be inspected",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "file metadata cache parent is not a directory",
        ));
    }
    Ok(())
}

fn validate_cache_file(metadata: &fs::Metadata) -> Result<()> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache is not a regular file",
        ));
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(Error::new(
            ErrorKind::Conflict,
            "file metadata cache permissions are not private",
        ));
    }
    Ok(())
}

fn read_cache(path: &Path) -> Result<Option<Vec<u8>>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(Error::with_source(
                ErrorKind::Io,
                "file metadata cache could not be inspected",
                error,
            ));
        }
    };
    validate_cache_file(&metadata)?;
    if metadata.len() > MAXIMUM_CACHE_BYTES as u64 {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache exceeds the size limit",
        ));
    }
    let length = usize::try_from(metadata.len()).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "file metadata cache exceeds the size limit",
        )
    })?;
    let mut bytes = vec![0; length];
    let mut file = File::open(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "file metadata cache could not be opened",
            error,
        )
    })?;
    file.read_exact(&mut bytes).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "file metadata cache could not be read",
            error,
        )
    })?;
    if fs::symlink_metadata(path)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "file metadata cache could not be inspected",
                error,
            )
        })?
        .len()
        != metadata.len()
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "file metadata cache changed while being read",
        ));
    }
    Ok(Some(bytes))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    validate_cache_parent(path)?;
    if bytes.len() > MAXIMUM_CACHE_BYTES {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "file metadata cache is too large",
        ));
    }
    let parent = path.parent().expect("validated parent");
    let staging = parent.join(format!(".yeokcham-metadata-{}.partial", Uuid::new_v4()));
    let mut file = create_private_file(&staging).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "file metadata cache staging file could not be created",
            error,
        )
    })?;
    if let Err(error) = file.write_all(bytes).and_then(|()| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(&staging);
        return Err(Error::with_source(
            ErrorKind::Io,
            "file metadata cache could not be written",
            error,
        ));
    }
    drop(file);
    if let Err(error) = fs::rename(&staging, path) {
        let _ = fs::remove_file(&staging);
        return Err(Error::with_source(
            ErrorKind::Io,
            "file metadata cache could not be published",
            error,
        ));
    }
    sync_parent(path)
}

fn create_private_file(path: &Path) -> io::Result<File> {
    #[cfg(unix)]
    {
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(path)
    }
    #[cfg(not(unix))]
    {
        OpenOptions::new().create_new(true).write(true).open(path)
    }
}

fn sync_parent(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        let parent = path.parent().expect("validated parent");
        File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "file metadata cache directory could not be synchronized",
                    error,
                )
            })?;
    }
    Ok(())
}

#[cfg(unix)]
fn path_bytes(path: &Path) -> Result<&[u8]> {
    Ok(path.as_os_str().as_bytes())
}

#[cfg(not(unix))]
fn path_bytes(_: &Path) -> Result<&[u8]> {
    Err(Error::new(
        ErrorKind::Unsupported,
        "file metadata cache paths require Unix",
    ))
}

#[cfg(unix)]
fn bytes_to_path(bytes: &[u8]) -> Result<PathBuf> {
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes.to_vec())))
}

#[cfg(not(unix))]
fn bytes_to_path(_: &[u8]) -> Result<PathBuf> {
    Err(Error::new(
        ErrorKind::Unsupported,
        "file metadata cache paths require Unix",
    ))
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use uuid::Uuid;

    use super::*;
    use crate::{FilesystemMonitor, FilesystemMonitorLimits};

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-file-cache-{}", Uuid::new_v4()));
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

    fn snapshot(root: &Path) -> Vec<FileMetadataEntry> {
        fs::write(root.join("source"), b"source").expect("source");
        FilesystemMonitor::new(
            root,
            FilesystemMonitorLimits::new(4, 32, 32, 32).expect("limits"),
        )
        .expect("monitor")
        .metadata_snapshot()
    }

    #[test]
    fn atomically_round_trips_and_clears_a_repository_bound_snapshot() {
        let temporary = TestDirectory::new();
        let cache = FileMetadataCache::open(temporary.path().join("metadata.yk")).expect("cache");
        let repository_id = RepositoryId::generate();
        let entries = snapshot(temporary.path());

        assert_eq!(cache.load().expect("missing"), None);
        cache.store(repository_id, &entries).expect("store");
        assert_eq!(cache.load().expect("load"), Some((repository_id, entries)));
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(cache.path())
                .expect("metadata")
                .permissions()
                .mode()
                & 0o077,
            0
        );
        cache.clear().expect("clear");
        assert_eq!(cache.load().expect("cleared"), None);
    }

    #[test]
    fn rejects_corruption_and_never_debugs_paths() {
        let temporary = TestDirectory::new();
        let cache = FileMetadataCache::open(temporary.path().join("metadata.yk")).expect("cache");
        cache
            .store(RepositoryId::generate(), &snapshot(temporary.path()))
            .expect("store");
        fs::write(cache.path(), b"corrupt").expect("corrupt cache");

        let error = cache.load().expect_err("corrupt cache must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!format!("{cache:?}").contains("metadata.yk"));
    }

    #[test]
    fn rejects_unsorted_snapshot_entries() {
        let temporary = TestDirectory::new();
        let cache = FileMetadataCache::open(temporary.path().join("metadata.yk")).expect("cache");
        let metadata = FileMetadata::new(FileMetadataKind::File, 0, UNIX_EPOCH);
        let entries = [
            FileMetadataEntry::new(PathBuf::from("z"), metadata),
            FileMetadataEntry::new(PathBuf::from("a"), metadata),
        ];

        let error = cache
            .store(RepositoryId::generate(), &entries)
            .expect_err("unsorted entries");

        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn cache_type_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<FileMetadataCache>();
    }
}
