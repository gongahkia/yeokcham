use std::fmt;

use ed25519_dalek::{Signature, Signer as _, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::ref_snapshot::{canonical_ref_state_bytes, decode_ref_state, encode_ref_state};
use crate::{
    CanonicalDecoder, CanonicalEncoder, DeviceId, Error, ErrorKind, GitRefState, RepositoryId,
    Result,
};

const MAGIC: [u8; 4] = *b"YKRE";
const FOOTER_MAGIC: [u8; 4] = *b"YKRH";
const UNSIGNED_VERSION: u16 = 1;
const SIGNED_VERSION: u16 = 2;
const SIGNED_REQUIRED_FEATURES: u64 = 1;
const ZERO_EVENT_ID: [u8; 32] = [0; 32];

/// An Ed25519 public key carried by a signed ref event.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RefEventVerifyingKey([u8; 32]);

impl RefEventVerifyingKey {
    /// validates and constructs an Ed25519 public key from canonical bytes.
    pub fn from_bytes(bytes: [u8; 32]) -> Result<Self> {
        VerifyingKey::from_bytes(&bytes).map_err(|_| {
            Error::new(
                ErrorKind::InvalidInput,
                "ref event verifying key is invalid",
            )
        })?;
        Ok(Self(bytes))
    }

    /// returns the canonical public-key bytes.
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    pub(crate) fn dalek_key(self) -> Result<VerifyingKey> {
        VerifyingKey::from_bytes(&self.0)
            .map_err(|_| Error::new(ErrorKind::CorruptData, "ref event verifying key is invalid"))
    }
}

impl fmt::Debug for RefEventVerifyingKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RefEventVerifyingKey(<redacted>)")
    }
}

/// A caller-owned Ed25519 signing key for one ref-event transition.
pub struct RefEventSigningKey(SigningKey);

impl RefEventSigningKey {
    /// constructs a signing key from caller-managed 32-byte secret material.
    pub fn from_secret_bytes(bytes: [u8; 32]) -> Self {
        Self(SigningKey::from_bytes(&bytes))
    }

    /// returns the public key used to verify transitions from this signer.
    pub fn verifying_key(&self) -> RefEventVerifyingKey {
        RefEventVerifyingKey(self.0.verifying_key().to_bytes())
    }

    pub(crate) fn sign(&self, bytes: &[u8]) -> [u8; 64] {
        self.0.sign(bytes).to_bytes()
    }
}

impl fmt::Debug for RefEventSigningKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RefEventSigningKey(<redacted>)")
    }
}

#[derive(Clone, Eq, PartialEq)]
enum RefEventAuthentication {
    Unsigned,
    Ed25519 {
        signer: RefEventVerifyingKey,
        signature: [u8; 64],
    },
}

/// One bounded decoding policy for an immutable local ref event.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RefEventReadLimits {
    maximum_directory_entries: usize,
    maximum_event_bytes: u64,
    maximum_reference_entries: usize,
}

impl RefEventReadLimits {
    /// Creates bounded limits for one event record.
    pub fn new(
        maximum_directory_entries: usize,
        maximum_event_bytes: u64,
        maximum_reference_entries: usize,
    ) -> Result<Self> {
        if maximum_directory_entries == 0
            || maximum_event_bytes == 0
            || maximum_reference_entries == 0
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "ref event limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_directory_entries,
            maximum_event_bytes,
            maximum_reference_entries,
        })
    }

    /// Returns the maximum directory entries inspected during one scan.
    pub const fn maximum_directory_entries(self) -> usize {
        self.maximum_directory_entries
    }

    /// Returns the maximum accepted bytes from one event file.
    pub const fn maximum_event_bytes(self) -> u64 {
        self.maximum_event_bytes
    }

    /// Returns the maximum regular-reference entries in one event state.
    pub const fn maximum_reference_entries(self) -> usize {
        self.maximum_reference_entries
    }
}

/// Immutable checked transition from one complete Git ref state to the next.
///
/// V1 events are checksum-protected only. V2 events carry an Ed25519
/// signature that callers can verify against the embedded public key or an
/// externally expected key. Signature validity does not authorize a device;
/// device registration and key lifecycle remain separate responsibilities.
#[derive(Clone, Eq, PartialEq)]
pub struct RefEvent {
    repository_id: RepositoryId,
    device_id: DeviceId,
    sequence: u64,
    previous_event_id: [u8; 32],
    expected_state_id: [u8; 32],
    state: GitRefState,
    authentication: RefEventAuthentication,
}

impl RefEvent {
    /// Creates one checked transition on one device's sequence chain.
    pub fn new(
        repository_id: RepositoryId,
        device_id: DeviceId,
        sequence: u64,
        previous_event_id: [u8; 32],
        expected_state_id: [u8; 32],
        state: GitRefState,
    ) -> Result<Self> {
        Self::from_parts(
            repository_id,
            device_id,
            sequence,
            previous_event_id,
            expected_state_id,
            state,
            RefEventAuthentication::Unsigned,
        )
    }

