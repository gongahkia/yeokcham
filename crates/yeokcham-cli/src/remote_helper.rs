use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
};

use uuid::Uuid;
use yeokcham_core::{Error, ErrorKind, GitImportLimits, LocalRepository, Result};

mod remote_helper_protocol;
mod telemetry;

use remote_helper_protocol::{RemoteHelperCommand, parse_command, read_command_line};

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
    root: PathBuf,
    repository: PathBuf,
}

impl ExportedRepository {
    fn create(source: &Path) -> Result<Self> {
        let root = create_private_temporary_directory()?;
        let repository = root.join("repository.git");
        let result = (|| {
            let source = LocalRepository::open(source)?;
            let limits = GitImportLimits::initial()?;
            source.export_loose_objects(&repository, limits.export_limits()?)
        })();
        match result {
            Ok(_) => Ok(Self { root, repository }),
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
        let _ = fs::remove_dir_all(&self.root);
    }
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
