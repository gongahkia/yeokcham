use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    sync::Mutex,
    thread,
    time::Duration,
};

use serde_json::Value;

use crate::{
    Backend, BackendByteRange, BackendCursor, BackendFuture, BackendKey, BackendListEntry,
    BackendListLimits, BackendListPage, BackendObjectMetadata, BackendPrefix, BackendPutResult,
    BackendReadRequest, BackendResumablePutStart, BackendUploadSession, DriveAccessToken,
    DriveCredentialStore, DriveOAuthConfiguration, DriveOAuthTransport, DriveObjectName,
    DriveObjectNamingKey, Error, ErrorKind, Result,
};

const DRIVE_API_ROOT: &str = "https://www.googleapis.com/drive/v3";
const DRIVE_UPLOAD_ROOT: &str = "https://www.googleapis.com/upload/drive/v3";
const DRIVE_FILE_MIME_TYPE: &str = "application/octet-stream";
const MAXIMUM_DRIVE_ID_BYTES: usize = 256;
const MAXIMUM_PAGE_TOKEN_BYTES: usize = 4_096;
const MAXIMUM_DRIVE_RESPONSE_BYTES: usize = 64 * 1024;
const DRIVE_LIST_PAGE_SIZE: usize = 1_000;
const RESUMABLE_CHUNK_BYTES: usize = 256 * 1024;
const CAPSULE_PREFIX_BYTES: usize = 32;
const MAXIMUM_METADATA_CACHE_ENTRIES: usize = 4_096;

/// One validated opaque Google Drive folder identifier.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DriveFolderId(String);

impl DriveFolderId {
    /// Validates one Drive resource identifier supplied by an explicit setup workflow.
    pub fn new(id: impl Into<String>) -> Result<Self> {
        let id = id.into();
        validate_drive_identifier(&id, "Drive folder ID is invalid")?;
        Ok(Self(id))
    }

    /// Returns the identifier only for an authenticated Drive API request.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Creates one visible dedicated Drive folder with an opaque random name.
    ///
    /// The caller's OAuth client creates this folder under `drive.file`; no
    /// pre-existing arbitrary folder access is assumed or requested.
    pub fn create<T: DriveHttpTransport, A: DriveAccessTokenProvider>(
        transport: &T,
        access_tokens: &A,
    ) -> Result<Self> {
        let mut name = [0; 32];
        getrandom::fill(&mut name).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Drive folder name could not be generated",
                error,
            )
        })?;
        let metadata = format!(
            r#"{{"name":"{}","mimeType":"application/vnd.google-apps.folder"}}"#,
            hex::encode(name),
        );
        let request = DriveHttpRequest::new(
            DriveHttpMethod::Post,
            format!("{DRIVE_API_ROOT}/files?fields=id&supportsAllDrives=true"),
            vec![(
                "content-type".to_owned(),
                "application/json; charset=UTF-8".to_owned(),
            )],
            metadata.into_bytes(),
            MAXIMUM_DRIVE_RESPONSE_BYTES,
        )?;
        let token = access_tokens.access_token()?;
        let response = transport.request(&request.with_bearer_token(token.access_token())?)?;
        require_status(&response, &[200, 201], "Drive folder could not be created")?;
        Self::new(parse_created_file_id(response.body())?)
    }
}

impl std::fmt::Debug for DriveFolderId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveFolderId(<redacted>)")
    }
}

/// Supplies one short-lived bearer token for a Drive HTTP request.
pub trait DriveAccessTokenProvider: Send + Sync {
    /// Returns one access token without exposing persisted credential material.
    fn access_token(&self) -> Result<DriveAccessToken>;
}

/// Refreshes OS-stored Drive credentials on demand for Drive API requests.
pub struct StoredDriveAccessTokenProvider<C, T> {
    configuration: DriveOAuthConfiguration,
    credential_store: C,
    oauth_transport: T,
}

impl<C, T> StoredDriveAccessTokenProvider<C, T> {
    /// Creates a provider that reads only a refresh token from the supplied credential store.
    pub fn new(
        configuration: DriveOAuthConfiguration,
        credential_store: C,
        oauth_transport: T,
    ) -> Self {
        Self {
            configuration,
            credential_store,
            oauth_transport,
        }
    }
}

impl<C: DriveCredentialStore, T: DriveOAuthTransport> DriveAccessTokenProvider
    for StoredDriveAccessTokenProvider<C, T>
{
    fn access_token(&self) -> Result<DriveAccessToken> {
        self.credential_store
            .load(&self.configuration)?
            .refresh_access_token(&self.configuration, &self.oauth_transport)
    }
}

impl<C, T> std::fmt::Debug for StoredDriveAccessTokenProvider<C, T> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("StoredDriveAccessTokenProvider(<redacted>)")
    }
}

/// An HTTP method accepted by the restricted Drive transport interface.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DriveHttpMethod {
    /// A read-only request.
    Get,
    /// A create request.
    Post,
    /// An idempotent range upload request.
    Put,
    /// A maintenance delete request.
    Delete,
}

/// One bounded HTTP request sent only to a validated Drive endpoint.
#[derive(Clone)]
pub struct DriveHttpRequest {
    method: DriveHttpMethod,
    url: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    maximum_response_bytes: usize,
}

impl DriveHttpRequest {
    /// Validates and constructs a restricted Drive HTTP request.
    pub fn new(
        method: DriveHttpMethod,
        url: impl Into<String>,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
        maximum_response_bytes: usize,
    ) -> Result<Self> {
        let url = url.into();
        if !is_drive_url(&url) || maximum_response_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Drive HTTP request is invalid",
            ));
        }
        for (name, value) in &headers {
            if name.is_empty()
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                || value.bytes().any(|byte| matches!(byte, b'\r' | b'\n'))
            {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    "Drive HTTP request headers are invalid",
                ));
            }
        }
        Ok(Self {
            method,
            url,
            headers,
            body,
            maximum_response_bytes,
        })
    }

    /// Returns the request method for a transport implementation.
    pub const fn method(&self) -> DriveHttpMethod {
        self.method
    }

    /// Returns the validated Drive URL for a transport implementation.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Returns request headers for a transport implementation.
    pub fn headers(&self) -> &[(String, String)] {
        &self.headers
    }

    /// Returns the exact request body for a transport implementation.
    pub fn body(&self) -> &[u8] {
        &self.body
    }

    /// Returns the hard response-byte limit for a transport implementation.
    pub const fn maximum_response_bytes(&self) -> usize {
        self.maximum_response_bytes
    }

    fn with_bearer_token(&self, access_token: &str) -> Result<Self> {
        let mut headers = self.headers.clone();
        headers.push(("authorization".to_owned(), format!("Bearer {access_token}")));
        Self::new(
            self.method,
            self.url.clone(),
            headers,
            self.body.clone(),
            self.maximum_response_bytes,
        )
    }
}

impl std::fmt::Debug for DriveHttpRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DriveHttpRequest")
            .field("method", &self.method)
            .field("url", &"<redacted>")
            .field("headers", &"<redacted>")
            .field("body", &"<redacted>")
            .field("maximum_response_bytes", &self.maximum_response_bytes)
            .finish()
    }
}

/// One bounded HTTP response returned by a Drive transport.
pub struct DriveHttpResponse {
    status: u16,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

impl DriveHttpResponse {
    /// Validates and constructs one bounded Drive HTTP response.
    pub fn new(status: u16, headers: Vec<(String, String)>, body: Vec<u8>) -> Result<Self> {
        let mut normalized = BTreeMap::new();
        for (name, value) in headers {
            if name.is_empty()
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                || value.bytes().any(|byte| matches!(byte, b'\r' | b'\n'))
            {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    "Drive HTTP response headers are invalid",
                ));
            }
            normalized.insert(name.to_ascii_lowercase(), value);
        }
        Ok(Self {
            status,
            headers: normalized,
            body,
        })
    }

    /// Returns the HTTP response status.
    pub const fn status(&self) -> u16 {
        self.status
    }

    /// Returns one case-insensitive response header.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }

    /// Returns exact response bytes for immediate protocol parsing.
    pub fn body(&self) -> &[u8] {
        &self.body
    }
}

