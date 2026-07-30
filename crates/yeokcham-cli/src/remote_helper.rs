use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
    thread,
};

use uuid::Uuid;
use yeokcham_core::{
    DeviceId, Error, ErrorKind, GitImportLimits, GitRefState, GitRepository, LocalRepository,
    RefEvent, Result,
};

mod remote_helper_protocol;
mod telemetry;

use remote_helper_protocol::{RemoteHelperCommand, parse_command, read_command_line};

const PACK_CACHE_DIRECTORY: &str = "cache/packs";
const PACK_CACHE_STAGING_SUFFIX: &str = ".partial";
const MAXIMUM_RECEIVE_PACK_RESPONSE_BYTES: u64 = 128 * 1024 * 1024;

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
            RemoteHelperCommand::ConnectReceivePack => {
                tracing::debug!(
                    event = "remote_helper_command",
                    command = "connect_receive_pack"
                );
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
                proxy_receive_pack(&repository_path, output)?;
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

    fn temporary_root(&self) -> Result<&Path> {
        self.temporary_root.as_deref().ok_or_else(|| {
            Error::new(
                ErrorKind::Internal,
                "receive-pack staging repository is not temporary",
            )
        })
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
    let mut command = git_command();
    command.arg("--git-dir").arg(repository);
    command
}

fn git_command() -> ProcessCommand {
    let mut command = ProcessCommand::new("git");
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
    let status = git_command()
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

struct ReceivePackStaging {
    export: ExportedRepository,
    hook_directory: PathBuf,
    expected_state: GitRefState,
}

impl ReceivePackStaging {
    fn create(repository_path: &Path) -> Result<Self> {
        let repository = LocalRepository::open(repository_path)?;
        let limits = GitImportLimits::initial()?;
        repository.verify(limits.verification_limits()?)?;
        let export = ExportedRepository::create_temporary(&repository, limits)?;
        let hook_directory = install_immutable_tag_hook(export.repository_path())?;
        let expected_state = GitRepository::open(export.repository_path())?.ref_state()?;
        Ok(Self {
            export,
            hook_directory,
            expected_state,
        })
    }

    fn response_path(&self) -> Result<PathBuf> {
        Ok(self.export.temporary_root()?.join("receive-pack-response"))
    }

    fn synchronize(&self, repository_path: &Path) -> Result<()> {
        let repository = LocalRepository::open(repository_path)?;
        let limits = GitImportLimits::initial()?;
        let source = GitRepository::open(self.export.repository_path())?;
        let device_id = DeviceId::from_bytes(*repository.id().as_bytes())?;
        repository.sync_git_repository_from_expected_state(
            &source,
            &self.expected_state,
            device_id,
            limits,
        )?;
        Ok(())
    }
}

fn install_immutable_tag_hook(repository: &Path) -> Result<PathBuf> {
    let hooks = repository.join("hooks");
    let metadata = fs::symlink_metadata(&hooks).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack hook directory could not be inspected",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "receive-pack hook directory is not a directory",
        ));
    }
    let hook = hooks.join("update");
    let bytes = b"#!/bin/sh\ncase \"$1\" in\nrefs/tags/*)\n  test \"$2\" = 0000000000000000000000000000000000000000 || exit 1\n  ;;\nesac\nexit 0\n";
    fs::write(&hook, bytes).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack hook could not be written",
            error,
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack hook permissions could not be set",
                error,
            )
        })?;
    }
    Ok(hooks)
}

fn git_path_configuration(name: &str, path: &Path) -> OsString {
    let mut configuration = OsString::from(name);
    configuration.push("=");
    configuration.push(path.as_os_str());
    configuration
}

fn proxy_receive_pack(repository_path: &Path, output: &mut impl Write) -> Result<()> {
    let staging = ReceivePackStaging::create(repository_path)?;
    let response_path = staging.response_path()?;
    let response = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&response_path)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack response file could not be created",
                error,
            )
        })?;
    let mut child = git_command()
        .arg("-c")
        .arg("receive.denyNonFastForwards=true")
        .arg("-c")
        .arg("receive.denyDeletes=false")
        .arg("-c")
        .arg(git_path_configuration(
            "core.hooksPath",
            &staging.hook_directory,
        ))
        .arg("receive-pack")
        .arg(staging.export.repository_path())
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Git receive-pack could not be started",
                error,
            )
        })?;
    let mut child_output = child.stdout.take().ok_or_else(|| {
        Error::new(
            ErrorKind::Internal,
            "Git receive-pack output could not be captured",
        )
    })?;
    if let Err(error) = relay_receive_pack_advertisement(&mut child_output, output) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    let collector = thread::spawn(move || collect_receive_pack_response(child_output, response));
    let status = child.wait().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "Git receive-pack could not be awaited",
            error,
        )
    })?;
    collector.join().map_err(|_| {
        Error::new(
            ErrorKind::Internal,
            "receive-pack response collector unexpectedly stopped",
        )
    })??;
    if status.success() {
        staging.synchronize(repository_path)?;
    }
    replay_receive_pack_response(&response_path, output)
}

