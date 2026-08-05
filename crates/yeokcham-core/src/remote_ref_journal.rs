use std::collections::BTreeSet;

use crate::{
    Backend, BackendFuture, BackendKey, BackendListLimits, BackendPrefix, BackendPutResult,
    BackendReadLimits, BackendReadRequest, DeviceRegistry, DeviceRegistryEvent,
    DeviceRegistryReadLimits, EncryptedBackend, Error, ErrorKind, GitRefState, RefEvent,
    RefEventReadLimits, RefEventVerifyingKey, RepositoryId, Result,
};

const REMOTE_PREFIX: &str = "replication";
const REGISTRY_DIRECTORY: &str = "device-registry";
const REF_EVENT_DIRECTORY: &str = "ref-journal";
const REGISTRY_EXTENSION: &str = ".ykdr";
const REF_EVENT_EXTENSION: &str = ".ykre";

/// bounded policies for one remote device-registry and ref-journal exchange.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RemoteRefJournalLimits {
    device_registry_limits: DeviceRegistryReadLimits,
    ref_event_limits: RefEventReadLimits,
    backend_list_limits: BackendListLimits,
}

impl RemoteRefJournalLimits {
    /// creates one bounded remote journal exchange policy.
    pub fn new(
        device_registry_limits: DeviceRegistryReadLimits,
        ref_event_limits: RefEventReadLimits,
        backend_list_limits: BackendListLimits,
    ) -> Result<Self> {
        if backend_list_limits.maximum_entries() > ref_event_limits.maximum_directory_entries()
            || backend_list_limits.maximum_entries() > device_registry_limits.maximum_events()
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "remote journal page limit exceeds the record limit",
            ));
        }
        Ok(Self {
            device_registry_limits,
            ref_event_limits,
            backend_list_limits,
        })
    }

    /// returns bounded device-registry decoding limits.
    pub const fn device_registry_limits(self) -> DeviceRegistryReadLimits {
        self.device_registry_limits
    }

    /// returns bounded ref-event decoding limits.
    pub const fn ref_event_limits(self) -> RefEventReadLimits {
        self.ref_event_limits
    }

    /// returns bounded backend pagination limits.
    pub const fn backend_list_limits(self) -> BackendListLimits {
        self.backend_list_limits
    }
}

/// fetched immutable device-registry records and their resolved authorization state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteDeviceRegistry {
    registry: DeviceRegistry,
    events: Vec<DeviceRegistryEvent>,
}

impl RemoteDeviceRegistry {
    /// returns the root-authorized resolved device registry.
    pub const fn registry(&self) -> &DeviceRegistry {
        &self.registry
    }

    /// returns every validated immutable registry record in chain order.
    pub fn events(&self) -> &[DeviceRegistryEvent] {
        &self.events
    }
}

/// fetched remote journal records with their resolved device authorization.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteRefJournal {
    device_registry: RemoteDeviceRegistry,
    events: Vec<RefEvent>,
}

impl RemoteRefJournal {
    /// returns the resolved remote device registry.
    pub const fn device_registry(&self) -> &RemoteDeviceRegistry {
        &self.device_registry
    }

    /// returns every validated authorized remote journal event.
    pub fn events(&self) -> &[RefEvent] {
        &self.events
    }

    /// resolves all remote events from the caller-verified initial ref state.
    pub fn reconcile(&self, initial: &GitRefState) -> RemoteRefJournalReconciliation {
        reconcile_ref_events(initial, &self.events)
    }
}

/// result of resolving all authorized remote journal events.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RemoteRefJournalReconciliation {
    /// all events form exactly one valid continuation.
    Resolved(GitRefState),
    /// no branch is discarded; the caller must explicitly resolve these records.
    Divergent(RemoteRefJournalDivergence),
}

/// visible unresolved records after the longest unambiguous journal prefix.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteRefJournalDivergence {
    base_state: GitRefState,
    unresolved_events: Vec<RefEvent>,
}

