use std::{collections::BTreeMap, fmt};

use ed25519_dalek::Signature;
use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, DeviceId, Error, ErrorKind, RefEvent, RefEventSigningKey,
    RefEventVerifyingKey, RepositoryId, Result,
};

const MAGIC: [u8; 4] = *b"YKDR";
const FOOTER_MAGIC: [u8; 4] = *b"YKDH";
const VERSION: u16 = 1;
const REGISTER_TAG: u8 = 1;
const REVOKE_TAG: u8 = 2;
const ZERO_EVENT_ID: [u8; 32] = [0; 32];
const ENCODED_BYTES: u64 = 4 + 2 + 8 + 8 + 16 + 8 + 32 + 1 + 16 + 32 + 8 + 32 + 64 + 4 + 32;

/// bounded decoding policy for immutable device-registry records.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct DeviceRegistryReadLimits {
    maximum_events: usize,
    maximum_event_bytes: u64,
}

impl DeviceRegistryReadLimits {
    /// creates bounded limits for one complete registry chain.
    pub fn new(maximum_events: usize, maximum_event_bytes: u64) -> Result<Self> {
        if maximum_events == 0 || maximum_event_bytes < ENCODED_BYTES {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "device registry limits are invalid",
            ));
        }
        Ok(Self {
            maximum_events,
            maximum_event_bytes,
        })
    }

    /// returns the maximum accepted immutable registry records.
    pub const fn maximum_events(self) -> usize {
        self.maximum_events
    }

    /// returns the maximum accepted bytes from one registry record.
    pub const fn maximum_event_bytes(self) -> u64 {
        self.maximum_event_bytes
    }
}

/// immutable root-authorized change to one device authorization record.
#[derive(Clone, Eq, PartialEq)]
pub struct DeviceRegistryEvent {
    repository_id: RepositoryId,
    sequence: u64,
    previous_event_id: [u8; 32],
    change: DeviceRegistryChange,
    signature: [u8; 64],
}

#[derive(Clone, Eq, PartialEq)]
enum DeviceRegistryChange {
    Register {
        device_id: DeviceId,
        verifying_key: RefEventVerifyingKey,
    },
    Revoke {
        device_id: DeviceId,
        accepted_sequence: u64,
        accepted_event_id: [u8; 32],
    },
}

impl DeviceRegistryEvent {
    /// creates a root-signed immutable registration for one new device.
    pub fn register(
        repository_id: RepositoryId,
        sequence: u64,
        previous_event_id: [u8; 32],
        device_id: DeviceId,
        verifying_key: RefEventVerifyingKey,
        root_signing_key: &RefEventSigningKey,
    ) -> Result<Self> {
        Self::new(
            repository_id,
            sequence,
            previous_event_id,
            DeviceRegistryChange::Register {
                device_id,
                verifying_key,
            },
            root_signing_key,
        )
    }

