use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use yeokcham_core::{
    DEFAULT_SPARSE_PREFETCH_PROCESS_BYTES, DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES, DaemonMessage,
    DaemonProtocolFrame, DaemonRequest, DaemonResponse, Error, ErrorKind, FilesystemMonitor,
    FilesystemMonitorLimits, GitImportLimits, LocalRepository, MAXIMUM_DAEMON_FRAME_BYTES, Result,
    SharedObjectCache, SparsePrefetchPolicy, SparsePrefetchSelection,
};

const SOCKET_NAME: &str = "yeokcham-daemon.sock";
const USAGE: &str = "usage: yeokcham-daemon [--socket <path>] [--repository <yeokcham-repo> --sparse-path <relative-path>... [--prefetch-byte-budget <bytes>]]";
const PREFETCH_POLL_INTERVAL: Duration = Duration::from_secs(1);
const PREFETCH_MONITOR_DEPTH: usize = 2;
const PREFETCH_MONITOR_MAXIMUM_DIRECTORIES: usize = 16;
const PREFETCH_MONITOR_MAXIMUM_ENTRIES: usize = 1_000_000;
const PREFETCH_MONITOR_MAXIMUM_ENTRIES_PER_DIRECTORY: usize = 1_000_000;

struct DaemonOptions {
    socket: PathBuf,
    prefetch: Option<DaemonPrefetchConfiguration>,
}

struct DaemonPrefetchConfiguration {
    repository: PathBuf,
    selection: SparsePrefetchSelection,
}

struct DaemonPrefetcher {
    repository: LocalRepository,
    selection: SparsePrefetchSelection,
    cache: SharedObjectCache,
    monitors: [FilesystemMonitor; 2],
    pending: bool,
}

impl DaemonPrefetcher {
    fn new(configuration: DaemonPrefetchConfiguration) -> Result<Self> {
        let repository = LocalRepository::open(configuration.repository)?;
        let limits = FilesystemMonitorLimits::new(
            PREFETCH_MONITOR_DEPTH,
            PREFETCH_MONITOR_MAXIMUM_DIRECTORIES,
            PREFETCH_MONITOR_MAXIMUM_ENTRIES,
            PREFETCH_MONITOR_MAXIMUM_ENTRIES_PER_DIRECTORY,
        )?;
        let monitors = [
            FilesystemMonitor::new(repository.path().join("manifests/refs"), limits)?,
            FilesystemMonitor::new(repository.path().join("journals/refs"), limits)?,
        ];
        let cache = SharedObjectCache::new(
            usize::try_from(DEFAULT_SPARSE_PREFETCH_PROCESS_BYTES).map_err(|_| {
                Error::new(
                    ErrorKind::Unsupported,
                    "daemon sparse prefetch cache exceeds this platform",
                )
            })?,
        )?;
        let mut prefetcher = Self {
            repository,
            selection: configuration.selection,
            cache,
            monitors,
            pending: true,
        };
        prefetcher.refresh()?;
        Ok(prefetcher)
    }

