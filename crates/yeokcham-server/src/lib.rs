//! Bounded loopback-only Yeokcham-native HTTP V1 service.

use std::{
    io::{self, Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::Duration,
};

use yeokcham_core::{
    Error, ErrorKind, GitImportLimits, GitObject, GitObjectId, GitObjectKind, HeadState,
    LocalRepository, Result,
};

const MAXIMUM_REQUEST_HEADER_BYTES: usize = 8 * 1024;
const MAXIMUM_RESPONSE_BODY_BYTES: usize = 64 * 1024 * 1024;
const MAXIMUM_CONNECTIONS: usize = 4;
const MAXIMUM_PENDING_CONNECTIONS: usize = 8;
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// The supported documented native HTTP transport version.
pub const NATIVE_HTTP_VERSION: u8 = 1;

/// A loopback-only HTTP server for one opened Yeokcham repository.
pub struct Server {
    listener: TcpListener,
    repository: LocalRepository,
}

impl Server {
    /// Binds a server only to a loopback socket address.
    pub fn bind(repository: LocalRepository, address: SocketAddr) -> Result<Self> {
        if !address.ip().is_loopback() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "native HTTP server address is not loopback",
            ));
        }
        let listener = TcpListener::bind(address).map_err(|error| {
            Error::with_source(ErrorKind::Io, "native HTTP server could not bind", error)
        })?;
        Ok(Self {
            listener,
            repository,
        })
    }

    /// Returns the actual bound loopback address.
    pub fn local_addr(&self) -> Result<SocketAddr> {
        self.listener.local_addr().map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "native HTTP server address could not be read",
                error,
            )
        })
    }

    /// Serves HTTP requests until the process terminates.
    ///
    /// At most four requests execute concurrently and at most eight accepted
    /// connections wait for a worker. Each connection supports one request.
    pub fn serve(self) -> Result<()> {
        let repository = Arc::new(self.repository);
        let (sender, receiver) = mpsc::sync_channel(MAXIMUM_PENDING_CONNECTIONS);
        let receiver = Arc::new(Mutex::new(receiver));
        for _ in 0..MAXIMUM_CONNECTIONS {
            let repository = Arc::clone(&repository);
            let receiver = Arc::clone(&receiver);
            thread::Builder::new()
                .name("yeokcham-http".to_owned())
                .spawn(move || {
                    loop {
                        let stream = match receiver
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .recv()
                        {
                            Ok(stream) => stream,
                            Err(_) => return,
                        };
                        let _ = handle_connection(&repository, stream);
                    }
                })
                .map_err(|error| {
                    Error::with_source(
                        ErrorKind::Io,
                        "native HTTP server worker could not start",
                        error,
                    )
                })?;
        }
        for accepted in self.listener.incoming() {
            let stream = accepted.map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "native HTTP server could not accept a connection",
                    error,
                )
            })?;
            sender.send(stream).map_err(|_| {
                Error::new(ErrorKind::Internal, "native HTTP server workers stopped")
            })?;
        }
        Err(Error::new(
            ErrorKind::Internal,
            "native HTTP server listener stopped unexpectedly",
        ))
    }

    #[cfg(test)]
    fn serve_connection(&self) -> Result<()> {
        let (stream, _) = self.listener.accept().map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "native HTTP server could not accept a connection",
                error,
            )
        })?;
        handle_connection(&self.repository, stream)
    }
}

#[derive(Clone, Copy)]
enum Request {
    Health,
    Refs,
    Object(GitObjectId),
}

struct Response {
    status: u16,
    reason: &'static str,
    content_type: &'static str,
    headers: Vec<(&'static str, String)>,
    body: Vec<u8>,
}

impl Response {
    fn json(status: u16, reason: &'static str, body: String) -> Self {
        Self {
            status,
            reason,
            content_type: "application/json",
            headers: Vec::new(),
            body: body.into_bytes(),
        }
    }

