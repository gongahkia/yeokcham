use std::{
    collections::{BTreeMap, BTreeSet},
    error::Error as StdError,
    io,
    path::Path,
};

use crate::{
    Error, ErrorKind, GitObject, GitObjectId, GitObjectKind, GitRefState, HeadState, RefName,
    Result,
};

const MAX_REFERENCE_COUNT: usize = 1_000_000;
const MAX_REACHABLE_OBJECT_COUNT: usize = 1_000_000;

/// An opened, ownership-checked Git repository behind Yeokcham's Git adapter.
///
/// The adapter uses isolated, strict `gix` opening: it reads only repository
/// configuration, does not use Git environment overrides, and rejects an
/// untrusted Git directory. It supports bare repositories and worktrees but
/// enumerates refs, resolves their direct targets, and reads verified objects.
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
        if inner.to_thread_local().object_hash() != gix::hash::Kind::Sha1 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Git repository uses an unsupported object hash",
            ));
        }
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

    pub(crate) fn clone_for_thread(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
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
            let Some(name) = regular_ref_name(bytes)? else {
                continue;
            };
            if names.len() == MAX_REFERENCE_COUNT {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "Git repository has too many references",
                ));
            }
            names.push(name);
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

    /// Returns a checked point-in-time state of regular refs and `HEAD`.
    ///
    /// Every regular symbolic ref is followed to its first direct SHA-1 object
    /// target. `HEAD` remains symbolic, including for an unborn branch, or
    /// remains detached. The state is not a transaction snapshot: concurrent
    /// Git mutation can cause an error or a later consistency check to fail.
    pub fn ref_state(&self) -> Result<GitRefState> {
        let repository = self.inner.to_thread_local();
        let references = repository.references().map_err(reference_store_error)?;
        let iterator = references.all().map_err(|source| {
            reference_corrupt_error("Git references could not be enumerated", source)
        })?;
        let mut regular_refs = BTreeMap::new();

        for reference in iterator {
            let mut reference = reference.map_err(|source| {
                Error::with_boxed_source(
                    ErrorKind::CorruptData,
                    "Git reference could not be enumerated",
                    source,
                )
            })?;
            let bytes: &[u8] = reference.name().as_bstr().as_ref();
            let Some(name) = regular_ref_name(bytes)? else {
                continue;
            };
            if regular_refs.len() == MAX_REFERENCE_COUNT {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "Git repository has too many references",
                ));
            }
            let target = reference.follow_to_object().map_err(|source| {
                reference_corrupt_error("Git reference target is unavailable or malformed", source)
            })?;
            let target = git_object_id_from_gix(&target.detach())?;
            if regular_refs.insert(name, target).is_some() {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "Git reference enumeration contains duplicate names",
                ));
            }
        }

        let head = repository.head().map_err(|source| {
            reference_corrupt_error("Git HEAD is unavailable or malformed", source)
        })?;
        let head = match head.referent_name() {
            Some(name) => {
                let bytes: &[u8] = name.as_bstr().as_ref();
                let name = regular_ref_name(bytes)?.ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "Git HEAD has an invalid symbolic target",
                    )
                })?;
                HeadState::Symbolic(name)
            }
            None => {
                let head = repository.find_reference("HEAD").map_err(|source| {
                    reference_corrupt_error("Git HEAD is unavailable or malformed", source)
                })?;
                let target = head.try_id().ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "Git HEAD has an invalid detached target",
                    )
                })?;
                HeadState::Detached(git_object_id_from_gix(&target.detach())?)
            }
        };
        GitRefState::new(regular_refs, head).map_err(|source| {
            Error::with_source(ErrorKind::CorruptData, "Git ref state is invalid", source)
        })
    }

    /// Returns all SHA-1 objects reachable from regular Git refs, sorted by ID.
    ///
    /// Symbolic refs are followed to their first object without peeling
    /// annotated tags. The walk includes commit parents and trees, tree entries,
    /// and annotated-tag targets. Pseudo-refs such as `HEAD` are excluded.
    ///
    /// The result is a point-in-time traversal only; it is not a ref transaction
    /// snapshot. Malformed or unavailable reachable objects fail closed. The
    /// repository hash was accepted as SHA-1 at open time; traversal rejects
    /// repositories with more than 1,000,000 reachable objects.
    pub fn reachable_object_ids(&self) -> Result<Vec<GitObjectId>> {
        let repository = self.inner.to_thread_local();
        let references = repository.references().map_err(reference_store_error)?;
        let iterator = references.all().map_err(|source| {
            reference_corrupt_error("Git references could not be enumerated", source)
        })?;
        let mut pending = Vec::new();
        let mut reachable = BTreeSet::new();

        for reference in iterator {
            let mut reference = reference.map_err(|source| {
                Error::with_boxed_source(
                    ErrorKind::CorruptData,
                    "Git reference could not be enumerated",
                    source,
                )
            })?;
            let bytes: &[u8] = reference.name().as_bstr().as_ref();
            if regular_ref_name(bytes)?.is_none() {
                continue;
            }
            let object_id = reference.follow_to_object().map_err(|source| {
                reference_corrupt_error("Git reference target is unavailable or malformed", source)
            })?;
            schedule_reachable_object(object_id.detach(), &mut pending, &mut reachable)?;
        }

        while let Some(object_id) = pending.pop() {
            let object = repository.find_object(object_id).map_err(|source| {
                reference_corrupt_error("reachable Git object is unavailable or malformed", source)
            })?;
            match object.kind {
                gix::objs::Kind::Blob => {}
                gix::objs::Kind::Commit => {
                    let commit = object.into_commit();
                    let tree_id = commit.tree_id().map_err(|source| {
                        reference_corrupt_error("reachable Git commit is malformed", source)
                    })?;
                    schedule_reachable_object(tree_id.detach(), &mut pending, &mut reachable)?;
                    for parent_id in commit.parent_ids() {
                        schedule_reachable_object(
                            parent_id.detach(),
                            &mut pending,
                            &mut reachable,
                        )?;
                    }
                }
                gix::objs::Kind::Tree => {
                    let tree = object.into_tree();
                    for entry in tree.iter() {
                        let entry = entry.map_err(|source| {
                            reference_corrupt_error("reachable Git tree is malformed", source)
                        })?;
                        schedule_reachable_object(
                            entry.id().detach(),
                            &mut pending,
                            &mut reachable,
                        )?;
                    }
                }
                gix::objs::Kind::Tag => {
                    let tag = object.into_tag();
                    let target_id = tag.target_id().map_err(|source| {
                        reference_corrupt_error("reachable Git tag is malformed", source)
                    })?;
                    schedule_reachable_object(target_id.detach(), &mut pending, &mut reachable)?;
                }
            }
        }

        Ok(reachable.into_iter().collect())
    }

    /// Reads one SHA-1 Git object's exact decompressed body within `maximum_bytes`.
    ///
    /// The returned [`GitObject`] carries its Git type and requested ID, but this
    /// method does not recompute or verify that ID. The caller must supply a
    /// bound appropriate for its memory budget; an object exceeding it is not
    /// decompressed. Pseudo-refs and object traversal are not involved.
    pub fn read_object(&self, id: GitObjectId, maximum_bytes: usize) -> Result<GitObject> {
        self.read_object_with_expected_body_bytes(id, maximum_bytes, None)
    }

    fn read_object_with_expected_body_bytes(
        &self,
        id: GitObjectId,
        maximum_bytes: usize,
        expected_body_bytes: Option<u64>,
    ) -> Result<GitObject> {
        let repository = self.inner.to_thread_local();
        if repository.object_hash() != gix::hash::Kind::Sha1 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Git repository uses an unsupported object hash",
            ));
        }
        let object_id = gix::hash::ObjectId::from(id.into_bytes());
        let header = repository
            .try_find_header(object_id)
            .map_err(|source| reference_corrupt_error("Git object could not be inspected", source))?
            .ok_or_else(|| Error::new(ErrorKind::NotFound, "Git object does not exist"))?;
        if header.size() > maximum_bytes as u64 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Git object exceeds the read limit",
            ));
        }
        if expected_body_bytes.is_some_and(|expected| expected != header.size()) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Git object changed while being read",
            ));
        }
        let object = repository
            .try_find_object(object_id)
            .map_err(|source| reference_corrupt_error("Git object could not be read", source))?
            .ok_or_else(|| Error::new(ErrorKind::NotFound, "Git object does not exist"))?;
        let actual_kind = object.kind;
        let data = object.detach().data;
        if actual_kind != header.kind() || data.len() as u64 != header.size() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Git object changed while being read",
            ));
        }
        Ok(GitObject::new(
            id,
            GitObjectKind::from_gix(actual_kind),
            data,
        ))
    }

    /// Returns one object's decompressed body size without allocating its body.
    ///
    /// The size is checked against `maximum_bytes` before it is returned. This
    /// is a point-in-time header read and does not verify the object identity.
    pub(crate) fn object_body_bytes(&self, id: GitObjectId, maximum_bytes: usize) -> Result<u64> {
        let repository = self.inner.to_thread_local();
        if repository.object_hash() != gix::hash::Kind::Sha1 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Git repository uses an unsupported object hash",
            ));
        }
        let object_id = gix::hash::ObjectId::from(id.into_bytes());
        let header = repository
            .try_find_header(object_id)
            .map_err(|source| reference_corrupt_error("Git object could not be inspected", source))?
            .ok_or_else(|| Error::new(ErrorKind::NotFound, "Git object does not exist"))?;
        if header.size() > maximum_bytes as u64 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Git object exceeds the read limit",
            ));
        }
        Ok(header.size())
    }

    /// Reads and verifies one SHA-1 Git object within `maximum_bytes`.
    ///
    /// This is equivalent to [`read_object`](Self::read_object) followed by
    /// [`GitObject::verify_id`]. The returned object is safe to use as a
    /// verified source object, subject to later graph and persistence checks.
    pub fn read_verified_object(&self, id: GitObjectId, maximum_bytes: usize) -> Result<GitObject> {
        let object = self.read_object(id, maximum_bytes)?;
        object.verify_id()?;
        Ok(object)
    }

    /// Reads and verifies an object only if its current header has `expected_body_bytes`.
    ///
    /// This closes the gap between a caller's bounded header planning and the
    /// worker's later allocation when a source repository changes concurrently.
    pub(crate) fn read_verified_object_with_expected_body_bytes(
        &self,
        id: GitObjectId,
        maximum_bytes: usize,
        expected_body_bytes: u64,
    ) -> Result<GitObject> {
        let object = self.read_object_with_expected_body_bytes(
            id,
            maximum_bytes,
            Some(expected_body_bytes),
        )?;
        object.verify_id()?;
        Ok(object)
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

fn regular_ref_name(bytes: &[u8]) -> Result<Option<RefName>> {
    if !bytes.starts_with(b"refs/") {
        return Ok(None);
    }
    RefName::from_bytes(bytes).map(Some).map_err(|source| {
        Error::with_source(
            ErrorKind::CorruptData,
            "Git reference name is invalid",
            source,
        )
    })
}

fn schedule_reachable_object(
    object_id: gix::hash::ObjectId,
    pending: &mut Vec<gix::hash::ObjectId>,
    reachable: &mut BTreeSet<GitObjectId>,
) -> Result<()> {
    let git_object_id = git_object_id_from_gix(&object_id)?;
    if reachable.contains(&git_object_id) {
        return Ok(());
    }
    if reachable.len() == MAX_REACHABLE_OBJECT_COUNT {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "Git repository has too many reachable objects",
        ));
    }
    reachable.insert(git_object_id);
    pending.push(object_id);
    Ok(())
}