impl std::fmt::Debug for DriveHttpResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DriveHttpResponse")
            .field("status", &self.status)
            .field("headers", &"<redacted>")
            .field("body", &"<redacted>")
            .finish()
    }
}

/// Restricted HTTPS transport seam for Google Drive requests.
pub trait DriveHttpTransport: Send + Sync {
    /// Sends one bounded request to a validated Drive endpoint.
    fn request(&self, request: &DriveHttpRequest) -> Result<DriveHttpResponse>;
}

/// Synchronous HTTPS transport for Drive API operations.
pub struct UreqDriveHttpTransport {
    agent: ureq::Agent,
}

impl UreqDriveHttpTransport {
    /// Constructs a non-redirecting HTTPS transport with one nonzero request deadline.
    pub fn new(request_timeout: Duration) -> Result<Self> {
        if request_timeout.is_zero() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Drive request timeout must not be zero",
            ));
        }
        Ok(Self {
            agent: ureq::AgentBuilder::new()
                .timeout(request_timeout)
                .redirects(0)
                .build(),
        })
    }
}

impl DriveHttpTransport for UreqDriveHttpTransport {
    fn request(&self, request: &DriveHttpRequest) -> Result<DriveHttpResponse> {
        let mut request_builder = match request.method() {
            DriveHttpMethod::Get => self.agent.get(request.url()),
            DriveHttpMethod::Post => self.agent.post(request.url()),
            DriveHttpMethod::Put => self.agent.put(request.url()),
            DriveHttpMethod::Delete => self.agent.delete(request.url()),
        };
        for (name, value) in request.headers() {
            request_builder = request_builder.set(name, value);
        }
        let response = match request_builder.send_bytes(request.body()) {
            Ok(response) => response,
            Err(ureq::Error::Status(_, response)) => response,
            Err(error) => {
                return Err(Error::with_source(
                    ErrorKind::Io,
                    "Drive HTTP request failed",
                    error,
                ));
            }
        };
        let status = response.status();
        let headers = response
            .headers_names()
            .into_iter()
            .filter_map(|name| response.header(&name).map(|value| (name, value.to_owned())))
            .collect();
        let mut body = Vec::new();
        response
            .into_reader()
            .take(
                u64::try_from(request.maximum_response_bytes())
                    .map_err(|_| {
                        Error::new(
                            ErrorKind::Unsupported,
                            "Drive response-byte limit is invalid",
                        )
                    })?
                    .checked_add(1)
                    .ok_or_else(|| {
                        Error::new(
                            ErrorKind::Unsupported,
                            "Drive response-byte limit is invalid",
                        )
                    })?,
            )
            .read_to_end(&mut body)
            .map_err(|error| {
                Error::with_source(
                    ErrorKind::Io,
                    "Drive HTTP response could not be read",
                    error,
                )
            })?;
        if body.len() > request.maximum_response_bytes() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Drive HTTP response exceeds the byte limit",
            ));
        }
        DriveHttpResponse::new(status, headers, body)
    }
}

impl std::fmt::Debug for UreqDriveHttpTransport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("UreqDriveHttpTransport")
    }
}

/// Bounded retry policy for transient Drive API responses.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DriveRetryPolicy {
    maximum_attempts: u8,
    initial_delay: Duration,
    maximum_delay: Duration,
}

impl DriveRetryPolicy {
    /// Validates a finite exponential-backoff policy.
    pub fn new(
        maximum_attempts: u8,
        initial_delay: Duration,
        maximum_delay: Duration,
    ) -> Result<Self> {
        if maximum_attempts == 0 || initial_delay.is_zero() || maximum_delay < initial_delay {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Drive retry policy is invalid",
            ));
        }
        Ok(Self {
            maximum_attempts,
            initial_delay,
            maximum_delay,
        })
    }

    /// Returns the finite default for rate-limit and transient service responses.
    pub fn default_bounded() -> Self {
        Self {
            maximum_attempts: 5,
            initial_delay: Duration::from_millis(250),
            maximum_delay: Duration::from_secs(4),
        }
    }
}

/// Sleeps between bounded retry attempts.
pub trait DriveSleeper: Send + Sync {
    /// Delays one retry without changing Drive state.
    fn sleep(&self, delay: Duration);
}

/// Production retry sleeper.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemDriveSleeper;

impl DriveSleeper for SystemDriveSleeper {
    fn sleep(&self, delay: Duration) {
        thread::sleep(delay);
    }
}

#[derive(Clone, Debug)]
struct DriveFile {
    id: String,
    name: String,
    size: u64,
}

#[derive(Default)]
struct DriveMetadataCache {
    files: BTreeMap<DriveObjectName, DriveFile>,
}

impl DriveMetadataCache {
    fn get(&self, name: &DriveObjectName) -> Option<DriveFile> {
        self.files.get(name).cloned()
    }

    fn insert(&mut self, name: DriveObjectName, file: DriveFile) {
        if !self.files.contains_key(&name) && self.files.len() >= MAXIMUM_METADATA_CACHE_ENTRIES {
            if let Some(oldest) = self.files.keys().next().cloned() {
                self.files.remove(&oldest);
            }
        }
        self.files.insert(name, file);
    }

    fn remove(&mut self, name: &DriveObjectName) {
        self.files.remove(name);
    }
}

struct DriveUploadState {
    key: BackendKey,
    name: DriveObjectName,
    session_url: String,
    physical_total: u64,
    logical_written: u64,
    physical_uploaded: u64,
    pending: Vec<u8>,
    completed: bool,
    created_file_id: Option<String>,
}

/// Google Drive implementation of the immutable backend contract.
///
/// It stores a randomized encrypted key capsule before each payload so list can
/// reconstruct logical keys while all provider-visible names remain opaque. Wrap
/// this physical backend in [`crate::EncryptedBackend`] before storing source or
/// repository bytes.
pub struct DriveBackend<T, A, S = SystemDriveSleeper> {
    folder: DriveFolderId,
    naming_key: DriveObjectNamingKey,
    transport: T,
    access_tokens: A,
    retry_policy: DriveRetryPolicy,
    sleeper: S,
    metadata_cache: Mutex<DriveMetadataCache>,
    uploads: Mutex<BTreeMap<[u8; 16], DriveUploadState>>,
}

impl<T, A> DriveBackend<T, A, SystemDriveSleeper> {
    /// Constructs one backend rooted at an app-created or app-opened Drive folder.
    pub fn new(
        folder: DriveFolderId,
        naming_key: DriveObjectNamingKey,
        transport: T,
        access_tokens: A,
    ) -> Self {
        Self {
            folder,
            naming_key,
            transport,
            access_tokens,
            retry_policy: DriveRetryPolicy::default_bounded(),
            sleeper: SystemDriveSleeper,
            metadata_cache: Mutex::new(DriveMetadataCache::default()),
            uploads: Mutex::new(BTreeMap::new()),
        }
    }
}

impl<T, A, S> DriveBackend<T, A, S> {
    /// Replaces the bounded retry policy before any Drive operation runs.
    pub fn with_retry_policy(mut self, retry_policy: DriveRetryPolicy) -> Self {
        self.retry_policy = retry_policy;
        self
    }

    /// Replaces the retry sleeper, primarily for deterministic transport tests.
    pub fn with_sleeper<S2>(self, sleeper: S2) -> DriveBackend<T, A, S2> {
        DriveBackend {
            folder: self.folder,
            naming_key: self.naming_key,
            transport: self.transport,
            access_tokens: self.access_tokens,
            retry_policy: self.retry_policy,
            sleeper,
            metadata_cache: self.metadata_cache,
            uploads: self.uploads,
        }
    }
}

impl<T: DriveHttpTransport, A: DriveAccessTokenProvider, S: DriveSleeper> DriveBackend<T, A, S> {
    fn put_if_absent_sync(&self, key: &BackendKey, data: &[u8]) -> Result<BackendPutResult> {
        let total_length = u64::try_from(data.len())
            .map_err(|_| Error::new(ErrorKind::Unsupported, "Drive object is too large"))?;
        match self.start_resumable_sync(key, total_length)? {
            BackendResumablePutStart::AlreadyExists(metadata) => {
                Ok(BackendPutResult::AlreadyExists(metadata))
            }
            BackendResumablePutStart::Started(session) => {
                self.write_resumable_sync(&session, 0, data)?;
                self.complete_resumable_sync(&session)
            }
        }
    }