    fn error(status: u16, reason: &'static str, code: &'static str) -> Self {
        Self::json(
            status,
            reason,
            format!("{{\"version\":{NATIVE_HTTP_VERSION},\"error\":\"{code}\"}}"),
        )
    }
}

fn handle_connection(repository: &LocalRepository, mut stream: TcpStream) -> Result<()> {
    stream
        .set_read_timeout(Some(CONNECTION_TIMEOUT))
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "native HTTP server stream could not be configured",
                error,
            )
        })?;
    stream
        .set_write_timeout(Some(CONNECTION_TIMEOUT))
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "native HTTP server stream could not be configured",
                error,
            )
        })?;
    let response = match read_request(&mut stream) {
        Ok(request) => route_request(repository, request),
        Err(response) => response,
    };
    write_response(&mut stream, response)
}

fn read_request(stream: &mut TcpStream) -> std::result::Result<Request, Response> {
    let mut bytes = Vec::with_capacity(256);
    loop {
        if bytes.len() == MAXIMUM_REQUEST_HEADER_BYTES {
            return Err(Response::error(
                431,
                "Request Header Fields Too Large",
                "request_too_large",
            ));
        }
        let mut byte = [0; 1];
        match stream.read_exact(&mut byte) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::UnexpectedEof
                ) =>
            {
                return Err(Response::error(400, "Bad Request", "invalid_request"));
            }
            Err(_) => return Err(Response::error(400, "Bad Request", "invalid_request")),
        }
        bytes.push(byte[0]);
        if bytes.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    parse_request(&bytes)
}

fn parse_request(bytes: &[u8]) -> std::result::Result<Request, Response> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Response::error(400, "Bad Request", "invalid_request"))?;
    if !text.is_ascii() {
        return Err(Response::error(400, "Bad Request", "invalid_request"));
    }
    let mut lines = text.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| Response::error(400, "Bad Request", "invalid_request"))?;
    let mut request_parts = request_line.split(' ');
    let method = request_parts
        .next()
        .ok_or_else(|| Response::error(400, "Bad Request", "invalid_request"))?;
    let target = request_parts
        .next()
        .ok_or_else(|| Response::error(400, "Bad Request", "invalid_request"))?;
    let version = request_parts
        .next()
        .ok_or_else(|| Response::error(400, "Bad Request", "invalid_request"))?;
    if request_parts.next().is_some() || version != "HTTP/1.1" {
        return Err(Response::error(400, "Bad Request", "invalid_request"));
    }
    if method != "GET" {
        let mut response = Response::error(405, "Method Not Allowed", "method_not_allowed");
        response.headers.push(("Allow", "GET".to_owned()));
        return Err(response);
    }
    for line in lines {
        if line.is_empty() {
            break;
        }
        let (name, _) = line
            .split_once(':')
            .ok_or_else(|| Response::error(400, "Bad Request", "invalid_request"))?;
        if name.is_empty() || !name.bytes().all(is_header_name_byte) {
            return Err(Response::error(400, "Bad Request", "invalid_request"));
        }
        if name.eq_ignore_ascii_case("content-length")
            || name.eq_ignore_ascii_case("transfer-encoding")
        {
            return Err(Response::error(
                400,
                "Bad Request",
                "request_body_unsupported",
            ));
        }
    }
    match target {
        "/v1/health" => Ok(Request::Health),
        "/v1/refs" => Ok(Request::Refs),
        _ => target
            .strip_prefix("/v1/objects/")
            .filter(|id| id.len() == GitObjectId::HEX_LENGTH)
            .ok_or_else(|| Response::error(404, "Not Found", "not_found"))?
            .parse()
            .map(Request::Object)
            .map_err(|_| Response::error(404, "Not Found", "not_found")),
    }
}

fn is_header_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

fn route_request(repository: &LocalRepository, request: Request) -> Response {
    match request {
        Request::Health => Response::json(
            200,
            "OK",
            format!("{{\"version\":{NATIVE_HTTP_VERSION},\"status\":\"ok\"}}"),
        ),
        Request::Refs => refs_response(repository),
        Request::Object(id) => object_response(repository, id),
    }
}