    fn refresh(&mut self) -> Result<()> {
        for monitor in &mut self.monitors {
            if !monitor.poll()?.is_empty() {
                self.pending = true;
            }
        }
        if self.pending {
            self.repository.prefetch_current_sparse_paths(
                &self.selection,
                GitImportLimits::initial()?,
                &self.cache,
            )?;
            self.pending = false;
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct DaemonControl(Arc<AtomicBool>);

impl DaemonControl {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }
    fn request_shutdown(&self) {
        self.0.store(true, Ordering::Release);
    }
    fn is_shutdown_requested(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

struct DaemonServer {
    listener: UnixListener,
    socket: PathBuf,
    control: DaemonControl,
    prefetcher: Option<DaemonPrefetcher>,
}

impl DaemonServer {
    fn bind(
        socket: &Path,
        control: DaemonControl,
        prefetcher: Option<DaemonPrefetcher>,
    ) -> Result<Self> {
        validate_socket_parent(socket)?;
        match fs::symlink_metadata(socket) {
            Ok(_) => {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "daemon socket path already exists",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "daemon socket path could not be inspected",
                    error,
                ));
            }
        }
        let listener = UnixListener::bind(socket).map_err(|error| {
            Error::with_source(ErrorKind::Io, "daemon socket could not be bound", error)
        })?;
        fs::set_permissions(socket, fs::Permissions::from_mode(0o600)).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "daemon socket permissions could not be set",
                error,
            )
        })?;
        listener.set_nonblocking(true).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "daemon socket could not be configured",
                error,
            )
        })?;
        Ok(Self {
            listener,
            socket: socket.to_path_buf(),
            control,
            prefetcher,
        })
    }

    fn serve(&mut self) -> Result<()> {
        let mut last_prefetch_poll = Instant::now();
        while !self.control.is_shutdown_requested() {
            if last_prefetch_poll.elapsed() >= PREFETCH_POLL_INTERVAL {
                if let Some(prefetcher) = &mut self.prefetcher {
                    prefetcher.refresh()?;
                }
                last_prefetch_poll = Instant::now();
            }
            match self.listener.accept() {
                Ok((stream, _)) => {
                    let _ = handle_stream(stream, &self.control);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10))
                }
                Err(error) => {
                    return Err(Error::with_source(
                        ErrorKind::Io,
                        "daemon socket could not accept a connection",
                        error,
                    ));
                }
            }
        }
        Ok(())
    }
}

impl Drop for DaemonServer {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.socket);
    }
}

fn handle_stream(mut stream: UnixStream, control: &DaemonControl) -> Result<()> {
    stream.set_nonblocking(false).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "daemon stream could not be configured",
            error,
        )
    })?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "daemon stream could not be configured",
                error,
            )
        })?;
    let frame = read_frame(&mut stream)?;
    let shutdown = matches!(
        frame.message(),
        DaemonMessage::Request(DaemonRequest::Shutdown)
    );
    let response = match frame.message() {
        DaemonMessage::Request(DaemonRequest::Ping) => {
            DaemonProtocolFrame::response(frame.request_id(), DaemonResponse::Pong)?
        }
        DaemonMessage::Request(DaemonRequest::Shutdown) => {
            DaemonProtocolFrame::response(frame.request_id(), DaemonResponse::ShutdownAccepted)?
        }
        DaemonMessage::Response(_) => {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "daemon client sent a response frame",
            ));
        }
    };
    stream.write_all(&response.encode()).map_err(|error| {
        Error::with_source(ErrorKind::Io, "daemon response could not be written", error)
    })?;
    stream.flush().map_err(|error| {
        Error::with_source(ErrorKind::Io, "daemon response could not be written", error)
    })?;
    if shutdown {
        control.request_shutdown();
    }
    Ok(())
}

fn read_frame(stream: &mut UnixStream) -> Result<DaemonProtocolFrame> {
    let mut prefix = [0; 4];
    stream.read_exact(&mut prefix).map_err(|error| {
        Error::with_source(ErrorKind::Io, "daemon request could not be read", error)
    })?;
    let length = usize::try_from(u32::from_be_bytes(prefix))
        .map_err(|_| Error::new(ErrorKind::CorruptData, "daemon frame length is invalid"))?;
    if length > MAXIMUM_DAEMON_FRAME_BYTES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "daemon frame exceeds the maximum size",
        ));
    }
    let mut encoded = Vec::with_capacity(4 + length);
    encoded.extend_from_slice(&prefix);
    encoded.resize(4 + length, 0);
    stream.read_exact(&mut encoded[4..]).map_err(|error| {
        Error::with_source(ErrorKind::Io, "daemon request could not be read", error)
    })?;
    DaemonProtocolFrame::decode(&encoded)
}

fn validate_socket_parent(socket: &Path) -> Result<()> {
    let parent = socket
        .parent()
        .ok_or_else(|| Error::new(ErrorKind::InvalidInput, "daemon socket path has no parent"))?;
    let metadata = fs::symlink_metadata(parent).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "daemon socket parent could not be inspected",
            error,
        )
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "daemon socket parent is not private",
        ));
    }
    Ok(())
}

