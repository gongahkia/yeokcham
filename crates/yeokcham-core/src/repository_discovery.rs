use std::{
    collections::VecDeque,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use crate::{Error, ErrorKind, LocalRepository, RepositoryId, Result};

const MAXIMUM_DISCOVERY_DEPTH: usize = 128;
const MAXIMUM_DISCOVERY_DIRECTORIES: usize = 1_000_000;
const MAXIMUM_DISCOVERY_REPOSITORIES: usize = 100_000;
const MAXIMUM_DISCOVERY_DIRECTORY_ENTRIES: usize = 1_000_000;

/// Bounds for one explicit-root local repository discovery scan.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RepositoryDiscoveryLimits {
    maximum_depth: usize,
    maximum_directories: usize,
    maximum_repositories: usize,
    maximum_entries_per_directory: usize,
}

impl RepositoryDiscoveryLimits {
    /// Creates one bounded local discovery policy.
    pub fn new(
        maximum_depth: usize,
        maximum_directories: usize,
        maximum_repositories: usize,
        maximum_entries_per_directory: usize,
    ) -> Result<Self> {
        if maximum_depth > MAXIMUM_DISCOVERY_DEPTH
            || maximum_directories == 0
            || maximum_directories > MAXIMUM_DISCOVERY_DIRECTORIES
            || maximum_repositories == 0
            || maximum_repositories > MAXIMUM_DISCOVERY_REPOSITORIES
            || maximum_repositories > maximum_directories
            || maximum_entries_per_directory == 0
            || maximum_entries_per_directory > MAXIMUM_DISCOVERY_DIRECTORY_ENTRIES
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "repository discovery limits are invalid",
            ));
        }
        Ok(Self {
            maximum_depth,
            maximum_directories,
            maximum_repositories,
            maximum_entries_per_directory,
        })
    }

    /// Returns the maximum number of levels below the explicit root to inspect.
    pub const fn maximum_depth(self) -> usize {
        self.maximum_depth
    }

    /// Returns the maximum number of non-symlink directories to inspect.
    pub const fn maximum_directories(self) -> usize {
        self.maximum_directories
    }

    /// Returns the maximum number of validated repositories to return.
    pub const fn maximum_repositories(self) -> usize {
        self.maximum_repositories
    }

    /// Returns the maximum entries sorted from any one scanned directory.
    pub const fn maximum_entries_per_directory(self) -> usize {
        self.maximum_entries_per_directory
    }
}

/// One validated local Yeokcham repository found beneath an explicit root.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DiscoveredLocalRepository {
    path: PathBuf,
    id: RepositoryId,
}

impl DiscoveredLocalRepository {
    /// Returns the caller-owned local repository root path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns the validated repository identity from its bootstrap.
    pub const fn id(&self) -> RepositoryId {
        self.id
    }
}

impl fmt::Debug for DiscoveredLocalRepository {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("DiscoveredLocalRepository(<redacted>)")
    }
}

/// Results and opaque skip counts from one local repository discovery scan.
#[derive(Clone, Eq, PartialEq)]
pub struct RepositoryDiscoveryReport {
    repositories: Vec<DiscoveredLocalRepository>,
    inspected_directories: usize,
    skipped_symlinks: usize,
    skipped_unreadable_directories: usize,
    rejected_candidates: usize,
}

impl RepositoryDiscoveryReport {
    /// Returns validated repositories sorted by their exact local paths.
    pub fn repositories(&self) -> &[DiscoveredLocalRepository] {
        &self.repositories
    }

    /// Returns the count of non-symlink directories inspected within the limit.
    pub const fn inspected_directories(&self) -> usize {
        self.inspected_directories
    }

    /// Returns the count of symbolic-link entries skipped without dereferencing.
    pub const fn skipped_symlinks(&self) -> usize {
        self.skipped_symlinks
    }

    /// Returns the count of unreadable or concurrently removed directories skipped.
    pub const fn skipped_unreadable_directories(&self) -> usize {
        self.skipped_unreadable_directories
    }

    /// Returns the count of invalid Yeokcham-layout candidates skipped.
    pub const fn rejected_candidates(&self) -> usize {
        self.rejected_candidates
    }
}

impl fmt::Debug for RepositoryDiscoveryReport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RepositoryDiscoveryReport")
            .field("repository_count", &self.repositories.len())
            .field("inspected_directories", &self.inspected_directories)
            .field("skipped_symlinks", &self.skipped_symlinks)
            .field(
                "skipped_unreadable_directories",
                &self.skipped_unreadable_directories,
            )
            .field("rejected_candidates", &self.rejected_candidates)
            .finish()
    }
}