fn relay_receive_pack_advertisement(input: &mut impl Read, output: &mut impl Write) -> Result<()> {
    let mut total = 0_u64;
    loop {
        let mut header = [0_u8; 4];
        input.read_exact(&mut header).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack advertisement could not be read",
                error,
            )
        })?;
        let length = receive_pack_packet_length(&header)?;
        total = total
            .checked_add(u64::try_from(length.max(4)).map_err(|_| {
                Error::new(
                    ErrorKind::Unsupported,
                    "receive-pack packet length exceeds this platform",
                )
            })?)
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "receive-pack advertisement length overflows",
                )
            })?;
        if total > MAXIMUM_RECEIVE_PACK_RESPONSE_BYTES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "receive-pack advertisement exceeds the byte limit",
            ));
        }
        output.write_all(&header).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack advertisement could not be relayed",
                error,
            )
        })?;
        if length == 0 {
            return output.flush().map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "receive-pack advertisement could not be synchronized",
                    error,
                )
            });
        }
        if length < 4 {
            continue;
        }
        let payload_length = length.checked_sub(4).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "receive-pack packet has an invalid length",
            )
        })?;
        let mut payload = vec![0_u8; payload_length];
        input.read_exact(&mut payload).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack advertisement is truncated",
                error,
            )
        })?;
        output.write_all(&payload).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack advertisement could not be relayed",
                error,
            )
        })?;
    }
}

fn receive_pack_packet_length(header: &[u8; 4]) -> Result<usize> {
    let mut length = 0_usize;
    for byte in header {
        let nibble = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            b'A'..=b'F' => byte - b'A' + 10,
            _ => {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "receive-pack packet length is not hexadecimal",
                ));
            }
        };
        length = length
            .checked_mul(16)
            .and_then(|value| value.checked_add(usize::from(nibble)))
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "receive-pack packet length overflows",
                )
            })?;
    }
    if matches!(length, 0..=2) || length >= 4 {
        Ok(length)
    } else {
        Err(Error::new(
            ErrorKind::CorruptData,
            "receive-pack packet has an invalid length",
        ))
    }
}

fn collect_receive_pack_response(mut input: impl Read, mut output: fs::File) -> Result<()> {
    let mut total = 0_u64;
    let mut exceeded_limit = false;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let read = input.read(&mut buffer).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "receive-pack response could not be read",
                error,
            )
        })?;
        if read == 0 {
            break;
        }
        let allowed = MAXIMUM_RECEIVE_PACK_RESPONSE_BYTES.saturating_sub(total);
        let written = usize::try_from(allowed).unwrap_or(usize::MAX).min(read);
        if written > 0 {
            output.write_all(&buffer[..written]).map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "receive-pack response could not be recorded",
                    error,
                )
            })?;
            total = total
                .checked_add(u64::try_from(written).map_err(|_| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "receive-pack response length exceeds this platform",
                    )
                })?)
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "receive-pack response length overflows",
                    )
                })?;
        }
        exceeded_limit |= written < read;
    }
    output.sync_all().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack response could not be synchronized",
            error,
        )
    })?;
    if exceeded_limit {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "receive-pack response exceeds the byte limit",
        ));
    }
    Ok(())
}

fn replay_receive_pack_response(path: &Path, output: &mut impl Write) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack response file could not be inspected",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "receive-pack response is not a regular file",
        ));
    }
    if metadata.len() > MAXIMUM_RECEIVE_PACK_RESPONSE_BYTES {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "receive-pack response exceeds the byte limit",
        ));
    }
    let mut response = fs::File::open(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack response file could not be opened",
            error,
        )
    })?;
    io::copy(&mut response, output).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack response could not be relayed",
            error,
        )
    })?;
    output.flush().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "receive-pack response could not be synchronized",
            error,
        )
    })
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

    #[test]
    fn validates_receive_pack_packet_lengths() {
        assert_eq!(receive_pack_packet_length(b"0000").expect("flush"), 0);
        assert_eq!(receive_pack_packet_length(b"0001").expect("delimiter"), 1);
        assert_eq!(
            receive_pack_packet_length(b"0002").expect("response end"),
            2
        );
        assert_eq!(
            receive_pack_packet_length(b"0004").expect("empty packet"),
            4
        );
        assert_eq!(receive_pack_packet_length(b"0010").expect("packet"), 16);
        assert_eq!(
            receive_pack_packet_length(b"0003")
                .expect_err("reserved packet length")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            receive_pack_packet_length(b"00g0")
                .expect_err("non-hexadecimal packet length")
                .kind(),
            ErrorKind::CorruptData
        );
    }
}