fn default_socket() -> Result<PathBuf> {
    let directory = env::var_os("TMPDIR").map(PathBuf::from).ok_or_else(|| {
        Error::new(
            ErrorKind::NotFound,
            "per-user daemon runtime directory is unavailable",
        )
    })?;
    Ok(directory.join(SOCKET_NAME))
}

fn parse_options(arguments: &[OsString]) -> Result<DaemonOptions> {
    let mut socket = None;
    let mut repository = None;
    let mut sparse_paths = Vec::new();
    let mut byte_budget = DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES;
    let mut prefetch_requested = false;
    let mut index = 0usize;
    while index < arguments.len() {
        let flag = &arguments[index];
        index = index.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::InvalidInput, "daemon argument count overflows")
        })?;
        let value = arguments
            .get(index)
            .ok_or_else(|| Error::new(ErrorKind::InvalidInput, USAGE))?;
        index = index.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::InvalidInput, "daemon argument count overflows")
        })?;
        if flag == "--socket" {
            if socket.replace(PathBuf::from(value)).is_some() {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    "daemon socket option is duplicated",
                ));
            }
        } else if flag == "--repository" {
            prefetch_requested = true;
            if repository.replace(PathBuf::from(value)).is_some() {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    "daemon repository option is duplicated",
                ));
            }
        } else if flag == "--sparse-path" {
            prefetch_requested = true;
            sparse_paths.push(PathBuf::from(value));
        } else if flag == "--prefetch-byte-budget" {
            prefetch_requested = true;
            byte_budget = value
                .to_str()
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::InvalidInput,
                        "daemon prefetch byte budget is invalid",
                    )
                })?
                .parse()
                .map_err(|_| {
                    Error::new(
                        ErrorKind::InvalidInput,
                        "daemon prefetch byte budget is invalid",
                    )
                })?;
        } else {
            return Err(Error::new(ErrorKind::InvalidInput, USAGE));
        }
    }
    let prefetch = if !prefetch_requested {
        None
    } else if let (Some(repository), false) = (repository, sparse_paths.is_empty()) {
        Some(DaemonPrefetchConfiguration {
            repository,
            selection: SparsePrefetchSelection::new(
                sparse_paths,
                byte_budget,
                SparsePrefetchPolicy::default(),
            )?,
        })
    } else {
        return Err(Error::new(ErrorKind::InvalidInput, USAGE));
    };
    Ok(DaemonOptions {
        socket: socket.map(Ok).unwrap_or_else(default_socket)?,
        prefetch,
    })
}

