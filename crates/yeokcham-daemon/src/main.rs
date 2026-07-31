use std::{
    env, fs,
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
    time::Duration,
};

use yeokcham_core::{
    DaemonMessage, DaemonProtocolFrame, DaemonRequest, DaemonResponse, Error, ErrorKind,
    MAXIMUM_DAEMON_FRAME_BYTES, Result,
};

const SOCKET_NAME: &str = "yeokcham-daemon.sock";

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
}

impl DaemonServer {
    fn bind(socket: &Path, control: DaemonControl) -> Result<Self> {
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
        })
    }

    fn serve(&self) -> Result<()> {
        while !self.control.is_shutdown_requested() {
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

fn parse_socket() -> Result<PathBuf> {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    match arguments.as_slice() {
        [] => default_socket(),
        [flag, path] if flag == "--socket" => Ok(PathBuf::from(path)),
        _ => Err(Error::new(
            ErrorKind::InvalidInput,
            "usage: yeokcham-daemon [--socket <path>]",
        )),
    }
}

fn run() -> Result<()> {
    let control = DaemonControl::new();
    DaemonServer::bind(&parse_socket()?, control)?.serve()
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
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn serves_ping_and_orderly_shutdown_over_a_private_unix_socket() {
        let directory = env::temp_dir().join(format!("yeokcham-daemon-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).expect("directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).expect("permissions");
        let socket = directory.join("daemon.sock");
        let control = DaemonControl::new();
        let server = DaemonServer::bind(&socket, control.clone()).expect("bind");
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