impl RemoteRefJournalDivergence {
    /// returns the last unambiguous complete ref state.
    pub const fn base_state(&self) -> &GitRefState {
        &self.base_state
    }

    /// returns every unselected valid journal event without dropping a branch.
    pub fn unresolved_events(&self) -> &[RefEvent] {
        &self.unresolved_events
    }
}

/// publishes one immutable root-signed device registration or revocation record.
///
/// the caller must retain and distribute the root public key independently; this
/// function never treats the remote store as a trust anchor.
pub fn publish_device_registry_event<'a, B: Backend>(
    backend: &'a EncryptedBackend<B>,
    root_verifying_key: RefEventVerifyingKey,
    event: &'a DeviceRegistryEvent,
    limits: RemoteRefJournalLimits,
) -> BackendFuture<'a, ()> {
    Box::pin(async move {
        ensure_backend_repository(backend, event.repository_id())?;
        let events = fetch_device_registry_events(backend, event.repository_id(), limits).await?;
        let mut candidate = events;
        candidate.push(event.clone());
        let resolved = DeviceRegistry::resolve(
            event.repository_id(),
            root_verifying_key,
            candidate,
            limits.device_registry_limits(),
        )?;
        let key = device_registry_event_key(event)?;
        put_exactly_once(
            backend,
            &key,
            &event.encode(),
            limits.device_registry_limits().maximum_event_bytes(),
        )
        .await?;
        let confirmed =
            fetch_device_registry_events(backend, event.repository_id(), limits).await?;
        let confirmed = DeviceRegistry::resolve(
            event.repository_id(),
            root_verifying_key,
            confirmed,
            limits.device_registry_limits(),
        )?;
        if confirmed != resolved {
            return Err(Error::new(
                ErrorKind::Conflict,
                "device registry changed during publication",
            ));
        }
        Ok(())
    })
}

/// fetches and verifies a remote immutable root-authorized device registry.
pub fn fetch_remote_device_registry<B: Backend>(
    backend: &EncryptedBackend<B>,
    repository_id: RepositoryId,
    root_verifying_key: RefEventVerifyingKey,
    limits: RemoteRefJournalLimits,
) -> BackendFuture<'_, RemoteDeviceRegistry> {
    Box::pin(async move {
        ensure_backend_repository(backend, repository_id)?;
        let events = fetch_device_registry_events(backend, repository_id, limits).await?;
        let registry = DeviceRegistry::resolve(
            repository_id,
            root_verifying_key,
            events.clone(),
            limits.device_registry_limits(),
        )?;
        Ok(RemoteDeviceRegistry { registry, events })
    })
}

/// fetches all remote signed device journals and validates each against the root-pinned registry.
pub fn fetch_remote_ref_journal<B: Backend>(
    backend: &EncryptedBackend<B>,
    repository_id: RepositoryId,
    root_verifying_key: RefEventVerifyingKey,
    limits: RemoteRefJournalLimits,
) -> BackendFuture<'_, RemoteRefJournal> {
    Box::pin(async move {
        ensure_backend_repository(backend, repository_id)?;
        let device_registry =
            fetch_remote_device_registry(backend, repository_id, root_verifying_key, limits)
                .await?;
        let prefix = remote_directory_prefix(repository_id, REF_EVENT_DIRECTORY)?;
        let keys = list_keys(
            backend,
            &prefix,
            limits.backend_list_limits(),
            limits.ref_event_limits().maximum_directory_entries(),
        )
        .await?;
        let mut events = Vec::with_capacity(keys.len());
        for key in keys {
            let (sequence, device_id, expected_id) =
                parse_remote_ref_event_key(repository_id, &key)?;
            let bytes = read_backend_event(
                backend,
                &key,
                limits.ref_event_limits().maximum_event_bytes(),
            )
            .await?;
            let event = RefEvent::decode(&bytes, limits.ref_event_limits())?;
            if event.encode() != bytes
                || event.repository_id() != repository_id
                || event.sequence() != sequence
                || event.device_id() != device_id
                || event.event_id() != expected_id
            {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "remote ref journal key does not match its event",
                ));
            }
            device_registry.registry().authorize_ref_event(&event)?;
            events.push(event);
        }
        Ok(RemoteRefJournal {
            device_registry,
            events,
        })
    })
}