    /// creates one Ed25519-signed checked transition on a device chain.
    pub fn new_signed(
        repository_id: RepositoryId,
        device_id: DeviceId,
        sequence: u64,
        previous_event_id: [u8; 32],
        expected_state_id: [u8; 32],
        state: GitRefState,
        signing_key: &RefEventSigningKey,
    ) -> Result<Self> {
        let signer = signing_key.verifying_key();
        let mut event = Self::from_parts(
            repository_id,
            device_id,
            sequence,
            previous_event_id,
            expected_state_id,
            state,
            RefEventAuthentication::Ed25519 {
                signer,
                signature: [0; 64],
            },
        )?;
        let signature = signing_key.sign(&event.signature_payload()?);
        if let RefEventAuthentication::Ed25519 {
            signature: stored, ..
        } = &mut event.authentication
        {
            *stored = signature;
        }
        Ok(event)
    }

    fn from_parts(
        repository_id: RepositoryId,
        device_id: DeviceId,
        sequence: u64,
        previous_event_id: [u8; 32],
        expected_state_id: [u8; 32],
        state: GitRefState,
        authentication: RefEventAuthentication,
    ) -> Result<Self> {
        if sequence == 0 || (sequence == 1) != (previous_event_id == ZERO_EVENT_ID) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "ref event sequence chain is invalid",
            ));
        }
        Ok(Self {
            repository_id,
            device_id,
            sequence,
            previous_event_id,
            expected_state_id,
            state,
            authentication,
        })
    }

    /// decodes one canonical bounded V1 or V2 event.
    pub fn decode(bytes: &[u8], limits: RefEventReadLimits) -> Result<Self> {
        let length = u64::try_from(bytes.len())
            .map_err(|_| Error::new(ErrorKind::Unsupported, "ref event exceeds the byte limit"))?;
        if length > limits.maximum_event_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref event exceeds the byte limit",
            ));
        }
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref event has invalid magic",
            ));
        }
        let version = decoder.read_u16()?;
        let required_features = decoder.read_u64()?;
        let optional_features = decoder.read_u64()?;
        let signed = match version {
            UNSIGNED_VERSION if required_features == 0 && optional_features == 0 => false,
            SIGNED_VERSION
                if required_features == SIGNED_REQUIRED_FEATURES && optional_features == 0 =>
            {
                true
            }
            UNSIGNED_VERSION | SIGNED_VERSION => {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "ref event uses unsupported features",
                ));
            }
            _ => {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "ref event version is unsupported",
                ));
            }
        };
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref event has an invalid repository ID",
            )
        })?;
        let device_id = DeviceId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(ErrorKind::CorruptData, "ref event has an invalid device ID")
        })?;
        let sequence = decoder.read_u64()?;
        let previous_event_id = decoder.read_fixed()?;
        let expected_state_id = decoder.read_fixed()?;
        let state = decode_ref_state(&mut decoder, limits.maximum_reference_entries)?;
        let authentication = if signed {
            let signer = RefEventVerifyingKey::from_bytes(decoder.read_fixed()?).map_err(|_| {
                Error::new(
                    ErrorKind::CorruptData,
                    "ref event has an invalid verifying key",
                )
            })?;
            RefEventAuthentication::Ed25519 {
                signer,
                signature: decoder.read_fixed()?,
            }
        } else {
            RefEventAuthentication::Unsigned
        };
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref event has invalid footer magic",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes
            .len()
            .checked_sub(checksum.len())
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "ref event checksum is truncated"))?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref event checksum does not match its bytes",
            ));
        }
        let event = Self::from_parts(
            repository_id,
            device_id,
            sequence,
            previous_event_id,
            expected_state_id,
            state,
            authentication,
        )
        .map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref event sequence chain is invalid",
            )
        })?;
        if event.is_signed() {
            event.verify_signature().map_err(|_| {
                Error::new(ErrorKind::CorruptData, "ref event signature is invalid")
            })?;
        }
        Ok(event)
    }

    /// Returns the repository identity bound by this event.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the writer identity declared by this event.
    pub const fn device_id(&self) -> DeviceId {
        self.device_id
    }

    /// Returns this device's strictly positive sequence number.
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Returns the preceding event's SHA-256 identity, or zero for sequence one.
    pub const fn previous_event_id(&self) -> [u8; 32] {
        self.previous_event_id
    }

    /// Returns the expected predecessor ref-state identity.
    pub const fn expected_state_id(&self) -> [u8; 32] {
        self.expected_state_id
    }

    /// reports whether this event carries an Ed25519 signature.
    pub const fn is_signed(&self) -> bool {
        matches!(self.authentication, RefEventAuthentication::Ed25519 { .. })
    }

    /// returns the embedded Ed25519 public key when this event is signed.
    pub const fn signer(&self) -> Option<RefEventVerifyingKey> {
        match self.authentication {
            RefEventAuthentication::Unsigned => None,
            RefEventAuthentication::Ed25519 { signer, .. } => Some(signer),
        }
    }

    /// verifies the signature against the event's embedded public key.
    pub fn verify_signature(&self) -> Result<()> {
        let signer = self.signer().ok_or_else(|| {
            Error::new(
                ErrorKind::Unsupported,
                "ref event does not carry a signature",
            )
        })?;
        self.verify_signature_with(signer)
    }

    /// verifies the signature against one caller-selected public key.
    pub fn verify_signature_with(&self, verifying_key: RefEventVerifyingKey) -> Result<()> {
        let signature = match self.authentication {
            RefEventAuthentication::Unsigned => {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "ref event does not carry a signature",
                ));
            }
            RefEventAuthentication::Ed25519 { signature, .. } => Signature::from_bytes(&signature),
        };
        verifying_key
            .dalek_key()?
            .verify_strict(&self.signature_payload()?, &signature)
            .map_err(|_| Error::new(ErrorKind::CorruptData, "ref event signature is invalid"))
    }

    /// Returns the complete successor Git ref state.
    pub const fn state(&self) -> &GitRefState {
        &self.state
    }

    /// Returns the SHA-256 identity of this event's canonical bytes.
    pub fn event_id(&self) -> [u8; 32] {
        Sha256::digest(self.encode()).into()
    }

    /// Returns the SHA-256 identity of one canonical Git ref state.
    pub fn state_id(state: &GitRefState) -> [u8; 32] {
        Sha256::digest(canonical_ref_state_bytes(state)).into()
    }

    /// Returns this event's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = self.encode_prefix();
        if let RefEventAuthentication::Ed25519 { signature, .. } = self.authentication {
            bytes.extend_from_slice(&signature);
        }
        bytes.extend_from_slice(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(&bytes).into();
        bytes.extend_from_slice(&checksum);
        bytes
    }

    fn signature_payload(&self) -> Result<Vec<u8>> {
        if !self.is_signed() {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref event does not carry a signature",
            ));
        }
        Ok(self.encode_prefix())
    }

    fn encode_prefix(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(if self.is_signed() {
            SIGNED_VERSION
        } else {
            UNSIGNED_VERSION
        });
        encoder.write_u64(if self.is_signed() {
            SIGNED_REQUIRED_FEATURES
        } else {
            0
        });
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.device_id.as_bytes());
        encoder.write_u64(self.sequence);
        encoder.write_fixed(&self.previous_event_id);
        encoder.write_fixed(&self.expected_state_id);
        encode_ref_state(&mut encoder, &self.state);
        if let RefEventAuthentication::Ed25519 { signer, .. } = self.authentication {
            encoder.write_fixed(signer.as_bytes());
        }
        encoder.into_bytes()
    }
}

