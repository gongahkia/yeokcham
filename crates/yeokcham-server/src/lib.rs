//! Bounded loopback-only Yeokcham-native HTTP V1 service.

use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::Duration,
};

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use subtle::ConstantTimeEq;
use yeokcham_core::{
    Error, ErrorKind, GitImportLimits, GitObject, GitObjectId, GitObjectKind, HeadState,
    LocalRepository, Result,
};
use zeroize::Zeroizing;

const AUTHENTICATION_TOKEN_BYTES: usize = 32;
const AUTHENTICATION_TOKEN_HEX_BYTES: usize = AUTHENTICATION_TOKEN_BYTES * 2;
const MAXIMUM_AUTHENTICATION_TOKEN_FILE_BYTES: usize = AUTHENTICATION_TOKEN_HEX_BYTES + 1;
const MAXIMUM_BASIC_AUTHORIZATION_BYTES: usize = 128;
const MAXIMUM_REQUEST_HEADER_BYTES: usize = 8 * 1024;
const MAXIMUM_RESPONSE_BODY_BYTES: usize = 64 * 1024 * 1024;
const MAXIMUM_RENDERED_COMMIT_PARENTS: usize = 1024;
const MAXIMUM_RENDERED_COMMIT_TEXT_BYTES: usize = 64 * 1024;
const MAXIMUM_RENDERED_SIGNATURE_BYTES: usize = 4 * 1024;
const MAXIMUM_RENDERED_TREE_ENTRIES: usize = 10_000;
const MAXIMUM_RENDERED_TREE_NAME_BYTES: usize = 1024;
const MAXIMUM_CONNECTIONS: usize = 4;
const MAXIMUM_PENDING_CONNECTIONS: usize = 8;
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// The supported documented native HTTP transport version.
pub const NATIVE_HTTP_VERSION: u8 = 1;

/// One 256-bit single-user bearer token held only in process memory.
pub struct AuthenticationToken(Zeroizing<[u8; AUTHENTICATION_TOKEN_BYTES]>);

impl AuthenticationToken {
    /// Loads one exact lowercase-hex token from a private regular file.
    ///
    /// The file must not be a symlink and must grant no group or other access.
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "authentication token file could not be opened",
                    error,
                )
            })?;
        let metadata = file.metadata().map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "authentication token file could not be inspected",
                error,
            )
        })?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "authentication token file is not private and regular",
            ));
        }
        let mut bytes = Zeroizing::new(Vec::with_capacity(MAXIMUM_AUTHENTICATION_TOKEN_FILE_BYTES));
        Read::by_ref(&mut file)
            .take(
                u64::try_from(MAXIMUM_AUTHENTICATION_TOKEN_FILE_BYTES + 1).map_err(|_| {
                    Error::new(
                        ErrorKind::Internal,
                        "authentication token file limit is invalid",
                    )
                })?,
            )
            .read_to_end(&mut bytes)
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "authentication token file could not be read",
                    error,
                )
            })?;
        if bytes.len() > MAXIMUM_AUTHENTICATION_TOKEN_FILE_BYTES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "authentication token file exceeds the byte limit",
            ));
        }
        if bytes.last() == Some(&b'\n') {
            bytes.pop();
        }
        if bytes.len() != AUTHENTICATION_TOKEN_HEX_BYTES
            || bytes
                .iter()
                .any(|byte| !byte.is_ascii_digit() && !(b'a'..=b'f').contains(byte))
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "authentication token file is invalid",
            ));
        }
        let mut token = Zeroizing::new([0; AUTHENTICATION_TOKEN_BYTES]);
        hex::decode_to_slice(&*bytes, &mut *token).map_err(|_| {
            Error::new(
                ErrorKind::InvalidInput,
                "authentication token file is invalid",
            )
        })?;
        Ok(Self(token))
    }

    fn matches_authorization(&self, value: &str) -> bool {
        let value = value.trim_matches([' ', '\t']);
        if let Some(token) = value.strip_prefix("Bearer ") {
            return self.matches_token(token.as_bytes());
        }
        let Some(encoded) = value.strip_prefix("Basic ") else {
            return false;
        };
        if encoded.len() > MAXIMUM_BASIC_AUTHORIZATION_BYTES {
            return false;
        }
        let decoded = match BASE64_STANDARD.decode(encoded) {
            Ok(decoded) => Zeroizing::new(decoded),
            Err(_) => return false,
        };
        let mut fields = decoded.splitn(2, |byte| *byte == b':');
        match (fields.next(), fields.next()) {
            (Some(b"yeokcham"), Some(token)) => self.matches_token(token),
            _ => false,
        }
    }

    fn matches_token(&self, value: &[u8]) -> bool {
        if value.len() != AUTHENTICATION_TOKEN_HEX_BYTES
            || value
                .iter()
                .any(|byte| !byte.is_ascii_digit() && !(b'a'..=b'f').contains(byte))
        {
            return false;
        }
        let mut candidate = Zeroizing::new([0; AUTHENTICATION_TOKEN_BYTES]);
        if hex::decode_to_slice(value, &mut *candidate).is_err() {
            return false;
        }
        self.0.ct_eq(&*candidate).into()
    }
}