    fn get_sync(&self, key: &BackendKey, request: BackendReadRequest) -> Result<Vec<u8>> {
        let (file, name) = self.lookup_key(key)?;
        let (capsule_length, logical_length) = self.verify_capsule(key, &name, &file)?;
        let range = requested_range(logical_length, request.requested_range())?;
        if range.len() > request.limits().maximum_bytes() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "backend read exceeds the byte limit",
            ));
        }
        if range.is_empty() {
            return Ok(Vec::new());
        }
        let physical_start = u64::try_from(capsule_length)
            .ok()
            .and_then(|length| length.checked_add(range.start()))
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "Drive object range overflows"))?;
        let physical_end = u64::try_from(capsule_length)
            .ok()
            .and_then(|length| length.checked_add(range.end_exclusive()))
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "Drive object range overflows"))?;
        let body = self.download_range(&file.id, physical_start, physical_end)?;
        if u64::try_from(body.len()).ok() != Some(range.len()) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object range response is invalid",
            ));
        }
        Ok(body)
    }

    fn head_sync(&self, key: &BackendKey) -> Result<BackendObjectMetadata> {
        let (file, name) = self.lookup_key(key)?;
        let (_, length) = self.verify_capsule(key, &name, &file)?;
        Ok(BackendObjectMetadata::new(length))
    }

    fn list_sync(
        &self,
        prefix: &BackendPrefix,
        cursor: Option<&BackendCursor>,
        limits: BackendListLimits,
    ) -> Result<BackendListPage> {
        let files = self.list_all_files(limits.maximum_scanned_entries())?;
        let mut entries = BTreeMap::new();
        for file in files {
            let Ok(name) = DriveObjectName::from_remote_name(&file.name) else {
                continue;
            };
            let (capsule_length, key) = self.read_capsule(&name, &file)?;
            let length = file
                .size
                .checked_sub(
                    u64::try_from(capsule_length).map_err(|_| {
                        Error::new(ErrorKind::Unsupported, "Drive object is too large")
                    })?,
                )
                .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Drive object is truncated"))?;
            self.cache_insert(name.clone(), file.clone())?;
            if key.as_bytes().starts_with(prefix.as_bytes())
                && entries
                    .insert(key.clone(), BackendObjectMetadata::new(length))
                    .is_some()
            {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "Drive backend contains duplicate logical keys",
                ));
            }
        }
        let cursor = cursor.map(BackendCursor::key);
        let mut entries: Vec<_> = entries
            .into_iter()
            .filter(|(key, _)| cursor.is_none_or(|cursor| key > cursor))
            .map(|(key, metadata)| BackendListEntry::new(key, metadata))
            .collect();
        let next_cursor = if entries.len() > limits.maximum_entries() {
            entries.truncate(limits.maximum_entries());
            entries
                .last()
                .map(|entry| BackendCursor::from_key(entry.key().clone()))
        } else {
            None
        };
        Ok(BackendListPage::new(entries, next_cursor))
    }

    fn delete_sync(&self, key: &BackendKey) -> Result<()> {
        let (file, name) = self.lookup_key(key)?;
        let response = self.authorized_request(
            DriveHttpRequest::new(
                DriveHttpMethod::Delete,
                format!("{DRIVE_API_ROOT}/files/{}?supportsAllDrives=true", file.id),
                Vec::new(),
                Vec::new(),
                MAXIMUM_DRIVE_RESPONSE_BYTES,
            )?,
            true,
        )?;
        require_status(&response, &[200, 204], "Drive object could not be deleted")?;
        self.cache_remove(&name)
    }

    fn start_resumable_sync(
        &self,
        key: &BackendKey,
        total_length: u64,
    ) -> Result<BackendResumablePutStart> {
        let name = self.drive_name(key)?;
        if let Some(file) = self.lookup_name_fresh(&name)? {
            let (_, logical_length) = self.verify_capsule(key, &name, &file)?;
            return Ok(BackendResumablePutStart::AlreadyExists(
                BackendObjectMetadata::new(logical_length),
            ));
        }
        let capsule = self.naming_key.seal_backend_key(key, &name)?;
        let physical_total = u64::try_from(capsule.len())
            .ok()
            .and_then(|length| length.checked_add(total_length))
            .ok_or_else(|| Error::new(ErrorKind::Unsupported, "Drive object is too large"))?;
        let metadata = format!(
            r#"{{"name":"{}","parents":["{}"],"mimeType":"{}"}}"#,
            name.as_str(),
            self.folder.as_str(),
            DRIVE_FILE_MIME_TYPE,
        );
        let response = self.authorized_request(
            DriveHttpRequest::new(
                DriveHttpMethod::Post,
                format!(
                    "{DRIVE_UPLOAD_ROOT}/files?uploadType=resumable&supportsAllDrives=true&fields=id"
                ),
                vec![
                    (
                        "content-type".to_owned(),
                        "application/json; charset=UTF-8".to_owned(),
                    ),
                    (
                        "x-upload-content-type".to_owned(),
                        DRIVE_FILE_MIME_TYPE.to_owned(),
                    ),
                    (
                        "x-upload-content-length".to_owned(),
                        physical_total.to_string(),
                    ),
                ],
                metadata.into_bytes(),
                MAXIMUM_DRIVE_RESPONSE_BYTES,
            )?,
            false,
        )?;
        require_status(
            &response,
            &[200],
            "Drive resumable upload could not be started",
        )?;
        let session_url = response.header("location").ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Drive resumable upload response has no session URL",
            )
        })?;
        if !is_drive_url(session_url) || session_url.len() > MAXIMUM_PAGE_TOKEN_BYTES {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive resumable upload session URL is invalid",
            ));
        }
        let mut id = [0; 16];
        getrandom::fill(&mut id).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "Drive upload ID could not be generated",
                error,
            )
        })?;
        let mut uploads = self
            .uploads
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive upload state lock is poisoned"))?;
        if uploads.contains_key(&id) {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Drive upload ID collision occurred",
            ));
        }
        uploads.insert(
            id,
            DriveUploadState {
                key: key.clone(),
                name,
                session_url: session_url.to_owned(),
                physical_total,
                logical_written: 0,
                physical_uploaded: 0,
                pending: capsule,
                completed: false,
                created_file_id: None,
            },
        );
        Ok(BackendResumablePutStart::Started(
            BackendUploadSession::new(key.clone(), id, total_length),
        ))
    }

    fn write_resumable_sync(
        &self,
        session: &BackendUploadSession,
        offset: u64,
        data: &[u8],
    ) -> Result<()> {
        let mut uploads = self
            .uploads
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive upload state lock is poisoned"))?;
        let state = uploads.get_mut(&session.id()).ok_or_else(|| {
            Error::new(
                ErrorKind::NotFound,
                "Drive resumable upload session does not exist",
            )
        })?;
        if state.key != *session.key() || offset != state.logical_written || state.completed {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Drive resumable write is not contiguous",
            ));
        }
        let end = offset
            .checked_add(u64::try_from(data.len()).map_err(|_| {
                Error::new(ErrorKind::Unsupported, "Drive resumable write is too large")
            })?)
            .ok_or_else(|| {
                Error::new(ErrorKind::InvalidInput, "Drive resumable range overflows")
            })?;
        if end > session.total_length() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Drive resumable write exceeds its total length",
            ));
        }
        state.pending.extend_from_slice(data);
        state.logical_written = end;
        self.flush_upload(state, end == session.total_length())
    }

    fn complete_resumable_sync(&self, session: &BackendUploadSession) -> Result<BackendPutResult> {
        let mut uploads = self
            .uploads
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive upload state lock is poisoned"))?;
        let state = uploads.get_mut(&session.id()).ok_or_else(|| {
            Error::new(
                ErrorKind::NotFound,
                "Drive resumable upload session does not exist",
            )
        })?;
        if state.key != *session.key() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Drive resumable upload key is invalid",
            ));
        }
        if state.logical_written != session.total_length() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Drive resumable upload is incomplete",
            ));
        }
        if !state.completed {
            self.flush_upload(state, true)?;
        }
        let expected_name = state.name.clone();
        let created_file_id = state.created_file_id.clone().ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "Drive resumable completion did not identify its file",
            )
        })?;
        drop(uploads);
        let mut files = self.files_named(&expected_name)?;
        let created = match files.len() {
            1 if files[0].id == created_file_id => true,
            1 => false,
            2 if files.iter().any(|file| file.id == created_file_id) => {
                self.delete_file_id(&created_file_id)?;
                files = self.files_named(&expected_name)?;
                if files.len() != 1 {
                    return Err(Error::new(
                        ErrorKind::Conflict,
                        "Drive backend contains duplicate object names",
                    ));
                }
                false
            }
            _ => {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "Drive resumable upload is not visible after completion",
                ));
            }
        };
        let file = files.pop().ok_or_else(|| {
            Error::new(
                ErrorKind::Conflict,
                "Drive resumable upload is not visible after completion",
            )
        })?;
        let (_, length) = self.verify_capsule(session.key(), &expected_name, &file)?;
        if length != session.total_length() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive completed object length is invalid",
            ));
        }
        let result = if created {
            BackendPutResult::Created(BackendObjectMetadata::new(length))
        } else {
            BackendPutResult::AlreadyExists(BackendObjectMetadata::new(length))
        };
        self.uploads
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive upload state lock is poisoned"))?
            .remove(&session.id());
        Ok(result)
    }

    fn abort_resumable_sync(&self, session: &BackendUploadSession) -> Result<()> {
        let state = self
            .uploads
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive upload state lock is poisoned"))?
            .remove(&session.id());
        let Some(state) = state else {
            return Ok(());
        };
        if state.key != *session.key() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "Drive resumable upload key is invalid",
            ));
        }
        let response = self.authorized_request(
            DriveHttpRequest::new(
                DriveHttpMethod::Delete,
                state.session_url,
                Vec::new(),
                Vec::new(),
                MAXIMUM_DRIVE_RESPONSE_BYTES,
            )?,
            true,
        )?;
        require_status(
            &response,
            &[200, 204, 404],
            "Drive resumable upload could not be aborted",
        )
    }

    fn flush_upload(&self, state: &mut DriveUploadState, final_write: bool) -> Result<()> {
        loop {
            let bytes_to_upload = if final_write {
                state.pending.len()
            } else {
                state.pending.len() / RESUMABLE_CHUNK_BYTES * RESUMABLE_CHUNK_BYTES
            };
            if bytes_to_upload == 0 {
                return Ok(());
            }
            let start = state.physical_uploaded;
            let length = u64::try_from(bytes_to_upload).map_err(|_| {
                Error::new(ErrorKind::Unsupported, "Drive resumable write is too large")
            })?;
            let end = start
                .checked_add(length)
                .and_then(|value| value.checked_sub(1))
                .ok_or_else(|| {
                    Error::new(ErrorKind::Internal, "Drive resumable range is invalid")
                })?;
            let response = self.authorized_request(
                DriveHttpRequest::new(
                    DriveHttpMethod::Put,
                    state.session_url.clone(),
                    vec![
                        ("content-type".to_owned(), DRIVE_FILE_MIME_TYPE.to_owned()),
                        (
                            "content-range".to_owned(),
                            format!("bytes {start}-{end}/{}", state.physical_total),
                        ),
                    ],
                    state.pending[..bytes_to_upload].to_vec(),
                    MAXIMUM_DRIVE_RESPONSE_BYTES,
                )?,
                true,
            )?;
            let next_uploaded = state
                .physical_uploaded
                .checked_add(length)
                .ok_or_else(|| Error::new(ErrorKind::Unsupported, "Drive object is too large"))?;
            match response.status() {
                308 if next_uploaded < state.physical_total => {
                    let expected = format!("bytes=0-{}", next_uploaded - 1);
                    if response.header("range") != Some(expected.as_str()) {
                        return Err(Error::new(
                            ErrorKind::CorruptData,
                            "Drive resumable upload range acknowledgement is invalid",
                        ));
                    }
                }
                200 | 201 if next_uploaded == state.physical_total => {
                    state.created_file_id = Some(parse_created_file_id(response.body())?);
                    state.completed = true;
                }
                _ => return status_error(&response, "Drive resumable upload could not be written"),
            }
            state.pending.drain(..bytes_to_upload);
            state.physical_uploaded = next_uploaded;
            if state.completed || !final_write {
                return Ok(());
            }
        }
    }

    fn lookup_key(&self, key: &BackendKey) -> Result<(DriveFile, DriveObjectName)> {
        let name = self.drive_name(key)?;
        let file = self
            .lookup_name(&name)?
            .ok_or_else(|| Error::new(ErrorKind::NotFound, "Drive object does not exist"))?;
        Ok((file, name))
    }

    fn drive_name(&self, key: &BackendKey) -> Result<DriveObjectName> {
        if key.as_bytes().starts_with(b"chunks/") {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "Drive backend stores chunks only inside immutable segments",
            ));
        }
        self.naming_key.object_name(key)
    }

    fn lookup_name(&self, name: &DriveObjectName) -> Result<Option<DriveFile>> {
        if let Some(file) = self.cache_get(name)? {
            return Ok(Some(file));
        }
        self.lookup_name_fresh(name)
    }

    fn lookup_name_fresh(&self, name: &DriveObjectName) -> Result<Option<DriveFile>> {
        let files = self.files_named(name)?;
        match files.len() {
            0 => Ok(None),
            1 => {
                let file = files.into_iter().next().ok_or_else(|| {
                    Error::new(ErrorKind::Internal, "Drive file lookup is inconsistent")
                })?;
                self.cache_insert(name.clone(), file.clone())?;
                Ok(Some(file))
            }
            _ => Err(Error::new(
                ErrorKind::Conflict,
                "Drive backend contains duplicate object names",
            )),
        }
    }

    fn files_named(&self, name: &DriveObjectName) -> Result<Vec<DriveFile>> {
        let query = format!(
            "trashed = false and '{}' in parents and name = '{}'",
            self.folder.as_str(),
            name.as_str(),
        );
        self.list_files_query(&query, 2)
    }

    fn delete_file_id(&self, file_id: &str) -> Result<()> {
        let response = self.authorized_request(
            DriveHttpRequest::new(
                DriveHttpMethod::Delete,
                format!("{DRIVE_API_ROOT}/files/{file_id}?supportsAllDrives=true"),
                Vec::new(),
                Vec::new(),
                MAXIMUM_DRIVE_RESPONSE_BYTES,
            )?,
            true,
        )?;
        require_status(&response, &[200, 204], "Drive object could not be deleted")
    }

    fn cache_get(&self, name: &DriveObjectName) -> Result<Option<DriveFile>> {
        Ok(self
            .metadata_cache
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive metadata cache lock is poisoned"))?
            .get(name))
    }

    fn cache_insert(&self, name: DriveObjectName, file: DriveFile) -> Result<()> {
        self.metadata_cache
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive metadata cache lock is poisoned"))?
            .insert(name, file);
        Ok(())
    }

    fn cache_remove(&self, name: &DriveObjectName) -> Result<()> {
        self.metadata_cache
            .lock()
            .map_err(|_| Error::new(ErrorKind::Internal, "Drive metadata cache lock is poisoned"))?
            .remove(name);
        Ok(())
    }

    fn list_all_files(&self, maximum_scanned_entries: usize) -> Result<Vec<DriveFile>> {
        let query = format!("trashed = false and '{}' in parents", self.folder.as_str());
        self.list_files_query(&query, maximum_scanned_entries)
    }

    fn list_files_query(&self, query: &str, maximum_files: usize) -> Result<Vec<DriveFile>> {
        let mut files = Vec::new();
        let mut page_token: Option<String> = None;
        let mut seen_tokens = BTreeSet::new();
        loop {
            let page_size = (maximum_files - files.len()).min(DRIVE_LIST_PAGE_SIZE);
            if page_size == 0 {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "Drive list scan exceeds the entry limit",
                ));
            }
            let mut parameters = vec![
                ("q", query.to_owned()),
                ("spaces", "drive".to_owned()),
                (
                    "fields",
                    "files(id,name,size,mimeType),nextPageToken,incompleteSearch".to_owned(),
                ),
                ("pageSize", page_size.to_string()),
                ("supportsAllDrives", "true".to_owned()),
                ("includeItemsFromAllDrives", "true".to_owned()),
            ];
            if let Some(token) = page_token.take() {
                if token.len() > MAXIMUM_PAGE_TOKEN_BYTES || !seen_tokens.insert(token.clone()) {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "Drive list continuation token is invalid",
                    ));
                }
                parameters.push(("pageToken", token));
            }
            let response = self.authorized_request(
                DriveHttpRequest::new(
                    DriveHttpMethod::Get,
                    format!("{DRIVE_API_ROOT}/files?{}", query_string(&parameters)),
                    Vec::new(),
                    Vec::new(),
                    MAXIMUM_DRIVE_RESPONSE_BYTES,
                )?,
                true,
            )?;
            require_status(&response, &[200], "Drive files could not be listed")?;
            let (mut page_files, next_token) = parse_file_list(response.body())?;
            if page_files.len() > page_size || files.len() + page_files.len() > maximum_files {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "Drive list scan exceeds the entry limit",
                ));
            }
            files.append(&mut page_files);
            match next_token {
                Some(token) => page_token = Some(token),
                None => return Ok(files),
            }
        }
    }

    fn verify_capsule(
        &self,
        expected_key: &BackendKey,
        name: &DriveObjectName,
        file: &DriveFile,
    ) -> Result<(usize, u64)> {
        let (capsule_length, actual_key) = self.read_capsule(name, file)?;
        if actual_key != *expected_key {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule key does not match its name",
            ));
        }
        let logical_length = file
            .size
            .checked_sub(
                u64::try_from(capsule_length)
                    .map_err(|_| Error::new(ErrorKind::Unsupported, "Drive object is too large"))?,
            )
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Drive object is truncated"))?;
        Ok((capsule_length, logical_length))
    }

    fn read_capsule(
        &self,
        name: &DriveObjectName,
        file: &DriveFile,
    ) -> Result<(usize, BackendKey)> {
        if file.size < u64::try_from(CAPSULE_PREFIX_BYTES).expect("capsule prefix fits u64") {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object is truncated",
            ));
        }
        let prefix = self.download_range(
            &file.id,
            0,
            u64::try_from(CAPSULE_PREFIX_BYTES)
                .map_err(|_| Error::new(ErrorKind::Internal, "Drive capsule bound is invalid"))?,
        )?;
        let capsule_length = DriveObjectNamingKey::capsule_length(&prefix)?;
        if u64::try_from(capsule_length)
            .ok()
            .is_none_or(|length| length > file.size)
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object is truncated",
            ));
        }
        let capsule = if capsule_length <= prefix.len() {
            prefix[..capsule_length].to_vec()
        } else {
            self.download_range(
                &file.id,
                0,
                u64::try_from(capsule_length).map_err(|_| {
                    Error::new(ErrorKind::Unsupported, "Drive object capsule is too large")
                })?,
            )?
        };
        if capsule.len() != capsule_length {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object capsule response is truncated",
            ));
        }
        let key = self.naming_key.open_backend_key(&capsule, name)?;
        Ok((capsule_length, key))
    }

    fn download_range(&self, file_id: &str, start: u64, end_exclusive: u64) -> Result<Vec<u8>> {
        if start >= end_exclusive {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Drive object range is invalid",
            ));
        }
        let length = end_exclusive
            .checked_sub(start)
            .ok_or_else(|| Error::new(ErrorKind::InvalidInput, "Drive object range is invalid"))?;
        let maximum_response_bytes = usize::try_from(length).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "Drive object range exceeds the byte limit",
            )
        })?;
        let response = self.authorized_request(
            DriveHttpRequest::new(
                DriveHttpMethod::Get,
                format!("{DRIVE_API_ROOT}/files/{file_id}?alt=media&supportsAllDrives=true"),
                vec![(
                    "range".to_owned(),
                    format!("bytes={start}-{}", end_exclusive - 1),
                )],
                Vec::new(),
                maximum_response_bytes,
            )?,
            true,
        )?;
        require_status(&response, &[206], "Drive object could not be read")?;
        if u64::try_from(response.body().len()).ok() != Some(length) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive object range response is invalid",
            ));
        }
        Ok(response.body().to_vec())
    }

    fn authorized_request(
        &self,
        request: DriveHttpRequest,
        retryable: bool,
    ) -> Result<DriveHttpResponse> {
        let mut attempt = 0_u8;
        loop {
            let access_token = self.access_tokens.access_token()?;
            let response = self
                .transport
                .request(&request.with_bearer_token(access_token.access_token())?)?;
            attempt = attempt.saturating_add(1);
            if !retryable
                || !is_retryable_response(&response)
                || attempt >= self.retry_policy.maximum_attempts
            {
                return Ok(response);
            }
            self.sleeper
                .sleep(retry_delay(&response, self.retry_policy, attempt));
        }
    }
}

