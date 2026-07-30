use std::{
    env,
    ffi::{OsStr, OsString},
    path::PathBuf,
    process::ExitCode,
};

use yeokcham_core::{
    Error, ErrorKind, GitImportLimits, GitObjectId, GitRepository, LocalRepository, Result,
};

mod telemetry;

enum Command {
    Help,
    Init {
        source: PathBuf,
        destination: PathBuf,
        chunked_blob_minimum_bytes: Option<usize>,
    },
    Verify {
        repository: PathBuf,
    },
    ExportGit {
        repository: PathBuf,
        destination: PathBuf,
    },
    InspectObject {
        repository: PathBuf,
        id: GitObjectId,
    },
    InspectStorage {
        repository: PathBuf,
    },
}

fn main() -> ExitCode {
    if let Err(error) = telemetry::init() {
        eprintln!("error[{}]: {error}", error.code());
        return ExitCode::FAILURE;
    }
    tracing::debug!(event = "startup", "yeokcham initialized");
    match parse_command(env::args_os().skip(1).collect()).and_then(|command| match command {
        Command::Help => {
            print_usage();
            Ok(())
        }
        Command::Init {
            source,
            destination,
            chunked_blob_minimum_bytes,
        } => init(source, destination, chunked_blob_minimum_bytes),
        Command::Verify { repository } => verify(repository),
        Command::ExportGit {
            repository,
            destination,
        } => export_git(repository, destination),
        Command::InspectObject { repository, id } => inspect_object(repository, id),
        Command::InspectStorage { repository } => inspect_storage(repository),
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error[{}]: {error}", error.code());
            ExitCode::FAILURE
        }
    }
}

fn parse_command(arguments: Vec<OsString>) -> Result<Command> {
    let Some(command) = arguments.first().and_then(|argument| argument.to_str()) else {
        return Err(usage_error());
    };
    match command {
        "help" | "--help" | "-h" if arguments.len() == 1 => Ok(Command::Help),
        "init" => parse_init(&arguments),
        "verify" if arguments.len() == 2 => Ok(Command::Verify {
            repository: PathBuf::from(&arguments[1]),
        }),
        "export-git" if arguments.len() == 3 => Ok(Command::ExportGit {
            repository: PathBuf::from(&arguments[1]),
            destination: PathBuf::from(&arguments[2]),
        }),
        "inspect" if arguments.len() == 4 && arguments[1].as_os_str() == OsStr::new("object") => {
            let id = arguments[3]
                .to_str()
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| Error::new(ErrorKind::InvalidInput, "Git object ID is invalid"))?;
            Ok(Command::InspectObject {
                repository: PathBuf::from(&arguments[2]),
                id,
            })
        }
        "inspect" if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("storage") => {
            Ok(Command::InspectStorage {
                repository: PathBuf::from(&arguments[2]),
            })
        }
        _ => Err(usage_error()),
    }
}

fn parse_init(arguments: &[OsString]) -> Result<Command> {
    if arguments.len() == 4 && arguments[1].as_os_str() == OsStr::new("--from-git") {
        return Ok(Command::Init {
            source: PathBuf::from(&arguments[2]),
            destination: PathBuf::from(&arguments[3]),
            chunked_blob_minimum_bytes: None,
        });
    }
    if arguments.len() == 6
        && arguments[1].as_os_str() == OsStr::new("--from-git")
        && arguments[4].as_os_str() == OsStr::new("--chunked-blob-minimum")
    {
        let minimum = arguments[5]
            .to_str()
            .ok_or_else(usage_error)?
            .parse()
            .map_err(|_| Error::new(ErrorKind::InvalidInput, "chunked-blob minimum is invalid"))?;
        return Ok(Command::Init {
            source: PathBuf::from(&arguments[2]),
            destination: PathBuf::from(&arguments[3]),
            chunked_blob_minimum_bytes: Some(minimum),
        });
    }
    Err(usage_error())
}

fn init(
    source: PathBuf,
    destination: PathBuf,
    chunked_blob_minimum_bytes: Option<usize>,
) -> Result<()> {
    let source = GitRepository::open(source)?;
    let repository = LocalRepository::create(destination)?;
    let limits = GitImportLimits::initial()?;
    let limits = match chunked_blob_minimum_bytes {
        Some(minimum) => limits.with_chunked_blob_minimum_bytes(minimum)?,
        None => limits,
    };
    let report = repository.import_git_repository(&source, limits)?;
    println!(
        "imported objects={} tiny_blobs={} whole_blobs={} chunked_blobs={} metadata_objects={} refs={}",
        report.object_count(),
        report.tiny_blob_count(),
        report.whole_blob_count(),
        report.chunked_blob_count(),
        report.metadata_object_count(),
        report.ref_count(),
    );
    Ok(())
}

fn verify(repository: PathBuf) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let report = LocalRepository::open(repository)?.verify(limits.verification_limits()?)?;
    println!(
        "verified segments={} indexes={} blob_manifests={} tiny_blob_group_manifests={} metadata_manifests={} ref_snapshots={}",
        report.segment_count(),
        report.index_count(),
        report.blob_manifest_count(),
        report.tiny_blob_group_manifest_count(),
        report.metadata_object_manifest_count(),
        report.ref_snapshot_count(),
    );
    Ok(())
}

fn export_git(repository: PathBuf, destination: PathBuf) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let report = LocalRepository::open(repository)?
        .export_loose_objects(destination, limits.export_limits()?)?;
    println!(
        "exported objects={} blobs={} metadata_objects={} refs={}",
        report.object_count(),
        report.blob_count(),
        report.metadata_object_count(),
        report.ref_count(),
    );
    Ok(())
}

fn inspect_object(repository: PathBuf, id: GitObjectId) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let repository = LocalRepository::open(repository)?;
    if let Some(manifest) = repository.resolve_blob_manifest(id, limits.blob_manifest_limits())? {
        println!(
            "object={} kind=blob bytes={} storage={:?}",
            manifest.git_object_id(),
            manifest.plaintext_bytes(),
            manifest.representation(),
        );
        return Ok(());
    }
    if let Some(manifest) =
        repository.resolve_metadata_object_manifest(id, limits.metadata_object_manifest_limits())?
    {
        println!(
            "object={} kind={:?} bytes={}",
            manifest.git_object_id(),
            manifest.kind(),
            manifest.plaintext_bytes(),
        );
        return Ok(());
    }
    Err(Error::new(
        ErrorKind::NotFound,
        "Git object is not published",
    ))
}

fn inspect_storage(repository: PathBuf) -> Result<()> {
    verify(repository)
}

fn usage_error() -> Error {
    Error::new(
        ErrorKind::InvalidInput,
        "invalid command; run yeokcham --help",
    )
}

fn print_usage() {
    println!(
        "usage:\n  yeokcham init --from-git <source-git-repo> <yeokcham-repo> [--chunked-blob-minimum <bytes>]\n  yeokcham verify <yeokcham-repo>\n  yeokcham export-git <yeokcham-repo> <destination-git-repo>\n  yeokcham inspect object <yeokcham-repo> <git-object-id>\n  yeokcham inspect storage <yeokcham-repo>"
    );
}