impl fmt::Debug for AuthenticationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("AuthenticationToken(<redacted>)")
    }
}

/// Creates a new private token file without replacing an existing path.
///
/// The token is 32 random bytes encoded as lowercase hexadecimal plus one
/// newline. This function never writes the token to stdout or tracing.
pub fn create_authentication_token_file(path: impl AsRef<Path>) -> Result<()> {
    let path = path.as_ref();
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent_metadata = fs::symlink_metadata(parent).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "authentication token parent directory could not be inspected",
            error,
        )
    })?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "authentication token parent is not a directory",
        ));
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "authentication token file could not be created",
                error,
            )
        })?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "authentication token file permissions could not be set",
                error,
            )
        })?;
    let mut token = Zeroizing::new([0; AUTHENTICATION_TOKEN_BYTES]);
    getrandom::fill(&mut *token).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "authentication token could not be generated",
            error,
        )
    })?;
    let encoded = Zeroizing::new(hex::encode(*token));
    file.write_all(encoded.as_bytes())
        .and_then(|()| file.write_all(b"\n"))
        .and_then(|()| file.sync_all())
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "authentication token file could not be written",
                error,
            )
        })?;
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "authentication token parent directory could not be synchronized",
                error,
            )
        })
}

/// A loopback-only HTTP server for one opened Yeokcham repository.
pub struct Server {
    listener: TcpListener,
    repository: LocalRepository,
    authentication: AuthenticationToken,
}

impl Server {
    /// Binds a server only to a loopback socket address.
    pub fn bind(
        repository: LocalRepository,
        address: SocketAddr,
        authentication: AuthenticationToken,
    ) -> Result<Self> {
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
            authentication,
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
        let authentication = Arc::new(self.authentication);
        let (sender, receiver) = mpsc::sync_channel(MAXIMUM_PENDING_CONNECTIONS);
        let receiver = Arc::new(Mutex::new(receiver));
        for _ in 0..MAXIMUM_CONNECTIONS {
            let repository = Arc::clone(&repository);
            let authentication = Arc::clone(&authentication);
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
                        let _ = handle_connection(&repository, &authentication, stream);
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
        handle_connection(&self.repository, &self.authentication, stream)
    }
}

#[derive(Clone, Copy)]
enum Request {
    Browser,
    Commit(GitObjectId),
    Health,
    Refs,
    Tree(GitObjectId),
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

fn handle_connection(
    repository: &LocalRepository,
    authentication: &AuthenticationToken,
    mut stream: TcpStream,
) -> Result<()> {
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
    let response = match read_request(&mut stream, authentication) {
        Ok(request) => route_request(repository, request),
        Err(response) => response,
    };
    write_response(&mut stream, response)
}

fn read_request(
    stream: &mut TcpStream,
    authentication: &AuthenticationToken,
) -> std::result::Result<Request, Response> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(256));
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
    parse_request(&bytes, authentication)
}

fn parse_request(
    bytes: &[u8],
    authentication: &AuthenticationToken,
) -> std::result::Result<Request, Response> {
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
    let mut authorization_seen = false;
    let mut authenticated = false;
    for line in lines {
        if line.is_empty() {
            break;
        }
        let (name, value) = line
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
        if name.eq_ignore_ascii_case("authorization") {
            if authorization_seen {
                return Err(unauthorized_response());
            }
            authorization_seen = true;
            authenticated = authentication.matches_authorization(value);
        }
    }
    if !authenticated {
        return Err(unauthorized_response());
    }
    if method != "GET" {
        let mut response = Response::error(405, "Method Not Allowed", "method_not_allowed");
        response.headers.push(("Allow", "GET".to_owned()));
        return Err(response);
    }
    match target {
        "/" => Ok(Request::Browser),
        "/v1/health" => Ok(Request::Health),
        "/v1/refs" => Ok(Request::Refs),
        _ => parse_object_target(target, "/commits/")
            .map(Request::Commit)
            .or_else(|| parse_object_target(target, "/trees/").map(Request::Tree))
            .or_else(|| parse_object_target(target, "/v1/objects/").map(Request::Object))
            .ok_or_else(|| Response::error(404, "Not Found", "not_found")),
    }
}

