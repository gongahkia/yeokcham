use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    future::Future,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
    sync::Arc,
    task::{Context, Poll, Wake, Waker},
    time::{Duration, SystemTime},
};

use yeokcham_core::{
    BackendListLimits, DeviceId, DeviceRegistryReadLimits, DriveBackend, DriveCredentialStore,
    DriveFolderId, DriveOAuthConfiguration, EncryptedBackend, EncryptedRepositoryRecoveryLimits,
    Error, ErrorKind, GitImportLimits, GitObjectId, GitRepository, GithubForceUpdatePolicy,
    GithubMirrorConfiguration, GithubMirrorDirection, GithubPublicationRule, GithubRepository,
    KeyringDriveCredentialStore, LocalRepository, RefEvent, RefEventReadLimits,
    RefEventVerifyingKey, RemoteRefJournalLimits, RemoteRefJournalReconciliation,
    RepositoryEncryptionKey, RepositoryKeyExport, Result, StoredDriveAccessTokenProvider,
    UreqDriveHttpTransport, UreqDriveOAuthTransport, fetch_remote_ref_journal,
};
use zeroize::Zeroizing;

mod telemetry;

const MAXIMUM_KEY_EXPORT_BYTES: u64 = 8 * 1024;
const MAXIMUM_PASSPHRASE_INPUT_BYTES: u64 = 1_025;
const MAXIMUM_CACHE_PATHS: usize = 100_000;
const MAXIMUM_CACHE_DEPTH: usize = 32;
const MAXIMUM_GITHUB_GIT_OUTPUT_BYTES: usize = 64 * 1024 * 1024;

type DefaultDriveBackend = EncryptedBackend<
    DriveBackend<
        UreqDriveHttpTransport,
        StoredDriveAccessTokenProvider<KeyringDriveCredentialStore, UreqDriveOAuthTransport>,
    >,
>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GithubTransport {
    Https,
    Ssh,
}

impl GithubTransport {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Https => "https",
            Self::Ssh => "ssh",
        }
    }
}

impl std::str::FromStr for GithubTransport {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "https" => Ok(Self::Https),
            "ssh" => Ok(Self::Ssh),
            _ => Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub transport is invalid",
            )),
        }
    }
}

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
    CacheTrim {
        repository: PathBuf,
        maximum_bytes: u64,
    },
    GithubConfigure {
        repository: PathBuf,
        target: GithubRepository,
        direction: GithubMirrorDirection,
        force_update_policy: GithubForceUpdatePolicy,
        publication_rules: Vec<GithubPublicationRule>,
    },
    GithubInspect {
        repository: PathBuf,
    },
    GithubPublicationPlan {
        repository: PathBuf,
        show_objects: bool,
    },
    GithubPublish {
        repository: PathBuf,
        transport: GithubTransport,
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
        Command::CacheTrim {
            repository,
            maximum_bytes,
        } => cache_trim(repository, maximum_bytes),
        Command::GithubConfigure {
            repository,
            target,
            direction,
            force_update_policy,
            publication_rules,
        } => github_configure(
            repository,
            target,
            direction,
            force_update_policy,
            publication_rules,
        ),
        Command::GithubInspect { repository } => github_inspect(repository),
        Command::GithubPublicationPlan {
            repository,
            show_objects,
        } => github_publication_plan(repository, show_objects),
        Command::GithubPublish {
            repository,
            transport,
        } => github_publish(repository, transport),
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
        "github" => parse_github(&arguments),
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
        "cache"
            if arguments.len() == 5
                && arguments[1].as_os_str() == OsStr::new("trim")
                && arguments[2].as_os_str() == OsStr::new("--max-bytes") =>
        {
            let maximum_bytes = arguments[3]
                .to_str()
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| Error::new(ErrorKind::InvalidInput, "cache byte limit is invalid"))?;
            Ok(Command::CacheTrim {
                repository: PathBuf::from(&arguments[4]),
                maximum_bytes,
            })
        }
        _ => Err(usage_error()),
    }
}

