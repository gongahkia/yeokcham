use std::fmt;

use sha2::{Digest, Sha256};

use crate::ref_snapshot::{canonical_ref_state_bytes, decode_ref_state, encode_ref_state};
use crate::{
    CanonicalDecoder, CanonicalEncoder, DeviceId, Error, ErrorKind, GitRefState, RepositoryId,
    Result,
};

const MAGIC: [u8; 4] = *b"YKRE";
const FOOTER_MAGIC: [u8; 4] = *b"YKRH";
const VERSION: u16 = 1;
const ZERO_EVENT_ID: [u8; 32] = [0; 32];

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
/// The event is locally durable and detects accidental or hostile replacement,
/// but V1 carries no authorisation signature. It is consequently limited to a
/// single trusted local writer until signed multi-device journals are added.
#[derive(Clone, Eq, PartialEq)]
pub struct RefEvent {
    repository_id: RepositoryId,
    device_id: DeviceId,
    sequence: u64,
    previous_event_id: [u8; 32],
    expected_state_id: [u8; 32],
    state: GitRefState,
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
        })
    }

    /// Decodes one canonical bounded V1 event.
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
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref event version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref event uses unsupported features",
            ));
        }
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
        Self::new(
            repository_id,
            device_id,
            sequence,
            previous_event_id,
            expected_state_id,
            state,
        )
        .map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref event sequence chain is invalid",
            )
        })
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
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.device_id.as_bytes());
        encoder.write_u64(self.sequence);
        encoder.write_fixed(&self.previous_event_id);
        encoder.write_fixed(&self.expected_state_id);
        encode_ref_state(&mut encoder, &self.state);
        encoder.write_fixed(&FOOTER_MAGIC);
        let mut bytes = encoder.into_bytes();
        let checksum: [u8; 32] = Sha256::digest(&bytes).into();
        bytes.extend_from_slice(&checksum);
        bytes
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

    #[test]
    fn canonical_event_round_trips_and_detects_tampering() {
        let event = event();
        let bytes = event.encode();
        let limits = RefEventReadLimits::new(8, 4_096, 8).expect("limits");
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
    fn ref_event_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<RefEvent>();
        assert_send_sync::<RefEventReadLimits>();
    }
}
