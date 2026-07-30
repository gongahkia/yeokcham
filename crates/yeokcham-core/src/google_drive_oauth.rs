use std::{
    io::{self, Read, Write},
    net::{TcpListener, TcpStream},
    thread,
    time::{Duration, Instant},
};

use serde_json::Value;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{Error, ErrorKind, Result};

/// The least-privilege OAuth scope for files selected, opened, or created by Yeokcham.
pub const DRIVE_FILE_SCOPE: &str = "https://www.googleapis.com/auth/drive.file";

const AUTHORIZATION_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
const LOOPBACK_CALLBACK_PATH: &str = "/oauth2/callback";
const MAXIMUM_CLIENT_ID_BYTES: usize = 1_024;
const RANDOM_TOKEN_BYTES: usize = 32;
const MAXIMUM_LOOPBACK_REQUEST_BYTES: usize = 16 * 1024;
const MAXIMUM_TOKEN_RESPONSE_BYTES: usize = 64 * 1024;

/// Non-secret configuration for one Google Desktop OAuth client.
#[derive(Clone)]
pub struct DriveOAuthConfiguration {
    client_id: String,
}

impl DriveOAuthConfiguration {
    /// Validates a Google Desktop OAuth client ID supplied by the operator.
    pub fn new(client_id: impl Into<String>) -> Result<Self> {
        let client_id = client_id.into();
        if client_id.is_empty()
            || client_id.len() > MAXIMUM_CLIENT_ID_BYTES
            || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth client ID is invalid",
            ));
        }
        Ok(Self { client_id })
    }

    /// Starts one PKCE-protected loopback authorization request.
    pub fn begin_loopback(self) -> Result<DriveOAuthLoopback> {
        self.begin_loopback_on(0)
    }

    /// Starts one PKCE-protected loopback authorization request on the selected port.
    ///
    /// A nonzero port permits an operator to forward the loopback callback over
    /// SSH before starting a headless authorization session. Port zero selects a
    /// fresh operating-system port.
    pub fn begin_loopback_on(self, port: u16) -> Result<DriveOAuthLoopback> {
        DriveOAuthLoopback::begin(self, port)
    }

    /// Exchanges a persisted refresh token for a new in-memory bearer access token.
    pub fn refresh_access_token<T: DriveOAuthTransport>(
        &self,
        refresh_token: &str,
        transport: &T,
    ) -> Result<DriveAccessToken> {
        if refresh_token.is_empty() || refresh_token.len() > MAXIMUM_TOKEN_RESPONSE_BYTES {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth refresh token is invalid",
            ));
        }
        let response = transport.post_form(
            TOKEN_ENDPOINT,
            &[
                ("client_id", &self.client_id),
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh_token),
            ],
        )?;
        parse_access_token_response(response)
    }

    pub(crate) fn client_id(&self) -> &str {
        &self.client_id
    }
}

impl std::fmt::Debug for DriveOAuthConfiguration {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveOAuthConfiguration(<redacted>)")
    }
}

/// One bounded response returned by a Google OAuth transport.
pub struct DriveOAuthHttpResponse {
    status: u16,
    body: Zeroizing<Vec<u8>>,
}

impl DriveOAuthHttpResponse {
    /// Creates a response from the status code and bounded body bytes.
    pub fn new(status: u16, body: Vec<u8>) -> Result<Self> {
        if body.len() > MAXIMUM_TOKEN_RESPONSE_BYTES {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth response exceeds the byte limit",
            ));
        }
        Ok(Self {
            status,
            body: Zeroizing::new(body),
        })
    }

    /// Returns the HTTP response status.
    pub const fn status(&self) -> u16 {
        self.status
    }

    /// Returns the exact response body for immediate protocol processing.
    pub fn body(&self) -> &[u8] {
        &self.body
    }
}

impl std::fmt::Debug for DriveOAuthHttpResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DriveOAuthHttpResponse")
            .field("status", &self.status)
            .field("body", &"<redacted>")
            .finish()
    }
}

/// A narrow transport seam for Google OAuth token exchange and refresh operations.
pub trait DriveOAuthTransport: Send + Sync {
    /// Posts URL-encoded form fields and returns a bounded raw HTTP response.
    fn post_form(&self, endpoint: &str, form: &[(&str, &str)]) -> Result<DriveOAuthHttpResponse>;
}

