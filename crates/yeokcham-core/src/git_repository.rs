use std::{error::Error as StdError, io, path::Path};

use crate::{Error, ErrorKind, RefName, Result};

const MAX_REFERENCE_COUNT: usize = 1_000_000;

/// An opened, ownership-checked Git repository behind Yeokcham's Git adapter.
///
/// The adapter uses isolated, strict `gix` opening: it reads only repository
/// configuration, does not use Git environment overrides, and rejects an
/// untrusted Git directory. It supports bare repositories and worktrees but
/// enumerates regular ref names but does not yet resolve ref targets or return
/// objects.
pub struct GitRepository {
    inner: gix::ThreadSafeRepository,
}

impl GitRepository {
    /// Opens the Git repository explicitly located at `path`.
    ///
    /// This does not search parent directories or use `GIT_DIR` overrides.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if !path.try_exists().map_err(|error| {
            Error::with_source(ErrorKind::Io, "Git path could not be inspected", error)
        })? {
            return Err(Error::new(
                ErrorKind::NotFound,
                "Git repository does not exist",
            ));
        }
        let options = gix::open::Options::isolated()
            .strict_config(true)
            .bail_if_untrusted(true);
        let inner = options.open(path).map_err(open_error)?;
        Ok(Self { inner })
    }

    /// Returns the Git directory containing objects, refs, and configuration.
    pub fn git_dir(&self) -> &Path {
        self.inner.git_dir()
    }

    /// Returns the worktree path, or `None` for a bare repository.
    pub fn work_dir(&self) -> Option<&Path> {
        self.inner.work_dir()
    }

    /// Reports whether this opened repository has no worktree.
    pub fn is_bare(&self) -> bool {
        self.work_dir().is_none()
    }

    /// Returns regular Git reference names sorted by their exact bytes.
    ///
    /// Pseudo-refs such as `HEAD` are excluded. Names are validated through
    /// [`RefName`] without UTF-8 conversion or normalization. The result is a
    /// point-in-time enumeration only; it is not a ref transaction snapshot.
    ///
    /// Enumeration rejects malformed references and repositories with more
    /// than 1,000,000 regular refs to bound allocation.
    pub fn ref_names(&self) -> Result<Vec<RefName>> {
        let repository = self.inner.to_thread_local();
        let references = repository.references().map_err(reference_store_error)?;
        let iterator = references.all().map_err(|source| {
            reference_corrupt_error("Git references could not be enumerated", source)
        })?;
        let mut names = Vec::new();

        for reference in iterator {
            let reference = reference.map_err(|source| {
                Error::with_boxed_source(
                    ErrorKind::CorruptData,
                    "Git reference could not be enumerated",
                    source,
                )
            })?;
            let bytes: &[u8] = reference.name().as_bstr().as_ref();
            if !bytes.starts_with(b"refs/") {
                continue;
            }
            if names.len() == MAX_REFERENCE_COUNT {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "Git repository has too many references",
                ));
            }
            names.push(RefName::from_bytes(bytes).map_err(|source| {
                Error::with_source(
                    ErrorKind::CorruptData,
                    "Git reference name is invalid",
                    source,
                )
            })?);
        }

        names.sort();
        if names.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Git reference enumeration contains duplicate names",
            ));
        }
        Ok(names)
    }
}

fn open_error(error: gix::open::Error) -> Error {
    match error {
        gix::open::Error::NotARepository { .. } => {
            Error::new(ErrorKind::InvalidInput, "path is not a Git repository")
        }
        gix::open::Error::UnsafeGitDir { .. } => Error::new(
            ErrorKind::InvalidInput,
            "Git repository directory is not trusted",
        ),
        gix::open::Error::Io(source) if source.kind() == io::ErrorKind::NotFound => {
            Error::with_source(ErrorKind::NotFound, "Git repository does not exist", source)
        }
        gix::open::Error::Io(source) => {
            Error::with_source(ErrorKind::Io, "Git repository could not be opened", source)
        }
        source => Error::with_source(
            ErrorKind::CorruptData,
            "Git repository configuration is invalid",
            source,
        ),
    }
}

fn reference_store_error(error: gix::refs::packed::buffer::open::Error) -> Error {
    match error {
        gix::refs::packed::buffer::open::Error::Io(source) => {
            Error::with_source(ErrorKind::Io, "Git references could not be read", source)
        }
        source => reference_corrupt_error("Git packed references are malformed", source),
    }
}