fn refs_response(repository: &LocalRepository) -> Response {
    let limits = match GitImportLimits::initial() {
        Ok(limits) => limits,
        Err(_) => return Response::error(500, "Internal Server Error", "internal"),
    };
    let state = match repository.resolve_ref_state(limits.ref_snapshot_limits()) {
        Ok(Some(state)) => state,
        Ok(None) => return Response::error(404, "Not Found", "ref_state_unavailable"),
        Err(_) => return Response::error(500, "Internal Server Error", "repository_unavailable"),
    };
    let mut body = format!(
        "{{\"version\":{NATIVE_HTTP_VERSION},\"repository_id\":\"{}\",\"refs\":[",
        repository.id()
    );
    for (index, (name, id)) in state.regular_refs().iter().enumerate() {
        if index != 0 {
            body.push(',');
        }
        body.push_str("{\"name_hex\":\"");
        body.push_str(&hex::encode(name.as_bytes()));
        body.push_str("\",\"object_id\":\"");
        body.push_str(&id.to_string());
        body.push_str("\"}");
        if body.len() > MAXIMUM_RESPONSE_BODY_BYTES {
            return Response::error(500, "Internal Server Error", "response_too_large");
        }
    }
    body.push_str("],\"head\":");
    match state.head() {
        HeadState::Symbolic(name) => {
            body.push_str("{\"kind\":\"symbolic\",\"ref_name_hex\":\"");
            body.push_str(&hex::encode(name.as_bytes()));
            body.push_str("\"}");
        }
        HeadState::Detached(id) => {
            body.push_str("{\"kind\":\"detached\",\"object_id\":\"");
            body.push_str(&id.to_string());
            body.push_str("\"}");
        }
    }
    body.push('}');
    if body.len() > MAXIMUM_RESPONSE_BODY_BYTES {
        return Response::error(500, "Internal Server Error", "response_too_large");
    }
    Response::json(200, "OK", body)
}

fn object_response(repository: &LocalRepository, id: GitObjectId) -> Response {
    let limits = match GitImportLimits::initial() {
        Ok(limits) => limits,
        Err(_) => return Response::error(500, "Internal Server Error", "internal"),
    };
    let object = match repository.reconstruct_git_object(id, limits) {
        Ok(object) => object,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Response::error(404, "Not Found", "not_found");
        }
        Err(_) => return Response::error(500, "Internal Server Error", "repository_unavailable"),
    };
    object_response_from_verified(object)
}

fn object_response_from_verified(object: GitObject) -> Response {
    let id = object.id().to_string();
    let kind = match object.kind() {
        GitObjectKind::Blob => "blob",
        GitObjectKind::Tree => "tree",
        GitObjectKind::Commit => "commit",
        GitObjectKind::Tag => "tag",
    };
    let body = object.into_data();
    if body.len() > MAXIMUM_RESPONSE_BODY_BYTES {
        return Response::error(500, "Internal Server Error", "response_too_large");
    }
    Response {
        status: 200,
        reason: "OK",
        content_type: "application/vnd.yeokcham.git-object",
        headers: vec![
            ("X-Yeokcham-Native-Version", NATIVE_HTTP_VERSION.to_string()),
            ("X-Yeokcham-Git-Object-Id", id),
            ("X-Yeokcham-Git-Object-Kind", kind.to_owned()),
        ],
        body,
    }
}