/// publishes one signed event only when it extends the current unique remote state.
///
/// this detects stale writers before creating an immutable remote journal record.
pub fn publish_remote_ref_event<'a, B: Backend>(
    backend: &'a EncryptedBackend<B>,
    root_verifying_key: RefEventVerifyingKey,
    initial: &'a GitRefState,
    event: &'a RefEvent,
    limits: RemoteRefJournalLimits,
) -> BackendFuture<'a, ()> {
    Box::pin(async move {
        ensure_backend_repository(backend, event.repository_id())?;
        let remote =
            fetch_remote_ref_journal(backend, event.repository_id(), root_verifying_key, limits)
                .await?;
        remote.device_registry().registry().authorize_new_event(
            event.device_id(),
            event.signer().ok_or_else(|| {
                Error::new(
                    ErrorKind::Conflict,
                    "unsigned ref event cannot be published to a multi-device journal",
                )
            })?,
        )?;
        remote
            .device_registry()
            .registry()
            .authorize_ref_event(event)?;
        if remote.events().iter().any(|existing| existing == event) {
            return Ok(());
        }
        let current = match remote.reconcile(initial) {
            RemoteRefJournalReconciliation::Resolved(state) => state,
            RemoteRefJournalReconciliation::Divergent(_) => {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "remote ref journal is divergent",
                ));
            }
        };
        if event.expected_state_id() != RefEvent::state_id(&current) {
            return Err(Error::new(
                ErrorKind::Conflict,
                "local ref state is stale relative to the remote journal",
            ));
        }
        let mut candidate = remote.events().to_vec();
        candidate.push(event.clone());
        match reconcile_ref_events(initial, &candidate) {
            RemoteRefJournalReconciliation::Resolved(_) => {}
            RemoteRefJournalReconciliation::Divergent(_) => {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "ref event does not continue the remote journal",
                ));
            }
        }
        let key = remote_ref_event_key(event)?;
        put_exactly_once(
            backend,
            &key,
            &event.encode(),
            limits.ref_event_limits().maximum_event_bytes(),
        )
        .await?;
        let confirmed =
            fetch_remote_ref_journal(backend, event.repository_id(), root_verifying_key, limits)
                .await?;
        if !confirmed.events().iter().any(|existing| existing == event) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "published remote ref event is unavailable",
            ));
        }
        Ok(())
    })
}

fn reconcile_ref_events(
    initial: &GitRefState,
    events: &[RefEvent],
) -> RemoteRefJournalReconciliation {
    let mut current = initial.clone();
    let mut chains: std::collections::BTreeMap<crate::DeviceId, (u64, [u8; 32])> =
        std::collections::BTreeMap::new();
    let mut pending = events.to_vec();
    while !pending.is_empty() {
        let expected_state_id = RefEvent::state_id(&current);
        let candidates: Vec<usize> = pending
            .iter()
            .enumerate()
            .filter_map(|(index, event)| {
                let expected_chain = match chains.get(&event.device_id()) {
                    Some((sequence, event_id)) => (sequence.checked_add(1)?, *event_id),
                    None => (1, [0; 32]),
                };
                (event.expected_state_id() == expected_state_id
                    && event.sequence() == expected_chain.0
                    && event.previous_event_id() == expected_chain.1)
                    .then_some(index)
            })
            .collect();
        let index = match candidates.as_slice() {
            [index] => *index,
            _ => {
                return RemoteRefJournalReconciliation::Divergent(RemoteRefJournalDivergence {
                    base_state: current,
                    unresolved_events: pending,
                });
            }
        };
        let event = pending.remove(index);
        chains.insert(event.device_id(), (event.sequence(), event.event_id()));
        current = event.state().clone();
    }
    RemoteRefJournalReconciliation::Resolved(current)
}