fn parse_github(arguments: &[OsString]) -> Result<Command> {
    if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("inspect") {
        return Ok(Command::GithubInspect {
            repository: PathBuf::from(&arguments[2]),
        });
    }
    if arguments.len() == 3 && arguments[1].as_os_str() == OsStr::new("plan") {
        return Ok(Command::GithubPublicationPlan {
            repository: PathBuf::from(&arguments[2]),
            show_objects: false,
        });
    }
    if arguments.len() == 4
        && arguments[1].as_os_str() == OsStr::new("plan")
        && arguments[2].as_os_str() == OsStr::new("--show-objects")
    {
        return Ok(Command::GithubPublicationPlan {
            repository: PathBuf::from(&arguments[3]),
            show_objects: true,
        });
    }
    if arguments.len() >= 3 && arguments[1].as_os_str() == OsStr::new("publish") {
        let repository = PathBuf::from(&arguments[2]);
        let mut transport = GithubTransport::Https;
        let mut apply = false;
        let mut transport_seen = false;
        let mut index = 3;
        while index < arguments.len() {
            let option = arguments[index].as_os_str();
            if option == OsStr::new("--apply") && !apply {
                apply = true;
                index += 1;
                continue;
            }
            if option == OsStr::new("--transport") && !transport_seen {
                let Some(value) = arguments.get(index + 1).and_then(|value| value.to_str()) else {
                    return Err(usage_error());
                };
                transport = value.parse()?;
                transport_seen = true;
                index += 2;
                continue;
            }
            return Err(usage_error());
        }
        if !apply {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub publication requires --apply; run github plan first",
            ));
        }
        return Ok(Command::GithubPublish {
            repository,
            transport,
        });
    }
    if arguments.len() < 9 || arguments[1].as_os_str() != OsStr::new("configure") {
        return Err(usage_error());
    }
    let repository = PathBuf::from(&arguments[2]);
    let mut target = None;
    let mut direction = None;
    let mut force_update_policy = GithubForceUpdatePolicy::Reject;
    let mut force_update_policy_seen = false;
    let mut publication_rules = Vec::new();
    let mut index = 3;
    while index < arguments.len() {
        let option = arguments[index].as_os_str();
        let value = arguments.get(index + 1).and_then(|value| value.to_str());
        let Some(value) = value else {
            return Err(usage_error());
        };
        match option {
            option if option == OsStr::new("--repository") && target.is_none() => {
                target = Some(value.parse()?);
            }
            option if option == OsStr::new("--direction") && direction.is_none() => {
                direction = Some(value.parse()?);
            }
            option if option == OsStr::new("--force-update") && !force_update_policy_seen => {
                force_update_policy = value.parse()?;
                force_update_policy_seen = true;
            }
            option if option == OsStr::new("--publish") => {
                publication_rules.push(value.parse()?);
            }
            _ => return Err(usage_error()),
        }
        index += 2;
    }
    let target = target.ok_or_else(usage_error)?;
    let direction = direction.ok_or_else(usage_error)?;
    if publication_rules.is_empty() {
        return Err(usage_error());
    }
    Ok(Command::GithubConfigure {
        repository,
        target,
        direction,
        force_update_policy,
        publication_rules,
    })
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

fn github_configure(
    repository: PathBuf,
    target: GithubRepository,
    direction: GithubMirrorDirection,
    force_update_policy: GithubForceUpdatePolicy,
    publication_rules: Vec<GithubPublicationRule>,
) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let configuration = GithubMirrorConfiguration::new(
        repository.id(),
        target,
        direction,
        force_update_policy,
        publication_rules,
    )?;
    repository.configure_github_mirror(&configuration)?;
    println!(
        "github_mirror_configured direction={} force_update_policy={} publication_rules={}",
        configuration.direction().as_str(),
        configuration.force_update_policy().as_str(),
        configuration.publication_rules().len(),
    );
    Ok(())
}

fn github_inspect(repository: PathBuf) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let configuration = repository
        .github_mirror_configuration()?
        .ok_or_else(|| Error::new(ErrorKind::NotFound, "GitHub mirror is not configured"))?;
    println!(
        "github_mirror_configured direction={} force_update_policy={} publication_rules={} checkpoints={}",
        configuration.direction().as_str(),
        configuration.force_update_policy().as_str(),
        configuration.publication_rules().len(),
        configuration.checkpoints().len(),
    );
    Ok(())
}

#[derive(Clone)]
struct GithubPublicationReference {
    local: yeokcham_core::RefName,
    remote: yeokcham_core::RefName,
    object_id: GitObjectId,
}

struct GithubPublicationPreview {
    references: Vec<GithubPublicationReference>,
    object_ids: BTreeSet<GitObjectId>,
}

fn github_publication_plan(repository: PathBuf, show_objects: bool) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let repository = LocalRepository::open(repository)?;
    let configuration = repository
        .github_mirror_configuration()?
        .ok_or_else(|| Error::new(ErrorKind::NotFound, "GitHub mirror is not configured"))?;
    let references = selected_github_publication_references(&repository, &configuration, limits)?;
    let export = create_temporary_github_export(&repository, limits)?;
    let result = github_publication_object_ids(&export, &references, limits).map(|object_ids| {
        GithubPublicationPreview {
            references,
            object_ids,
        }
    });
    let cleanup = remove_temporary_github_export(&export);
    let preview = match (result, cleanup) {
        (Err(error), _) => return Err(error),
        (Ok(_), Err(error)) => return Err(error),
        (Ok(preview), Ok(())) => preview,
    };
    println!(
        "github_publication_plan references={} objects={}",
        preview.references.len(),
        preview.object_ids.len(),
    );
    for reference in &preview.references {
        println!(
            "github_publication_reference local={} remote={} object={}",
            github_reference_text(&reference.local)?,
            github_reference_text(&reference.remote)?,
            reference.object_id,
        );
    }
    if show_objects {
        for object_id in &preview.object_ids {
            println!("github_publication_object={object_id}");
        }
    }
    Ok(())
}

