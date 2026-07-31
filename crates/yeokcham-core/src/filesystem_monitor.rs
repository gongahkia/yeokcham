use std::{
    collections::{BTreeMap, VecDeque},
    fmt, fs, io,
    path::{Path, PathBuf},
    time::SystemTime,
};

use crate::{Error, ErrorKind, Result};

const MAXIMUM_MONITOR_DEPTH: usize = 128;
const MAXIMUM_MONITOR_DIRECTORIES: usize = 1_000_000;
const MAXIMUM_MONITOR_ENTRIES: usize = 1_000_000;
const MAXIMUM_MONITOR_DIRECTORY_ENTRIES: usize = 1_000_000;

/// Bounds for one explicit-root filesystem monitor snapshot.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct FilesystemMonitorLimits {
    maximum_depth: usize,
    maximum_directories: usize,
    maximum_entries: usize,
    maximum_entries_per_directory: usize,
}

impl FilesystemMonitorLimits {
    /// Creates one bounded filesystem monitor policy.
    pub fn new(
        maximum_depth: usize,
        maximum_directories: usize,
        maximum_entries: usize,
        maximum_entries_per_directory: usize,
    ) -> Result<Self> {
        if maximum_depth > MAXIMUM_MONITOR_DEPTH
            || maximum_directories == 0
            || maximum_directories > MAXIMUM_MONITOR_DIRECTORIES
            || maximum_entries == 0
            || maximum_entries > MAXIMUM_MONITOR_ENTRIES
            || maximum_entries_per_directory == 0
            || maximum_entries_per_directory > MAXIMUM_MONITOR_DIRECTORY_ENTRIES
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "filesystem monitor limits are invalid",
            ));
        }
        Ok(Self {
            maximum_depth,
            maximum_directories,
            maximum_entries,
            maximum_entries_per_directory,
        })
    }

    /// Returns the maximum number of levels below the explicit root to inspect.
    pub const fn maximum_depth(self) -> usize {
        self.maximum_depth
    }

    /// Returns the maximum number of directories inspected per snapshot.
    pub const fn maximum_directories(self) -> usize {
        self.maximum_directories
    }

    /// Returns the maximum entries retained per snapshot.
    pub const fn maximum_entries(self) -> usize {
        self.maximum_entries
    }

    /// Returns the maximum entries sorted from one directory.
    pub const fn maximum_entries_per_directory(self) -> usize {
        self.maximum_entries_per_directory
    }
}

/// A metadata-only filesystem change kind.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum FilesystemChangeKind {
    /// An entry appeared below the monitored root.
    Created,
    /// An existing entry's tracked metadata changed.
    Modified,
    /// An entry disappeared below the monitored root.
    Removed,
}

/// One relative-path filesystem change detected between complete snapshots.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct FilesystemChange {
    path: PathBuf,
    kind: FilesystemChangeKind,
}

impl FilesystemChange {
    /// Returns the relative entry path below the explicit monitored root.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns the detected metadata change kind.
    pub const fn kind(&self) -> FilesystemChangeKind {
        self.kind
    }
}

impl fmt::Debug for FilesystemChange {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("FilesystemChange(<redacted>)")
    }
}

/// A bounded polling monitor for one explicit non-symlink filesystem root.
pub struct FilesystemMonitor {
    root: PathBuf,
    limits: FilesystemMonitorLimits,
    snapshot: BTreeMap<PathBuf, EntryFingerprint>,
}

impl FilesystemMonitor {
    /// Creates a monitor after capturing one complete initial metadata snapshot.
    pub fn new(root: impl AsRef<Path>, limits: FilesystemMonitorLimits) -> Result<Self> {
        let root = root.as_ref();
        validate_root(root)?;
        let snapshot = scan(root, limits)?;
        Ok(Self {
            root: root.to_path_buf(),
            limits,
            snapshot,
        })
    }

    /// Returns the explicit monitored root path.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Returns the immutable snapshot bounds.
    pub const fn limits(&self) -> FilesystemMonitorLimits {
        self.limits
    }

    /// Returns the number of entries in the last complete snapshot.
    pub fn tracked_entry_count(&self) -> usize {
        self.snapshot.len()
    }

