use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
};

use uuid::Uuid;
use yeokcham_core::{
    Error, ErrorKind, GitImportLimits, GitRefState, GitRepository, LocalRepository, RefEvent,
    Result,
};

mod remote_helper_protocol;
mod telemetry;

use remote_helper_protocol::{RemoteHelperCommand, parse_command, read_command_line};

const PACK_CACHE_DIRECTORY: &str = "cache/packs";
const PACK_CACHE_STAGING_SUFFIX: &str = ".partial";

fn main() -> ExitCode {
    if let Err(error) = telemetry::init() {
        eprintln!("error[{}]: {error}", error.code());
        return ExitCode::FAILURE;
    }
    let arguments: Vec<OsString> = env::args_os().skip(1).collect();
    let result = run(
        &arguments,
        &mut io::stdin().lock(),
        &mut io::stdout().lock(),
    );
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error[{}]: {error}", error.code());
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: &[OsString], input: &mut impl Read, output: &mut impl Write) -> Result<()> {
    let repository_path = repository_path(arguments)?;
    while let Some(line) = read_command_line(input)? {
        match parse_command(&line)? {
            RemoteHelperCommand::Capabilities => {
                tracing::debug!(event = "remote_helper_command", command = "capabilities");
                output.write_all(b"connect\n\n").map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "remote-helper response could not be written",
                        error,
                    )
                })?;
                output.flush().map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "remote-helper response could not be synchronized",
                        error,
                    )
                })?;
            }
            RemoteHelperCommand::ConnectUploadPack => {
                tracing::debug!(
                    event = "remote_helper_command",
                    command = "connect_upload_pack"
                );
                let export = ExportedRepository::create(&repository_path)?;
                output.write_all(b"\n").map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "remote-helper response could not be written",
                        error,
                    )
                })?;
                output.flush().map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "remote-helper response could not be synchronized",
                        error,
                    )
                })?;
                proxy_upload_pack(export.repository_path())?;
                return Ok(());
            }
            RemoteHelperCommand::End => return Ok(()),
        }
    }
    Ok(())
}

fn repository_path(arguments: &[OsString]) -> Result<PathBuf> {
    match arguments {
        [path] => Ok(PathBuf::from(path)),
        [_, path] => Ok(PathBuf::from(path)),
        _ => Err(Error::new(
            ErrorKind::InvalidInput,
            "git-remote-yeokcham requires a repository location",
        )),
    }
}

struct ExportedRepository {
    temporary_root: Option<PathBuf>,
    repository: PathBuf,
}

impl ExportedRepository {
    fn create(source_path: &Path) -> Result<Self> {
        let source = LocalRepository::open(source_path)?;
        let limits = GitImportLimits::initial()?;
        source.verify(limits.verification_limits()?)?;
        if let Some(state) = source.resolve_ref_state(limits.ref_snapshot_limits())? {
            let cache = PackCache::new(source.path(), state);
            let repository = cache.open_or_build(&source, limits)?;
            return Ok(Self {
                temporary_root: None,
                repository,
            });
        }
        Self::create_temporary(&source, limits)
    }

    fn create_temporary(source: &LocalRepository, limits: GitImportLimits) -> Result<Self> {
        let root = create_private_temporary_directory()?;
        let repository = root.join("repository.git");
        let result = source.export_loose_objects(&repository, limits.export_limits()?);
        match result {
            Ok(_) => Ok(Self {
                temporary_root: Some(root),
                repository,
            }),
            Err(error) => {
                let _ = fs::remove_dir_all(&root);
                Err(error)
            }
        }
    }

    fn repository_path(&self) -> &Path {
        &self.repository
    }
}

impl Drop for ExportedRepository {
    fn drop(&mut self) {
        if let Some(root) = &self.temporary_root {
            let _ = fs::remove_dir_all(root);
        }
    }
}

struct PackCache {
    directory: PathBuf,
    entry: PathBuf,
    state: GitRefState,
}

impl PackCache {
    fn new(repository_root: &Path, state: GitRefState) -> Self {
        let directory = repository_root.join(PACK_CACHE_DIRECTORY);
        let entry = directory.join(ref_state_cache_name(&state));
        Self {
            directory,
            entry,
            state,
        }
    }

    fn open_or_build(&self, source: &LocalRepository, limits: GitImportLimits) -> Result<PathBuf> {
        ensure_pack_cache_directory(&self.directory)?;
        for _ in 0..2 {
            if self.is_valid(&self.entry)? {
                tracing::debug!(event = "remote_helper_pack_cache", outcome = "hit");
                return Ok(self.entry.clone());
            }
            self.discard_entry()?;
            let staging = self.create_staging_path()?;
            let result = (|| {
                source.export_loose_objects(&staging, limits.export_limits()?)?;
                repack_repository(&staging)?;
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
                    tracing::debug!(event = "remote_helper_pack_cache", outcome = "miss");
                    return Ok(self.entry.clone());
                }
                Ok(false) => {
                    let _ = remove_cache_path(&staging);
                }
                Err(error) => {
                    let _ = remove_cache_path(&staging);
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

    fn discard_entry(&self) -> Result<()> {
        remove_cache_path(&self.entry)
    }

    fn create_staging_path(&self) -> Result<PathBuf> {
        for _ in 0..16 {
            let path = self.directory.join(format!(
                ".{}-{}{}",
                ref_state_cache_name(&self.state),
                Uuid::new_v4(),
                PACK_CACHE_STAGING_SUFFIX,
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

fn ensure_pack_cache_directory(directory: &Path) -> Result<()> {
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
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "pack cache path is not a directory",
                ));
            }
            Ok(())
        }
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

fn repack_repository(repository: &Path) -> Result<()> {
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

fn git_repository_command(repository: &Path) -> ProcessCommand {
    let mut command = ProcessCommand::new("git");
    for variable in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_GLOBAL",
    ] {
        command.env_remove(variable);
    }
    command.arg("--git-dir").arg(repository);
    command
}

fn remove_cache_path(path: &Path) -> Result<()> {
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

fn create_private_temporary_directory() -> Result<PathBuf> {
    let parent = env::temp_dir();
    for _ in 0..16 {
        let path = parent.join(format!("yeokcham-remote-helper-{}", Uuid::new_v4()));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;

            builder.mode(0o700);
        }
        match builder.create(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "remote-helper temporary directory could not be created",
                    error,
                ));
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "remote-helper temporary directory could not be allocated",
    ))
}

fn proxy_upload_pack(repository: &Path) -> Result<()> {
    let status = ProcessCommand::new("git")
        .arg("upload-pack")
        .arg(repository)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| {
            Error::with_source(ErrorKind::Io, "Git upload-pack could not be started", error)
        })?;
    if status.success() {
        Ok(())
    } else {
        Err(Error::new(
            ErrorKind::Io,
            "Git upload-pack did not complete",
        ))
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn writes_only_connect_capability() {
        let mut input = Cursor::new(b"capabilities\n\n".to_vec());
        let mut output = Vec::new();

        run(&[OsString::from("repository")], &mut input, &mut output).expect("run protocol");

        assert_eq!(output, b"connect\n\n");
    }

    #[test]
    fn retains_only_the_remote_location_argument() {
        assert_eq!(
            repository_path(&[OsString::from("origin"), OsString::from("repository")])
                .expect("configured remote"),
            PathBuf::from("repository")
        );
        assert_eq!(
            repository_path(&[OsString::from("repository")]).expect("direct remote"),
            PathBuf::from("repository")
        );
    }
}
