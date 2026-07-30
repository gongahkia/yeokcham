use std::{
    env,
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    future::Future,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
    sync::Arc,
    task::{Context, Poll, Wake, Waker},
    time::Duration,
};

use yeokcham_core::{
    BackendListLimits, DeviceId, DeviceRegistryReadLimits, DriveBackend, DriveCredentialStore,
    DriveFolderId, DriveOAuthConfiguration, EncryptedBackend, EncryptedRepositoryRecoveryLimits,
    Error, ErrorKind, GitImportLimits, GitObjectId, GitRepository, KeyringDriveCredentialStore,
    LocalRepository, RefEvent, RefEventReadLimits, RefEventVerifyingKey, RemoteRefJournalLimits,
    RemoteRefJournalReconciliation, RepositoryEncryptionKey, RepositoryKeyExport, Result,
    StoredDriveAccessTokenProvider, UreqDriveHttpTransport, UreqDriveOAuthTransport,
    fetch_remote_ref_journal,
};
use zeroize::Zeroizing;

mod telemetry;

const MAXIMUM_KEY_EXPORT_BYTES: u64 = 8 * 1024;
const MAXIMUM_PASSPHRASE_INPUT_BYTES: u64 = 1_025;
const MAXIMUM_CACHE_PATHS: usize = 100_000;
const MAXIMUM_CACHE_DEPTH: usize = 32;

type DefaultDriveBackend = EncryptedBackend<
    DriveBackend<
        UreqDriveHttpTransport,
        StoredDriveAccessTokenProvider<KeyringDriveCredentialStore, UreqDriveOAuthTransport>,
    >,
>;