fn github_publish(repository: PathBuf, transport: GithubTransport) -> Result<()> {
    let limits = GitImportLimits::initial()?;
    let repository = LocalRepository::open(repository)?;
    let configuration = repository
        .github_mirror_configuration()?
        .ok_or_else(|| Error::new(ErrorKind::NotFound, "GitHub mirror is not configured"))?;
    let references = selected_github_publication_references(&repository, &configuration, limits)?;
    let remote_url = github_remote_url(&configuration, transport);
    let export = create_temporary_github_export(&repository, limits)?;
    let result = github_publish_export(
        &repository,
        &configuration,
        &remote_url,
        &export,
        &references,
        limits,
    );
    let cleanup = remove_temporary_github_export(&export);
    let report = match (result, cleanup) {
        (Err(error), _) => return Err(error),
        (Ok(_), Err(error)) => return Err(error),
        (Ok(report), Ok(())) => report,
    };
    println!(
        "github_published transport={} references={} objects={}",
        transport.as_str(),
        report.references.len(),
        report.object_count,
    );
    for reference in &report.references {
        println!(
            "github_published_reference local={} remote={} object={}",
            github_reference_text(&reference.local)?,
            github_reference_text(&reference.remote)?,
            reference.object_id,
        );
    }
    Ok(())
}

struct GithubPublicationReport {
    references: Vec<GithubPublicationReference>,
    object_count: usize,
}

fn github_publish_export(
    repository: &LocalRepository,
    configuration: &GithubMirrorConfiguration,
    remote_url: &str,
    exported: &Path,
    references: &[GithubPublicationReference],
    limits: GitImportLimits,
) -> Result<GithubPublicationReport> {
    let object_count = github_publication_object_ids(exported, references, limits)?.len();
    let remote_refs = github_remote_refs(remote_url, references)?;
    let force_leases = github_force_leases(configuration, references, &remote_refs)?;
    push_github_refs(exported, remote_url, references, &force_leases)?;
    let confirmed_refs = github_remote_refs(remote_url, references)?;
    for reference in references {
        if confirmed_refs.get(&reference.remote) != Some(&reference.object_id) {
            return Err(Error::new(
                ErrorKind::Conflict,
                "GitHub did not confirm the published object ID",
            ));
        }
    }
    let observed_at_unix_seconds = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|_| Error::new(ErrorKind::Internal, "system clock is before Unix epoch"))?
        .as_secs();
    repository.record_github_mirror_checkpoints(
        references.iter().map(|reference| {
            (
                reference.local.clone(),
                yeokcham_core::GithubMirrorCheckpoint::new(
                    reference.object_id,
                    reference.remote.clone(),
                    reference.object_id,
                    observed_at_unix_seconds,
                ),
            )
        }),
        limits.ref_snapshot_limits(),
    )?;
    Ok(GithubPublicationReport {
        references: references.to_vec(),
        object_count,
    })
}

fn github_remote_url(
    configuration: &GithubMirrorConfiguration,
    transport: GithubTransport,
) -> String {
    let target = configuration.target();
    match transport {
        GithubTransport::Https => format!(
            "https://github.com/{}/{}.git",
            target.owner(),
            target.repository()
        ),
        GithubTransport::Ssh => format!(
            "git@github.com:{}/{}.git",
            target.owner(),
            target.repository()
        ),
    }
}