impl fmt::Debug for RefEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RefEvent")
            .field("repository_id", &self.repository_id)
            .field("device_id", &self.device_id)
            .field("sequence", &self.sequence)
            .field("previous_event_id", &"<redacted>")
            .field("expected_state_id", &"<redacted>")
            .field("signed", &self.is_signed())
            .field("signer", &"<redacted>")
            .field("state", &self.state)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::{HeadState, RefName};

    use super::*;

    fn event() -> RefEvent {
        let repository_id = "550e8400-e29b-41d4-a716-446655440000"
            .parse()
            .expect("repository ID");
        let device_id = "6ba7b814-9dad-41d1-80b4-00c04fd430c8"
            .parse()
            .expect("device ID");
        let state = GitRefState::new(
            BTreeMap::from([(
                RefName::from_bytes(b"refs/heads/main").expect("ref"),
                crate::GitObjectId::from_bytes([7; crate::GitObjectId::BYTE_LENGTH]),
            )]),
            HeadState::Symbolic(RefName::from_bytes(b"refs/heads/main").expect("HEAD")),
        )
        .expect("state");
        RefEvent::new(repository_id, device_id, 1, ZERO_EVENT_ID, [8; 32], state).expect("event")
    }

    fn signing_key() -> RefEventSigningKey {
        RefEventSigningKey::from_secret_bytes([9; 32])
    }

    fn rechecksum(bytes: &mut [u8]) {
        let checksum_offset = bytes.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        bytes[checksum_offset..].copy_from_slice(&checksum);
    }

    #[test]
    fn canonical_event_round_trips_and_detects_tampering() {
        let event = event();
        let bytes = event.encode();
        let limits = RefEventReadLimits::new(8, 4_096, 8).expect("limits");
        assert_eq!(&bytes[..4], b"YKRE");
        assert_eq!(&bytes[4..6], &UNSIGNED_VERSION.to_be_bytes());
        assert_eq!(&bytes[6..22], &[0; 16]);
        assert!(!event.is_signed());
        assert_eq!(RefEvent::decode(&bytes, limits).expect("decode"), event);
        let expected_id: [u8; 32] = Sha256::digest(&bytes).into();
        assert_eq!(event.event_id(), expected_id);

        let mut tampered = bytes;
        *tampered.last_mut().expect("checksum") ^= 1;
        assert_eq!(
            RefEvent::decode(&tampered, limits)
                .expect_err("tampering must fail")
                .kind(),
            ErrorKind::CorruptData
        );
    }

    #[test]
    fn rejects_invalid_sequence_chain() {
        let event = event();
        assert_eq!(
            RefEvent::new(
                event.repository_id(),
                event.device_id(),
                2,
                ZERO_EVENT_ID,
                event.expected_state_id(),
                event.state().clone(),
            )
            .expect_err("sequence two needs a parent")
            .kind(),
            ErrorKind::InvalidInput
        );
    }

    #[test]
    fn signed_events_round_trip_and_reject_tampering_or_wrong_keys() {
        let unsigned = event();
        let signing_key = signing_key();
        let event = RefEvent::new_signed(
            unsigned.repository_id(),
            unsigned.device_id(),
            unsigned.sequence(),
            unsigned.previous_event_id(),
            unsigned.expected_state_id(),
            unsigned.state().clone(),
            &signing_key,
        )
        .expect("signed event");
        let bytes = event.encode();
        let limits = RefEventReadLimits::new(8, 4_096, 8).expect("limits");

        assert_eq!(&bytes[..4], b"YKRE");
        assert_eq!(&bytes[4..6], &SIGNED_VERSION.to_be_bytes());
        assert_eq!(&bytes[6..14], &SIGNED_REQUIRED_FEATURES.to_be_bytes());
        assert_eq!(&bytes[14..22], &[0; 8]);
        assert!(event.is_signed());
        assert_eq!(event.signer(), Some(signing_key.verifying_key()));
        event.verify_signature().expect("embedded signature");
        assert_eq!(RefEvent::decode(&bytes, limits).expect("decode"), event);
        let wrong_key = RefEventSigningKey::from_secret_bytes([10; 32]);
        assert_eq!(
            event
                .verify_signature_with(wrong_key.verifying_key())
                .expect_err("wrong key")
                .kind(),
            ErrorKind::CorruptData
        );

        let mut tampered = bytes;
        let signature_offset = tampered.len() - 32 - FOOTER_MAGIC.len() - 64;
        tampered[signature_offset] ^= 1;
        rechecksum(&mut tampered);
        assert_eq!(
            RefEvent::decode(&tampered, limits)
                .expect_err("signature tampering")
                .kind(),
            ErrorKind::CorruptData
        );
    }

    #[test]
    fn rejects_unknown_event_versions_and_features() {
        let limits = RefEventReadLimits::new(8, 4_096, 8).expect("limits");

        let mut unknown_version = event().encode();
        unknown_version[4..6].copy_from_slice(&3_u16.to_be_bytes());
        rechecksum(&mut unknown_version);
        assert_eq!(
            RefEvent::decode(&unknown_version, limits)
                .expect_err("unknown version")
                .kind(),
            ErrorKind::Unsupported
        );

        let mut unsupported_features = event().encode();
        unsupported_features[6..14].copy_from_slice(&SIGNED_REQUIRED_FEATURES.to_be_bytes());
        rechecksum(&mut unsupported_features);
        assert_eq!(
            RefEvent::decode(&unsupported_features, limits)
                .expect_err("unsupported V1 features")
                .kind(),
            ErrorKind::Unsupported
        );
    }

    #[test]
    fn unsigned_events_reject_signature_verification() {
        assert_eq!(
            event()
                .verify_signature()
                .expect_err("unsigned event")
                .kind(),
            ErrorKind::Unsupported
        );
    }

    #[test]
    fn ref_event_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RefEvent>();
        assert_send_sync::<RefEventReadLimits>();
        assert_send_sync::<RefEventSigningKey>();
        assert_send_sync::<RefEventVerifyingKey>();
    }

    #[test]
    fn key_debug_output_is_redacted() {
        let signing_key = signing_key();

        assert_eq!(format!("{signing_key:?}"), "RefEventSigningKey(<redacted>)");
        assert_eq!(
            format!("{:?}", signing_key.verifying_key()),
            "RefEventVerifyingKey(<redacted>)"
        );
    }
}