enum Command {
    Help,
    Init {
        source: PathBuf,
        destination: PathBuf,
        chunked_blob_minimum_bytes: Option<usize>,
    },
    Sync {
        source: PathBuf,
        repository: PathBuf,
        device_id: DeviceId,
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
    InspectRefs {
        repository: PathBuf,
    },
    CacheClear {
        repository: PathBuf,
    },
    CacheInspect {
        repository: PathBuf,
    },
    CacheVerify {
        repository: PathBuf,
    },
    DriveAuth {
        client_id: String,
        redirect_port: Option<u16>,
    },
    DriveInit {
        client_id: String,
    },
    DriveBackup {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
        repository: PathBuf,
    },
    DrivePush {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
        repository: PathBuf,
    },
    DriveRestore {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
        destination: PathBuf,
    },
    DriveClone {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
        destination: PathBuf,
    },
    DriveVerify {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
    },
    DriveJournalInspect {
        client_id: String,
        folder_id: DriveFolderId,
        key_export: PathBuf,
        root_verifying_key: RefEventVerifyingKey,
        repository: PathBuf,
    },
    KeyCreateExport {
        repository: PathBuf,
        destination: PathBuf,
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
        Command::Sync {
            source,
            repository,
            device_id,
        } => sync(source, repository, device_id),
        Command::Verify { repository } => verify(repository),
        Command::ExportGit {
            repository,
            destination,
        } => export_git(repository, destination),
        Command::InspectObject { repository, id } => inspect_object(repository, id),
        Command::InspectStorage { repository } => inspect_storage(repository),
        Command::InspectRefs { repository } => inspect_refs(repository),
        Command::CacheClear { repository } => cache_clear(repository),
        Command::CacheInspect { repository } => cache_inspect(repository),
        Command::CacheVerify { repository } => cache_verify(repository),
        Command::DriveAuth {
            client_id,
            redirect_port,
        } => drive_auth(client_id, redirect_port),
        Command::DriveInit { client_id } => drive_init(client_id),
        Command::DriveBackup {
            client_id,
            folder_id,
            key_export,
            repository,
        } => drive_backup(client_id, folder_id, key_export, repository),
        Command::DrivePush {
            client_id,
            folder_id,
            key_export,
            repository,
        } => drive_push(client_id, folder_id, key_export, repository),
        Command::DriveRestore {
            client_id,
            folder_id,
            key_export,
            destination,
        } => drive_restore(client_id, folder_id, key_export, destination),
        Command::DriveClone {
            client_id,
            folder_id,
            key_export,
            destination,
        } => drive_clone(client_id, folder_id, key_export, destination),
        Command::DriveVerify {
            client_id,
            folder_id,
            key_export,
        } => drive_verify(client_id, folder_id, key_export),
        Command::DriveJournalInspect {
            client_id,
            folder_id,
            key_export,
            root_verifying_key,
            repository,
        } => drive_journal_inspect(
            client_id,
            folder_id,
            key_export,
            root_verifying_key,
            repository,
        ),
        Command::KeyCreateExport {
            repository,
            destination,
        } => key_create_export(repository, destination),
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
        "sync" => parse_sync(&arguments),
        "drive" => parse_drive(&arguments),
        "key" => parse_key(&arguments),
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
        "inspect" if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("refs") => {
            Ok(Command::InspectRefs {
                repository: PathBuf::from(&arguments[2]),
            })
        }
        "cache" if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("clear") => {
            Ok(Command::CacheClear {
                repository: PathBuf::from(&arguments[2]),
            })
        }
        "cache" if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("inspect") => {
            Ok(Command::CacheInspect {
                repository: PathBuf::from(&arguments[2]),
            })
        }
        "cache" if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("verify") => {
            Ok(Command::CacheVerify {
                repository: PathBuf::from(&arguments[2]),
            })
        }
        _ => Err(usage_error()),
    }
}

fn parse_key(arguments: &[OsString]) -> Result<Command> {
    if arguments.len() == 5
        && arguments[1].as_os_str() == OsStr::new("create-export")
        && arguments[2].as_os_str() == OsStr::new("--passphrase-stdin")
    {
        return Ok(Command::KeyCreateExport {
            repository: PathBuf::from(&arguments[3]),
            destination: PathBuf::from(&arguments[4]),
        });
    }
    Err(usage_error())
}

fn parse_drive(arguments: &[OsString]) -> Result<Command> {
    if arguments.len() == 4
        && arguments[1].as_os_str() == OsStr::new("init")
        && arguments[2].as_os_str() == OsStr::new("--client-id")
    {
        return Ok(Command::DriveInit {
            client_id: arguments[3].to_str().ok_or_else(usage_error)?.to_owned(),
        });
    }
    if arguments.len() == 4
        && arguments[1].as_os_str() == OsStr::new("auth")
        && arguments[2].as_os_str() == OsStr::new("--client-id")
    {
        return Ok(Command::DriveAuth {
            client_id: arguments[3].to_str().ok_or_else(usage_error)?.to_owned(),
            redirect_port: None,
        });
    }
    if arguments.len() == 6
        && arguments[1].as_os_str() == OsStr::new("auth")
        && arguments[2].as_os_str() == OsStr::new("--client-id")
        && arguments[4].as_os_str() == OsStr::new("--redirect-port")
    {
        let redirect_port = arguments[5]
            .to_str()
            .ok_or_else(usage_error)?
            .parse()
            .map_err(|_| Error::new(ErrorKind::InvalidInput, "Drive redirect port is invalid"))?;
        return Ok(Command::DriveAuth {
            client_id: arguments[3].to_str().ok_or_else(usage_error)?.to_owned(),
            redirect_port: Some(redirect_port),
        });
    }
    if arguments.len() == 10
        && (arguments[1].as_os_str() == OsStr::new("backup")
            || arguments[1].as_os_str() == OsStr::new("push"))
        && arguments[2].as_os_str() == OsStr::new("--client-id")
        && arguments[4].as_os_str() == OsStr::new("--folder-id")
        && arguments[6].as_os_str() == OsStr::new("--key-export")
        && arguments[8].as_os_str() == OsStr::new("--passphrase-stdin")
    {
        let client_id = arguments[3].to_str().ok_or_else(usage_error)?.to_owned();
        let folder_id =
            DriveFolderId::new(arguments[5].to_str().ok_or_else(usage_error)?.to_owned())?;
        let key_export = PathBuf::from(&arguments[7]);
        let repository = PathBuf::from(&arguments[9]);
        return if arguments[1].as_os_str() == OsStr::new("push") {
            Ok(Command::DrivePush {
                client_id,
                folder_id,
                key_export,
                repository,
            })
        } else {
            Ok(Command::DriveBackup {
                client_id,
                folder_id,
                key_export,
                repository,
            })
        };
    }
    if arguments.len() == 10
        && (arguments[1].as_os_str() == OsStr::new("restore")
            || arguments[1].as_os_str() == OsStr::new("clone"))
        && arguments[2].as_os_str() == OsStr::new("--client-id")
        && arguments[4].as_os_str() == OsStr::new("--folder-id")
        && arguments[6].as_os_str() == OsStr::new("--key-export")
        && arguments[8].as_os_str() == OsStr::new("--passphrase-stdin")
    {
        let client_id = arguments[3].to_str().ok_or_else(usage_error)?.to_owned();
        let folder_id =
            DriveFolderId::new(arguments[5].to_str().ok_or_else(usage_error)?.to_owned())?;
        let key_export = PathBuf::from(&arguments[7]);
        let destination = PathBuf::from(&arguments[9]);
        return if arguments[1].as_os_str() == OsStr::new("clone") {
            Ok(Command::DriveClone {
                client_id,
                folder_id,
                key_export,
                destination,
            })
        } else {
            Ok(Command::DriveRestore {
                client_id,
                folder_id,
                key_export,
                destination,
            })
        };
    }
    if arguments.len() == 9
        && arguments[1].as_os_str() == OsStr::new("verify")
        && arguments[2].as_os_str() == OsStr::new("--client-id")
        && arguments[4].as_os_str() == OsStr::new("--folder-id")
        && arguments[6].as_os_str() == OsStr::new("--key-export")
        && arguments[8].as_os_str() == OsStr::new("--passphrase-stdin")
    {
        return Ok(Command::DriveVerify {
            client_id: arguments[3].to_str().ok_or_else(usage_error)?.to_owned(),
            folder_id: DriveFolderId::new(
                arguments[5].to_str().ok_or_else(usage_error)?.to_owned(),
            )?,
            key_export: PathBuf::from(&arguments[7]),
        });
    }
    if arguments.len() == 13
        && arguments[1].as_os_str() == OsStr::new("journal")
        && arguments[2].as_os_str() == OsStr::new("inspect")
        && arguments[3].as_os_str() == OsStr::new("--client-id")
        && arguments[5].as_os_str() == OsStr::new("--folder-id")
        && arguments[7].as_os_str() == OsStr::new("--key-export")
        && arguments[9].as_os_str() == OsStr::new("--root-key")
        && arguments[11].as_os_str() == OsStr::new("--passphrase-stdin")
    {
        return Ok(Command::DriveJournalInspect {
            client_id: arguments[4].to_str().ok_or_else(usage_error)?.to_owned(),
            folder_id: DriveFolderId::new(
                arguments[6].to_str().ok_or_else(usage_error)?.to_owned(),
            )?,
            key_export: PathBuf::from(&arguments[8]),
            root_verifying_key: parse_root_verifying_key(
                arguments[10].to_str().ok_or_else(usage_error)?,
            )?,
            repository: PathBuf::from(&arguments[12]),
        });
    }
    Err(usage_error())
}

fn parse_sync(arguments: &[OsString]) -> Result<Command> {
    if arguments.len() != 6
        || arguments[1].as_os_str() != OsStr::new("--from-git")
        || arguments[4].as_os_str() != OsStr::new("--device")
    {
        return Err(usage_error());
    }
    let device_id = arguments[5]
        .to_str()
        .ok_or_else(usage_error)?
        .parse()
        .map_err(|_| Error::new(ErrorKind::InvalidInput, "device ID is invalid"))?;
    Ok(Command::Sync {
        source: PathBuf::from(&arguments[2]),
        repository: PathBuf::from(&arguments[3]),
        device_id,
    })
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

fn sync(source: PathBuf, repository: PathBuf, device_id: DeviceId) -> Result<()> {
    let source = GitRepository::open(source)?;
    let repository = LocalRepository::open(repository)?;
    let limits = GitImportLimits::initial()?;
    let report = repository.sync_git_repository(&source, device_id, limits)?;
    println!(
        "synced objects={} tiny_blobs={} whole_blobs={} chunked_blobs={} metadata_objects={} refs={}",
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

fn inspect_refs(repository: PathBuf) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let repository = LocalRepository::open(repository)?;
    let events = repository.ref_events(RefEventReadLimits::new(
        limits.ref_snapshot_limits().maximum_directory_entries(),
        limits.ref_snapshot_limits().maximum_snapshot_bytes(),
        limits.ref_snapshot_limits().maximum_reference_entries(),
    )?)?;
    match repository.resolve_ref_state(limits.ref_snapshot_limits()) {
        Ok(state) => {
            let ref_count = state.as_ref().map_or(0, |state| state.regular_refs().len());
            println!("refs={ref_count} events={}", events.len());
        }
        Err(error) => println!(
            "refs=unresolved events={} state_error={}",
            events.len(),
            error.code()
        ),
    }
    for event in events {
        println!("device={} sequence={}", event.device_id(), event.sequence());
    }
    Ok(())
}

fn cache_clear(repository: PathBuf) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let cache = repository.path().join("cache");
    match fs::symlink_metadata(&cache) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "repository cache path is invalid",
            ));
        }
        Ok(_) => {
            fs::remove_dir_all(&cache).map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "repository cache could not be removed",
                    error,
                )
            })?;
            File::open(repository.path())
                .and_then(|directory| directory.sync_all())
                .map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "repository cache deletion could not be synchronized",
                        error,
                    )
                })?;
        }
        Err(error) => {
            return Err(Error::with_source(
                ErrorKind::Io,
                "repository cache could not be inspected",
                error,
            ));
        }
    }
    println!("cache_cleared");
    Ok(())
}