fn github_remote_refs(
    remote_url: &str,
    references: &[GithubPublicationReference],
) -> Result<BTreeMap<yeokcham_core::RefName, GitObjectId>> {
    let maximum_output_bytes = references
        .len()
        .checked_mul(512)
        .ok_or_else(|| Error::new(ErrorKind::Unsupported, "GitHub ref output is too large"))?;
    let mut command = github_git_command();
    command.args(["ls-remote", "--refs", remote_url]);
    for reference in references {
        command.arg(github_reference_text(&reference.remote)?);
    }
    let output = run_bounded_git_stdout(
        command,
        maximum_output_bytes,
        "GitHub refs could not be read",
    )?;
    let expected = references
        .iter()
        .map(|reference| reference.remote.clone())
        .collect::<BTreeSet<_>>();
    let mut remote_refs = BTreeMap::new();
    for line in output
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        let Some(separator) = line.iter().position(|byte| *byte == b'\t') else {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub refs have an invalid record",
            ));
        };
        let (id, reference) = (&line[..separator], &line[separator + 1..]);
        let id = std::str::from_utf8(id)
            .ok()
            .and_then(|id| id.parse::<GitObjectId>().ok())
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "GitHub refs have an invalid ID"))?;
        let reference = std::str::from_utf8(reference)
            .ok()
            .and_then(|reference| reference.parse().ok())
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "GitHub refs have an invalid reference",
                )
            })?;
        if !expected.contains(&reference) || remote_refs.insert(reference, id).is_some() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub refs have an unexpected record",
            ));
        }
    }
    Ok(remote_refs)
}

fn github_force_leases(
    configuration: &GithubMirrorConfiguration,
    references: &[GithubPublicationReference],
    remote_refs: &BTreeMap<yeokcham_core::RefName, GitObjectId>,
) -> Result<Vec<String>> {
    let mut leases = Vec::new();
    for reference in references {
        let Some(remote_object_id) = remote_refs.get(&reference.remote) else {
            continue;
        };
        if *remote_object_id == reference.object_id {
            continue;
        }
        if reference.remote.as_bytes().starts_with(b"refs/tags/") {
            return Err(Error::new(
                ErrorKind::Conflict,
                "GitHub publication refuses to replace an existing tag",
            ));
        }
        if configuration.force_update_policy() != GithubForceUpdatePolicy::RequireExactCheckpoint {
            continue;
        }
        let Some(checkpoint) = configuration.checkpoints().get(&reference.local) else {
            continue;
        };
        if checkpoint.remote_reference() != &reference.remote
            || checkpoint.remote_object_id() != *remote_object_id
        {
            continue;
        }
        leases.push(format!(
            "--force-with-lease={}:{}",
            github_reference_text(&reference.remote)?,
            remote_object_id,
        ));
    }
    Ok(leases)
}

fn push_github_refs(
    exported: &Path,
    remote_url: &str,
    references: &[GithubPublicationReference],
    force_leases: &[String],
) -> Result<()> {
    let maximum_output_bytes = references
        .len()
        .checked_mul(512)
        .ok_or_else(|| Error::new(ErrorKind::Unsupported, "GitHub push output is too large"))?;
    let mut command = github_git_command();
    command
        .args([
            "-c",
            "push.default=nothing",
            "-c",
            "push.followTags=false",
            "-c",
            "push.recurseSubmodules=no",
            "--git-dir",
        ])
        .arg(exported)
        .args(["push", "--atomic", "--no-verify", "--porcelain"]);
    for lease in force_leases {
        command.arg(lease);
    }
    command.arg(remote_url);
    for reference in references {
        command.arg(format!(
            "{}:{}",
            github_reference_text(&reference.local)?,
            github_reference_text(&reference.remote)?,
        ));
    }
    run_bounded_git_stdout(
        command,
        maximum_output_bytes,
        "GitHub push could not be completed",
    )?;
    Ok(())
}