fn parse_object_target(target: &str, prefix: &str) -> Option<GitObjectId> {
    target
        .strip_prefix(prefix)
        .filter(|id| id.len() == GitObjectId::HEX_LENGTH)
        .and_then(|id| id.parse().ok())
}

fn unauthorized_response() -> Response {
    let mut response = Response::error(401, "Unauthorized", "authentication_required");
    response
        .headers
        .push(("WWW-Authenticate", "Basic realm=\"Yeokcham\"".to_owned()));
    response
        .headers
        .push(("WWW-Authenticate", "Bearer".to_owned()));
    response
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
        Request::Browser => browser_response(repository),
        Request::Commit(id) => commit_response(repository, id),
        Request::Health => Response::json(
            200,
            "OK",
            format!("{{\"version\":{NATIVE_HTTP_VERSION},\"status\":\"ok\"}}"),
        ),
        Request::Refs => refs_response(repository),
        Request::Tree(id) => tree_response(repository, id),
        Request::Object(id) => object_response(repository, id),
    }
}

fn browser_response(repository: &LocalRepository) -> Response {
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
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Yeokcham repository</title></head><body><main><h1>Yeokcham repository</h1><p>Repository <code>{}</code></p><h2>References</h2><ul>",
        repository.id()
    );
    for (name, id) in state.regular_refs() {
        body.push_str("<li><code>");
        body.push_str(&html_escape_ref_name(name.as_bytes()));
        body.push_str("</code> <code>");
        body.push_str(&id.to_string());
        body.push_str("</code></li>");
        if body.len() > MAXIMUM_RESPONSE_BODY_BYTES {
            return Response::error(500, "Internal Server Error", "response_too_large");
        }
    }
    body.push_str("</ul><h2>HEAD</h2><p><code>");
    match state.head() {
        HeadState::Symbolic(name) => body.push_str(&html_escape_ref_name(name.as_bytes())),
        HeadState::Detached(id) => body.push_str(&id.to_string()),
    }
    body.push_str("</code></p></main></body></html>");
    if body.len() > MAXIMUM_RESPONSE_BODY_BYTES {
        return Response::error(500, "Internal Server Error", "response_too_large");
    }
    Response {
        status: 200,
        reason: "OK",
        content_type: "text/html; charset=utf-8",
        headers: vec![
            (
                "Content-Security-Policy",
                "default-src 'none'; base-uri 'none'; form-action 'none'".to_owned(),
            ),
            ("X-Content-Type-Options", "nosniff".to_owned()),
        ],
        body: body.into_bytes(),
    }
}

fn html_escape_ref_name(bytes: &[u8]) -> String {
    let Ok(name) = std::str::from_utf8(bytes) else {
        return format!("hex:{}", hex::encode(bytes));
    };
    let mut escaped = String::with_capacity(name.len());
    for character in name.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '\"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            _ => escaped.push(character),
        }
    }
    escaped
}

struct HtmlBody(String);

impl HtmlBody {
    fn new() -> Self {
        Self(String::with_capacity(1024))
    }

    fn push(&mut self, value: &str) -> std::result::Result<(), ()> {
        let length = self.0.len().checked_add(value.len()).ok_or(())?;
        if length > MAXIMUM_RESPONSE_BODY_BYTES {
            return Err(());
        }
        self.0.push_str(value);
        Ok(())
    }

    fn push_id(&mut self, id: GitObjectId) -> std::result::Result<(), ()> {
        self.push(&id.to_string())
    }

    fn push_escaped_preview(
        &mut self,
        bytes: &[u8],
        maximum_input_bytes: usize,
    ) -> std::result::Result<bool, ()> {
        if let Ok(value) = std::str::from_utf8(bytes) {
            let mut rendered_input_bytes: usize = 0;
            for character in value.chars() {
                let character_bytes = character.len_utf8();
                let next = rendered_input_bytes
                    .checked_add(character_bytes)
                    .ok_or(())?;
                if next > maximum_input_bytes {
                    return Ok(true);
                }
                rendered_input_bytes = next;
                match character {
                    '&' => self.push("&amp;")?,
                    '<' => self.push("&lt;")?,
                    '>' => self.push("&gt;")?,
                    '\"' => self.push("&quot;")?,
                    '\'' => self.push("&#39;")?,
                    _ => {
                        let mut rendered = [0; 4];
                        self.push(character.encode_utf8(&mut rendered))?;
                    }
                }
            }
            Ok(false)
        } else {
            self.push("hex:")?;
            for byte in bytes.iter().take(maximum_input_bytes) {
                self.push(&format!("{byte:02x}"))?;
            }
            Ok(bytes.len() > maximum_input_bytes)
        }
    }