struct PackCacheEntry {
    name: OsString,
    path: PathBuf,
}

#[derive(Default)]
struct PackCacheStatistics {
    entry_count: usize,
    partial_entry_count: usize,
    file_count: usize,
    byte_count: u64,
    scanned_path_count: usize,
}

fn cache_inspect(repository: PathBuf) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let entries = pack_cache_entries(&repository)?;
    let statistics = pack_cache_statistics(&entries)?;
    println!(
        "pack_cache_entries={} pack_cache_partial_entries={} pack_cache_files={} pack_cache_bytes={}",
        statistics.entry_count,
        statistics.partial_entry_count,
        statistics.file_count,
        statistics.byte_count,
    );
    Ok(())
}

fn cache_verify(repository: PathBuf) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let repository = LocalRepository::open(repository)?;
    repository.verify(limits.verification_limits()?)?;
    let entries = pack_cache_entries(&repository)?;
    let statistics = pack_cache_statistics(&entries)?;
    if statistics.partial_entry_count != 0 {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache contains incomplete entries",
        ));
    }
    for entry in &entries {
        let name = entry.name.to_str().ok_or_else(|| {
            Error::new(ErrorKind::CorruptData, "pack cache entry name is invalid")
        })?;
        if name.len() != 64 || !name.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "pack cache entry name is invalid",
            ));
        }
        let cache_repository = GitRepository::open(&entry.path).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "pack cache entry is not a Git repository",
            )
        })?;
        let state = cache_repository
            .ref_state()
            .map_err(|_| Error::new(ErrorKind::CorruptData, "pack cache entry has invalid refs"))?;
        if hex::encode(RefEvent::state_id(&state)) != name {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "pack cache entry name does not match its refs",
            ));
        }
        verify_packed_cache_repository(&entry.path)?;
    }
    println!(
        "verified_pack_cache_entries={} pack_cache_bytes={}",
        statistics.entry_count, statistics.byte_count,
    );
    Ok(())
}