/// A synchronous HTTPS Google OAuth transport with one bounded request timeout.
pub struct UreqDriveOAuthTransport {
    agent: ureq::Agent,
}

impl UreqDriveOAuthTransport {
    /// Constructs an HTTPS transport with a nonzero deadline for each request.
    pub fn new(request_timeout: Duration) -> Result<Self> {
        if request_timeout.is_zero() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth request timeout must not be zero",
            ));
        }
        Ok(Self {
            agent: ureq::AgentBuilder::new().timeout(request_timeout).build(),
        })
    }
}

impl DriveOAuthTransport for UreqDriveOAuthTransport {
    fn post_form(&self, endpoint: &str, form: &[(&str, &str)]) -> Result<DriveOAuthHttpResponse> {
        let response = match self
            .agent
            .post(endpoint)
            .set("accept", "application/json")
            .set("content-type", "application/x-www-form-urlencoded")
            .send_string(&form_urlencode(form))
        {
            Ok(response) => response,
            Err(ureq::Error::Status(_, response)) => response,
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "Google OAuth request failed",
                    error,
                ));
            }
        };
        let status = response.status();
        let mut body = Vec::new();
        response
            .into_reader()
            .take((MAXIMUM_TOKEN_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut body)
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "Google OAuth response could not be read",
                    error,
                )
            })?;
        DriveOAuthHttpResponse::new(status, body)
    }
}

impl std::fmt::Debug for UreqDriveOAuthTransport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("UreqDriveOAuthTransport")
    }
}

/// One access and refresh token pair obtained through Google OAuth.
pub struct DriveOAuthToken {
    access_token: Zeroizing<String>,
    refresh_token: Zeroizing<String>,
    expires_in: Duration,
}

impl DriveOAuthToken {
    /// Returns the bearer token for an immediate authenticated Google API request.
    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    /// Returns the refresh token for immediate OS-credential-store persistence only.
    pub fn refresh_token(&self) -> &str {
        &self.refresh_token
    }

    /// Returns the access-token lifetime reported by Google.
    pub const fn expires_in(&self) -> Duration {
        self.expires_in
    }
}

impl std::fmt::Debug for DriveOAuthToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveOAuthToken(<redacted>)")
    }
}

/// One short-lived bearer access token obtained through Google OAuth.
pub struct DriveAccessToken {
    access_token: Zeroizing<String>,
    expires_in: Duration,
}

impl DriveAccessToken {
    /// Returns the bearer token for one immediate authenticated Google API request.
    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    /// Returns the lifetime reported by Google for this access token.
    pub const fn expires_in(&self) -> Duration {
        self.expires_in
    }
}

impl std::fmt::Debug for DriveAccessToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveAccessToken(<redacted>)")
    }
}

#[cfg(test)]
impl DriveOAuthToken {
    pub(crate) fn test_token(access_token: &str, refresh_token: &str) -> Self {
        Self {
            access_token: Zeroizing::new(access_token.to_owned()),
            refresh_token: Zeroizing::new(refresh_token.to_owned()),
            expires_in: Duration::from_secs(3600),
        }
    }
}

/// A pending PKCE authorization bound to one loopback listener and state value.
pub struct DriveOAuthLoopback {
    configuration: DriveOAuthConfiguration,
    listener: TcpListener,
    redirect_uri: String,
    authorization_url: String,
    state: Zeroizing<String>,
    code_verifier: Zeroizing<String>,
}