impl<T, A, S> std::fmt::Debug for DriveBackend<T, A, S> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DriveBackend(<redacted>)")
    }
}

impl<T: DriveHttpTransport, A: DriveAccessTokenProvider, S: DriveSleeper> Backend
    for DriveBackend<T, A, S>
{
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move { self.put_if_absent_sync(key, data) })
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move { self.get_sync(key, request) })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        Box::pin(async move { self.head_sync(key) })
    }

    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        Box::pin(async move { self.list_sync(prefix, cursor, limits) })
    }

    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.delete_sync(key) })
    }

    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        Box::pin(async move { self.start_resumable_sync(key, total_length) })
    }

    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.write_resumable_sync(session, offset, data) })
    }

    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move { self.complete_resumable_sync(session) })
    }

    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        Box::pin(async move { self.abort_resumable_sync(session) })
    }
}

fn validate_drive_identifier(identifier: &str, message: &'static str) -> Result<()> {
    if identifier.is_empty()
        || identifier.len() > MAXIMUM_DRIVE_ID_BYTES
        || !identifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(Error::new(ErrorKind::InvalidInput, message));
    }
    Ok(())
}

fn is_drive_url(url: &str) -> bool {
    url.starts_with("https://www.googleapis.com/drive/")
        || url.starts_with("https://www.googleapis.com/upload/drive/")
}