    /// creates a root-signed revocation capped at one accepted device head.
    pub fn revoke(
        repository_id: RepositoryId,
        sequence: u64,
        previous_event_id: [u8; 32],
        device_id: DeviceId,
        accepted_sequence: u64,
        accepted_event_id: [u8; 32],
        root_signing_key: &RefEventSigningKey,
    ) -> Result<Self> {
        if (accepted_sequence == 0) != (accepted_event_id == ZERO_EVENT_ID) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "revocation head is invalid",
            ));
        }
        Self::new(
            repository_id,
            sequence,
            previous_event_id,
            DeviceRegistryChange::Revoke {
                device_id,
                accepted_sequence,
                accepted_event_id,
            },
            root_signing_key,
        )
    }

    fn new(
        repository_id: RepositoryId,
        sequence: u64,
        previous_event_id: [u8; 32],
        change: DeviceRegistryChange,
        root_signing_key: &RefEventSigningKey,
    ) -> Result<Self> {
        if sequence == 0 || (sequence == 1) != (previous_event_id == ZERO_EVENT_ID) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "device registry sequence chain is invalid",
            ));
        }
        let mut event = Self {
            repository_id,
            sequence,
            previous_event_id,
            change,
            signature: [0; 64],
        };
        event.signature = root_signing_key.sign(&event.signature_payload());
        Ok(event)
    }

    /// decodes one canonical root-signed immutable registry record.
    pub fn decode(bytes: &[u8], limits: DeviceRegistryReadLimits) -> Result<Self> {
        let length = u64::try_from(bytes.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "device registry record exceeds the byte limit",
            )
        })?;
        if length != ENCODED_BYTES || length > limits.maximum_event_bytes() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "device registry record has an unsupported length",
            ));
        }
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC || decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "device registry record version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "device registry record uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "device registry record has an invalid repository ID",
            )
        })?;
        let sequence = decoder.read_u64()?;
        let previous_event_id = decoder.read_fixed()?;
        let device_id = DeviceId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "device registry record has an invalid device ID",
            )
        })?;
        let change = match decoder.read_u8()? {
            REGISTER_TAG => {
                let verifying_key = RefEventVerifyingKey::from_bytes(decoder.read_fixed()?)
                    .map_err(|_| {
                        Error::new(
                            ErrorKind::CorruptData,
                            "device registry record has an invalid verifying key",
                        )
                    })?;
                if decoder.read_u64()? != 0 || decoder.read_fixed::<32>()? != ZERO_EVENT_ID {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "device registry registration padding is invalid",
                    ));
                }
                DeviceRegistryChange::Register {
                    device_id,
                    verifying_key,
                }
            }
            REVOKE_TAG => {
                if decoder.read_fixed::<32>()? != [0; 32] {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "device registry revocation padding is invalid",
                    ));
                }
                let accepted_sequence = decoder.read_u64()?;
                let accepted_event_id = decoder.read_fixed()?;
                if (accepted_sequence == 0) != (accepted_event_id == ZERO_EVENT_ID) {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "device registry revocation head is invalid",
                    ));
                }
                DeviceRegistryChange::Revoke {
                    device_id,
                    accepted_sequence,
                    accepted_event_id,
                }
            }
            _ => {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "device registry change is unsupported",
                ));
            }
        };
        let signature = decoder.read_fixed()?;
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "device registry record has an invalid footer",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "device registry record checksum is truncated",
            )
        })?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "device registry record checksum does not match its bytes",
            ));
        }
        let event = Self {
            repository_id,
            sequence,
            previous_event_id,
            change,
            signature,
        };
        if event.sequence == 0
            || (event.sequence == 1) != (event.previous_event_id == ZERO_EVENT_ID)
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "device registry sequence chain is invalid",
            ));
        }
        Ok(event)
    }

    /// returns the repository identity bound by this record.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// returns this record's positive root-authorized sequence.
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    /// returns the preceding registry event identity.
    pub const fn previous_event_id(&self) -> [u8; 32] {
        self.previous_event_id
    }

    /// returns the affected device identity.
    pub const fn device_id(&self) -> DeviceId {
        match self.change {
            DeviceRegistryChange::Register { device_id, .. }
            | DeviceRegistryChange::Revoke { device_id, .. } => device_id,
        }
    }

    /// reports whether this record registers a device.
    pub const fn is_registration(&self) -> bool {
        matches!(self.change, DeviceRegistryChange::Register { .. })
    }

    /// returns the registered device verifying key when present.
    pub const fn registered_verifying_key(&self) -> Option<RefEventVerifyingKey> {
        match self.change {
            DeviceRegistryChange::Register { verifying_key, .. } => Some(verifying_key),
            DeviceRegistryChange::Revoke { .. } => None,
        }
    }

    /// returns the revocation's accepted device-journal head when present.
    pub const fn revocation_head(&self) -> Option<(u64, [u8; 32])> {
        match self.change {
            DeviceRegistryChange::Register { .. } => None,
            DeviceRegistryChange::Revoke {
                accepted_sequence,
                accepted_event_id,
                ..
            } => Some((accepted_sequence, accepted_event_id)),
        }
    }

    /// verifies this record against the caller-pinned registry root key.
    pub fn verify_root(&self, root_verifying_key: RefEventVerifyingKey) -> Result<()> {
        let signature = Signature::from_bytes(&self.signature);
        root_verifying_key
            .dalek_key()?
            .verify_strict(&self.signature_payload(), &signature)
            .map_err(|_| {
                Error::new(
                    ErrorKind::CorruptData,
                    "device registry root signature is invalid",
                )
            })
    }

    /// returns this record's immutable canonical identity.
    pub fn event_id(&self) -> [u8; 32] {
        Sha256::digest(self.encode()).into()
    }

    /// returns this record's canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = self.encode_prefix();
        bytes.extend_from_slice(&self.signature);
        bytes.extend_from_slice(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(&bytes).into();
        bytes.extend_from_slice(&checksum);
        bytes
    }

    fn signature_payload(&self) -> Vec<u8> {
        self.encode_prefix()
    }

    fn encode_prefix(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_u64(self.sequence);
        encoder.write_fixed(&self.previous_event_id);
        match self.change {
            DeviceRegistryChange::Register {
                device_id,
                verifying_key,
            } => {
                encoder.write_fixed(device_id.as_bytes());
                encoder.write_u8(REGISTER_TAG);
                encoder.write_fixed(verifying_key.as_bytes());
                encoder.write_u64(0);
                encoder.write_fixed(&ZERO_EVENT_ID);
            }
            DeviceRegistryChange::Revoke {
                device_id,
                accepted_sequence,
                accepted_event_id,
            } => {
                encoder.write_fixed(device_id.as_bytes());
                encoder.write_u8(REVOKE_TAG);
                encoder.write_fixed(&[0; 32]);
                encoder.write_u64(accepted_sequence);
                encoder.write_fixed(&accepted_event_id);
            }
        }
        encoder.into_bytes()
    }
}