fn selected_github_publication_references(
    repository: &LocalRepository,
    configuration: &GithubMirrorConfiguration,
    limits: GitImportLimits,
) -> Result<Vec<GithubPublicationReference>> {
    if configuration.direction() == GithubMirrorDirection::PullOnly {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "GitHub mirror direction does not allow publication",
        ));
    }
    let state = repository
        .resolve_ref_state(limits.ref_snapshot_limits())?
        .ok_or_else(|| {
            Error::new(
                ErrorKind::NotFound,
                "repository has no acknowledged ref state",
            )
        })?;
    let references = state
        .regular_refs()
        .iter()
        .filter(|(reference, _)| configuration.selects_reference(reference))
        .map(|(reference, object_id)| {
            github_reference_text(reference)?;
            Ok(GithubPublicationReference {
                local: reference.clone(),
                remote: reference.clone(),
                object_id: *object_id,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    if references.is_empty() {
        return Err(Error::new(
            ErrorKind::NotFound,
            "GitHub mirror has no selected acknowledged refs",
        ));
    }
    Ok(references)
}

fn create_temporary_github_export(
    repository: &LocalRepository,
    limits: GitImportLimits,
) -> Result<PathBuf> {
    for _ in 0..16 {
        let path = env::temp_dir().join(format!("yeokcham-github-export-{}", uuid::Uuid::new_v4()));
        match repository.export_loose_objects(&path, limits.export_limits()?) {
            Ok(_) => return Ok(path),
            Err(error) if error.kind() == ErrorKind::Conflict => continue,
            Err(error) => {
                let _ = fs::remove_dir_all(&path);
                return Err(error);
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "temporary GitHub export path could not be allocated",
    ))
}

fn remove_temporary_github_export(path: &Path) -> Result<()> {
    fs::remove_dir_all(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "temporary GitHub export could not be removed",
            error,
        )
    })
}

fn github_publication_object_ids(
    exported: &Path,
    references: &[GithubPublicationReference],
    limits: GitImportLimits,
) -> Result<BTreeSet<GitObjectId>> {
    let maximum_output_bytes = limits
        .maximum_objects()
        .checked_mul(64)
        .ok_or_else(|| {
            Error::new(
                ErrorKind::Unsupported,
                "GitHub publication output is too large",
            )
        })?
        .min(MAXIMUM_GITHUB_GIT_OUTPUT_BYTES);
    let mut command = github_git_command();
    command
        .arg("--git-dir")
        .arg(exported)
        .args(["rev-list", "--objects", "--no-object-names"]);
    for reference in references {
        command.arg(github_reference_text(&reference.local)?);
    }
    let output = run_bounded_git_stdout(
        command,
        maximum_output_bytes,
        "GitHub publication object walk could not be completed",
    )?;
    let mut object_ids = BTreeSet::new();
    for line in output
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        let id = std::str::from_utf8(line)
            .ok()
            .and_then(|line| line.parse::<GitObjectId>().ok())
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "GitHub publication object walk returned an invalid object ID",
                )
            })?;
        if object_ids.len() == limits.maximum_objects() && !object_ids.contains(&id) {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub publication object count exceeds the limit",
            ));
        }
        object_ids.insert(id);
    }
    for reference in references {
        if object_ids.len() == limits.maximum_objects()
            && !object_ids.contains(&reference.object_id)
        {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub publication object count exceeds the limit",
            ));
        }
        object_ids.insert(reference.object_id);
    }
    if object_ids.is_empty() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "GitHub publication object walk returned no objects",
        ));
    }
    Ok(object_ids)
}

fn github_reference_text(reference: &yeokcham_core::RefName) -> Result<&str> {
    std::str::from_utf8(reference.as_bytes()).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "GitHub publication does not support a non-UTF-8 reference",
        )
    })
}

fn github_git_command() -> ProcessCommand {
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
        "GIT_CONFIG_PARAMETERS",
        "GIT_ASKPASS",
        "GIT_SSH",
        "GIT_SSH_COMMAND",
        "GIT_SSH_VARIANT",
        "SSH_ASKPASS",
    ] {
        command.env_remove(variable);
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command
}

fn run_bounded_git_stdout(
    mut command: ProcessCommand,
    maximum_bytes: usize,
    failure_message: &'static str,
) -> Result<Vec<u8>> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|error| Error::with_source(ErrorKind::Io, failure_message, error))?;
    let mut stdout = child.stdout.take().ok_or_else(|| {
        Error::new(
            ErrorKind::Internal,
            "GitHub publication command has no standard output",
        )
    })?;
    let mut output = Vec::new();
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        let capacity = maximum_bytes
            .checked_add(1)
            .and_then(|maximum| maximum.checked_sub(output.len()))
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "GitHub publication command output exceeds the byte limit",
                )
            })?;
        let read_length = capacity.min(buffer.len());
        let read = stdout
            .read(&mut buffer[..read_length])
            .map_err(|error| Error::with_source(ErrorKind::Io, failure_message, error))?;
        if read == 0 {
            break;
        }
        output.extend_from_slice(&buffer[..read]);
        if output.len() > maximum_bytes {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub publication command output exceeds the byte limit",
            ));
        }
    }
    let status = child
        .wait()
        .map_err(|error| Error::with_source(ErrorKind::Io, failure_message, error))?;
    if !status.success() {
        return Err(Error::new(ErrorKind::Io, failure_message));
    }
    Ok(output)
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

struct PackCacheTrimCandidate {
    path: PathBuf,
    byte_count: u64,
    access_time: SystemTime,
}