fn query_string(parameters: &[(&str, String)]) -> String {
    parameters
        .iter()
        .map(|(name, value)| format!("{}={}", percent_encode(name), percent_encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push('%');
            encoded.push_str(&format!("{byte:02X}"));
        }
    }
    encoded
}

fn require_status(
    response: &DriveHttpResponse,
    statuses: &[u16],
    message: &'static str,
) -> Result<()> {
    if statuses.contains(&response.status()) {
        Ok(())
    } else {
        status_error(response, message)
    }
}

fn status_error(response: &DriveHttpResponse, message: &'static str) -> Result<()> {
    let kind = match response.status() {
        404 => ErrorKind::NotFound,
        409 => ErrorKind::Conflict,
        400..=499 => ErrorKind::Conflict,
        _ => ErrorKind::Io,
    };
    Err(Error::new(kind, message))
}

fn is_retryable_response(response: &DriveHttpResponse) -> bool {
    matches!(response.status(), 429 | 500 | 502 | 503 | 504)
        || (response.status() == 403
            && (response
                .body()
                .windows(b"rateLimitExceeded".len())
                .any(|window| window == b"rateLimitExceeded")
                || response
                    .body()
                    .windows(b"userRateLimitExceeded".len())
                    .any(|window| window == b"userRateLimitExceeded")))
}