impl fmt::Debug for DeviceRegistryEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DeviceRegistryEvent")
            .field("repository_id", &self.repository_id)
            .field("sequence", &self.sequence)
            .field("device_id", &self.device_id())
            .field("registration", &self.is_registration())
            .finish()
    }
}

/// resolved authorization state for one registered device.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct DeviceRegistration {
    verifying_key: RefEventVerifyingKey,
    accepted_through: Option<(u64, [u8; 32])>,
}

impl DeviceRegistration {
    /// returns the registered signing public key.
    pub const fn verifying_key(self) -> RefEventVerifyingKey {
        self.verifying_key
    }

    /// returns the final accepted journal head after revocation, when revoked.
    pub const fn accepted_through(self) -> Option<(u64, [u8; 32])> {
        self.accepted_through
    }

    /// reports whether this device remains allowed to publish new journal entries.
    pub const fn is_active(self) -> bool {
        self.accepted_through.is_none()
    }
}

/// one resolved device registry anchored by a caller-pinned root public key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceRegistry {
    repository_id: RepositoryId,
    root_verifying_key: RefEventVerifyingKey,
    head: [u8; 32],
    registrations: BTreeMap<DeviceId, DeviceRegistration>,
}

impl DeviceRegistry {
    /// resolves one complete root-authorized immutable registry chain.
    pub fn resolve(
        repository_id: RepositoryId,
        root_verifying_key: RefEventVerifyingKey,
        events: Vec<DeviceRegistryEvent>,
        limits: DeviceRegistryReadLimits,
    ) -> Result<Self> {
        if events.is_empty() || events.len() > limits.maximum_events() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "device registry event count is invalid",
            ));
        }
        let mut pending = events;
        let mut expected_sequence = 1_u64;
        let mut expected_previous = ZERO_EVENT_ID;
        let mut registrations = BTreeMap::new();
        while !pending.is_empty() {
            let candidates: Vec<usize> = pending
                .iter()
                .enumerate()
                .filter_map(|(index, event)| {
                    (event.repository_id == repository_id
                        && event.sequence == expected_sequence
                        && event.previous_event_id == expected_previous)
                        .then_some(index)
                })
                .collect();
            let index = match candidates.as_slice() {
                [index] => *index,
                [] => {
                    return Err(Error::new(
                        ErrorKind::Conflict,
                        "device registry chain is incomplete or divergent",
                    ));
                }
                _ => {
                    return Err(Error::new(
                        ErrorKind::Conflict,
                        "device registry chain diverges",
                    ));
                }
            };
            let event = pending.remove(index);
            event.verify_root(root_verifying_key)?;
            match event.change {
                DeviceRegistryChange::Register {
                    device_id,
                    verifying_key,
                } => {
                    if registrations
                        .insert(
                            device_id,
                            DeviceRegistration {
                                verifying_key,
                                accepted_through: None,
                            },
                        )
                        .is_some()
                    {
                        return Err(Error::new(
                            ErrorKind::Conflict,
                            "device registry registers a device more than once",
                        ));
                    }
                }
                DeviceRegistryChange::Revoke {
                    device_id,
                    accepted_sequence,
                    accepted_event_id,
                } => {
                    let registration = registrations.get_mut(&device_id).ok_or_else(|| {
                        Error::new(
                            ErrorKind::Conflict,
                            "device registry revokes an unknown device",
                        )
                    })?;
                    if registration.accepted_through.is_some() {
                        return Err(Error::new(
                            ErrorKind::Conflict,
                            "device registry revokes a device more than once",
                        ));
                    }
                    registration.accepted_through = Some((accepted_sequence, accepted_event_id));
                }
            }
            expected_previous = event.event_id();
            expected_sequence = expected_sequence.checked_add(1).ok_or_else(|| {
                Error::new(ErrorKind::Unsupported, "device registry sequence overflows")
            })?;
        }
        Ok(Self {
            repository_id,
            root_verifying_key,
            head: expected_previous,
            registrations,
        })
    }

    /// returns the repository identity bound by this resolved registry.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// returns the caller-pinned root public key.
    pub const fn root_verifying_key(&self) -> RefEventVerifyingKey {
        self.root_verifying_key
    }

    /// returns the final immutable registry event identity.
    pub const fn head(&self) -> [u8; 32] {
        self.head
    }

    /// returns authorization data for one device.
    pub fn registration(&self, device_id: DeviceId) -> Option<DeviceRegistration> {
        self.registrations.get(&device_id).copied()
    }

    /// verifies that one signed journal event is authorized by this registry.
    pub fn authorize_ref_event(&self, event: &RefEvent) -> Result<()> {
        if event.repository_id() != self.repository_id || !event.is_signed() {
            return Err(Error::new(
                ErrorKind::Conflict,
                "ref event is not authorized by the device registry",
            ));
        }
        let registration = self
            .registration(event.device_id())
            .ok_or_else(|| Error::new(ErrorKind::Conflict, "ref event device is not registered"))?;
        if event.signer() != Some(registration.verifying_key) {
            return Err(Error::new(
                ErrorKind::Conflict,
                "ref event signer is not registered for its device",
            ));
        }
        if let Some((sequence, event_id)) = registration.accepted_through {
            if event.sequence() > sequence
                || (event.sequence() == sequence && event.event_id() != event_id)
            {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "ref event exceeds the device revocation head",
                ));
            }
        }
        Ok(())
    }

    /// verifies that a device is still permitted to publish new journal entries.
    pub fn authorize_new_event(
        &self,
        device_id: DeviceId,
        signer: RefEventVerifyingKey,
    ) -> Result<()> {
        let registration = self
            .registration(device_id)
            .ok_or_else(|| Error::new(ErrorKind::Conflict, "device is not registered"))?;
        if !registration.is_active() || registration.verifying_key != signer {
            return Err(Error::new(
                ErrorKind::Conflict,
                "device is not authorized to publish new journal events",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::{GitObjectId, GitRefState, HeadState, RefName};

    use super::*;

    fn repository_id() -> RepositoryId {
        "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID")
    }

    fn device_id() -> DeviceId {
        "6ba7b814-9dad-41d1-80b4-00c04fd430c8"
            .parse()
            .expect("device ID")
    }

    fn root_key() -> RefEventSigningKey {
        RefEventSigningKey::from_secret_bytes([3; 32])
    }

    fn device_key() -> RefEventSigningKey {
        RefEventSigningKey::from_secret_bytes([4; 32])
    }

    fn state() -> GitRefState {
        GitRefState::new(
            BTreeMap::from([(
                RefName::from_bytes(b"refs/heads/main").expect("ref"),
                GitObjectId::from_bytes([7; GitObjectId::BYTE_LENGTH]),
            )]),
            HeadState::Symbolic(RefName::from_bytes(b"refs/heads/main").expect("HEAD")),
        )
        .expect("state")
    }

    fn limits() -> DeviceRegistryReadLimits {
        DeviceRegistryReadLimits::new(8, ENCODED_BYTES).expect("limits")
    }

    #[test]
    fn signed_registration_round_trips_and_authorizes_matching_event() {
        let root = root_key();
        let device = device_key();
        let registration = DeviceRegistryEvent::register(
            repository_id(),
            1,
            ZERO_EVENT_ID,
            device_id(),
            device.verifying_key(),
            &root,
        )
        .expect("registration");
        let decoded =
            DeviceRegistryEvent::decode(&registration.encode(), limits()).expect("decode");
        assert_eq!(decoded, registration);
        decoded
            .verify_root(root.verifying_key())
            .expect("signature");
        let registry = DeviceRegistry::resolve(
            repository_id(),
            root.verifying_key(),
            vec![registration],
            limits(),
        )
        .expect("registry");
        let event = RefEvent::new_signed(
            repository_id(),
            device_id(),
            1,
            ZERO_EVENT_ID,
            [0; 32],
            state(),
            &device,
        )
        .expect("event");
        registry.authorize_ref_event(&event).expect("authorized");
        registry
            .authorize_new_event(device_id(), device.verifying_key())
            .expect("active device");
    }

    #[test]
    fn revocation_preserves_only_the_capped_device_prefix() {
        let root = root_key();
        let device = device_key();
        let registration = DeviceRegistryEvent::register(
            repository_id(),
            1,
            ZERO_EVENT_ID,
            device_id(),
            device.verifying_key(),
            &root,
        )
        .expect("registration");
        let accepted = RefEvent::new_signed(
            repository_id(),
            device_id(),
            1,
            ZERO_EVENT_ID,
            [0; 32],
            state(),
            &device,
        )
        .expect("accepted event");
        let revocation = DeviceRegistryEvent::revoke(
            repository_id(),
            2,
            registration.event_id(),
            device_id(),
            accepted.sequence(),
            accepted.event_id(),
            &root,
        )
        .expect("revocation");
        let registry = DeviceRegistry::resolve(
            repository_id(),
            root.verifying_key(),
            vec![registration, revocation],
            limits(),
        )
        .expect("registry");
        registry
            .authorize_ref_event(&accepted)
            .expect("accepted prefix");
        let later = RefEvent::new_signed(
            repository_id(),
            device_id(),
            2,
            accepted.event_id(),
            RefEvent::state_id(accepted.state()),
            state(),
            &device,
        )
        .expect("later event");
        assert_eq!(
            registry
                .authorize_ref_event(&later)
                .expect_err("revoked")
                .kind(),
            ErrorKind::Conflict
        );
        assert_eq!(
            registry
                .authorize_new_event(device_id(), device.verifying_key())
                .expect_err("revoked")
                .kind(),
            ErrorKind::Conflict
        );
    }

    #[test]
    fn chain_and_root_signature_fail_closed() {
        let root = root_key();
        let registration = DeviceRegistryEvent::register(
            repository_id(),
            1,
            ZERO_EVENT_ID,
            device_id(),
            device_key().verifying_key(),
            &root,
        )
        .expect("registration");
        let wrong_root = RefEventSigningKey::from_secret_bytes([5; 32]);
        assert_eq!(
            DeviceRegistry::resolve(
                repository_id(),
                wrong_root.verifying_key(),
                vec![registration.clone()],
                limits(),
            )
            .expect_err("wrong root")
            .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            DeviceRegistry::resolve(
                repository_id(),
                root.verifying_key(),
                vec![registration.clone(), registration],
                limits(),
            )
            .expect_err("duplicate")
            .kind(),
            ErrorKind::Conflict
        );
    }
}