fn pack_cache_entries(repository: &LocalRepository) -> Result<Vec<PackCacheEntry>> {
    let cache = repository.path().join("cache");
    if !existing_cache_directory(&cache)? {
        return Ok(Vec::new());
    }
    let packs = cache.join("packs");
    if !existing_cache_directory(&packs)? {
        return Ok(Vec::new());
    }
    let entries = fs::read_dir(&packs).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache directory could not be read",
            error,
        )
    })?;
    let mut result = Vec::new();
    for entry in entries {
        if result.len() == MAXIMUM_CACHE_PATHS {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "pack cache has too many entries",
            ));
        }
        let entry = entry.map_err(|error| {
            Error::with_source(ErrorKind::Io, "pack cache entry could not be read", error)
        })?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache entry could not be inspected",
                error,
            )
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "pack cache entry is not a directory",
            ));
        }
        result.push(PackCacheEntry {
            name: entry.file_name(),
            path,
        });
    }
    Ok(result)
}

fn existing_cache_directory(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_symlink() && metadata.is_dir() => Ok(true),
        Ok(_) => Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache path is not a directory",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(Error::with_source(
            ErrorKind::Io,
            "pack cache path could not be inspected",
            error,
        )),
    }
}

fn pack_cache_statistics(entries: &[PackCacheEntry]) -> Result<PackCacheStatistics> {
    let mut statistics = PackCacheStatistics::default();
    for entry in entries {
        statistics.entry_count = statistics.entry_count.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::Unsupported, "pack cache entry count overflows")
        })?;
        if entry.name.to_string_lossy().ends_with(".partial") {
            statistics.partial_entry_count = statistics
                .partial_entry_count
                .checked_add(1)
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::Unsupported,
                        "pack cache partial entry count overflows",
                    )
                })?;
        }
        collect_pack_cache_usage(&entry.path, &mut statistics, 0)?;
    }
    Ok(statistics)
}