fn retry_delay(response: &DriveHttpResponse, policy: DriveRetryPolicy, attempt: u8) -> Duration {
    if let Some(seconds) = response
        .header("retry-after")
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_secs(seconds).min(policy.maximum_delay);
    }
    let multiplier = 1_u32
        .checked_shl(u32::from(attempt.saturating_sub(1)))
        .unwrap_or(u32::MAX);
    policy
        .initial_delay
        .checked_mul(multiplier)
        .unwrap_or(policy.maximum_delay)
        .min(policy.maximum_delay)
}

fn requested_range(length: u64, requested: Option<BackendByteRange>) -> Result<BackendByteRange> {
    let range = requested.unwrap_or(BackendByteRange::new(0, length)?);
    if range.end_exclusive() > length {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "backend byte range exceeds the object",
        ));
    }
    Ok(range)
}

fn parse_file_list(body: &[u8]) -> Result<(Vec<DriveFile>, Option<String>)> {
    let value: Value = serde_json::from_slice(body)
        .map_err(|_| Error::new(ErrorKind::CorruptData, "Drive files response is invalid"))?;
    let object = value
        .as_object()
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Drive files response is invalid"))?;
    if object
        .get("incompleteSearch")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Err(Error::new(
            ErrorKind::Conflict,
            "Drive files search was incomplete",
        ));
    }
    let files = object
        .get("files")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Drive files response is invalid"))?;
    let mut parsed = Vec::with_capacity(files.len());
    for file in files {
        let object = file
            .as_object()
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "Drive file record is invalid"))?;
        let id = required_json_string(object, "id", "Drive file ID is invalid")?;
        validate_drive_identifier(&id, "Drive file ID is invalid")?;
        let name = required_json_string(object, "name", "Drive file name is invalid")?;
        if name.len() > MAXIMUM_DRIVE_ID_BYTES || name.bytes().any(|byte| byte.is_ascii_control()) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive file name is invalid",
            ));
        }
        let mime_type = required_json_string(object, "mimeType", "Drive file type is invalid")?;
        if mime_type != DRIVE_FILE_MIME_TYPE {
            continue;
        }
        let size = required_json_string(object, "size", "Drive file size is invalid")?
            .parse::<u64>()
            .map_err(|_| Error::new(ErrorKind::CorruptData, "Drive file size is invalid"))?;
        parsed.push(DriveFile { id, name, size });
    }
    let next_token = match object.get("nextPageToken") {
        None | Some(Value::Null) => None,
        Some(Value::String(token))
            if !token.is_empty()
                && token.len() <= MAXIMUM_PAGE_TOKEN_BYTES
                && !token.bytes().any(|byte| byte.is_ascii_control()) =>
        {
            Some(token.clone())
        }
        _ => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "Drive list continuation token is invalid",
            ));
        }
    };
    Ok((parsed, next_token))
}

fn parse_created_file_id(body: &[u8]) -> Result<String> {
    let value: Value = serde_json::from_slice(body).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "Drive resumable completion response is invalid",
        )
    })?;
    let object = value.as_object().ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "Drive resumable completion response is invalid",
        )
    })?;
    let id = required_json_string(object, "id", "Drive completed file ID is invalid")?;
    validate_drive_identifier(&id, "Drive completed file ID is invalid")?;
    Ok(id)
}