    fn into_string(self) -> String {
        self.0
    }
}

struct CommitView<'a> {
    tree: GitObjectId,
    parents: Vec<GitObjectId>,
    parent_count: usize,
    author: Option<&'a [u8]>,
    committer: Option<&'a [u8]>,
    message: &'a [u8],
}

struct TreeView<'a> {
    entries: Vec<TreeEntry<'a>>,
    entry_count: usize,
}

struct TreeEntry<'a> {
    mode: &'a [u8],
    name: &'a [u8],
    id: GitObjectId,
}

fn parse_commit_view(bytes: &[u8]) -> std::result::Result<CommitView<'_>, ()> {
    let separator = bytes
        .windows(2)
        .position(|window| window == b"\n\n")
        .ok_or(())?;
    let (headers, message) = bytes.split_at(separator);
    let message = &message[2..];
    let mut tree = None;
    let mut parents = Vec::new();
    let mut parent_count: usize = 0;
    let mut author = None;
    let mut committer = None;
    for line in headers.split(|byte| *byte == b'\n') {
        if line.starts_with(b" ") {
            continue;
        }
        let separator = line.iter().position(|byte| *byte == b' ').ok_or(())?;
        let (name, value) = line.split_at(separator);
        let value = &value[1..];
        match name {
            b"tree" => {
                if tree.replace(parse_object_id(value)?).is_some() {
                    return Err(());
                }
            }
            b"parent" => {
                let parent = parse_object_id(value)?;
                parent_count = parent_count.checked_add(1).ok_or(())?;
                if parents.len() < MAXIMUM_RENDERED_COMMIT_PARENTS {
                    parents.push(parent);
                }
            }
            b"author" => {
                author.get_or_insert(value);
            }
            b"committer" => {
                committer.get_or_insert(value);
            }
            _ => {}
        }
    }
    Ok(CommitView {
        tree: tree.ok_or(())?,
        parents,
        parent_count,
        author,
        committer,
        message,
    })
}

fn parse_tree_view(bytes: &[u8]) -> std::result::Result<TreeView<'_>, ()> {
    let mut entries = Vec::new();
    let mut entry_count: usize = 0;
    let mut offset = 0;
    while offset < bytes.len() {
        let mode_end = bytes[offset..]
            .iter()
            .position(|byte| *byte == b' ')
            .map(|length| offset + length)
            .ok_or(())?;
        let mode = &bytes[offset..mode_end];
        if mode.is_empty() || mode.iter().any(|byte| !matches!(byte, b'0'..=b'7')) {
            return Err(());
        }
        let name_start = mode_end.checked_add(1).ok_or(())?;
        let name_end = bytes[name_start..]
            .iter()
            .position(|byte| *byte == 0)
            .map(|length| name_start + length)
            .ok_or(())?;
        let name = &bytes[name_start..name_end];
        if name.is_empty() || name == b"." || name == b".." || name.contains(&b'/') {
            return Err(());
        }
        let id_start = name_end.checked_add(1).ok_or(())?;
        let id_end = id_start.checked_add(GitObjectId::BYTE_LENGTH).ok_or(())?;
        let id_bytes: [u8; GitObjectId::BYTE_LENGTH] = bytes
            .get(id_start..id_end)
            .ok_or(())?
            .try_into()
            .map_err(|_| ())?;
        entry_count = entry_count.checked_add(1).ok_or(())?;
        if entries.len() < MAXIMUM_RENDERED_TREE_ENTRIES {
            entries.push(TreeEntry {
                mode,
                name,
                id: GitObjectId::from_bytes(id_bytes),
            });
        }
        offset = id_end;
    }
    Ok(TreeView {
        entries,
        entry_count,
    })
}

fn parse_object_id(bytes: &[u8]) -> std::result::Result<GitObjectId, ()> {
    std::str::from_utf8(bytes)
        .ok()
        .and_then(|value| value.parse().ok())
        .ok_or(())
}

fn commit_response(repository: &LocalRepository, id: GitObjectId) -> Response {
    let object = match reconstruct_object(repository, id) {
        Ok(object) => object,
        Err(response) => return response,
    };
    if object.kind() != GitObjectKind::Commit {
        return Response::error(422, "Unprocessable Content", "object_kind_mismatch");
    }
    let commit = match parse_commit_view(object.data()) {
        Ok(commit) => commit,
        Err(()) => return Response::error(422, "Unprocessable Content", "invalid_commit_object"),
    };
    let mut body = HtmlBody::new();
    if render_commit_html(&mut body, id, &commit).is_err() {
        return Response::error(500, "Internal Server Error", "response_too_large");
    }
    html_response(body.into_string())
}