fn collect_pack_cache_usage(
    path: &Path,
    statistics: &mut PackCacheStatistics,
    depth: usize,
) -> Result<()> {
    if depth > MAXIMUM_CACHE_DEPTH {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "pack cache directory depth exceeds the limit",
        ));
    }
    statistics.scanned_path_count = statistics
        .scanned_path_count
        .checked_add(1)
        .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache path count overflows"))?;
    if statistics.scanned_path_count > MAXIMUM_CACHE_PATHS {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "pack cache contains too many paths",
        ));
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache path could not be inspected",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache contains a symbolic link",
        ));
    }
    if metadata.is_file() {
        statistics.file_count = statistics
            .file_count
            .checked_add(1)
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache file count overflows"))?;
        statistics.byte_count = statistics
            .byte_count
            .checked_add(metadata.len())
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache byte count overflows"))?;
        return Ok(());
    }
    if !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache contains an unsupported file type",
        ));
    }
    let entries = fs::read_dir(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache directory could not be read",
            error,
        )
    })?;
    for entry in entries {
        let path = entry
            .map_err(|error| {
                Error::with_source(ErrorKind::Io, "pack cache entry could not be read", error)
            })?
            .path();
        collect_pack_cache_usage(&path, statistics, depth + 1)?;
    }
    Ok(())
}

fn verify_packed_cache_repository(repository: &Path) -> Result<()> {
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
    let status = command
        .arg("--git-dir")
        .arg(repository)
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
    if !status.success() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "pack cache entry fails Git verification",
        ));
    }
    Ok(())
}

fn drive_auth(client_id: String, redirect_port: Option<u16>) -> Result<()> {
    let configuration = DriveOAuthConfiguration::new(client_id)?;
    let loopback = match redirect_port {
        Some(port) => configuration.clone().begin_loopback_on(port)?,
        None => configuration.clone().begin_loopback()?,
    };
    println!(
        "Open this URL in a system browser:\n{}",
        loopback.authorization_url()
    );
    let transport = UreqDriveOAuthTransport::new(Duration::from_secs(30))?;
    let token = loopback.complete(&transport, Duration::from_secs(300))?;
    KeyringDriveCredentialStore.store(&configuration, &token)?;
    println!("Google Drive authorization stored in the OS credential store");
    Ok(())
}

fn drive_init(client_id: String) -> Result<()> {
    let configuration = DriveOAuthConfiguration::new(client_id)?;
    let token_transport = UreqDriveOAuthTransport::new(Duration::from_secs(30))?;
    let access_tokens = StoredDriveAccessTokenProvider::new(
        configuration,
        KeyringDriveCredentialStore,
        token_transport,
    );
    let transport = UreqDriveHttpTransport::new(Duration::from_secs(30))?;
    let folder = DriveFolderId::create(&transport, &access_tokens)?;
    println!("created_drive_folder_id={}", folder.as_str());
    Ok(())
}

fn drive_backup(
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    repository: PathBuf,
) -> Result<()> {
    drive_snapshot_backup("drive_backup", client_id, folder_id, key_export, repository)
}

fn drive_push(
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    repository: PathBuf,
) -> Result<()> {
    drive_snapshot_backup("drive_push", client_id, folder_id, key_export, repository)
}

fn drive_snapshot_backup(
    operation: &str,
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    repository: PathBuf,
) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let key = read_recovery_key(key_export)?;
    if repository.id() != key.repository_id() {
        return Err(Error::new(
            ErrorKind::Conflict,
            "recovery key does not belong to the local repository",
        ));
    }
    let backend = encrypted_drive_backend(client_id, folder_id, key)?;
    let report = block_on(repository.backup_to_backend(&backend, recovery_limits()?))?;
    println!(
        "{operation} files={} bytes={}",
        report.file_count(),
        report.total_bytes(),
    );
    Ok(())
}

fn drive_restore(
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    destination: PathBuf,
) -> Result<()> {
    drive_snapshot_restore(
        "drive_restore",
        client_id,
        folder_id,
        key_export,
        destination,
    )
}

fn drive_clone(
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    destination: PathBuf,
) -> Result<()> {
    drive_snapshot_restore("drive_clone", client_id, folder_id, key_export, destination)
}