fn run() -> Result<()> {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    let options = parse_options(&arguments)?;
    let control = DaemonControl::new();
    let prefetcher = options.prefetch.map(DaemonPrefetcher::new).transpose()?;
    DaemonServer::bind(&options.socket, control, prefetcher)?.serve()
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error[{}]: {error}", error.code());
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::PermissionsExt,
        process::Command,
        thread,
        time::{SystemTime, UNIX_EPOCH},
    };
    use yeokcham_core::{GitRepository, SparsePrefetchPolicy};

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

    #[test]
    fn parses_explicit_current_sparse_prefetch_configuration() {
        let options = parse_options(&[
            OsString::from("--socket"),
            OsString::from("/private/socket"),
            OsString::from("--repository"),
            OsString::from("/private/repository"),
            OsString::from("--sparse-path"),
            OsString::from("app"),
            OsString::from("--sparse-path"),
            OsString::from("docs/guide"),
            OsString::from("--prefetch-byte-budget"),
            OsString::from("4096"),
        ])
        .expect("options");
        let prefetch = options.prefetch.expect("prefetch configuration");
        assert_eq!(options.socket, PathBuf::from("/private/socket"));
        assert_eq!(prefetch.repository, PathBuf::from("/private/repository"));
        assert_eq!(prefetch.selection.byte_budget(), 4096);
        assert_eq!(
            prefetch.selection.sparse_paths(),
            [PathBuf::from("app"), PathBuf::from("docs/guide")]
        );
    }

    #[test]
    fn rejects_incomplete_or_unsupported_prefetch_options() {
        for arguments in [
            vec![OsString::from("--repository"), OsString::from("repository")],
            vec![OsString::from("--sparse-path"), OsString::from("app")],
            vec![
                OsString::from("--prefetch-byte-budget"),
                OsString::from("4096"),
            ],
            vec![OsString::from("--unsupported"), OsString::from("value")],
        ] {
            assert!(parse_options(&arguments).is_err());
        }
    }

    #[test]
    fn prefetches_an_explicit_current_sparse_selection_at_startup() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let directory = env::temp_dir().join(format!(
            "yeokcham-daemon-prefetch-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&directory).expect("directory");
        let source_path = directory.join("source");
        let repository_path = directory.join("repository");
        fs::create_dir(&source_path).expect("source");
        run_git_in(&source_path, &["init", "-b", "main"]);
        run_git_in(&source_path, &["config", "user.name", "Yeokcham Test"]);
        run_git_in(
            &source_path,
            &["config", "user.email", "yeokcham-test@example.invalid"],
        );
        fs::create_dir(source_path.join("app")).expect("app directory");
        fs::write(source_path.join("app/main.rs"), b"selected\n").expect("selected blob");
        fs::write(source_path.join("README.md"), b"excluded\n").expect("excluded blob");
        run_git_in(&source_path, &["add", "."]);
        run_git_in(&source_path, &["commit", "-m", "fixture"]);
        let limits = GitImportLimits::initial().expect("limits");
        LocalRepository::create(&repository_path)
            .expect("repository")
            .import_git_repository(
                &GitRepository::open(&source_path).expect("source repository"),
                limits,
            )
            .expect("import source");
        let selection = SparsePrefetchSelection::new(
            [PathBuf::from("app")],
            DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES,
            SparsePrefetchPolicy::default(),
        )
        .expect("selection");

        let mut prefetcher = DaemonPrefetcher::new(DaemonPrefetchConfiguration {
            repository: repository_path,
            selection,
        })
        .expect("prefetcher");

        assert!(prefetcher.cache.object_count() >= 4);
        assert!(!prefetcher.pending);
        prefetcher.refresh().expect("unchanged refresh");
        let snapshot = fs::read_dir(prefetcher.repository.path().join("manifests/refs"))
            .expect("ref snapshot directory")
            .next()
            .expect("ref snapshot entry")
            .expect("ref snapshot entry result")
            .path();
        let snapshot_bytes = fs::read(&snapshot).expect("read ref snapshot");
        prefetcher.cache.clear();
        thread::sleep(Duration::from_millis(10));
        fs::write(&snapshot, snapshot_bytes).expect("refresh ref snapshot metadata");
        prefetcher.refresh().expect("changed refresh");
        assert!(prefetcher.cache.object_count() >= 4);
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn serves_ping_and_orderly_shutdown_over_a_private_unix_socket() {
        let directory = env::temp_dir().join(format!("yeokcham-daemon-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).expect("directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).expect("permissions");
        let socket = directory.join("daemon.sock");
        let control = DaemonControl::new();
        let mut server = DaemonServer::bind(&socket, control.clone(), None).expect("bind");
        let thread = thread::spawn(move || server.serve().expect("serve"));
        for request in [DaemonRequest::Ping, DaemonRequest::Shutdown] {
            let mut stream = UnixStream::connect(&socket).expect("connect");
            stream
                .write_all(
                    &DaemonProtocolFrame::request(9, request)
                        .expect("request")
                        .encode(),
                )
                .expect("write");
            let response = read_frame(&mut stream).expect("response");
            assert_eq!(response.request_id(), 9);
        }
        thread.join().expect("join");
        assert!(control.is_shutdown_requested());
        assert!(!socket.exists());
        let _ = fs::remove_dir_all(directory);
    }
}