async fn fetch_device_registry_events<B: Backend>(
    backend: &EncryptedBackend<B>,
    repository_id: RepositoryId,
    limits: RemoteRefJournalLimits,
) -> Result<Vec<DeviceRegistryEvent>> {
    let prefix = remote_directory_prefix(repository_id, REGISTRY_DIRECTORY)?;
    let keys = list_keys(
        backend,
        &prefix,
        limits.backend_list_limits(),
        limits.device_registry_limits().maximum_events(),
    )
    .await?;
    let mut events = Vec::with_capacity(keys.len());
    for key in keys {
        let (sequence, expected_id) = parse_device_registry_event_key(repository_id, &key)?;
        let bytes = read_backend_event(
            backend,
            &key,
            limits.device_registry_limits().maximum_event_bytes(),
        )
        .await?;
        let event = DeviceRegistryEvent::decode(&bytes, limits.device_registry_limits())?;
        if event.encode() != bytes
            || event.repository_id() != repository_id
            || event.sequence() != sequence
            || event.event_id() != expected_id
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "remote device registry key does not match its record",
            ));
        }
        events.push(event);
    }
    Ok(events)
}

async fn list_keys<B: Backend>(
    backend: &EncryptedBackend<B>,
    prefix: &BackendPrefix,
    list_limits: BackendListLimits,
    maximum_entries: usize,
) -> Result<Vec<BackendKey>> {
    let mut cursor = None;
    let mut seen_cursors = BTreeSet::new();
    let mut keys = BTreeSet::new();
    loop {
        let page = backend.list(prefix, cursor.as_ref(), list_limits).await?;
        for entry in page.entries() {
            if !entry.key().as_bytes().starts_with(prefix.as_bytes()) {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "backend listing returned a key outside the requested prefix",
                ));
            }
            if !keys.insert(entry.key().clone()) {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "backend listing returned a duplicate key",
                ));
            }
            if keys.len() > maximum_entries {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "remote journal exceeds the entry limit",
                ));
            }
        }
        let Some(next) = page.next_cursor().cloned() else {
            return Ok(keys.into_iter().collect());
        };
        if !seen_cursors.insert(next.clone()) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "backend listing cursor repeats",
            ));
        }
        cursor = Some(next);
    }
}

async fn read_backend_event<B: Backend>(
    backend: &EncryptedBackend<B>,
    key: &BackendKey,
    maximum_bytes: u64,
) -> Result<Vec<u8>> {
    let bytes = backend
        .get(
            key,
            BackendReadRequest::full(BackendReadLimits::new(maximum_bytes)),
        )
        .await?;
    if bytes.len() as u64 > maximum_bytes {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "remote journal record exceeds the byte limit",
        ));
    }
    Ok(bytes)
}

async fn put_exactly_once<B: Backend>(
    backend: &EncryptedBackend<B>,
    key: &BackendKey,
    bytes: &[u8],
    maximum_bytes: u64,
) -> Result<()> {
    match backend.put_if_absent(key, bytes).await? {
        BackendPutResult::Created(_) => Ok(()),
        BackendPutResult::AlreadyExists(metadata) if metadata.length() == bytes.len() as u64 => {
            if read_backend_event(backend, key, maximum_bytes).await? == bytes {
                Ok(())
            } else {
                Err(Error::new(
                    ErrorKind::Conflict,
                    "remote immutable record conflicts with existing data",
                ))
            }
        }
        BackendPutResult::AlreadyExists(_) => Err(Error::new(
            ErrorKind::Conflict,
            "remote immutable record conflicts with existing data",
        )),
    }
}

fn ensure_backend_repository<B>(
    backend: &EncryptedBackend<B>,
    repository_id: RepositoryId,
) -> Result<()> {
    if backend.repository_id() != repository_id {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "remote journal repository does not match the encryption key",
        ));
    }
    Ok(())
}