impl DriveOAuthLoopback {
    fn begin(configuration: DriveOAuthConfiguration, requested_port: u16) -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", requested_port)).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Google OAuth loopback listener could not be bound",
                error,
            )
        })?;
        listener.set_nonblocking(true).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Google OAuth loopback listener could not be configured",
                error,
            )
        })?;
        let port = listener
            .local_addr()
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "Google OAuth loopback listener could not be inspected",
                    error,
                )
            })?
            .port();
        let redirect_uri = format!("http://127.0.0.1:{port}{LOOPBACK_CALLBACK_PATH}");
        let state = random_base64url()?;
        let code_verifier = random_base64url()?;
        let code_challenge = base64url_encode(&Sha256::digest(code_verifier.as_bytes()));
        let authorization_url = format!(
            "{AUTHORIZATION_ENDPOINT}?{}",
            form_urlencode(&[
                ("access_type", "offline"),
                ("client_id", &configuration.client_id),
                ("code_challenge", &code_challenge),
                ("code_challenge_method", "S256"),
                ("prompt", "consent"),
                ("redirect_uri", &redirect_uri),
                ("response_type", "code"),
                ("scope", DRIVE_FILE_SCOPE),
                ("state", &state),
            ])
        );
        Ok(Self {
            configuration,
            listener,
            redirect_uri,
            authorization_url,
            state,
            code_verifier,
        })
    }

    /// Returns the URL that must be opened in a system browser for consent.
    pub fn authorization_url(&self) -> &str {
        &self.authorization_url
    }

    /// Returns the exact loopback redirect URI bound to this authorization request.
    pub fn redirect_uri(&self) -> &str {
        &self.redirect_uri
    }

    /// Waits for the loopback callback, verifies state, and exchanges its code.
    pub fn complete<T: DriveOAuthTransport>(
        self,
        transport: &T,
        timeout: Duration,
    ) -> Result<DriveOAuthToken> {
        let code = self.wait_for_callback(timeout)?;
        exchange_code(
            transport,
            &self.configuration.client_id,
            &self.redirect_uri,
            &self.code_verifier,
            &code,
        )
    }

    fn wait_for_callback(&self, timeout: Duration) -> Result<Zeroizing<String>> {
        if timeout.is_zero() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth callback timeout must not be zero",
            ));
        }
        let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidInput,
                "Google OAuth callback timeout is invalid",
            )
        })?;
        loop {
            match self.listener.accept() {
                Ok((mut stream, _)) => return self.handle_callback(&mut stream, deadline),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(Error::new(
                            ErrorKind::Conflict,
                            "Google OAuth callback timed out",
                        ));
                    }
                    thread::sleep(Duration::from_millis(25));
                }
                Err(error) => {
                    return Err(Error::with_source(
                        ErrorKind::Io,
                        "Google OAuth callback could not be accepted",
                        error,
                    ));
                }
            }
        }
    }

    fn handle_callback(
        &self,
        stream: &mut TcpStream,
        deadline: Instant,
    ) -> Result<Zeroizing<String>> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Google OAuth callback timed out",
            ));
        }
        stream.set_read_timeout(Some(remaining)).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Google OAuth callback could not be configured",
                error,
            )
        })?;
        let request = read_loopback_request(stream)?;
        let (code, state) = parse_loopback_request(&request)?;
        if state != self.state.as_str() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Google OAuth callback state is invalid",
            ));
        }
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\nconnection: close\r\n\r\n<html><body>Authorization completed. Return to Yeokcham.</body></html>",
        );
        Ok(Zeroizing::new(code))
    }
}

impl std::fmt::Debug for DriveOAuthLoopback {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveOAuthLoopback(<redacted>)")
    }
}

fn exchange_code<T: DriveOAuthTransport>(
    transport: &T,
    client_id: &str,
    redirect_uri: &str,
    code_verifier: &str,
    code: &str,
) -> Result<DriveOAuthToken> {
    let response = transport.post_form(
        TOKEN_ENDPOINT,
        &[
            ("client_id", client_id),
            ("code", code),
            ("code_verifier", code_verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirect_uri),
        ],
    )?;
    parse_token_response(response)
}

fn parse_token_response(response: DriveOAuthHttpResponse) -> Result<DriveOAuthToken> {
    let (access_token, expires_in, value) = parse_access_token_values(response)?;
    let refresh_token = required_token_string(&value, "refresh_token")?;
    Ok(DriveOAuthToken {
        access_token,
        refresh_token,
        expires_in,
    })
}

fn parse_access_token_response(response: DriveOAuthHttpResponse) -> Result<DriveAccessToken> {
    let (access_token, expires_in, _) = parse_access_token_values(response)?;
    Ok(DriveAccessToken {
        access_token,
        expires_in,
    })
}