fn cache_trim(repository: PathBuf, maximum_bytes: u64) -> Result<()> {
    let repository = LocalRepository::open(repository)?;
    let entries = pack_cache_entries(&repository)?;
    let mut total_bytes = 0_u64;
    let mut candidates = Vec::with_capacity(entries.len());
    for entry in &entries {
        let usage = pack_cache_entry_statistics(entry)?;
        total_bytes = total_bytes
            .checked_add(usage.byte_count)
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache byte count overflows"))?;
        candidates.push(PackCacheTrimCandidate {
            path: entry.path.clone(),
            byte_count: usage.byte_count,
            access_time: pack_cache_access_time(entry)?,
        });
    }
    candidates.sort_by(|left, right| {
        left.access_time
            .cmp(&right.access_time)
            .then_with(|| left.path.cmp(&right.path))
    });
    let mut removed_entries = 0_usize;
    for candidate in candidates {
        if total_bytes <= maximum_bytes {
            break;
        }
        remove_pack_cache_entry(&candidate.path)?;
        total_bytes = total_bytes
            .checked_sub(candidate.byte_count)
            .ok_or_else(|| Error::new(ErrorKind::Internal, "pack cache byte count underflows"))?;
        removed_entries = removed_entries.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::Unsupported, "pack cache removal count overflows")
        })?;
    }
    if removed_entries != 0 {
        let packs = repository.path().join("cache/packs");
        File::open(packs)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "pack cache trimming could not be synchronized",
                    error,
                )
            })?;
    }
    println!(
        "trimmed_pack_cache_entries={} pack_cache_bytes={total_bytes}",
        removed_entries,
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
        let entry_statistics = pack_cache_entry_statistics(entry)?;
        statistics.entry_count = statistics
            .entry_count
            .checked_add(entry_statistics.entry_count)
            .ok_or_else(|| {
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
        statistics.file_count = statistics
            .file_count
            .checked_add(entry_statistics.file_count)
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache file count overflows"))?;
        statistics.byte_count = statistics
            .byte_count
            .checked_add(entry_statistics.byte_count)
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache byte count overflows"))?;
        statistics.scanned_path_count = statistics
            .scanned_path_count
            .checked_add(entry_statistics.scanned_path_count)
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "pack cache path count overflows"))?;
        if statistics.scanned_path_count > MAXIMUM_CACHE_PATHS {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "pack cache contains too many paths",
            ));
        }
    }
    Ok(statistics)
}

fn pack_cache_entry_statistics(entry: &PackCacheEntry) -> Result<PackCacheStatistics> {
    let mut statistics = PackCacheStatistics {
        entry_count: 1,
        ..PackCacheStatistics::default()
    };
    collect_pack_cache_usage(&entry.path, &mut statistics, 0)?;
    Ok(statistics)
}

fn pack_cache_access_time(entry: &PackCacheEntry) -> Result<SystemTime> {
    let access = entry.path.join(".yeokcham-last-used");
    match fs::symlink_metadata(&access) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(Error::new(
                ErrorKind::CorruptData,
                "pack cache access record is invalid",
            ))
        }
        Ok(metadata) => metadata.modified().map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "pack cache access record could not be inspected",
                error,
            )
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::symlink_metadata(&entry.path)
            .and_then(|metadata| metadata.modified())
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "pack cache entry could not be inspected",
                    error,
                )
            }),
        Err(error) => Err(Error::with_source(
            ErrorKind::Io,
            "pack cache access record could not be inspected",
            error,
        )),
    }
}