fn reference_corrupt_error<E>(message: &'static str, source: E) -> Error
where
    E: StdError + Send + Sync + 'static,
{
    Error::with_source(ErrorKind::CorruptData, message, source)
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
        process::Command,
    };

    #[cfg(target_os = "linux")]
    use std::{ffi::OsString, os::unix::ffi::OsStringExt};

    use uuid::Uuid;

    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-git-test-{}", Uuid::new_v4()));
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

    fn run_git(arguments: &[&str]) {
        let output = Command::new("git")
            .args(arguments)
            .output()
            .expect("run Git");
        assert!(
            output.status.success(),
            "Git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn run_git_in(directory: &Path, arguments: &[&str]) {
        let output = Command::new("git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .output()
            .expect("run Git");
        assert!(
            output.status.success(),
            "Git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn git_stdout(directory: &Path, arguments: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .output()
            .expect("run Git");
        assert!(
            output.status.success(),
            "Git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("Git output must be UTF-8")
            .trim()
            .to_owned()
    }

    fn initialize_committed_worktree(temporary: &TestDirectory) -> PathBuf {
        let worktree = temporary.path().join("worktree");
        let worktree_text = worktree.to_str().expect("UTF-8 test path");
        run_git(&["init", "--initial-branch=main", worktree_text]);
        run_git_in(
            &worktree,
            &[
                "-c",
                "user.name=Yeokcham Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "--allow-empty",
                "--message=initial",
            ],
        );
        worktree
    }

    #[test]
    fn opens_bare_and_worktree_repositories() {
        let temporary = TestDirectory::new();
        let bare = temporary.path().join("bare.git");
        let worktree = temporary.path().join("worktree");
        let bare_text = bare.to_str().expect("UTF-8 test path");
        let worktree_text = worktree.to_str().expect("UTF-8 test path");
        run_git(&["init", "--bare", bare_text]);
        run_git(&["init", "--initial-branch=main", worktree_text]);

        let bare_repository = GitRepository::open(&bare).expect("open bare repository");
        let worktree_repository = GitRepository::open(&worktree).expect("open worktree repository");

        assert!(bare_repository.is_bare());
        assert_eq!(bare_repository.work_dir(), None);
        assert_eq!(bare_repository.git_dir(), bare);
        assert!(!worktree_repository.is_bare());
        assert_eq!(worktree_repository.work_dir(), Some(worktree.as_path()));
        assert_eq!(worktree_repository.git_dir(), worktree.join(".git"));
    }

    #[test]
    fn rejects_missing_and_non_repository_paths_without_disclosing_them() {
        let temporary = TestDirectory::new();
        let missing = temporary.path().join("missing");
        let directory = temporary.path().join("not-a-repository");
        fs::create_dir(&directory).expect("create directory");

        let missing_error = GitRepository::open(&missing)
            .err()
            .expect("missing path must fail");
        let invalid_error = GitRepository::open(&directory)
            .err()
            .expect("non-repository path must fail");

        assert_eq!(missing_error.kind(), ErrorKind::NotFound);
        assert_eq!(invalid_error.kind(), ErrorKind::InvalidInput);
        assert!(!format!("{invalid_error:?}").contains("not-a-repository"));
    }

    #[test]
    fn enumerates_sorted_regular_ref_names_from_packed_and_loose_storage() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        let object_id = git_stdout(&worktree, &["rev-parse", "HEAD"]);
        run_git_in(&worktree, &["update-ref", "refs/heads/alpha", &object_id]);
        run_git_in(&worktree, &["update-ref", "refs/tags/v1.0", &object_id]);
        run_git_in(&worktree, &["pack-refs", "--all", "--prune"]);
        run_git_in(&worktree, &["update-ref", "refs/heads/z-last", &object_id]);
        run_git_in(
            &worktree,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );

        let names = GitRepository::open(&worktree)
            .expect("open repository")
            .ref_names()
            .expect("enumerate references");
        let bytes: Vec<Vec<u8>> = names.iter().map(|name| name.as_bytes().to_vec()).collect();

        assert_eq!(
            bytes,
            vec![
                b"refs/heads/alpha".to_vec(),
                b"refs/heads/main".to_vec(),
                b"refs/heads/z-last".to_vec(),
                b"refs/remotes/origin/HEAD".to_vec(),
                b"refs/tags/v1.0".to_vec(),
            ]
        );
        assert!(bytes.iter().all(|name| name.starts_with(b"refs/")));
        assert!(!bytes.iter().any(|name| name == b"HEAD"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn preserves_non_utf8_regular_ref_names() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        let object_id = git_stdout(&worktree, &["rev-parse", "HEAD"]);
        let raw_component = OsString::from_vec(vec![0xff]);
        let raw_path = worktree.join(".git/refs/heads").join(raw_component);
        fs::write(raw_path, format!("{object_id}\n")).expect("write raw-byte ref");

        let names = GitRepository::open(&worktree)
            .expect("open repository")
            .ref_names()
            .expect("enumerate references");
        let bytes: Vec<Vec<u8>> = names.iter().map(|name| name.as_bytes().to_vec()).collect();

        assert!(bytes.contains(&b"refs/heads/\xff".to_vec()));
    }

    #[test]
    fn rejects_malformed_packed_references_without_disclosing_them() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::write(worktree.join(".git/packed-refs"), b"not-a-reference\n")
            .expect("write malformed packed refs");

        let error = GitRepository::open(&worktree)
            .expect("open repository")
            .ref_names()
            .expect_err("malformed packed refs must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains("not-a-reference"));
    }
}