fn parse_access_token_values(
    response: DriveOAuthHttpResponse,
) -> Result<(Zeroizing<String>, Duration, Value)> {
    if response.status() != 200 {
        return Err(Error::new(
            ErrorKind::Conflict,
            "Google OAuth token exchange was rejected",
        ));
    }
    let value: Value = serde_json::from_slice(response.body()).map_err(|error| {
        Error::with_source(
            ErrorKind::CorruptData,
            "Google OAuth token response is invalid",
            error,
        )
    })?;
    let access_token = required_token_string(&value, "access_token")?;
    let token_type = required_token_string(&value, "token_type")?;
    if !token_type.eq_ignore_ascii_case("bearer") {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "Google OAuth token type is invalid",
        ));
    }
    if let Some(scope) = value.get("scope") {
        let scope = scope.as_str().ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Google OAuth token scope is invalid",
            )
        })?;
        if !scope
            .split_ascii_whitespace()
            .any(|scope| scope == DRIVE_FILE_SCOPE)
        {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Google OAuth token scope was not granted",
            ));
        }
    }
    let expires_in = value
        .get("expires_in")
        .and_then(Value::as_u64)
        .filter(|seconds| *seconds > 0)
        .ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Google OAuth token expiration is invalid",
            )
        })?;
    Ok((access_token, Duration::from_secs(expires_in), value))
}

fn required_token_string(value: &Value, field: &str) -> Result<Zeroizing<String>> {
    let value = value
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= MAXIMUM_TOKEN_RESPONSE_BYTES)
        .ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Google OAuth token response is invalid",
            )
        })?;
    Ok(Zeroizing::new(value.to_owned()))
}

fn read_loopback_request(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut request = Vec::new();
    let mut buffer = [0; 1024];
    while request.len() < MAXIMUM_LOOPBACK_REQUEST_BYTES {
        let read = stream.read(&mut buffer).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Google OAuth callback could not be read",
                error,
            )
        })?;
        if read == 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Google OAuth callback is incomplete",
            ));
        }
        request.extend_from_slice(&buffer[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            return Ok(request);
        }
    }
    Err(Error::new(
        ErrorKind::CorruptData,
        "Google OAuth callback exceeds the byte limit",
    ))
}

fn parse_loopback_request(request: &[u8]) -> Result<(String, String)> {
    let request = std::str::from_utf8(request)
        .map_err(|_| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))?;
    let request_line = request
        .split("\r\n")
        .next()
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))?;
    let mut request_line = request_line.split_ascii_whitespace();
    if request_line.next() != Some("GET")
        || request_line.next().is_none_or(|target| {
            let (path, _) = target.split_once('?').unwrap_or((target, ""));
            path != LOOPBACK_CALLBACK_PATH
        })
        || request_line.next() != Some("HTTP/1.1")
        || request_line.next().is_some()
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "Google OAuth callback is invalid",
        ));
    }
    let target = request_line_placeholder(request)?;
    let (_, query) = target
        .split_once('?')
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))?;
    let fields = form_urldecode(query)?;
    let code = unique_form_value(&fields, "code")?;
    let state = unique_form_value(&fields, "state")?;
    Ok((code, state))
}

fn request_line_placeholder(request: &str) -> Result<&str> {
    let request_line = request
        .split("\r\n")
        .next()
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))?;
    request_line
        .split_ascii_whitespace()
        .nth(1)
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))
}

fn form_urldecode(query: &str) -> Result<Vec<(String, String)>> {
    let mut fields = Vec::new();
    for part in query.split('&') {
        if part.is_empty() || fields.len() >= 16 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Google OAuth callback is invalid",
            ));
        }
        let (name, value) = part.split_once('=').ok_or_else(|| {
            Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid")
        })?;
        let name = form_urldecode_component(name)?;
        let value = form_urldecode_component(value)?;
        if name.is_empty()
            || value.len() > MAXIMUM_LOOPBACK_REQUEST_BYTES
            || fields.iter().any(|(existing, _)| existing == &name)
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Google OAuth callback is invalid",
            ));
        }
        fields.push((name, value));
    }
    Ok(fields)
}

fn unique_form_value(fields: &[(String, String)], name: &str) -> Result<String> {
    fields
        .iter()
        .find_map(|(field, value)| (field == name).then(|| value.clone()))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))
}