fn remove_pack_cache_entry(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
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
    fs::remove_dir_all(path).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "pack cache entry could not be removed",
            error,
        )
    })
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
        "usage:\n  yeokcham init --from-git <source-git-repo> <yeokcham-repo> [--chunked-blob-minimum <bytes>]\n  yeokcham sync --from-git <source-git-repo> <yeokcham-repo> --device <device-id>\n  yeokcham verify <yeokcham-repo>\n  yeokcham export-git <yeokcham-repo> <destination-git-repo>\n  yeokcham inspect object <yeokcham-repo> <git-object-id>\n  yeokcham inspect storage <yeokcham-repo>\n  yeokcham inspect refs <yeokcham-repo>\n  yeokcham cache inspect|verify|clear <yeokcham-repo>\n  yeokcham cache trim --max-bytes <bytes> <yeokcham-repo>\n  yeokcham github configure <yeokcham-repo> --repository <owner/repository> --direction <publish-only|pull-only|bidirectional-fast-forward|manual> [--force-update <reject|require-exact-checkpoint>] --publish <heads|tags|refs/heads/*|refs/tags/*> [--publish ...]\n  yeokcham github inspect <yeokcham-repo>\n  yeokcham github plan [--show-objects] <yeokcham-repo>\n  yeokcham github publish <yeokcham-repo> --apply [--transport <https|ssh>]\n  yeokcham key create-export --passphrase-stdin <yeokcham-repo> <recovery-key-export>\n  yeokcham drive auth --client-id <google-desktop-client-id> [--redirect-port <port>]\n  yeokcham drive init --client-id <google-desktop-client-id>\n  yeokcham drive backup|push --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <yeokcham-repo>\n  yeokcham drive restore|clone --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <destination>\n  yeokcham drive verify --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin\n  yeokcham drive journal inspect --client-id <google-desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --root-key <root-ed25519-public-key-hex> --passphrase-stdin <yeokcham-repo>"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = env::temp_dir().join(format!("yeokcham-cli-unit-{}", uuid::Uuid::new_v4()));
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

    fn run_test_git(directory: &Path, arguments: &[&str]) {
        let output = ProcessCommand::new("git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .output()
            .expect("run Git");
        assert!(
            output.status.success(),
            "Git command must succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn publishes_only_selected_refs_confirms_them_and_records_checkpoints() {
        let temporary = TestDirectory::new();
        let source = temporary.path().join("source");
        let store = temporary.path().join("store");
        let remote = temporary.path().join("remote.git");
        fs::create_dir(&source).expect("create source");
        run_test_git(&source, &["init", "-b", "main"]);
        run_test_git(&source, &["config", "user.name", "Yeokcham Test"]);
        run_test_git(
            &source,
            &["config", "user.email", "yeokcham-test@example.invalid"],
        );
        fs::write(source.join("selected.txt"), b"selected\n").expect("write selected");
        run_test_git(&source, &["add", "selected.txt"]);
        run_test_git(&source, &["commit", "-m", "selected"]);
        run_test_git(&source, &["tag", "-a", "v1.0", "-m", "version one"]);
        run_test_git(&source, &["switch", "-c", "private"]);
        fs::write(source.join("private.txt"), b"private\n").expect("write private");
        run_test_git(&source, &["add", "private.txt"]);
        run_test_git(&source, &["commit", "-m", "private"]);
        run_test_git(&source, &["switch", "main"]);
        let output = ProcessCommand::new("git")
            .args(["init", "--bare"])
            .arg(&remote)
            .output()
            .expect("create remote");
        assert!(output.status.success());

        let limits = GitImportLimits::initial().expect("limits");
        let repository = LocalRepository::create(&store).expect("create store");
        repository
            .import_git_repository(&GitRepository::open(&source).expect("open source"), limits)
            .expect("import source");
        let configuration = GithubMirrorConfiguration::new(
            repository.id(),
            "yeokcham/example".parse().expect("target"),
            GithubMirrorDirection::PublishOnly,
            GithubForceUpdatePolicy::Reject,
            [
                "refs/heads/main".parse().expect("main rule"),
                GithubPublicationRule::Tags,
            ],
        )
        .expect("configuration");
        repository
            .configure_github_mirror(&configuration)
            .expect("configure mirror");
        let references =
            selected_github_publication_references(&repository, &configuration, limits)
                .expect("selected references");
        assert_eq!(references.len(), 2);
        let export = create_temporary_github_export(&repository, limits).expect("export");
        let report = github_publish_export(
            &repository,
            &configuration,
            remote.to_str().expect("UTF-8 remote path"),
            &export,
            &references,
            limits,
        )
        .expect("publish");
        remove_temporary_github_export(&export).expect("remove export");
        assert_eq!(report.references.len(), 2);
        assert!(report.object_count > 0);

        let remote_state = GitRepository::open(&remote)
            .expect("open remote")
            .ref_state()
            .expect("remote refs");
        assert!(
            remote_state
                .regular_refs()
                .contains_key(&"refs/heads/main".parse().expect("main"))
        );
        assert!(
            remote_state
                .regular_refs()
                .contains_key(&"refs/tags/v1.0".parse().expect("tag"))
        );
        assert!(
            !remote_state
                .regular_refs()
                .contains_key(&"refs/heads/private".parse().expect("private"))
        );
        let checkpoints = repository
            .github_mirror_configuration()
            .expect("read configuration")
            .expect("configuration")
            .checkpoints()
            .clone();
        assert_eq!(checkpoints.len(), 2);
        for reference in &references {
            let checkpoint = checkpoints.get(&reference.local).expect("checkpoint");
            assert_eq!(checkpoint.remote_reference(), &reference.remote);
            assert_eq!(checkpoint.local_object_id(), reference.object_id);
            assert_eq!(checkpoint.remote_object_id(), reference.object_id);
        }
    }

    #[test]
    fn parses_github_mirror_configuration_and_rejects_ambiguous_policy() {
        let command = parse_command(
            [
                "github",
                "configure",
                "repository",
                "--repository",
                "yeokcham/example",
                "--direction",
                "bidirectional-fast-forward",
                "--force-update",
                "require-exact-checkpoint",
                "--publish",
                "heads",
                "--publish",
                "refs/tags/v1.0",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("GitHub configuration");
        assert!(matches!(
            command,
            Command::GithubConfigure {
                repository,
                target,
                direction: GithubMirrorDirection::BidirectionalFastForward,
                force_update_policy: GithubForceUpdatePolicy::RequireExactCheckpoint,
                publication_rules,
            } if repository == PathBuf::from("repository")
                && target.owner() == "yeokcham"
                && target.repository() == "example"
                && publication_rules.len() == 2
        ));
        let inspect = parse_command(
            ["github", "inspect", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("GitHub inspection");
        assert!(matches!(inspect, Command::GithubInspect { .. }));
        let plan = parse_command(
            ["github", "plan", "--show-objects", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("GitHub publication plan");
        assert!(matches!(
            plan,
            Command::GithubPublicationPlan {
                repository,
                show_objects: true,
            } if repository == PathBuf::from("repository")
        ));
        let publish = parse_command(
            [
                "github",
                "publish",
                "repository",
                "--apply",
                "--transport",
                "ssh",
            ]
            .map(OsString::from)
            .to_vec(),
        )
        .expect("GitHub publication");
        assert!(matches!(
            publish,
            Command::GithubPublish {
                repository,
                transport: GithubTransport::Ssh,
            } if repository == PathBuf::from("repository")
        ));
        let error = parse_command(
            ["github", "publish", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect_err("publication must require explicit application");
        assert_eq!(
            error.public_message(),
            "GitHub publication requires --apply; run github plan first"
        );
        assert!(
            parse_command(
                [
                    "github",
                    "configure",
                    "repository",
                    "--repository",
                    "yeokcham/example",
                    "--direction",
                    "manual",
                    "--direction",
                    "publish-only",
                    "--publish",
                    "heads",
                ]
                .map(OsString::from)
                .to_vec(),
            )
            .is_err()
        );
    }

    #[test]
    fn force_policy_uses_only_an_exact_matching_checkpoint_and_never_replaces_tags() {
        let local: yeokcham_core::RefName = "refs/heads/main".parse().expect("local ref");
        let remote: yeokcham_core::RefName = "refs/heads/main".parse().expect("remote ref");
        let checkpoint_id = GitObjectId::from_bytes([1; GitObjectId::BYTE_LENGTH]);
        let local_object_id = GitObjectId::from_bytes([2; GitObjectId::BYTE_LENGTH]);
        let changed_remote_id = GitObjectId::from_bytes([3; GitObjectId::BYTE_LENGTH]);
        let mut configuration = GithubMirrorConfiguration::new(
            yeokcham_core::RepositoryId::generate(),
            "yeokcham/example".parse().expect("target"),
            GithubMirrorDirection::PublishOnly,
            GithubForceUpdatePolicy::RequireExactCheckpoint,
            [GithubPublicationRule::Exact(local.clone())],
        )
        .expect("configuration");
        configuration
            .record_checkpoint(
                local.clone(),
                yeokcham_core::GithubMirrorCheckpoint::new(
                    checkpoint_id,
                    remote.clone(),
                    checkpoint_id,
                    1,
                ),
            )
            .expect("checkpoint");
        let reference = GithubPublicationReference {
            local: local.clone(),
            remote: remote.clone(),
            object_id: local_object_id,
        };
        let matching_remote = BTreeMap::from([(remote.clone(), checkpoint_id)]);
        assert_eq!(
            github_force_leases(&configuration, &[reference.clone()], &matching_remote)
                .expect("matching checkpoint lease"),
            vec![format!("--force-with-lease={remote}:{checkpoint_id}")]
        );
        let changed_remote = BTreeMap::from([(remote, changed_remote_id)]);
        assert!(
            github_force_leases(&configuration, &[reference], &changed_remote)
                .expect("changed checkpoint must not receive a force lease")
                .is_empty()
        );

        let tag: yeokcham_core::RefName = "refs/tags/v1.0".parse().expect("tag ref");
        let tag_configuration = GithubMirrorConfiguration::new(
            yeokcham_core::RepositoryId::generate(),
            "yeokcham/example".parse().expect("target"),
            GithubMirrorDirection::PublishOnly,
            GithubForceUpdatePolicy::RequireExactCheckpoint,
            [GithubPublicationRule::Tags],
        )
        .expect("tag configuration");
        let error = github_force_leases(
            &tag_configuration,
            &[GithubPublicationReference {
                local: tag.clone(),
                remote: tag.clone(),
                object_id: local_object_id,
            }],
            &BTreeMap::from([(tag, checkpoint_id)]),
        )
        .expect_err("tag replacement must fail");
        assert_eq!(error.kind(), ErrorKind::Conflict);
    }

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
        let trim = parse_command(
            ["cache", "trim", "--max-bytes", "4096", "repository"]
                .map(OsString::from)
                .to_vec(),
        )
        .expect("cache trim");
        assert!(matches!(
            trim,
            Command::CacheTrim {
                repository,
                maximum_bytes: 4096,
            } if repository == PathBuf::from("repository")
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