fn remote_directory_prefix(repository_id: RepositoryId, directory: &str) -> Result<BackendPrefix> {
    BackendPrefix::from_bytes(format!("{REMOTE_PREFIX}/{repository_id}/{directory}/").as_bytes())
}

fn device_registry_event_key(event: &DeviceRegistryEvent) -> Result<BackendKey> {
    BackendKey::from_bytes(
        format!(
            "{REMOTE_PREFIX}/{}/{REGISTRY_DIRECTORY}/{:020}-{}.{}",
            event.repository_id(),
            event.sequence(),
            hex::encode(event.event_id()),
            &REGISTRY_EXTENSION[1..],
        )
        .as_bytes(),
    )
}

fn remote_ref_event_key(event: &RefEvent) -> Result<BackendKey> {
    BackendKey::from_bytes(
        format!(
            "{REMOTE_PREFIX}/{}/{REF_EVENT_DIRECTORY}/{:020}-{}-{}.{}",
            event.repository_id(),
            event.sequence(),
            event.device_id(),
            hex::encode(event.event_id()),
            &REF_EVENT_EXTENSION[1..],
        )
        .as_bytes(),
    )
}

fn parse_device_registry_event_key(
    repository_id: RepositoryId,
    key: &BackendKey,
) -> Result<(u64, [u8; 32])> {
    let prefix = remote_directory_prefix(repository_id, REGISTRY_DIRECTORY)?;
    let prefix = std::str::from_utf8(prefix.as_bytes()).map_err(|_| {
        Error::new(
            ErrorKind::Internal,
            "remote device registry prefix is invalid",
        )
    })?;
    let name = std::str::from_utf8(key.as_bytes())
        .ok()
        .and_then(|key| key.strip_prefix(prefix))
        .ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "remote device registry key is invalid",
            )
        })?;
    let stem = name.strip_suffix(REGISTRY_EXTENSION).ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "remote device registry key is invalid",
        )
    })?;
    if !stem.is_ascii() || stem.len() != 85 || stem.as_bytes().get(20) != Some(&b'-') {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "remote device registry key is invalid",
        ));
    }
    let sequence = parse_sequence(&stem[..20])?;
    let mut event_id = [0; 32];
    hex::decode_to_slice(&stem[21..], &mut event_id).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "remote device registry key is invalid",
        )
    })?;
    Ok((sequence, event_id))
}

fn parse_remote_ref_event_key(
    repository_id: RepositoryId,
    key: &BackendKey,
) -> Result<(u64, crate::DeviceId, [u8; 32])> {
    let prefix = remote_directory_prefix(repository_id, REF_EVENT_DIRECTORY)?;
    let prefix = std::str::from_utf8(prefix.as_bytes())
        .map_err(|_| Error::new(ErrorKind::Internal, "remote ref journal prefix is invalid"))?;
    let name = std::str::from_utf8(key.as_bytes())
        .ok()
        .and_then(|key| key.strip_prefix(prefix))
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "remote ref journal key is invalid"))?;
    let stem = name
        .strip_suffix(REF_EVENT_EXTENSION)
        .ok_or_else(|| Error::new(ErrorKind::CorruptData, "remote ref journal key is invalid"))?;
    if !stem.is_ascii()
        || stem.len() != 122
        || stem.as_bytes().get(20) != Some(&b'-')
        || stem.as_bytes().get(57) != Some(&b'-')
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "remote ref journal key is invalid",
        ));
    }
    let sequence = parse_sequence(&stem[..20])?;
    let device_id = stem[21..57]
        .parse()
        .map_err(|_| Error::new(ErrorKind::CorruptData, "remote ref journal key is invalid"))?;
    let mut event_id = [0; 32];
    hex::decode_to_slice(&stem[58..], &mut event_id)
        .map_err(|_| Error::new(ErrorKind::CorruptData, "remote ref journal key is invalid"))?;
    Ok((sequence, device_id, event_id))
}