    /// Captures a complete new snapshot and returns sorted metadata changes.
    ///
    /// The last successful snapshot remains unchanged if scanning fails.
    pub fn poll(&mut self) -> Result<Vec<FilesystemChange>> {
        validate_root(&self.root)?;
        let next = scan(&self.root, self.limits)?;
        let mut changes = Vec::new();
        for (path, current) in &self.snapshot {
            match next.get(path) {
                Some(observed) if observed != current => changes.push(FilesystemChange {
                    path: path.clone(),
                    kind: FilesystemChangeKind::Modified,
                }),
                None => changes.push(FilesystemChange {
                    path: path.clone(),
                    kind: FilesystemChangeKind::Removed,
                }),
                Some(_) => {}
            }
        }
        for path in next.keys() {
            if !self.snapshot.contains_key(path) {
                changes.push(FilesystemChange {
                    path: path.clone(),
                    kind: FilesystemChangeKind::Created,
                });
            }
        }
        changes.sort();
        self.snapshot = next;
        Ok(changes)
    }
}

impl fmt::Debug for FilesystemMonitor {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FilesystemMonitor")
            .field("tracked_entry_count", &self.snapshot.len())
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum EntryKind {
    File,
    Directory,
    Symlink,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct EntryFingerprint {
    kind: EntryKind,
    length: u64,
    modified: SystemTime,
}

fn scan(
    root: &Path,
    limits: FilesystemMonitorLimits,
) -> Result<BTreeMap<PathBuf, EntryFingerprint>> {
    let mut pending = VecDeque::from([(root.to_path_buf(), PathBuf::new(), 0_usize)]);
    let mut directories = 0_usize;
    let mut entries = BTreeMap::new();
    while let Some((directory, relative, depth)) = pending.pop_front() {
        directories = directories.checked_add(1).ok_or_else(|| {
            Error::new(
                ErrorKind::Unsupported,
                "filesystem monitor directory limit is exceeded",
            )
        })?;
        if directories > limits.maximum_directories {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "filesystem monitor directory limit is exceeded",
            ));
        }
        for path in sorted_entries(&directory, limits.maximum_entries_per_directory)? {
            let name = path.file_name().ok_or_else(|| {
                Error::new(ErrorKind::Internal, "filesystem monitor entry has no name")
            })?;
            let entry_relative = relative.join(name);
            let metadata = fs::symlink_metadata(&path).map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "filesystem monitor entry could not be inspected",
                    error,
                )
            })?;
            let kind = entry_kind(&metadata)?;
            if entries.len() == limits.maximum_entries {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "filesystem monitor entry limit is exceeded",
                ));
            }
            let modified = metadata.modified().map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "filesystem monitor entry timestamp could not be read",
                    error,
                )
            })?;
            if entries
                .insert(
                    entry_relative.clone(),
                    EntryFingerprint {
                        kind,
                        length: metadata.len(),
                        modified,
                    },
                )
                .is_some()
            {
                return Err(Error::new(
                    ErrorKind::Internal,
                    "filesystem monitor produced duplicate paths",
                ));
            }
            if kind == EntryKind::Directory && depth < limits.maximum_depth {
                pending.push_back((path, entry_relative, depth + 1));
            }
        }
    }
    Ok(entries)
}

fn validate_root(root: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(root).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => {
            Error::new(ErrorKind::NotFound, "filesystem monitor root is missing")
        }
        _ => Error::with_source(
            ErrorKind::Io,
            "filesystem monitor root could not be inspected",
            error,
        ),
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "filesystem monitor root is not a directory",
        ));
    }
    Ok(())
}

fn sorted_entries(directory: &Path, maximum_entries: usize) -> Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(directory).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "filesystem monitor directory could not be listed",
            error,
        )
    })? {
        if entries.len() == maximum_entries {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "filesystem monitor directory entry limit is exceeded",
            ));
        }
        entries.push(
            entry
                .map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "filesystem monitor directory could not be listed",
                        error,
                    )
                })?
                .path(),
        );
    }
    entries.sort();
    Ok(entries)
}