fn form_urldecode_component(value: &str) -> Result<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut index = 0;
    let value = value.as_bytes();
    while index < value.len() {
        match value[index] {
            b'+' => bytes.push(b' '),
            b'%' if index + 2 < value.len() => {
                let high = decode_hex(value[index + 1]).ok_or_else(|| {
                    Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid")
                })?;
                let low = decode_hex(value[index + 2]).ok_or_else(|| {
                    Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid")
                })?;
                bytes.push((high << 4) | low);
                index += 2;
            }
            b'%' => {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "Google OAuth callback is invalid",
                ));
            }
            byte if byte.is_ascii() && !byte.is_ascii_control() => bytes.push(byte),
            _ => {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "Google OAuth callback is invalid",
                ));
            }
        }
        index += 1;
    }
    String::from_utf8(bytes)
        .map_err(|_| Error::new(ErrorKind::CorruptData, "Google OAuth callback is invalid"))
}

fn decode_hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn form_urlencode(fields: &[(&str, &str)]) -> String {
    let mut encoded = String::new();
    for (index, (name, value)) in fields.iter().enumerate() {
        if index != 0 {
            encoded.push('&');
        }
        form_urlencode_component(name, &mut encoded);
        encoded.push('=');
        form_urlencode_component(value, &mut encoded);
    }
    encoded
}

fn form_urlencode_component(value: &str, encoded: &mut String) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else if byte == b' ' {
            encoded.push('+');
        } else {
            encoded.push('%');
            encoded.push(char::from(HEX[(byte >> 4) as usize]));
            encoded.push(char::from(HEX[(byte & 0x0f) as usize]));
        }
    }
}

fn random_base64url() -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(vec![0; RANDOM_TOKEN_BYTES]);
    getrandom::fill(bytes.as_mut_slice()).map_err(|error| {
        Error::with_source(
            ErrorKind::Io,
            "Google OAuth random state could not be generated",
            error,
        )
    })?;
    Ok(Zeroizing::new(base64url_encode(&bytes)))
}