/// Finds validated local Yeokcham repositories beneath one caller-provided root.
///
/// The scan does not follow symbolic links, inspect paths outside `root`, search
/// parent directories, or persist registration state. It stops at a validated or
/// malformed Yeokcham-layout candidate rather than scanning its storage layout.
pub fn discover_local_repositories(
    root: impl AsRef<Path>,
    limits: RepositoryDiscoveryLimits,
) -> Result<RepositoryDiscoveryReport> {
    let root = root.as_ref();
    validate_root(root)?;
    let mut pending = VecDeque::from([(root.to_path_buf(), 0_usize)]);
    let mut repositories = Vec::new();
    let mut inspected_directories = 0_usize;
    let mut skipped_symlinks = 0_usize;
    let mut skipped_unreadable_directories = 0_usize;
    let mut rejected_candidates = 0_usize;

    while let Some((directory, depth)) = pending.pop_front() {
        inspected_directories = inspected_directories.checked_add(1).ok_or_else(|| {
            Error::new(
                ErrorKind::Unsupported,
                "repository discovery directory limit is exceeded",
            )
        })?;
        if inspected_directories > limits.maximum_directories {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "repository discovery directory limit is exceeded",
            ));
        }

        match is_yeokcham_candidate(&directory)? {
            YeokchamCandidate::None => {}
            YeokchamCandidate::ValidMarker => {
                match LocalRepository::open(&directory) {
                    Ok(repository) => {
                        if repositories.len() == limits.maximum_repositories {
                            return Err(Error::new(
                                ErrorKind::Unsupported,
                                "repository discovery result limit is exceeded",
                            ));
                        }
                        repositories.push(DiscoveredLocalRepository {
                            path: directory,
                            id: repository.id(),
                        });
                    }
                    Err(_) => {
                        rejected_candidates =
                            rejected_candidates.checked_add(1).ok_or_else(|| {
                                Error::new(
                                    ErrorKind::Unsupported,
                                    "repository discovery candidate limit is exceeded",
                                )
                            })?
                    }
                }
                continue;
            }
            YeokchamCandidate::MalformedMarker => {
                rejected_candidates = rejected_candidates.checked_add(1).ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "repository discovery candidate limit is exceeded",
                    )
                })?;
                continue;
            }
        }
        if depth == limits.maximum_depth {
            continue;
        }

        let entries =
            match sorted_directory_entries(&directory, limits.maximum_entries_per_directory) {
                Ok(entries) => entries,
                Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                    return Err(Error::new(
                        ErrorKind::Unsupported,
                        "repository discovery directory entry limit is exceeded",
                    ));
                }
                Err(error) if directory != root && is_skippable_directory_error(&error) => {
                    skipped_unreadable_directories = skipped_unreadable_directories
                        .checked_add(1)
                        .ok_or_else(|| {
                            Error::new(
                                ErrorKind::Unsupported,
                                "repository discovery skip count is exceeded",
                            )
                        })?;
                    continue;
                }
                Err(error) => {
                    return Err(Error::with_source(
                        ErrorKind::Io,
                        "repository discovery directory could not be listed",
                        error,
                    ));
                }
            };
        for entry in entries {
            let metadata = match fs::symlink_metadata(&entry) {
                Ok(metadata) => metadata,
                Err(error) if is_skippable_directory_error(&error) => {
                    skipped_unreadable_directories = skipped_unreadable_directories
                        .checked_add(1)
                        .ok_or_else(|| {
                            Error::new(
                                ErrorKind::Unsupported,
                                "repository discovery skip count is exceeded",
                            )
                        })?;
                    continue;
                }
                Err(error) => {
                    return Err(Error::with_source(
                        ErrorKind::Io,
                        "repository discovery entry could not be inspected",
                        error,
                    ));
                }
            };
            if metadata.file_type().is_symlink() {
                skipped_symlinks = skipped_symlinks.checked_add(1).ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "repository discovery skip count is exceeded",
                    )
                })?;
                continue;
            }
            if metadata.is_dir() {
                pending.push_back((entry, depth + 1));
            }
        }
    }

    repositories.sort();
    if repositories
        .windows(2)
        .any(|pair| pair[0].path == pair[1].path)
    {
        return Err(Error::new(
            ErrorKind::Internal,
            "repository discovery produced duplicate paths",
        ));
    }
    Ok(RepositoryDiscoveryReport {
        repositories,
        inspected_directories,
        skipped_symlinks,
        skipped_unreadable_directories,
        rejected_candidates,
    })
}

fn validate_root(root: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(root).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => {
            Error::new(ErrorKind::NotFound, "repository discovery root is missing")
        }
        _ => Error::with_source(
            ErrorKind::Io,
            "repository discovery root could not be inspected",
            error,
        ),
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "repository discovery root is not a directory",
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum YeokchamCandidate {
    None,
    ValidMarker,
    MalformedMarker,
}

fn is_yeokcham_candidate(directory: &Path) -> Result<YeokchamCandidate> {
    let format = directory.join("format");
    let format = match fs::symlink_metadata(format) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => true,
        Ok(_) => return Ok(YeokchamCandidate::None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(YeokchamCandidate::None);
        }
        Err(error) => {
            return Err(Error::with_source(
                ErrorKind::Io,
                "repository discovery candidate could not be inspected",
                error,
            ));
        }
    };
    debug_assert!(format);
    match fs::symlink_metadata(directory.join("format/repository.bin")) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            Ok(YeokchamCandidate::ValidMarker)
        }
        Ok(_) => Ok(YeokchamCandidate::MalformedMarker),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(YeokchamCandidate::None),
        Err(error) => Err(Error::with_source(
            ErrorKind::Io,
            "repository discovery candidate could not be inspected",
            error,
        )),
    }
}