fn required_json_string(
    object: &serde_json::Map<String, Value>,
    field: &str,
    message: &'static str,
) -> Result<String> {
    object
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, message))
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        future::Future,
        sync::{Arc, Mutex},
        task::{Context, Poll, Wake, Waker},
    };

    use super::*;
    use crate::{BackendReadLimits, EncryptedBackend, RepositoryEncryptionKey};

    struct NoopWake;

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("Drive backend future unexpectedly yielded"),
        }
    }

    struct FixedTokenProvider;

    impl DriveAccessTokenProvider for FixedTokenProvider {
        fn access_token(&self) -> Result<DriveAccessToken> {
            Ok(DriveAccessToken::test_access_token("access-token"))
        }
    }

    #[derive(Default)]
    struct FakeTransport {
        requests: Mutex<Vec<DriveHttpRequest>>,
        responses: Mutex<VecDeque<DriveHttpResponse>>,
    }

    impl FakeTransport {
        fn with_responses(responses: Vec<DriveHttpResponse>) -> Self {
            Self {
                requests: Mutex::new(Vec::new()),
                responses: Mutex::new(responses.into()),
            }
        }

        fn push_response(&self, response: DriveHttpResponse) {
            self.responses
                .lock()
                .expect("response lock")
                .push_back(response);
        }
    }

    impl DriveHttpTransport for FakeTransport {
        fn request(&self, request: &DriveHttpRequest) -> Result<DriveHttpResponse> {
            self.requests
                .lock()
                .expect("request lock")
                .push(request.clone());
            self.responses
                .lock()
                .expect("response lock")
                .pop_front()
                .ok_or_else(|| Error::new(ErrorKind::Internal, "unexpected Drive request"))
        }
    }

    #[derive(Default)]
    struct EncryptedUploadTransport {
        requests: Mutex<Vec<DriveHttpRequest>>,
        uploaded: Mutex<Option<Vec<u8>>>,
        name: Mutex<Option<String>>,
    }

    impl DriveHttpTransport for EncryptedUploadTransport {
        fn request(&self, request: &DriveHttpRequest) -> Result<DriveHttpResponse> {
            self.requests
                .lock()
                .expect("request lock")
                .push(request.clone());
            match (request.method(), request.url()) {
                (DriveHttpMethod::Get, url) if url.contains("?alt=media") => {
                    let range = request
                        .headers()
                        .iter()
                        .find_map(|(name, value)| (name == "range").then_some(value))
                        .ok_or_else(|| Error::new(ErrorKind::Internal, "missing range header"))?;
                    let range = range.strip_prefix("bytes=").ok_or_else(|| {
                        Error::new(ErrorKind::Internal, "range header is invalid")
                    })?;
                    let (start, end) = range.split_once('-').ok_or_else(|| {
                        Error::new(ErrorKind::Internal, "range header is invalid")
                    })?;
                    let start = start
                        .parse::<usize>()
                        .map_err(|_| Error::new(ErrorKind::Internal, "range header is invalid"))?;
                    let end = end
                        .parse::<usize>()
                        .map_err(|_| Error::new(ErrorKind::Internal, "range header is invalid"))?;
                    let uploaded = self
                        .uploaded
                        .lock()
                        .expect("upload lock")
                        .clone()
                        .ok_or_else(|| Error::new(ErrorKind::Internal, "upload is missing"))?;
                    let end = end.checked_add(1).ok_or_else(|| {
                        Error::new(ErrorKind::Internal, "range header is invalid")
                    })?;
                    let bytes = uploaded
                        .get(start..end)
                        .ok_or_else(|| Error::new(ErrorKind::Internal, "range exceeds upload"))?;
                    Ok(bytes_response(206, bytes.to_vec()))
                }
                (DriveHttpMethod::Get, url) if url.contains("/drive/v3/files?") => {
                    let uploaded = self.uploaded.lock().expect("upload lock");
                    match uploaded.as_ref() {
                        Some(uploaded) => {
                            let name =
                                self.name
                                    .lock()
                                    .expect("name lock")
                                    .clone()
                                    .ok_or_else(|| {
                                        Error::new(ErrorKind::Internal, "Drive name is missing")
                                    })?;
                            Ok(files_response("file123", &name, uploaded.len()))
                        }
                        None => Ok(response(
                            200,
                            Vec::new(),
                            r#"{"files":[],"incompleteSearch":false}"#,
                        )),
                    }
                }
                (DriveHttpMethod::Post, _) => {
                    let metadata: Value = serde_json::from_slice(request.body()).map_err(|_| {
                        Error::new(ErrorKind::Internal, "Drive metadata is invalid")
                    })?;
                    let name = metadata
                        .get("name")
                        .and_then(Value::as_str)
                        .ok_or_else(|| {
                            Error::new(ErrorKind::Internal, "Drive metadata has no name")
                        })?;
                    *self.name.lock().expect("name lock") = Some(name.to_owned());
                    Ok(response(
                        200,
                        vec![(
                            "location",
                            "https://www.googleapis.com/upload/drive/v3/files?upload_id=123",
                        )],
                        "{}",
                    ))
                }
                (DriveHttpMethod::Put, _) => {
                    *self.uploaded.lock().expect("upload lock") = Some(request.body().to_vec());
                    Ok(response(200, Vec::new(), r#"{"id":"file123"}"#))
                }
                _ => Err(Error::new(ErrorKind::Internal, "unexpected Drive request")),
            }
        }
    }

    #[derive(Default)]
    struct FakeSleeper(Mutex<Vec<Duration>>);

    impl DriveSleeper for FakeSleeper {
        fn sleep(&self, delay: Duration) {
            self.0.lock().expect("sleep lock").push(delay);
        }
    }

    fn response(status: u16, headers: Vec<(&str, &str)>, body: &str) -> DriveHttpResponse {
        DriveHttpResponse::new(
            status,
            headers
                .into_iter()
                .map(|(name, value)| (name.to_owned(), value.to_owned()))
                .collect(),
            body.as_bytes().to_vec(),
        )
        .expect("response")
    }

    fn bytes_response(status: u16, body: Vec<u8>) -> DriveHttpResponse {
        DriveHttpResponse::new(status, Vec::new(), body).expect("response")
    }

    fn files_response(id: &str, name: &str, size: usize) -> DriveHttpResponse {
        response(
            200,
            Vec::new(),
            &format!(
                r#"{{"files":[{{"id":"{id}","name":"{name}","size":"{size}","mimeType":"application/octet-stream"}}],"incompleteSearch":false}}"#,
            ),
        )
    }

    fn backend(
        transport: FakeTransport,
    ) -> DriveBackend<FakeTransport, FixedTokenProvider, FakeSleeper> {
        let repository_key = RepositoryEncryptionKey::from_master_bytes(
            "550e8400-e29b-41d4-a716-446655440000"
                .parse()
                .expect("repository ID"),
            [8; 32],
        );
        DriveBackend::new(
            DriveFolderId::new("folder_id").expect("folder"),
            repository_key
                .derive_drive_object_naming_key()
                .expect("naming key"),
            transport,
            FixedTokenProvider,
        )
        .with_retry_policy(
            DriveRetryPolicy::new(2, Duration::from_millis(1), Duration::from_millis(2))
                .expect("retry policy"),
        )
        .with_sleeper(FakeSleeper::default())
    }

    fn key() -> BackendKey {
        BackendKey::from_bytes(b"segments/opaque-record").expect("key")
    }

    fn object_name(key: &BackendKey) -> DriveObjectName {
        RepositoryEncryptionKey::from_master_bytes(
            "550e8400-e29b-41d4-a716-446655440000"
                .parse()
                .expect("repository ID"),
            [8; 32],
        )
        .derive_drive_object_naming_key()
        .expect("naming key")
        .object_name(key)
        .expect("object name")
    }

    #[test]
    fn validates_folder_and_http_boundaries() {
        assert!(DriveFolderId::new("folder_id").is_ok());
        assert!(DriveFolderId::new("folder/id").is_err());
        assert!(
            DriveHttpRequest::new(
                DriveHttpMethod::Get,
                "https://example.invalid/",
                Vec::new(),
                Vec::new(),
                1,
            )
            .is_err()
        );
        assert_eq!(
            format!("{:?}", DriveFolderId::new("folder_id").expect("folder")),
            "DriveFolderId(<redacted>)"
        );
    }

    #[test]
    fn creates_an_opaque_dedicated_drive_folder() {
        let transport =
            FakeTransport::with_responses(vec![response(200, Vec::new(), r#"{"id":"folder_id"}"#)]);
        let folder = DriveFolderId::create(&transport, &FixedTokenProvider).expect("folder");
        assert_eq!(folder.as_str(), "folder_id");
        let request = &transport.requests.lock().expect("requests")[0];
        assert_eq!(request.method(), DriveHttpMethod::Post);
        let body = String::from_utf8_lossy(request.body());
        assert!(body.contains("application/vnd.google-apps.folder"));
        assert!(!body.contains("Yeokcham"));
    }

    #[test]
    fn retries_rate_limited_reads_without_exposing_bearer_tokens() {
        let transport = FakeTransport::with_responses(vec![
            response(429, vec![("retry-after", "1")], "{}"),
            response(200, vec![], r#"{"files":[],"incompleteSearch":false}"#),
        ]);
        let backend = backend(transport);
        let page = block_on(backend.list(
            &BackendPrefix::from_bytes(b"").expect("prefix"),
            None,
            BackendListLimits::new(1, 1).expect("limits"),
        ))
        .expect("list");
        assert!(page.entries().is_empty());
        let transport = &backend.transport;
        assert_eq!(transport.requests.lock().expect("requests").len(), 2);
        assert_eq!(
            backend.sleeper.0.lock().expect("sleeps").as_slice(),
            &[Duration::from_millis(2)]
        );
        let request = &transport.requests.lock().expect("requests")[0];
        assert!(!request.url().contains("segments/opaque-record"));
        assert!(
            request
                .headers()
                .iter()
                .any(|(name, _)| name == "authorization")
        );
        assert!(!format!("{request:?}").contains("access-token"));
    }

    #[test]
    fn rejects_incomplete_or_duplicate_drive_searches() {
        let incomplete = backend(FakeTransport::with_responses(vec![response(
            200,
            vec![],
            r#"{"files":[],"incompleteSearch":true}"#,
        )]));
        let error = block_on(incomplete.head(&key())).expect_err("incomplete");
        assert_eq!(error.kind(), ErrorKind::Conflict);

        let duplicate = backend(FakeTransport::with_responses(vec![response(
            200,
            vec![],
            r#"{"files":[{"id":"first","name":"0000000000000000000000000000000000000000000000000000000000000000","size":"1","mimeType":"application/octet-stream"},{"id":"second","name":"0000000000000000000000000000000000000000000000000000000000000000","size":"1","mimeType":"application/octet-stream"}],"incompleteSearch":false}"#,
        )]));
        let error = block_on(duplicate.head(&key())).expect_err("duplicate");
        assert_eq!(error.kind(), ErrorKind::Conflict);
    }

    #[test]
    fn parses_and_bounds_provider_file_pages() {
        assert!(parse_file_list(br#"{"files":[]}"#).is_ok());
        let error = parse_file_list(
            br#"{"files":[{"id":"id","name":"name","size":"not-a-number","mimeType":"application/octet-stream"}],"incompleteSearch":false}"#,
        )
        .expect_err("invalid size");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn reports_missing_object_without_getting_unbounded_media() {
        let backend = backend(FakeTransport::with_responses(vec![response(
            200,
            vec![],
            r#"{"files":[],"incompleteSearch":false}"#,
        )]));
        let error =
            block_on(backend.get(&key(), BackendReadRequest::full(BackendReadLimits::new(10))))
                .expect_err("missing");
        assert_eq!(error.kind(), ErrorKind::NotFound);
    }

    #[test]
    fn uploads_capsulated_opaque_objects_with_resumable_drive_requests() {
        let transport = FakeTransport::with_responses(vec![
            response(200, Vec::new(), r#"{"files":[],"incompleteSearch":false}"#),
            response(
                200,
                vec![(
                    "location",
                    "https://www.googleapis.com/upload/drive/v3/files?upload_id=123",
                )],
                "{}",
            ),
        ]);
        let backend = backend(transport);
        let key = key();
        let session =
            match block_on(backend.start_resumable_put_if_absent(&key, 3)).expect("start upload") {
                BackendResumablePutStart::Started(session) => session,
                BackendResumablePutStart::AlreadyExists(_) => panic!("unexpected existing object"),
            };
        let capsule = backend
            .uploads
            .lock()
            .expect("upload lock")
            .get(&session.id())
            .expect("state")
            .pending
            .clone();
        assert!(
            backend
                .metadata_cache
                .lock()
                .expect("cache lock")
                .files
                .is_empty()
        );
        let name = object_name(&key);
        backend
            .transport
            .push_response(response(200, Vec::new(), r#"{"id":"file123"}"#));
        backend.transport.push_response(files_response(
            "file123",
            name.as_str(),
            capsule.len() + 3,
        ));
        backend.transport.push_response(bytes_response(
            206,
            capsule[..CAPSULE_PREFIX_BYTES].to_vec(),
        ));
        backend
            .transport
            .push_response(bytes_response(206, capsule.clone()));
        block_on(backend.write_resumable(&session, 0, b"abc")).expect("write upload");
        assert_eq!(
            block_on(backend.complete_resumable(&session)).expect("complete upload"),
            BackendPutResult::Created(BackendObjectMetadata::new(3)),
        );
        let requests = backend.transport.requests.lock().expect("requests");
        assert_eq!(requests.len(), 6);
        assert!(!requests[0].url().contains("segments/opaque-record"));
        assert!(!String::from_utf8_lossy(requests[1].body()).contains("segments/opaque-record"));
        assert!(
            requests[2]
                .headers()
                .iter()
                .any(|(name, value)| name == "content-range" && value.ends_with("/73"))
        );
        assert!(requests[2].body().starts_with(&capsule));
    }

    #[test]
    fn encrypted_drive_composition_hides_source_bytes_and_logical_keys() {
        let repository_id = "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID");
        let repository_key = RepositoryEncryptionKey::from_master_bytes(repository_id, [8; 32]);
        let physical = DriveBackend::new(
            DriveFolderId::new("folder_id").expect("folder"),
            repository_key
                .derive_drive_object_naming_key()
                .expect("naming key"),
            EncryptedUploadTransport::default(),
            FixedTokenProvider,
        )
        .with_sleeper(FakeSleeper::default());
        let backend = EncryptedBackend::new(physical, repository_key);
        let key = BackendKey::from_bytes(b"manifests/objects/opaque-record").expect("key");
        let source = b"source bytes must not reach Drive plaintext";
        assert_eq!(
            block_on(backend.put_if_absent(&key, source)).expect("upload"),
            BackendPutResult::Created(BackendObjectMetadata::new(source.len() as u64)),
        );
        let physical = backend.into_inner();
        let uploaded = physical
            .transport
            .uploaded
            .lock()
            .expect("upload lock")
            .clone()
            .expect("upload");
        assert!(uploaded.starts_with(b"YKDO"));
        assert!(uploaded.windows(4).any(|window| window == b"YKCE"));
        assert!(
            !uploaded
                .windows(source.len())
                .any(|window| window == source)
        );
        assert!(
            !uploaded
                .windows(key.as_bytes().len())
                .any(|window| window == key.as_bytes())
        );
        for request in physical
            .transport
            .requests
            .lock()
            .expect("request lock")
            .iter()
        {
            assert!(!request.url().contains("manifests/objects/opaque-record"));
            assert!(
                !request
                    .body()
                    .windows(source.len())
                    .any(|window| window == source)
            );
            assert!(
                !request
                    .body()
                    .windows(key.as_bytes().len())
                    .any(|window| window == key.as_bytes())
            );
        }
    }

    #[test]
    fn incomplete_or_chunk_record_uploads_are_not_accepted() {
        let backend = backend(FakeTransport::with_responses(vec![
            response(200, Vec::new(), r#"{"files":[],"incompleteSearch":false}"#),
            response(
                200,
                vec![(
                    "location",
                    "https://www.googleapis.com/upload/drive/v3/files?upload_id=123",
                )],
                "{}",
            ),
            response(204, Vec::new(), ""),
        ]));
        let key = key();
        let session =
            match block_on(backend.start_resumable_put_if_absent(&key, 3)).expect("start upload") {
                BackendResumablePutStart::Started(session) => session,
                BackendResumablePutStart::AlreadyExists(_) => panic!("unexpected existing object"),
            };
        let error = block_on(backend.complete_resumable(&session)).expect_err("incomplete");
        assert_eq!(error.kind(), ErrorKind::Conflict);
        block_on(backend.abort_resumable(&session)).expect("abort");
        let chunk = BackendKey::from_bytes(b"chunks/standalone").expect("chunk key");
        let error = block_on(backend.head(&chunk)).expect_err("standalone chunk");
        assert_eq!(error.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn caches_only_confirmed_positive_file_metadata() {
        let transport = FakeTransport::with_responses(vec![
            response(200, Vec::new(), r#"{"files":[],"incompleteSearch":false}"#),
            response(
                200,
                vec![(
                    "location",
                    "https://www.googleapis.com/upload/drive/v3/files?upload_id=123",
                )],
                "{}",
            ),
        ]);
        let backend = backend(transport);
        let key = key();
        let session =
            match block_on(backend.start_resumable_put_if_absent(&key, 3)).expect("start upload") {
                BackendResumablePutStart::Started(session) => session,
                BackendResumablePutStart::AlreadyExists(_) => panic!("unexpected existing object"),
            };
        let capsule = backend
            .uploads
            .lock()
            .expect("upload lock")
            .get(&session.id())
            .expect("state")
            .pending
            .clone();
        let name = object_name(&key);
        backend.metadata_cache.lock().expect("cache lock").insert(
            name.clone(),
            DriveFile {
                id: "file123".to_owned(),
                name: name.as_str().to_owned(),
                size: u64::try_from(capsule.len() + 3).expect("size"),
            },
        );
        for _ in 0..2 {
            backend.transport.push_response(bytes_response(
                206,
                capsule[..CAPSULE_PREFIX_BYTES].to_vec(),
            ));
            backend
                .transport
                .push_response(bytes_response(206, capsule.clone()));
        }
        assert_eq!(
            block_on(backend.head(&key)).expect("first head").length(),
            3
        );
        assert_eq!(
            block_on(backend.head(&key)).expect("second head").length(),
            3
        );
        assert_eq!(
            backend
                .transport
                .requests
                .lock()
                .expect("requests")
                .iter()
                .filter(|request| {
                    request.method() == DriveHttpMethod::Get
                        && request.url().contains("/drive/v3/files?")
                })
                .count(),
            1,
        );
    }

    #[test]
    fn removes_its_racing_duplicate_and_returns_already_exists() {
        let transport = FakeTransport::with_responses(vec![
            response(200, Vec::new(), r#"{"files":[],"incompleteSearch":false}"#),
            response(
                200,
                vec![(
                    "location",
                    "https://www.googleapis.com/upload/drive/v3/files?upload_id=123",
                )],
                "{}",
            ),
        ]);
        let backend = backend(transport);
        let key = key();
        let session =
            match block_on(backend.start_resumable_put_if_absent(&key, 3)).expect("start upload") {
                BackendResumablePutStart::Started(session) => session,
                BackendResumablePutStart::AlreadyExists(_) => panic!("unexpected existing object"),
            };
        let capsule = backend
            .uploads
            .lock()
            .expect("upload lock")
            .get(&session.id())
            .expect("state")
            .pending
            .clone();
        let name = object_name(&key);
        backend
            .transport
            .push_response(response(200, Vec::new(), r#"{"id":"file123"}"#));
        backend.transport.push_response(response(
            200,
            Vec::new(),
            &format!(
                r#"{{"files":[{{"id":"existing","name":"{}","size":"{}","mimeType":"application/octet-stream"}},{{"id":"file123","name":"{}","size":"{}","mimeType":"application/octet-stream"}}],"incompleteSearch":false}}"#,
                name.as_str(),
                capsule.len() + 3,
                name.as_str(),
                capsule.len() + 3,
            ),
        ));
        backend
            .transport
            .push_response(response(204, Vec::new(), ""));
        backend.transport.push_response(files_response(
            "existing",
            name.as_str(),
            capsule.len() + 3,
        ));
        backend.transport.push_response(bytes_response(
            206,
            capsule[..CAPSULE_PREFIX_BYTES].to_vec(),
        ));
        backend
            .transport
            .push_response(bytes_response(206, capsule.clone()));
        block_on(backend.write_resumable(&session, 0, b"abc")).expect("write upload");
        assert_eq!(
            block_on(backend.complete_resumable(&session)).expect("complete upload"),
            BackendPutResult::AlreadyExists(BackendObjectMetadata::new(3)),
        );
        assert!(
            backend
                .transport
                .requests
                .lock()
                .expect("requests")
                .iter()
                .any(|request| request.method() == DriveHttpMethod::Delete
                    && request.url().contains("/files/file123?"))
        );
    }
}