fn base64url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::with_capacity((bytes.len() * 4).div_ceil(3));
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        encoded.push(char::from(ALPHABET[(first >> 2) as usize]));
        encoded.push(char::from(
            ALPHABET[(((first & 0x03) << 4) | (chunk.get(1).copied().unwrap_or(0) >> 4)) as usize],
        ));
        if let Some(second) = chunk.get(1) {
            encoded.push(char::from(
                ALPHABET
                    [(((second & 0x0f) << 2) | (chunk.get(2).copied().unwrap_or(0) >> 6)) as usize],
            ));
        }
        if let Some(third) = chunk.get(2) {
            encoded.push(char::from(ALPHABET[(third & 0x3f) as usize]));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, net::TcpStream, sync::Mutex};

    use super::*;

    struct FakeTransport {
        response: Mutex<Option<DriveOAuthHttpResponse>>,
        form: Mutex<BTreeMap<String, String>>,
    }

    impl FakeTransport {
        fn new(response: DriveOAuthHttpResponse) -> Self {
            Self {
                response: Mutex::new(Some(response)),
                form: Mutex::new(BTreeMap::new()),
            }
        }
    }

    impl DriveOAuthTransport for FakeTransport {
        fn post_form(
            &self,
            endpoint: &str,
            form: &[(&str, &str)],
        ) -> Result<DriveOAuthHttpResponse> {
            assert_eq!(endpoint, TOKEN_ENDPOINT);
            let mut recorded = self.form.lock().expect("form mutex");
            recorded.extend(
                form.iter()
                    .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
            );
            Ok(self
                .response
                .lock()
                .expect("response mutex")
                .take()
                .expect("one response"))
        }
    }

    fn configuration() -> DriveOAuthConfiguration {
        DriveOAuthConfiguration::new("123.apps.googleusercontent.com").expect("configuration")
    }

    fn success_response() -> DriveOAuthHttpResponse {
        DriveOAuthHttpResponse::new(
            200,
            br#"{"access_token":"access-token","refresh_token":"refresh-token","token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.file","expires_in":3600}"#.to_vec(),
        )
        .expect("response")
    }

    fn send_callback(loopback: &DriveOAuthLoopback, state: &str) -> std::thread::JoinHandle<()> {
        let redirect_uri = loopback.redirect_uri().to_owned();
        let state = form_urlencode(&[("state", state), ("code", "authorization-code")]);
        std::thread::spawn(move || {
            for _ in 0..20 {
                let address = redirect_uri
                    .strip_prefix("http://")
                    .expect("loopback scheme")
                    .split_once('/')
                    .expect("loopback path")
                    .0;
                if let Ok(mut stream) = TcpStream::connect(address) {
                    let path = redirect_uri
                        .strip_prefix(&format!("http://{address}"))
                        .expect("callback path");
                    stream
                        .write_all(
                            format!("GET {path}?{state} HTTP/1.1\r\nHost: {address}\r\n\r\n")
                                .as_bytes(),
                        )
                        .expect("write callback");
                    return;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            panic!("connect loopback callback");
        })
    }

    #[test]
    fn starts_a_pkce_loopback_authorization() {
        let loopback = configuration().begin_loopback().expect("loopback");
        let url = loopback.authorization_url();

        assert!(url.starts_with(AUTHORIZATION_ENDPOINT));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"));
        assert!(loopback.redirect_uri().starts_with("http://127.0.0.1:"));
        assert_eq!(format!("{loopback:?}"), "DriveOAuthLoopback(<redacted>)");
    }

    #[test]
    fn exchanges_a_state_bound_loopback_callback_for_tokens() {
        let loopback = configuration().begin_loopback().expect("loopback");
        let callback = send_callback(&loopback, &loopback.state);
        let transport = FakeTransport::new(success_response());

        let token = loopback
            .complete(&transport, Duration::from_secs(1))
            .expect("token exchange");
        callback.join().expect("callback thread");
        let form = transport.form.lock().expect("form mutex");
        assert_eq!(
            form.get("grant_type"),
            Some(&"authorization_code".to_owned())
        );
        assert_eq!(form.get("code"), Some(&"authorization-code".to_owned()));
        assert!(!form.get("code_verifier").expect("verifier").is_empty());
        assert_eq!(token.access_token(), "access-token");
        assert_eq!(token.refresh_token(), "refresh-token");
        assert_eq!(token.expires_in(), Duration::from_secs(3600));
        assert_eq!(format!("{token:?}"), "DriveOAuthToken(<redacted>)");
    }

    #[test]
    fn rejects_wrong_callback_state_without_exchanging_a_code() {
        let loopback = configuration().begin_loopback().expect("loopback");
        let callback = send_callback(&loopback, "wrong-state");
        let transport = FakeTransport::new(success_response());

        let error = loopback
            .complete(&transport, Duration::from_secs(1))
            .expect_err("state mismatch");
        callback.join().expect("callback thread");
        assert_eq!(error.kind(), ErrorKind::Conflict);
        assert!(transport.form.lock().expect("form mutex").is_empty());
    }

    #[test]
    fn rejects_unusable_configuration_and_token_responses() {
        assert!(DriveOAuthConfiguration::new("").is_err());
        assert!(DriveOAuthConfiguration::new("contains space").is_err());
        let response =
            DriveOAuthHttpResponse::new(200, b"token-response-secret".to_vec()).expect("response");
        assert!(!format!("{response:?}").contains("token-response-secret"));
        assert!(
            DriveOAuthHttpResponse::new(200, vec![0; MAXIMUM_TOKEN_RESPONSE_BYTES + 1]).is_err()
        );
        let response = DriveOAuthHttpResponse::new(
            200,
            br#"{"access_token":"access","token_type":"Bearer","expires_in":3600}"#.to_vec(),
        )
        .expect("response");
        assert_eq!(
            parse_token_response(response)
                .expect_err("refresh token required")
                .kind(),
            ErrorKind::CorruptData
        );
    }

    #[test]
    fn refreshes_an_access_token_without_requiring_a_new_refresh_token() {
        let transport = FakeTransport::new(
            DriveOAuthHttpResponse::new(
                200,
                br#"{"access_token":"fresh-access-token","token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.file","expires_in":3600}"#.to_vec(),
            )
            .expect("response"),
        );

        let token = configuration()
            .refresh_access_token("persisted-refresh-token", &transport)
            .expect("refresh token");
        let form = transport.form.lock().expect("form mutex");
        assert_eq!(form.get("grant_type"), Some(&"refresh_token".to_owned()));
        assert_eq!(
            form.get("refresh_token"),
            Some(&"persisted-refresh-token".to_owned())
        );
        assert_eq!(token.access_token(), "fresh-access-token");
        assert_eq!(token.expires_in(), Duration::from_secs(3600));
        assert_eq!(format!("{token:?}"), "DriveAccessToken(<redacted>)");
    }
}