fn git_object_id_from_gix(object_id: &gix::hash::ObjectId) -> Result<GitObjectId> {
    let bytes = object_id.as_slice();
    if bytes.len() != GitObjectId::BYTE_LENGTH {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "Git repository uses an unsupported object hash",
        ));
    }
    let mut digest = [0; GitObjectId::BYTE_LENGTH];
    digest.copy_from_slice(bytes);
    Ok(GitObjectId::from_bytes(digest))
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

    fn git_bytes(directory: &Path, arguments: &[&str]) -> Vec<u8> {
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
        output.stdout
    }

    fn git_object_ids(directory: &Path, arguments: &[&str]) -> Vec<GitObjectId> {
        let mut ids: Vec<GitObjectId> = git_stdout(directory, arguments)
            .lines()
            .map(|line| line.parse().expect("Git object ID"))
            .collect();
        ids.sort();
        ids.dedup();
        ids
    }

    fn commit(directory: &Path, message: &str) {
        run_git_in(
            directory,
            &[
                "-c",
                "user.name=Yeokcham Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "--message",
                message,
            ],
        );
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
    fn rejects_sha256_bare_and_worktree_repositories_at_open() {
        let temporary = TestDirectory::new();
        let bare = temporary.path().join("bare.git");
        let worktree = temporary.path().join("worktree");
        let bare_text = bare.to_str().expect("UTF-8 test path");
        let worktree_text = worktree.to_str().expect("UTF-8 test path");
        run_git(&["init", "--bare", "--object-format=sha256", bare_text]);
        run_git(&[
            "init",
            "--initial-branch=main",
            "--object-format=sha256",
            worktree_text,
        ]);

        for repository in [&bare, &worktree] {
            let error = GitRepository::open(repository)
                .err()
                .expect("SHA-256 repository must fail at open");

            assert_eq!(error.kind(), ErrorKind::Unsupported);
            assert_eq!(
                error.public_message(),
                "Git repository uses an unsupported object hash"
            );
            assert!(!format!("{error:?}").contains(&repository.display().to_string()));
        }
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

    #[test]
    fn reads_direct_regular_ref_targets_and_symbolic_or_detached_head() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        let object_id = git_stdout(&worktree, &["rev-parse", "HEAD"]);
        run_git_in(&worktree, &["update-ref", "refs/heads/alpha", &object_id]);
        run_git_in(&worktree, &["update-ref", "refs/tags/v1.0", &object_id]);
        run_git_in(
            &worktree,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/heads/main",
            ],
        );

        let repository = GitRepository::open(&worktree).expect("open repository");
        let state = repository.ref_state().expect("read ref state");
        let id: GitObjectId = object_id.parse().expect("object ID");
        assert_eq!(
            state
                .regular_refs()
                .get(&RefName::from_bytes(b"refs/heads/alpha").expect("ref name")),
            Some(&id)
        );
        assert_eq!(
            state
                .regular_refs()
                .get(&RefName::from_bytes(b"refs/remotes/origin/HEAD").expect("ref name")),
            Some(&id)
        );
        assert_eq!(
            state.head(),
            &HeadState::Symbolic(RefName::from_bytes(b"refs/heads/main").expect("ref name"))
        );

        run_git_in(&worktree, &["checkout", "--detach"]);
        let detached = GitRepository::open(&worktree)
            .expect("open detached repository")
            .ref_state()
            .expect("read detached state");
        assert_eq!(detached.head(), &HeadState::Detached(id));
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

    #[test]
    fn traverses_reachable_commits_trees_blobs_and_tags() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::create_dir(worktree.join("nested")).expect("create nested directory");
        fs::write(worktree.join("root.txt"), b"first version\n").expect("write root file");
        fs::write(worktree.join("nested/file.txt"), b"nested version\n")
            .expect("write nested file");
        run_git_in(&worktree, &["add", "root.txt", "nested/file.txt"]);
        commit(&worktree, "first contents");
        fs::write(worktree.join("root.txt"), b"second version\n").expect("update root file");
        run_git_in(&worktree, &["add", "root.txt"]);
        commit(&worktree, "second contents");
        run_git_in(
            &worktree,
            &[
                "-c",
                "user.name=Yeokcham Test",
                "-c",
                "user.email=test@example.invalid",
                "tag",
                "--annotate",
                "v1.0",
                "--message=version one",
            ],
        );

        let tree_id = git_stdout(&worktree, &["rev-parse", "HEAD^{tree}"]);
        let blob_id = git_stdout(&worktree, &["rev-parse", "HEAD:root.txt"]);
        let tag_id = git_stdout(&worktree, &["rev-parse", "refs/tags/v1.0^{tag}"]);
        run_git_in(&worktree, &["update-ref", "refs/custom/tree", &tree_id]);
        run_git_in(&worktree, &["update-ref", "refs/custom/blob", &blob_id]);
        run_git_in(
            &worktree,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/heads/main",
            ],
        );
        fs::write(worktree.join("unreachable.txt"), b"not reachable\n")
            .expect("write unreachable file");
        let unreachable_id = git_stdout(&worktree, &["hash-object", "-w", "unreachable.txt"]);

        let actual = GitRepository::open(&worktree)
            .expect("open repository")
            .reachable_object_ids()
            .expect("traverse reachable objects");
        let expected = git_object_ids(
            &worktree,
            &["rev-list", "--objects", "--no-object-names", "--all"],
        );

        assert_eq!(actual, expected);
        assert!(actual.contains(&tag_id.parse().expect("tag object ID")));
        assert!(actual.contains(&tree_id.parse().expect("tree object ID")));
        assert!(actual.contains(&blob_id.parse().expect("blob object ID")));
        assert!(!actual.contains(&unreachable_id.parse().expect("unreachable object ID")));
    }

    #[test]
    fn rejects_refs_to_unavailable_reachable_objects_without_disclosing_ids() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        let unavailable_id = "1111111111111111111111111111111111111111";
        fs::write(
            worktree.join(".git/refs/heads/unavailable"),
            format!("{unavailable_id}\n"),
        )
        .expect("write dangling ref");

        let error = GitRepository::open(&worktree)
            .expect("open repository")
            .reachable_object_ids()
            .expect_err("unavailable ref target must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains(unavailable_id));
    }

    #[test]
    fn reads_exact_object_bodies_and_types_from_packed_storage() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::write(worktree.join("body.bin"), b"\0body\xff\n").expect("write blob body");
        run_git_in(&worktree, &["add", "body.bin"]);
        commit(&worktree, "add binary body");
        run_git_in(
            &worktree,
            &[
                "-c",
                "user.name=Yeokcham Test",
                "-c",
                "user.email=test@example.invalid",
                "tag",
                "--annotate",
                "v1.0",
                "--message=version one",
            ],
        );
        run_git_in(&worktree, &["gc", "--prune=now"]);

        let cases = [
            (
                git_stdout(&worktree, &["rev-parse", "HEAD:body.bin"]),
                "blob",
                GitObjectKind::Blob,
            ),
            (
                git_stdout(&worktree, &["rev-parse", "HEAD^{tree}"]),
                "tree",
                GitObjectKind::Tree,
            ),
            (
                git_stdout(&worktree, &["rev-parse", "HEAD"]),
                "commit",
                GitObjectKind::Commit,
            ),
            (
                git_stdout(&worktree, &["rev-parse", "refs/tags/v1.0^{tag}"]),
                "tag",
                GitObjectKind::Tag,
            ),
        ];
        let repository = GitRepository::open(&worktree).expect("open repository");

        for (id_text, kind_text, expected_kind) in cases {
            let id: GitObjectId = id_text.parse().expect("object ID");
            let expected = git_bytes(&worktree, &["cat-file", kind_text, &id_text]);
            let object = repository
                .read_verified_object(id, expected.len())
                .expect("read and verify packed object");

            assert_eq!(object.id(), id);
            assert_eq!(object.kind(), expected_kind);
            assert_eq!(object.data(), expected);
        }
    }

    #[test]
    fn rejects_a_worker_read_when_its_planned_body_size_changes() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::write(worktree.join("body.bin"), b"bounded body").expect("write blob body");
        let id_text = git_stdout(&worktree, &["hash-object", "-w", "body.bin"]);
        let id: GitObjectId = id_text.parse().expect("object ID");
        let repository = GitRepository::open(&worktree).expect("open repository");
        let body_bytes = repository
            .object_body_bytes(id, 1024)
            .expect("inspect body bytes");

        let object = repository
            .read_verified_object_with_expected_body_bytes(id, 1024, body_bytes)
            .expect("planned body size");
        assert_eq!(
            object.data().len(),
            usize::try_from(body_bytes).expect("body size")
        );
        let error = repository
            .read_verified_object_with_expected_body_bytes(id, 1024, body_bytes + 1)
            .expect_err("different planned body size must fail");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains(&id_text));
    }

    #[test]
    fn rejects_read_limits_and_missing_objects_without_disclosing_ids() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::write(worktree.join("body.bin"), b"bounded body").expect("write blob body");
        let id_text = git_stdout(&worktree, &["hash-object", "-w", "body.bin"]);
        let id: GitObjectId = id_text.parse().expect("object ID");
        let repository = GitRepository::open(&worktree).expect("open repository");

        let limit_error = repository
            .read_object(id, 1)
            .expect_err("limit must reject object");
        let missing_id = "1111111111111111111111111111111111111111";
        let missing_error = repository
            .read_object(missing_id.parse().expect("object ID"), 1024)
            .expect_err("missing object must fail");

        assert_eq!(limit_error.kind(), ErrorKind::Unsupported);
        assert_eq!(missing_error.kind(), ErrorKind::NotFound);
        assert!(!limit_error.to_string().contains(&id_text));
        assert!(!missing_error.to_string().contains(missing_id));
    }

    #[test]
    fn rejects_loose_objects_whose_bytes_do_not_match_the_requested_id() {
        let temporary = TestDirectory::new();
        let worktree = initialize_committed_worktree(&temporary);
        fs::write(worktree.join("expected.bin"), b"expected bytes").expect("write expected body");
        fs::write(worktree.join("altered.bin"), b"altered bytes").expect("write altered body");
        let expected_id = git_stdout(&worktree, &["hash-object", "-w", "expected.bin"]);
        let altered_id = git_stdout(&worktree, &["hash-object", "-w", "altered.bin"]);
        let expected_path = worktree
            .join(".git/objects")
            .join(&expected_id[..2])
            .join(&expected_id[2..]);
        let altered_path = worktree
            .join(".git/objects")
            .join(&altered_id[..2])
            .join(&altered_id[2..]);
        fs::remove_file(&expected_path).expect("remove expected loose object");
        fs::copy(altered_path, expected_path).expect("overwrite loose object");

        let error = GitRepository::open(&worktree)
            .expect("open repository")
            .read_verified_object(expected_id.parse().expect("object ID"), 1024)
            .expect_err("mismatched loose object must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains(&expected_id));
        assert!(!error.to_string().contains("altered bytes"));
    }
}