fn drive_snapshot_restore(
    operation: &str,
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    destination: PathBuf,
) -> Result<()> {
    let key = read_recovery_key(key_export)?;
    let repository_id = key.repository_id();
    let backend = encrypted_drive_backend(client_id, folder_id, key)?;
    let (repository, report) = block_on(LocalRepository::restore_from_backend(
        &destination,
        repository_id,
        &backend,
        recovery_limits()?,
    ))?;
    repository.verify(GitImportLimits::initial()?.verification_limits()?)?;
    println!(
        "{operation} files={} bytes={}",
        report.file_count(),
        report.total_bytes(),
    );
    Ok(())
}

fn drive_verify(client_id: String, folder_id: DriveFolderId, key_export: PathBuf) -> Result<()> {
    let key = read_recovery_key(key_export)?;
    let repository_id = key.repository_id();
    let backend = encrypted_drive_backend(client_id, folder_id, key)?;
    let destination =
        env::temp_dir().join(format!("yeokcham-drive-verify-{}", uuid::Uuid::new_v4()));
    let result = block_on(LocalRepository::restore_from_backend(
        &destination,
        repository_id,
        &backend,
        recovery_limits()?,
    ))
    .and_then(|(repository, report)| {
        repository.verify(GitImportLimits::initial()?.verification_limits()?)?;
        Ok(report)
    });
    let cleanup = fs::remove_dir_all(&destination).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "temporary Drive verification files could not be removed",
            error,
        )
    });
    match (result, cleanup) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Ok(report), Ok(())) => {
            println!(
                "drive_verified files={} bytes={}",
                report.file_count(),
                report.total_bytes(),
            );
            Ok(())
        }
    }
}

fn drive_journal_inspect(
    client_id: String,
    folder_id: DriveFolderId,
    key_export: PathBuf,
    root_verifying_key: RefEventVerifyingKey,
    repository: PathBuf,
) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let key = read_recovery_key(key_export)?;
    if repository.id() != key.repository_id() {
        return Err(Error::new(
            ErrorKind::Conflict,
            "recovery key does not belong to the local repository",
        ));
    }
    let local_limits = GitImportLimits::initial()?;
    let initial = repository
        .resolve_ref_snapshot(local_limits.ref_snapshot_limits())?
        .ok_or_else(|| Error::new(ErrorKind::NotFound, "local repository has no ref snapshot"))?;
    let backend = encrypted_drive_backend(client_id, folder_id, key)?;
    let journal = block_on(fetch_remote_ref_journal(
        &backend,
        repository.id(),
        root_verifying_key,
        remote_journal_limits(local_limits)?,
    ))?;
    match journal.reconcile(initial.state()) {
        RemoteRefJournalReconciliation::Resolved(state) => println!(
            "remote_refs={} events={} registry_events={}",
            state.regular_refs().len(),
            journal.events().len(),
            journal.device_registry().events().len(),
        ),
        RemoteRefJournalReconciliation::Divergent(divergence) => {
            println!(
                "remote_refs=unresolved events={} registry_events={} unresolved_events={} base_refs={}",
                journal.events().len(),
                journal.device_registry().events().len(),
                divergence.unresolved_events().len(),
                divergence.base_state().regular_refs().len(),
            );
            for event in divergence.unresolved_events() {
                println!("device={} sequence={}", event.device_id(), event.sequence());
            }
        }
    }
    Ok(())
}

fn remote_journal_limits(limits: GitImportLimits) -> Result<RemoteRefJournalLimits> {
    let ref_limits = limits.ref_snapshot_limits();
    RemoteRefJournalLimits::new(
        DeviceRegistryReadLimits::new(
            ref_limits.maximum_directory_entries(),
            ref_limits.maximum_snapshot_bytes(),
        )?,
        RefEventReadLimits::new(
            ref_limits.maximum_directory_entries(),
            ref_limits.maximum_snapshot_bytes(),
            ref_limits.maximum_reference_entries(),
        )?,
        BackendListLimits::new(1_000, 1_000)?,
    )
}

fn parse_root_verifying_key(value: &str) -> Result<RefEventVerifyingKey> {
    let mut bytes = [0; 32];
    hex::decode_to_slice(value, &mut bytes).map_err(|_| {
        Error::new(
            ErrorKind::InvalidInput,
            "device registry root key is invalid",
        )
    })?;
    RefEventVerifyingKey::from_bytes(bytes)
}