fn tree_response(repository: &LocalRepository, id: GitObjectId) -> Response {
    let object = match reconstruct_object(repository, id) {
        Ok(object) => object,
        Err(response) => return response,
    };
    if object.kind() != GitObjectKind::Tree {
        return Response::error(422, "Unprocessable Content", "object_kind_mismatch");
    }
    let tree = match parse_tree_view(object.data()) {
        Ok(tree) => tree,
        Err(()) => return Response::error(422, "Unprocessable Content", "invalid_tree_object"),
    };
    let mut body = HtmlBody::new();
    if render_tree_html(&mut body, id, &tree).is_err() {
        return Response::error(500, "Internal Server Error", "response_too_large");
    }
    html_response(body.into_string())
}

fn render_commit_html(
    body: &mut HtmlBody,
    id: GitObjectId,
    commit: &CommitView<'_>,
) -> std::result::Result<(), ()> {
    body.push("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Yeokcham commit</title></head><body><main><p><a href=\"/\">Repository</a></p><h1>Commit <code>")?;
    body.push_id(id)?;
    body.push("</code></h1><h2>Tree</h2><p><a href=\"/trees/")?;
    body.push_id(commit.tree)?;
    body.push("\"><code>")?;
    body.push_id(commit.tree)?;
    body.push("</code></a></p><h2>Parents</h2><ul>")?;
    for parent in &commit.parents {
        body.push("<li><a href=\"/commits/")?;
        body.push_id(*parent)?;
        body.push("\"><code>")?;
        body.push_id(*parent)?;
        body.push("</code></a></li>")?;
    }
    body.push("</ul>")?;
    if commit.parent_count > commit.parents.len() {
        body.push("<p>Showing the first ")?;
        body.push(&commit.parents.len().to_string())?;
        body.push(" of ")?;
        body.push(&commit.parent_count.to_string())?;
        body.push(" parents.</p>")?;
    }
    render_commit_field(body, "Author", commit.author)?;
    render_commit_field(body, "Committer", commit.committer)?;
    body.push("<h2>Message preview</h2><pre>")?;
    if body.push_escaped_preview(commit.message, MAXIMUM_RENDERED_COMMIT_TEXT_BYTES)? {
        body.push(" [truncated]")?;
    }
    body.push("</pre></main></body></html>")
}

fn render_commit_field(
    body: &mut HtmlBody,
    label: &str,
    value: Option<&[u8]>,
) -> std::result::Result<(), ()> {
    let Some(value) = value else {
        return Ok(());
    };
    body.push("<h2>")?;
    body.push(label)?;
    body.push("</h2><p><code>")?;
    if body.push_escaped_preview(value, MAXIMUM_RENDERED_SIGNATURE_BYTES)? {
        body.push(" [truncated]")?;
    }
    body.push("</code></p>")
}

fn render_tree_html(
    body: &mut HtmlBody,
    id: GitObjectId,
    tree: &TreeView<'_>,
) -> std::result::Result<(), ()> {
    body.push("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Yeokcham tree</title></head><body><main><p><a href=\"/\">Repository</a></p><h1>Tree <code>")?;
    body.push_id(id)?;
    body.push("</code></h1><ul>")?;
    for entry in &tree.entries {
        body.push("<li><code>")?;
        body.push(std::str::from_utf8(entry.mode).map_err(|_| ())?)?;
        body.push("</code> <code>")?;
        if body.push_escaped_preview(entry.name, MAXIMUM_RENDERED_TREE_NAME_BYTES)? {
            body.push(" [truncated]")?;
        }
        body.push("</code> ")?;
        render_tree_entry_id(body, entry)?;
        body.push("</li>")?;
    }
    body.push("</ul>")?;
    if tree.entry_count > tree.entries.len() {
        body.push("<p>Showing the first ")?;
        body.push(&tree.entries.len().to_string())?;
        body.push(" of ")?;
        body.push(&tree.entry_count.to_string())?;
        body.push(" entries.</p>")?;
    }
    body.push("</main></body></html>")
}

fn render_tree_entry_id(body: &mut HtmlBody, entry: &TreeEntry<'_>) -> std::result::Result<(), ()> {
    let path = match entry.mode {
        b"40000" => Some("/trees/"),
        _ => None,
    };
    if let Some(path) = path {
        body.push("<a href=\"")?;
        body.push(path)?;
        body.push_id(entry.id)?;
        body.push("\">")?;
    }
    body.push("<code>")?;
    body.push_id(entry.id)?;
    body.push("</code>")?;
    if path.is_some() {
        body.push("</a>")?;
    }
    Ok(())
}