fn parse_sequence(text: &str) -> Result<u64> {
    let sequence = text
        .parse::<u64>()
        .map_err(|_| Error::new(ErrorKind::CorruptData, "remote journal sequence is invalid"))?;
    if sequence == 0 || format!("{sequence:020}") != text {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "remote journal sequence is invalid",
        ));
    }
    Ok(sequence)
}

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeMap,
        fs,
        future::Future,
        path::{Path, PathBuf},
        sync::Arc,
        task::{Context, Poll, Wake, Waker},
    };

    use uuid::Uuid;

    use crate::{
        DeviceId, FilesystemBackend, GitObjectId, HeadState, RefEventSigningKey, RefName,
        RepositoryEncryptionKey,
    };

    use super::*;

    struct NoopWake;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("yeokcham-remote-journal-{}", Uuid::new_v4()));
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

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        let mut future = std::pin::pin!(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("remote journal future unexpectedly yielded"),
        }
    }

    fn repository_id() -> RepositoryId {
        "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID")
    }

    fn device_id(text: &str) -> DeviceId {
        text.parse().expect("device ID")
    }

    fn state(object_byte: u8) -> GitRefState {
        GitRefState::new(
            BTreeMap::from([(
                RefName::from_bytes(b"refs/heads/main").expect("ref"),
                GitObjectId::from_bytes([object_byte; GitObjectId::BYTE_LENGTH]),
            )]),
            HeadState::Symbolic(RefName::from_bytes(b"refs/heads/main").expect("HEAD")),
        )
        .expect("state")
    }

    fn limits() -> RemoteRefJournalLimits {
        RemoteRefJournalLimits::new(
            DeviceRegistryReadLimits::new(16, 1024).expect("registry limits"),
            RefEventReadLimits::new(16, 4096, 16).expect("event limits"),
            BackendListLimits::new(4, 16).expect("list limits"),
        )
        .expect("remote limits")
    }

    fn backend() -> (TestDirectory, EncryptedBackend<FilesystemBackend>) {
        let directory = TestDirectory::new();
        let key = RepositoryEncryptionKey::from_master_bytes(repository_id(), [7; 32]);
        let backend = EncryptedBackend::new(
            FilesystemBackend::create(directory.path().join("backend")).expect("backend"),
            key,
        );
        (directory, backend)
    }

    fn root_key() -> RefEventSigningKey {
        RefEventSigningKey::from_secret_bytes([3; 32])
    }

    fn publish_registration(
        backend: &EncryptedBackend<FilesystemBackend>,
        root: &RefEventSigningKey,
        device_id: DeviceId,
        device: &RefEventSigningKey,
    ) {
        let event = DeviceRegistryEvent::register(
            repository_id(),
            1,
            [0; 32],
            device_id,
            device.verifying_key(),
            root,
        )
        .expect("registration");
        block_on(publish_device_registry_event(
            backend,
            root.verifying_key(),
            &event,
            limits(),
        ))
        .expect("publish registration");
    }

    #[test]
    fn fetches_reconciles_and_rejects_stale_signed_pushes() {
        let (_directory, backend) = backend();
        let root = root_key();
        let writer = RefEventSigningKey::from_secret_bytes([4; 32]);
        let writer_id = device_id("6ba7b814-9dad-41d1-80b4-00c04fd430c8");
        publish_registration(&backend, &root, writer_id, &writer);
        let initial = state(1);
        let accepted = RefEvent::new_signed(
            repository_id(),
            writer_id,
            1,
            [0; 32],
            RefEvent::state_id(&initial),
            state(2),
            &writer,
        )
        .expect("accepted event");
        block_on(publish_remote_ref_event(
            &backend,
            root.verifying_key(),
            &initial,
            &accepted,
            limits(),
        ))
        .expect("publish event");
        let journal = block_on(fetch_remote_ref_journal(
            &backend,
            repository_id(),
            root.verifying_key(),
            limits(),
        ))
        .expect("fetch");
        assert_eq!(journal.events(), &[accepted.clone()]);
        assert_eq!(
            journal.reconcile(&initial),
            RemoteRefJournalReconciliation::Resolved(state(2))
        );
        let stale = RefEvent::new_signed(
            repository_id(),
            writer_id,
            2,
            accepted.event_id(),
            RefEvent::state_id(&initial),
            state(3),
            &writer,
        )
        .expect("stale event");
        assert_eq!(
            block_on(publish_remote_ref_event(
                &backend,
                root.verifying_key(),
                &initial,
                &stale,
                limits(),
            ))
            .expect_err("stale")
            .kind(),
            ErrorKind::Conflict
        );
    }

    #[test]
    fn preserves_divergent_remote_branches_without_selecting_one() {
        let (_directory, backend) = backend();
        let root = root_key();
        let writer = RefEventSigningKey::from_secret_bytes([4; 32]);
        let writer_id = device_id("6ba7b814-9dad-41d1-80b4-00c04fd430c8");
        publish_registration(&backend, &root, writer_id, &writer);
        let initial = state(1);
        let left = RefEvent::new_signed(
            repository_id(),
            writer_id,
            1,
            [0; 32],
            RefEvent::state_id(&initial),
            state(2),
            &writer,
        )
        .expect("left");
        let right = RefEvent::new_signed(
            repository_id(),
            writer_id,
            1,
            [0; 32],
            RefEvent::state_id(&initial),
            state(3),
            &writer,
        )
        .expect("right");
        for event in [&left, &right] {
            let key = remote_ref_event_key(event).expect("key");
            block_on(backend.put_if_absent(&key, &event.encode())).expect("put");
        }
        let journal = block_on(fetch_remote_ref_journal(
            &backend,
            repository_id(),
            root.verifying_key(),
            limits(),
        ))
        .expect("fetch");
        let RemoteRefJournalReconciliation::Divergent(divergence) = journal.reconcile(&initial)
        else {
            panic!("expected divergence");
        };
        assert_eq!(divergence.base_state(), &initial);
        assert_eq!(divergence.unresolved_events().len(), 2);
    }

    #[test]
    fn revocation_rejects_new_remote_writes_beyond_the_capped_head() {
        let (_directory, backend) = backend();
        let root = root_key();
        let writer = RefEventSigningKey::from_secret_bytes([4; 32]);
        let writer_id = device_id("6ba7b814-9dad-41d1-80b4-00c04fd430c8");
        let registration = DeviceRegistryEvent::register(
            repository_id(),
            1,
            [0; 32],
            writer_id,
            writer.verifying_key(),
            &root,
        )
        .expect("registration");
        block_on(publish_device_registry_event(
            &backend,
            root.verifying_key(),
            &registration,
            limits(),
        ))
        .expect("registration");
        let initial = state(1);
        let accepted = RefEvent::new_signed(
            repository_id(),
            writer_id,
            1,
            [0; 32],
            RefEvent::state_id(&initial),
            state(2),
            &writer,
        )
        .expect("accepted");
        block_on(publish_remote_ref_event(
            &backend,
            root.verifying_key(),
            &initial,
            &accepted,
            limits(),
        ))
        .expect("publish accepted");
        let revocation = DeviceRegistryEvent::revoke(
            repository_id(),
            2,
            registration.event_id(),
            writer_id,
            accepted.sequence(),
            accepted.event_id(),
            &root,
        )
        .expect("revocation");
        block_on(publish_device_registry_event(
            &backend,
            root.verifying_key(),
            &revocation,
            limits(),
        ))
        .expect("publish revocation");
        let later = RefEvent::new_signed(
            repository_id(),
            writer_id,
            2,
            accepted.event_id(),
            RefEvent::state_id(accepted.state()),
            state(3),
            &writer,
        )
        .expect("later");
        assert_eq!(
            block_on(publish_remote_ref_event(
                &backend,
                root.verifying_key(),
                &initial,
                &later,
                limits(),
            ))
            .expect_err("revoked")
            .kind(),
            ErrorKind::Conflict
        );
    }
}