fn key_create_export(repository: PathBuf, destination: PathBuf) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let key = RepositoryEncryptionKey::generate(repository.id())?;
    let passphrase = read_passphrase()?;
    let export = key.export_with_passphrase(&passphrase)?;
    let mut destination_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "recovery key export could not be created",
                error,
            )
        })?;
    destination_file
        .write_all(export.as_bytes())
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "recovery key export could not be written",
                error,
            )
        })?;
    destination_file.sync_all().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "recovery key export could not be synchronized",
            error,
        )
    })?;
    println!("created encrypted recovery key export");
    Ok(())
}

fn encrypted_drive_backend(
    client_id: String,
    folder_id: DriveFolderId,
    key: RepositoryEncryptionKey,
) -> Result<DefaultDriveBackend> {
    let configuration = DriveOAuthConfiguration::new(client_id)?;
    let naming_key = key.derive_drive_object_naming_key()?;
    let token_transport = UreqDriveOAuthTransport::new(Duration::from_secs(30))?;
    let access_tokens = StoredDriveAccessTokenProvider::new(
        configuration,
        KeyringDriveCredentialStore,
        token_transport,
    );
    let transport = UreqDriveHttpTransport::new(Duration::from_secs(30))?;
    Ok(EncryptedBackend::new(
        DriveBackend::new(folder_id, naming_key, transport, access_tokens),
        key,
    ))
}

fn read_recovery_key(path: PathBuf) -> Result<RepositoryEncryptionKey> {
    let export =
        RepositoryKeyExport::from_bytes(read_bounded_file(&path, MAXIMUM_KEY_EXPORT_BYTES)?)?;
    let passphrase = read_passphrase()?;
    RepositoryEncryptionKey::import_with_passphrase(&export, &passphrase)
}

fn read_bounded_file(path: &PathBuf, maximum_bytes: u64) -> Result<Vec<u8>> {
    let mut file = File::open(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "recovery key export could not be opened",
            error,
        )
    })?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(maximum_bytes.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::Internal, "recovery key export bound is invalid")
        })?)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "recovery key export could not be read",
                error,
            )
        })?;
    if u64::try_from(bytes.len())
        .ok()
        .is_none_or(|length| length > maximum_bytes)
    {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "recovery key export exceeds the byte limit",
        ));
    }
    Ok(bytes)
}

fn read_passphrase() -> Result<Zeroizing<Vec<u8>>> {
    let mut passphrase = Zeroizing::new(Vec::new());
    io::stdin()
        .lock()
        .take(MAXIMUM_PASSPHRASE_INPUT_BYTES)
        .read_to_end(&mut passphrase)
        .map_err(|error| {
            Error::with_source(ErrorKind::Io, "passphrase could not be read", error)
        })?;
    if passphrase.last() == Some(&b'\n') {
        passphrase.pop();
        if passphrase.last() == Some(&b'\r') {
            passphrase.pop();
        }
    }
    if passphrase.is_empty() || passphrase.len() > 1_024 {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "recovery export passphrase is invalid",
        ));
    }
    Ok(passphrase)
}

fn recovery_limits() -> Result<EncryptedRepositoryRecoveryLimits> {
    let maximum_file_bytes = 64 * 1024 * 1024;
    let maximum_files = 100_000;
    EncryptedRepositoryRecoveryLimits::new(
        maximum_files,
        maximum_file_bytes,
        maximum_file_bytes
            .checked_mul(
                u64::try_from(maximum_files).map_err(|_| {
                    Error::new(ErrorKind::Internal, "recovery file count is invalid")
                })?,
            )
            .ok_or_else(|| Error::new(ErrorKind::Internal, "recovery total bound overflows"))?,
        128 * 1024 * 1024,
    )
}

struct NoopWake;

impl Wake for NoopWake {
    fn wake(self: Arc<Self>) {}
}

fn block_on<T>(future: impl Future<Output = Result<T>>) -> Result<T> {
    let waker = Waker::from(Arc::new(NoopWake));
    let mut context = Context::from_waker(&waker);
    let mut future = Box::pin(future);
    match future.as_mut().poll(&mut context) {
        Poll::Ready(value) => value,
        Poll::Pending => Err(Error::new(
            ErrorKind::Internal,
            "backend future unexpectedly yielded",
        )),
    }
}

fn usage_error() -> Error {
    Error::new(
        ErrorKind::InvalidInput,
        "invalid command; run yeokcham --help",
    )
}