fn html_response(body: String) -> Response {
    Response {
        status: 200,
        reason: "OK",
        content_type: "text/html; charset=utf-8",
        headers: vec![
            (
                "Content-Security-Policy",
                "default-src 'none'; base-uri 'none'; form-action 'none'".to_owned(),
            ),
            ("X-Content-Type-Options", "nosniff".to_owned()),
        ],
        body: body.into_bytes(),
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
    let object = match reconstruct_object(repository, id) {
        Ok(object) => object,
        Err(response) => return response,
    };
    object_response_from_verified(object)
}

fn reconstruct_object(
    repository: &LocalRepository,
    id: GitObjectId,
) -> std::result::Result<GitObject, Response> {
    let limits = match GitImportLimits::initial() {
        Ok(limits) => limits,
        Err(_) => return Err(Response::error(500, "Internal Server Error", "internal")),
    };
    repository
        .reconstruct_git_object(id, limits)
        .map_err(|error| match error.kind() {
            ErrorKind::NotFound => Response::error(404, "Not Found", "not_found"),
            _ => Response::error(500, "Internal Server Error", "repository_unavailable"),
        })
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
        os::unix::fs::{PermissionsExt, symlink},
        path::{Path, PathBuf},
        process::Command,
        thread,
    };

    use base64::Engine as _;
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

    fn imported_repository(
        directory: &TestDirectory,
    ) -> (LocalRepository, GitObjectId, GitObjectId) {
        let source = directory.path().join("source");
        let store = directory.path().join("store");
        fs::create_dir(&source).expect("create source");
        git(&source, &["init", "-b", "main"]);
        git(&source, &["config", "user.name", "Yeokcham Test"]);
        git(
            &source,
            &["config", "user.email", "yeokcham-test@example.invalid"],
        );
        fs::write(source.join("readme & <browser>.txt"), b"native transport\n")
            .expect("write fixture");
        git(&source, &["add", "."]);
        git(&source, &["commit", "-m", "native <transport> & viewer"]);
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
        let output = Command::new("git")
            .arg("-C")
            .arg(&source)
            .args(["rev-parse", "HEAD^{tree}"])
            .output()
            .expect("resolve tree");
        assert!(output.status.success(), "resolve tree");
        let tree = std::str::from_utf8(&output.stdout)
            .expect("tree ID UTF-8")
            .trim()
            .parse()
            .expect("tree ID");
        (repository, head, tree)
    }

    fn request(address: SocketAddr, request: &[u8]) -> Vec<u8> {
        let mut stream = TcpStream::connect(address).expect("connect server");
        stream.write_all(request).expect("write request");
        stream.shutdown(Shutdown::Write).expect("close request");
        let mut response = Vec::new();
        stream.read_to_end(&mut response).expect("read response");
        response
    }

    fn authentication(directory: &TestDirectory) -> (AuthenticationToken, String) {
        let path = directory.path().join("token");
        create_authentication_token_file(&path).expect("create token");
        let token = fs::read_to_string(&path)
            .expect("read token")
            .trim_end_matches('\n')
            .to_owned();
        (AuthenticationToken::load(path).expect("load token"), token)
    }

    fn basic_authorization(token: &str) -> String {
        BASE64_STANDARD.encode(format!("yeokcham:{token}"))
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
        let (repository, head_id, tree_id) = imported_repository(&directory);
        let (authentication, token) = authentication(&directory);
        let server = Server::bind(
            repository,
            "127.0.0.1:0".parse().expect("loopback address"),
            authentication,
        )
        .expect("bind server");
        let address = server.local_addr().expect("bound address");

        let unauthorized = serve_request(
            &server,
            address,
            b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n",
        );
        let (unauthorized_head, unauthorized_body) = split_response(&unauthorized);
        assert!(unauthorized_head.starts_with("HTTP/1.1 401 Unauthorized\r\n"));
        assert!(unauthorized_head.contains("WWW-Authenticate: Basic realm=\"Yeokcham\""));
        assert!(unauthorized_head.contains("WWW-Authenticate: Bearer"));
        assert_eq!(
            unauthorized_body,
            b"{\"version\":1,\"error\":\"authentication_required\"}"
        );

        let invalid_token = if let Some(suffix) = token.strip_prefix('0') {
            format!("1{suffix}")
        } else {
            format!("0{}", &token[1..])
        };
        let invalid = serve_request(
            &server,
            address,
            format!("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer {invalid_token}\r\n\r\n")
                .as_bytes(),
        );
        let (invalid_head, _) = split_response(&invalid);
        assert!(invalid_head.starts_with("HTTP/1.1 401 Unauthorized\r\n"));

        let health = serve_request(
            &server,
            address,
            format!("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n").as_bytes(),
        );
        let (health_head, health_body) = split_response(&health);
        assert!(health_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert_eq!(health_body, b"{\"version\":1,\"status\":\"ok\"}");

        let browser = serve_request(
            &server,
            address,
            format!(
                "GET / HTTP/1.1\r\nAuthorization: Basic {}\r\n\r\n",
                basic_authorization(&token)
            )
            .as_bytes(),
        );
        let (browser_head, browser_body) = split_response(&browser);
        assert!(browser_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(browser_head.contains("Content-Type: text/html; charset=utf-8"));
        assert!(browser_head.contains("Content-Security-Policy: default-src 'none'"));
        assert!(browser_head.contains("X-Content-Type-Options: nosniff"));
        let browser_text = std::str::from_utf8(browser_body).expect("browser HTML");
        assert!(browser_text.contains("<h1>Yeokcham repository</h1>"));
        assert!(browser_text.contains("refs/heads/main"));
        assert!(browser_text.contains(&head_id.to_string()));

        let commit = serve_request(
            &server,
            address,
            format!(
                "GET /commits/{head_id} HTTP/1.1\r\nAuthorization: Basic {}\r\n\r\n",
                basic_authorization(&token)
            )
            .as_bytes(),
        );
        let (commit_head, commit_body) = split_response(&commit);
        assert!(commit_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(commit_head.contains("Content-Type: text/html; charset=utf-8"));
        let commit_text = std::str::from_utf8(commit_body).expect("commit HTML");
        assert!(commit_text.contains(&format!("/trees/{tree_id}")));
        assert!(commit_text.contains("native &lt;transport&gt; &amp; viewer"));

        let tree = serve_request(
            &server,
            address,
            format!("GET /trees/{tree_id} HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n")
                .as_bytes(),
        );
        let (tree_head, tree_body) = split_response(&tree);
        assert!(tree_head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(tree_head.contains("Content-Type: text/html; charset=utf-8"));
        let tree_text = std::str::from_utf8(tree_body).expect("tree HTML");
        assert!(tree_text.contains("readme &amp; &lt;browser&gt;.txt"));

        let commit_kind = serve_request(
            &server,
            address,
            format!("GET /commits/{tree_id} HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n")
                .as_bytes(),
        );
        let (commit_kind_head, _) = split_response(&commit_kind);
        assert!(commit_kind_head.starts_with("HTTP/1.1 422 Unprocessable Content\r\n"));

        let tree_kind = serve_request(
            &server,
            address,
            format!("GET /trees/{head_id} HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n")
                .as_bytes(),
        );
        let (tree_kind_head, _) = split_response(&tree_kind);
        assert!(tree_kind_head.starts_with("HTTP/1.1 422 Unprocessable Content\r\n"));

        let refs = serve_request(
            &server,
            address,
            format!("GET /v1/refs HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n").as_bytes(),
        );
        let (refs_head, refs_body) = split_response(&refs);
        assert!(refs_head.starts_with("HTTP/1.1 200 OK\r\n"));
        let refs_text = std::str::from_utf8(refs_body).expect("refs JSON");
        assert!(refs_text.contains("\"name_hex\":\"726566732f68656164732f6d61696e\""));
        assert!(refs_text.contains(&head_id.to_string()));

        let object = serve_request(
            &server,
            address,
            format!("GET /v1/objects/{head_id} HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n")
                .as_bytes(),
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
            format!("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer {token}\r\nContent-Length: 0\r\n\r\n").as_bytes(),
        );
        let (body_head, _) = split_response(&body);
        assert!(body_head.starts_with("HTTP/1.1 400 Bad Request\r\n"));

        let method = serve_request(
            &server,
            address,
            format!("POST /v1/health HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n").as_bytes(),
        );
        let (method_head, _) = split_response(&method);
        assert!(method_head.starts_with("HTTP/1.1 405 Method Not Allowed\r\n"));
        assert!(method_head.contains("Allow: GET"));
    }

    #[test]
    fn parses_commit_and_tree_views_without_relaxing_binary_bounds() {
        let tree: GitObjectId = "0123456789012345678901234567890123456789"
            .parse()
            .expect("tree ID");
        let parent: GitObjectId = "1123456789012345678901234567890123456789"
            .parse()
            .expect("parent ID");
        let commit = format!(
            "tree {tree}\nparent {parent}\nauthor Yeokcham <test@example.invalid> 0 +0000\ncommitter Yeokcham <test@example.invalid> 0 +0000\ngpgsig signature\n continuation\n\nsubject"
        );
        let parsed = parse_commit_view(commit.as_bytes()).expect("valid commit view");
        assert_eq!(parsed.tree, tree);
        assert_eq!(parsed.parents, vec![parent]);
        assert_eq!(parsed.parent_count, 1);
        assert_eq!(parsed.message, b"subject");
        assert!(parse_commit_view(b"tree invalid\n\nsubject").is_err());

        let mut many_parents = format!("tree {tree}\n");
        for _ in 0..=MAXIMUM_RENDERED_COMMIT_PARENTS {
            many_parents.push_str(&format!("parent {parent}\n"));
        }
        many_parents.push_str("\nsubject");
        let parsed = parse_commit_view(many_parents.as_bytes()).expect("bounded parent view");
        assert_eq!(parsed.parents.len(), MAXIMUM_RENDERED_COMMIT_PARENTS);
        assert_eq!(parsed.parent_count, MAXIMUM_RENDERED_COMMIT_PARENTS + 1);

        let mut tree_bytes = b"100644 safe-name\0".to_vec();
        tree_bytes.extend_from_slice(tree.as_bytes());
        let parsed = parse_tree_view(&tree_bytes).expect("valid tree view");
        assert_eq!(parsed.entry_count, 1);
        assert_eq!(parsed.entries[0].mode, b"100644");
        assert_eq!(parsed.entries[0].name, b"safe-name");
        assert_eq!(parsed.entries[0].id, tree);

        let mut many_entries = Vec::new();
        for index in 0..=MAXIMUM_RENDERED_TREE_ENTRIES {
            many_entries.extend_from_slice(format!("100644 entry-{index}\0").as_bytes());
            many_entries.extend_from_slice(tree.as_bytes());
        }
        let parsed = parse_tree_view(&many_entries).expect("bounded tree view");
        assert_eq!(parsed.entries.len(), MAXIMUM_RENDERED_TREE_ENTRIES);
        assert_eq!(parsed.entry_count, MAXIMUM_RENDERED_TREE_ENTRIES + 1);

        let mut unsafe_tree = b"100644 unsafe/name\0".to_vec();
        unsafe_tree.extend_from_slice(tree.as_bytes());
        assert!(parse_tree_view(&unsafe_tree).is_err());

        let mut html = HtmlBody::new();
        assert!(
            html.push_escaped_preview(b"<>&", 2)
                .expect("render escaped preview")
        );
        assert_eq!(html.into_string(), "&lt;&gt;");
        let mut html = HtmlBody::new();
        assert!(
            !html
                .push_escaped_preview(b"\xff", 1)
                .expect("render binary preview")
        );
        assert_eq!(html.into_string(), "hex:ff");
    }

    #[test]
    fn rejects_nonloopback_bind_addresses() {
        let directory = TestDirectory::new();
        let repository = LocalRepository::create(directory.path().join("store")).expect("store");
        let (authentication, _) = authentication(&directory);
        let error = match Server::bind(
            repository,
            "0.0.0.0:0".parse().expect("address"),
            authentication,
        ) {
            Ok(_) => panic!("public bind must fail"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert_eq!(
            error.public_message(),
            "native HTTP server address is not loopback"
        );
    }

    #[test]
    fn private_regular_token_files_are_required_and_redacted() {
        let directory = TestDirectory::new();
        let path = directory.path().join("token");
        create_authentication_token_file(&path).expect("create token");
        let token = fs::read_to_string(&path).expect("read token");
        assert_eq!(token.len(), AUTHENTICATION_TOKEN_HEX_BYTES + 1);
        assert!(token.ends_with('\n'));
        assert!(
            token[..AUTHENTICATION_TOKEN_HEX_BYTES]
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
        assert_eq!(
            fs::metadata(&path).expect("metadata").permissions().mode() & 0o077,
            0
        );
        let authentication = AuthenticationToken::load(&path).expect("load private token");
        assert!(authentication.matches_authorization(&format!("Bearer {}", token.trim_end())));
        assert!(
            authentication
                .matches_authorization(&format!("Basic {}", basic_authorization(token.trim_end())))
        );
        assert!(!format!("{authentication:?}").contains(token.trim_end()));

        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).expect("widen permissions");
        let error = AuthenticationToken::load(&path).expect_err("wide token file must fail");
        assert_eq!(error.kind(), ErrorKind::InvalidInput);

        let malformed = directory.path().join("malformed");
        fs::write(&malformed, b"not-a-token\n").expect("write malformed token");
        fs::set_permissions(&malformed, fs::Permissions::from_mode(0o600))
            .expect("set malformed permissions");
        let error = AuthenticationToken::load(&malformed).expect_err("malformed token must fail");
        assert_eq!(error.kind(), ErrorKind::InvalidInput);

        let link = directory.path().join("token-link");
        symlink(&malformed, &link).expect("create token symlink");
        assert!(AuthenticationToken::load(&link).is_err());
        assert!(create_authentication_token_file(&path).is_err());
    }
}