fn entry_kind(metadata: &fs::Metadata) -> Result<EntryKind> {
    if metadata.file_type().is_symlink() {
        Ok(EntryKind::Symlink)
    } else if metadata.is_file() {
        Ok(EntryKind::File)
    } else if metadata.is_dir() {
        Ok(EntryKind::Directory)
    } else {
        Err(Error::new(
            ErrorKind::Unsupported,
            "filesystem monitor entry type is unsupported",
        ))
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use uuid::Uuid;

    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-monitor-{}", Uuid::new_v4()));
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

    fn limits() -> FilesystemMonitorLimits {
        FilesystemMonitorLimits::new(8, 64, 64, 64).expect("limits")
    }

    #[test]
    fn reports_sorted_create_modify_and_remove_events() {
        let temporary = TestDirectory::new();
        fs::write(temporary.path().join("changed"), b"one").expect("changed");
        fs::write(temporary.path().join("removed"), b"gone").expect("removed");
        let mut monitor = FilesystemMonitor::new(temporary.path(), limits()).expect("monitor");
        fs::write(temporary.path().join("changed"), b"different length").expect("modify");
        fs::remove_file(temporary.path().join("removed")).expect("remove");
        fs::write(temporary.path().join("created"), b"new").expect("create");

        let changes = monitor.poll().expect("poll");

        assert_eq!(
            changes,
            [
                FilesystemChange {
                    path: PathBuf::from("changed"),
                    kind: FilesystemChangeKind::Modified,
                },
                FilesystemChange {
                    path: PathBuf::from("created"),
                    kind: FilesystemChangeKind::Created,
                },
                FilesystemChange {
                    path: PathBuf::from("removed"),
                    kind: FilesystemChangeKind::Removed,
                },
            ]
        );
        assert_eq!(monitor.poll().expect("unchanged"), []);
    }

    #[test]
    fn rejects_limits_and_retains_last_snapshot_after_a_failed_poll() {
        let temporary = TestDirectory::new();
        fs::write(temporary.path().join("one"), b"one").expect("one");
        fs::write(temporary.path().join("two"), b"two").expect("two");
        let narrow = FilesystemMonitorLimits::new(1, 8, 8, 1).expect("limits");
        let new_error = FilesystemMonitor::new(temporary.path(), narrow).expect_err("wide root");
        assert_eq!(new_error.kind(), ErrorKind::Unsupported);

        let mut monitor = FilesystemMonitor::new(temporary.path(), limits()).expect("monitor");
        let snapshot_before = monitor.tracked_entry_count();
        fs::remove_dir_all(temporary.path()).expect("remove root");
        let failed = monitor.poll().expect_err("missing root");
        assert_eq!(snapshot_before, monitor.tracked_entry_count());
        assert_eq!(failed.kind(), ErrorKind::NotFound);
    }

    #[cfg(unix)]
    #[test]
    fn records_links_without_following_them() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let outside = TestDirectory::new();
        fs::write(outside.path().join("outside"), b"outside").expect("outside");
        symlink(outside.path(), temporary.path().join("linked-directory")).expect("link");
        let mut monitor = FilesystemMonitor::new(temporary.path(), limits()).expect("monitor");

        assert_eq!(monitor.tracked_entry_count(), 1);
        fs::remove_file(temporary.path().join("linked-directory")).expect("unlink");
        assert_eq!(
            monitor.poll().expect("poll"),
            [FilesystemChange {
                path: PathBuf::from("linked-directory"),
                kind: FilesystemChangeKind::Removed,
            }]
        );
    }

    #[test]
    fn monitor_types_are_send_and_sync_and_debug_is_redacted() {
        fn assert_send_sync<T: Send + Sync>() {}

        let temporary = TestDirectory::new();
        let monitor = FilesystemMonitor::new(temporary.path(), limits()).expect("monitor");
        let change = FilesystemChange {
            path: PathBuf::from("source-name"),
            kind: FilesystemChangeKind::Created,
        };

        assert_send_sync::<FilesystemMonitorLimits>();
        assert_send_sync::<FilesystemChange>();
        assert_send_sync::<FilesystemMonitor>();
        assert!(!format!("{monitor:?}").contains("yeokcham-monitor"));
        assert!(!format!("{change:?}").contains("source-name"));
    }
}