fn print_usage() {
    println!(
        "usage:\n  yeokcham init --from-git <source-git-repo> <yeokcham-repo> [--chunked-blob-minimum <bytes>]\n  yeokcham sync --from-git <source-git-repo> <yeokcham-repo> --device <device-id>\n  yeokcham verify <yeokcham-repo>\n  yeokcham export-git <yeokcham-repo> <destination-git-repo>\n  yeokcham inspect object <yeokcham-repo> <git-object-id>\n  yeokcham inspect storage <yeokcham-repo>\n  yeokcham inspect refs <yeokcham-repo>\n  yeokcham cache inspect|verify|clear <yeokcham-repo>\n  yeokcham key create-export --passphrase-stdin <yeokcham-repo> <recovery-key-export>\n  yeokcham drive auth --client-id <google-desktop-client-id> [--redirect-port <port>]\n  yeokcham drive init --client-id <google-desktop-client-id>\n  yeokcham drive backup|push --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <yeokcham-repo>\n  yeokcham drive restore|clone --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <destination>\n  yeokcham drive verify --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin\n  yeokcham drive journal inspect --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --root-key <root-ed25519-public-key-hex> --passphrase-stdin <yeokcham-repo>"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cache_workflows() {
        let clear = parse_command(
            ["cache", "clear", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("cache clear");
        assert!(matches!(
            clear,
            Command::CacheClear { repository } if repository == PathBuf::from("repository")
        ));
        let inspect = parse_command(
            ["cache", "inspect", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("cache inspect");
        assert!(matches!(
            inspect,
            Command::CacheInspect { repository } if repository == PathBuf::from("repository")
        ));
        let verify = parse_command(
            ["cache", "verify", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("cache verify");
        assert!(matches!(
            verify,
            Command::CacheVerify { repository } if repository == PathBuf::from("repository")
        ));
    }

    #[test]
    fn parses_manual_drive_authorization_with_an_optional_redirect_port() {
        let command = parse_command(
            [
                "drive",
                "auth",
                "--client-id",
                "123.apps.googleusercontent.com",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("default drive auth");
        assert!(matches!(
            command,
            Command::DriveAuth {
                ref client_id,
                redirect_port: None,
            } if client_id == "123.apps.googleusercontent.com"
        ));
        let command = parse_command(
            [
                "drive",
                "auth",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--redirect-port",
                "8787",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("forwarded drive auth");
        assert!(matches!(
            command,
            Command::DriveAuth {
                redirect_port: Some(8787),
                ..
            }
        ));
    }

    #[test]
    fn parses_drive_root_backup_restore_and_verification_workflows() {
        let key_export = parse_command(
            [
                "key",
                "create-export",
                "--passphrase-stdin",
                "repository",
                "key.ykrk",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("key export");
        assert!(matches!(key_export, Command::KeyCreateExport { .. }));

        let command = parse_command(
            [
                "drive",
                "init",
                "--client-id",
                "123.apps.googleusercontent.com",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive init");
        assert!(matches!(command, Command::DriveInit { .. }));

        let backup = parse_command(
            [
                "drive",
                "backup",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--passphrase-stdin",
                "repository",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive backup");
        assert!(matches!(
            backup,
            Command::DriveBackup {
                folder_id,
                key_export,
                repository,
                ..
            } if folder_id.as_str() == "folder_id"
                && key_export == PathBuf::from("key.ykrk")
                && repository == PathBuf::from("repository")
        ));

        let restore = parse_command(
            [
                "drive",
                "restore",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--passphrase-stdin",
                "destination",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive restore");
        assert!(matches!(restore, Command::DriveRestore { .. }));

        let push = parse_command(
            [
                "drive",
                "push",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--passphrase-stdin",
                "repository",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive push");
        assert!(matches!(push, Command::DrivePush { .. }));

        let clone = parse_command(
            [
                "drive",
                "clone",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--passphrase-stdin",
                "destination",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive clone");
        assert!(matches!(clone, Command::DriveClone { .. }));

        let root = yeokcham_core::RefEventSigningKey::from_secret_bytes([3; 32]);
        let root = hex::encode(root.verifying_key().as_bytes());
        let journal = parse_command(
            [
                "drive",
                "journal",
                "inspect",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--root-key",
                root.as_str(),
                "--passphrase-stdin",
                "repository",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive journal inspection");
        assert!(matches!(journal, Command::DriveJournalInspect { .. }));

        let verify = parse_command(
            [
                "drive",
                "verify",
                "--client-id",
                "123.apps.googleusercontent.com",
                "--folder-id",
                "folder_id",
                "--key-export",
                "key.ykrk",
                "--passphrase-stdin",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("Drive verification");
        assert!(matches!(verify, Command::DriveVerify { .. }));
    }
}