fn sorted_directory_entries(directory: &Path, maximum_entries: usize) -> io::Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(directory)? {
        if entries.len() == maximum_entries {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "repository discovery directory entry limit is exceeded",
            ));
        }
        entries.push(entry?.path());
    }
    entries.sort();
    Ok(entries)
}

fn is_skippable_directory_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
    )
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use uuid::Uuid;

    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-discovery-{}", Uuid::new_v4()));
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

    fn limits() -> RepositoryDiscoveryLimits {
        RepositoryDiscoveryLimits::new(8, 64, 8, 64).expect("limits")
    }

    #[test]
    fn discovers_sorted_valid_repositories_without_descending_into_them() {
        let temporary = TestDirectory::new();
        let outer = temporary.path().join("outer");
        let first = temporary.path().join("a-store");
        let second = outer.join("b-store");
        fs::create_dir(&outer).expect("outer");
        let first_repository = LocalRepository::create(&first).expect("first");
        let second_repository = LocalRepository::create(&second).expect("second");
        LocalRepository::create(first.join("nested-store")).expect("nested");

        let report = discover_local_repositories(temporary.path(), limits()).expect("discover");

        assert_eq!(report.inspected_directories(), 4);
        assert_eq!(report.skipped_symlinks(), 0);
        assert_eq!(report.rejected_candidates(), 0);
        assert_eq!(
            report.repositories(),
            [
                DiscoveredLocalRepository {
                    path: first,
                    id: first_repository.id(),
                },
                DiscoveredLocalRepository {
                    path: second,
                    id: second_repository.id(),
                },
            ]
        );
    }

    #[test]
    fn rejects_bad_roots_bounds_and_invalid_candidates_without_path_disclosure() {
        let temporary = TestDirectory::new();
        let malformed = temporary.path().join("malformed");
        fs::create_dir(&malformed).expect("malformed");
        fs::create_dir(malformed.join("format")).expect("format");
        fs::write(malformed.join("format/repository.bin"), b"invalid").expect("bootstrap");

        let report = discover_local_repositories(temporary.path(), limits()).expect("discover");
        let invalid_limits = RepositoryDiscoveryLimits::new(129, 1, 1, 1).expect_err("limit");
        let missing = discover_local_repositories(temporary.path().join("missing"), limits())
            .expect_err("missing root");

        assert_eq!(report.repositories(), []);
        assert_eq!(report.rejected_candidates(), 1);
        assert_eq!(invalid_limits.kind(), ErrorKind::InvalidInput);
        assert_eq!(missing.kind(), ErrorKind::NotFound);
        assert!(!format!("{report:?}").contains("malformed"));
    }

    #[cfg(unix)]
    #[test]
    fn skips_symbolic_links_without_following_their_targets() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let outside = TestDirectory::new();
        let outside_repository = outside.path().join("store");
        LocalRepository::create(&outside_repository).expect("outside repository");
        symlink(&outside_repository, temporary.path().join("linked-store")).expect("link");

        let report = discover_local_repositories(temporary.path(), limits()).expect("discover");

        assert_eq!(report.repositories(), []);
        assert_eq!(report.skipped_symlinks(), 1);
    }

    #[test]
    fn rejects_exhausted_directory_and_result_limits() {
        let temporary = TestDirectory::new();
        fs::create_dir(temporary.path().join("one")).expect("one");
        fs::create_dir(temporary.path().join("two")).expect("two");
        let directory_limit = RepositoryDiscoveryLimits::new(1, 2, 2, 8).expect("limits");
        let directory_error = discover_local_repositories(temporary.path(), directory_limit)
            .expect_err("directory limit");

        let first = LocalRepository::create(temporary.path().join("first")).expect("first");
        let second = LocalRepository::create(temporary.path().join("second")).expect("second");
        let result_limit = RepositoryDiscoveryLimits::new(1, 8, 1, 8).expect("limits");
        let result_error =
            discover_local_repositories(temporary.path(), result_limit).expect_err("result limit");

        assert_ne!(first.id(), second.id());
        assert_eq!(directory_error.kind(), ErrorKind::Unsupported);
        assert_eq!(result_error.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn rejects_wide_directories_before_unbounded_sorting() {
        let temporary = TestDirectory::new();
        for name in ["one", "two", "three"] {
            fs::create_dir(temporary.path().join(name)).expect("entry");
        }
        let limits = RepositoryDiscoveryLimits::new(1, 8, 8, 2).expect("limits");
        let error = discover_local_repositories(temporary.path(), limits)
            .expect_err("directory entry limit");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn discovery_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RepositoryDiscoveryLimits>();
        assert_send_sync::<DiscoveredLocalRepository>();
        assert_send_sync::<RepositoryDiscoveryReport>();
    }
}
