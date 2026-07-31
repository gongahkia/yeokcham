use std::{
    fs, io,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use uuid::Uuid;

use crate::{
    Error, ErrorKind, GitImportLimits, GitRefState, GitRepository, LocalRepository, RefEvent,
    Result,
};

const DIRECTORY: &str = "cache/packs";
const STAGING_SUFFIX: &str = ".partial";
const ACCESS_FILE: &str = ".yeokcham-last-used";

impl LocalRepository {
    /// builds the disposable helper snapshot-pack cache for one acknowledged ref state.
    pub fn prewarm_snapshot_pack_cache(
        &self,
        state: &GitRefState,
        limits: GitImportLimits,
    ) -> Result<()> {
        let cache = SnapshotPackCache::new(self.path(), state);
        cache.prewarm(self, limits)
    }
}

struct SnapshotPackCache {
    directory: PathBuf,
    entry: PathBuf,
    state: GitRefState,
}

impl SnapshotPackCache {
    fn new(repository_root: &Path, state: &GitRefState) -> Self {
        let directory = repository_root.join(DIRECTORY);
        let entry = directory.join(ref_state_cache_name(state));
        Self {
            directory,
            entry,
            state: state.clone(),
        }
    }

    fn prewarm(&self, source: &LocalRepository, limits: GitImportLimits) -> Result<()> {
        ensure_directory(&self.directory)?;
        source.verify(limits.verification_limits()?)?;
        for _ in 0..2 {
            if self.is_valid(&self.entry)? {
                record_access(&self.entry)?;
                return Ok(());
            }
            remove_path(&self.entry)?;
            let staging = self.staging_path()?;
            let result = (|| {
                source.export_loose_objects(&staging, limits.export_limits()?)?;
                repack(&staging)?;
                if !self.is_valid(&staging)? {
                    return Err(Error::new(
                        ErrorKind::Conflict,
                        "repository ref state changed while a pack cache was built",
                    ));
                }
                match fs::rename(&staging, &self.entry) {
                    Ok(()) => {
                        sync_directory(&self.directory)?;
                        Ok(true)
                    }
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
                    Err(error) => Err(Error::with_source(
                        ErrorKind::Io,
                        "pack cache could not be published",
                        error,
                    )),
                }
            })();
            match result {
                Ok(true) => {
                    record_access(&self.entry)?;
                    return Ok(());
                }
                Ok(false) => remove_path(&staging)?,
                Err(error) => {
                    let _ = remove_path(&staging);
                    return Err(error);
                }
            }
        }
        Err(Error::new(
            ErrorKind::Conflict,
            "pack cache could not be published concurrently",
        ))
    }

    fn is_valid(&self, path: &Path) -> Result<bool> {
        let metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "pack cache entry could not be inspected",
                    error,
                ));
            }
        };
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Ok(false);
        }
        let repository = match GitRepository::open(path) {
            Ok(repository) => repository,
            Err(error) if error.kind() == ErrorKind::Io => return Err(error),
            Err(_) => return Ok(false),
        };
        let state = match repository.ref_state() {
            Ok(state) => state,
            Err(error) if error.kind() == ErrorKind::Io => return Err(error),
            Err(_) => return Ok(false),
        };
        if state != self.state {
            return Ok(false);
        }
        verify_packed_repository(path)
    }

    fn staging_path(&self) -> Result<PathBuf> {
        for _ in 0..16 {
            let path = self.directory.join(format!(
                ".{}-{}{}",
                ref_state_cache_name(&self.state),
                Uuid::new_v4(),
                STAGING_SUFFIX,
            ));
            match fs::symlink_metadata(&path) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(path),
                Ok(_) => continue,
                Err(error) => {
                    return Err(Error::with_source(
                        ErrorKind::Io,
                        "pack cache staging path could not be inspected",
                        error,
                    ));
                }
            }
        }
        Err(Error::new(
            ErrorKind::Conflict,
            "pack cache staging path could not be allocated",
        ))
    }
}

fn ref_state_cache_name(state: &GitRefState) -> String {
    use std::fmt::Write as _;

    let mut name = String::with_capacity(64);
    for byte in RefEvent::state_id(state) {
        write!(&mut name, "{byte:02x}").expect("writing a String cannot fail");
    }
    name
}

fn ensure_directory(directory: &Path) -> Result<()> {
    let cache = directory.parent().ok_or_else(|| {
        Error::new(
            ErrorKind::Internal,
            "pack cache directory has no repository cache parent",
        )
    })?;
    ensure_private_directory(cache)?;
    ensure_private_directory(directory)
}

fn ensure_private_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache path is not a directory",
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;

                builder.mode(0o700);
            }
            builder.create(path).map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "pack cache directory could not be created",
                    error,
                )
            })
        }
        Err(error) => Err(Error::with_source(
            ErrorKind::Io,
            "pack cache directory could not be inspected",
            error,
        )),
    }
}

fn repack(repository: &Path) -> Result<()> {
    for arguments in [
        ["repack", "-a", "-d", "--no-write-bitmap-index"].as_slice(),
        ["prune-packed"].as_slice(),
    ] {
        let status = git_repository_command(repository)
            .args(arguments)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "Git pack cache command could not be started",
                    error,
                )
            })?;
        if !status.success() {
            return Err(Error::new(
                ErrorKind::Io,
                "Git pack cache command did not complete",
            ));
        }
    }
    Ok(())
}

fn verify_packed_repository(repository: &Path) -> Result<bool> {
    let status = git_repository_command(repository)
        .args(["fsck", "--full", "--strict"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Git pack cache verification could not be started",
                error,
            )
        })?;
    Ok(status.success())
}

fn record_access(entry: &Path) -> Result<()> {
    let access = entry.join(ACCESS_FILE);
    match fs::symlink_metadata(&access) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "pack cache access record is invalid",
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(Error::with_source(
                ErrorKind::Io,
                "pack cache access record could not be inspected",
                error,
            ));
        }
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Error::new(ErrorKind::Internal, "system clock is before Unix epoch"))?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(access)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache access record could not be written",
                error,
            )
        })?;
    use std::io::Write as _;
    writeln!(file, "{} {}", now.as_secs(), now.subsec_nanos()).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache access record could not be written",
            error,
        )
    })?;
    file.sync_all().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache access record could not be synchronized",
            error,
        )
    })?;
    sync_directory(entry)
}

fn git_repository_command(repository: &Path) -> Command {
    let mut command = Command::new("git");
    for variable in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_COUNT",
    ] {
        command.env_remove(variable);
    }
    command.arg("--git-dir").arg(repository);
    command
}

fn remove_path(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(Error::with_source(
                ErrorKind::Io,
                "pack cache entry could not be inspected",
                error,
            ));
        }
    };
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache entry could not be removed",
                error,
            )
        })
    } else {
        fs::remove_file(path).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache entry could not be removed",
                error,
            )
        })
    }
}

fn sync_directory(path: &Path) -> Result<()> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache directory could not be synchronized",
                error,
            )
        })
}
