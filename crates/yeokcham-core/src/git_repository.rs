use std::{io, path::Path};

use crate::{Error, ErrorKind, Result};

/// An opened, ownership-checked Git repository behind Yeokcham's Git adapter.
///
/// The adapter uses isolated, strict `gix` opening: it reads only repository
/// configuration, does not use Git environment overrides, and rejects an
/// untrusted Git directory. It supports bare repositories and worktrees but
/// does not yet enumerate refs or return objects.
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

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
        process::Command,
    };

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
}