fn write_response(stream: &mut TcpStream, response: Response) -> Result<()> {
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n",
        response.status,
        response.reason,
        response.content_type,
        response.body.len(),
    );
    for (name, value) in response.headers {
        head.push_str(name);
        head.push_str(": ");
        head.push_str(&value);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "native HTTP response could not be written",
            error,
        )
    })?;
    stream.write_all(&response.body).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "native HTTP response could not be written",
            error,
        )
    })?;
    stream.flush().map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "native HTTP response could not be written",
            error,
        )
    })
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Read as _, Write as _},
        net::{Shutdown, TcpStream},
        path::{Path, PathBuf},
        process::Command,
        thread,
    };

    use yeokcham_core::GitRepository;

    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("yeokcham-server-test-{}", uuid::Uuid::new_v4()));
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

    fn git(directory: &Path, arguments: &[&str]) {
        let output = Command::new("git")
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

    fn imported_repository(directory: &TestDirectory) -> (LocalRepository, GitObjectId) {
        let source = directory.path().join("source");
        let store = directory.path().join("store");
        fs::create_dir(&source).expect("create source");
        git(&source, &["init", "-b", "main"]);
        git(&source, &["config", "user.name", "Yeokcham Test"]);
        git(
            &source,
            &["config", "user.email", "yeokcham-test@example.invalid"],
        );
        fs::write(source.join("readme.txt"), b"native transport\n").expect("write fixture");
        git(&source, &["add", "readme.txt"]);
        git(&source, &["commit", "-m", "native transport"]);
        let limits = GitImportLimits::initial().expect("limits");
        let repository = LocalRepository::create(&store).expect("create store");
        repository
            .import_git_repository(&GitRepository::open(&source).expect("open source"), limits)
            .expect("import source");
        let state = repository
            .resolve_ref_state(limits.ref_snapshot_limits())
            .expect("resolve refs")
            .expect("refs");
        let head = match state.head() {
            HeadState::Symbolic(name) => *state.regular_refs().get(name).expect("main ref"),
            HeadState::Detached(id) => *id,
        };
        (repository, head)
    }

    fn request(address: SocketAddr, request: &[u8]) -> Vec<u8> {
        let mut stream = TcpStream::connect(address).expect("connect server");
        stream.write_all(request).expect("write request");
        stream.shutdown(Shutdown::Write).expect("close request");
        let mut response = Vec::new();
        stream.read_to_end(&mut response).expect("read response");
        response
    }

    fn serve_request(server: &Server, address: SocketAddr, request_bytes: &[u8]) -> Vec<u8> {
        thread::scope(|scope| {
            let worker = scope.spawn(|| server.serve_connection());
            let response = request(address, request_bytes);
            worker
                .join()
                .expect("server thread must not panic")
                .expect("serve request");
            response
        })
    }

    fn split_response(response: &[u8]) -> (&str, &[u8]) {
        let split = response
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .expect("HTTP delimiter");
        (
            std::str::from_utf8(&response[..split]).expect("UTF-8 response headers"),
            &response[(split + 4)..],
        )
    }

    #[test]
    fn serves_bounded_v1_health_refs_and_verified_objects() {
        let directory = TestDirectory::new();
        let (repository, head_id) = imported_repository(&directory);
        let server = Server::bind(repository, "127.0.0.1:0".parse().expect("loopback address"))
            .expect("bind server");
        let address = server.local_addr().expect("bound address");

        let health = serve_request(
            &server,
            address,
            b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n",
        );
        let (health_head, health_body) = split_response(&health);
        assert!(health_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert_eq!(health_body, b"{\"version\":1,\"status\":\"ok\"}");

        let refs = serve_request(
            &server,
            address,
            b"GET /v1/refs HTTP/1.1\r\nHost: localhost\r\n\r\n",
        );
        let (refs_head, refs_body) = split_response(&refs);
        assert!(refs_head.starts_with("HTTP/1.1 200 OK\r\n"));
        let refs_text = std::str::from_utf8(refs_body).expect("refs JSON");
        assert!(refs_text.contains("\"name_hex\":\"726566732f68656164732f6d61696e\""));
        assert!(refs_text.contains(&head_id.to_string()));

        let object = serve_request(
            &server,
            address,
            format!("GET /v1/objects/{head_id} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
        );
        let (object_head, object_body) = split_response(&object);
        assert!(object_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(
            object_head.contains("X-Yeokcham-Git-Object-Kind: commit"),
            "{object_head}"
        );
        assert!(object_head.contains(&format!("X-Yeokcham-Git-Object-Id: {head_id}")));
        assert!(object_body.starts_with(b"tree "));

        let body = serve_request(
            &server,
            address,
            b"GET /v1/health HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        );
        let (body_head, _) = split_response(&body);
        assert!(body_head.starts_with("HTTP/1.1 400 Bad Request\r\n"));

        let method = serve_request(&server, address, b"POST /v1/health HTTP/1.1\r\n\r\n");
        let (method_head, _) = split_response(&method);
        assert!(method_head.starts_with("HTTP/1.1 405 Method Not Allowed\r\n"));
        assert!(method_head.contains("Allow: GET"));
    }

    #[test]
    fn rejects_nonloopback_bind_addresses() {
        let directory = TestDirectory::new();
        let repository = LocalRepository::create(directory.path().join("store")).expect("store");
        let error = match Server::bind(repository, "0.0.0.0:0".parse().expect("address")) {
            Ok(_) => panic!("public bind must fail"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert_eq!(
            error.public_message(),
            "native HTTP server address is not loopback"
        );
    }
}
