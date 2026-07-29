use std::{collections::BTreeMap, fmt};

use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, GitObjectId, ManifestId, RefName,
    RepositoryId, Result,
};

const MAGIC: [u8; 4] = *b"YKRF";
const FOOTER_MAGIC: [u8; 4] = *b"YKRH";
const VERSION: u16 = 1;
const SYMBOLIC_HEAD_TAG: u8 = 1;
const DETACHED_HEAD_TAG: u8 = 2;

/// One Git `HEAD` state preserved by a ref snapshot.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum HeadState {
    /// `HEAD` names a regular reference, including an unborn branch.
    Symbolic(RefName),
    /// `HEAD` names one Git object directly.
    Detached(GitObjectId),
}

/// Point-in-time regular refs and `HEAD` extracted from a Git repository.
///
/// Regular symbolic references are resolved to their first direct object
/// target. `HEAD` retains its symbolic or detached form because Git requires
/// that distinction for a conventional exported repository.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitRefState {
    regular_refs: BTreeMap<RefName, GitObjectId>,
    head: HeadState,
}

impl GitRefState {
    /// Validates one complete point-in-time Git ref state.
    pub fn new(regular_refs: BTreeMap<RefName, GitObjectId>, head: HeadState) -> Result<Self> {
        validate_regular_refs(&regular_refs, ErrorKind::InvalidInput)?;
        validate_head(&head, ErrorKind::InvalidInput)?;
        Ok(Self { regular_refs, head })
    }

    /// Returns direct targets for every regular `refs/*` name.
    pub const fn regular_refs(&self) -> &BTreeMap<RefName, GitObjectId> {
        &self.regular_refs
    }

    /// Returns the preserved `HEAD` state.
    pub const fn head(&self) -> &HeadState {
        &self.head
    }
}

/// Caller-selected bounds for resolving one immutable `YKRF` snapshot.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RefSnapshotReadLimits {
    maximum_directory_entries: usize,
    maximum_snapshot_bytes: u64,
    maximum_reference_entries: usize,
}

impl RefSnapshotReadLimits {
    /// Validates directory, file, and reference bounds for one snapshot scan.
    pub fn new(
        maximum_directory_entries: usize,
        maximum_snapshot_bytes: u64,
        maximum_reference_entries: usize,
    ) -> Result<Self> {
        if maximum_directory_entries == 0
            || maximum_snapshot_bytes == 0
            || maximum_reference_entries == 0
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "ref snapshot limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_directory_entries,
            maximum_snapshot_bytes,
            maximum_reference_entries,
        })
    }

    /// Returns the maximum directory entries inspected during one scan.
    pub const fn maximum_directory_entries(self) -> usize {
        self.maximum_directory_entries
    }

    /// Returns the maximum accepted file bytes.
    pub const fn maximum_snapshot_bytes(self) -> u64 {
        self.maximum_snapshot_bytes
    }

    /// Returns the maximum accepted regular-reference entries.
    pub const fn maximum_reference_entries(self) -> usize {
        self.maximum_reference_entries
    }
}

/// Immutable portable V1 ref snapshot.
///
/// The filename is derived from `manifest_id`. Exactly one such snapshot is
/// accepted by the current local repository layout; journaled ref updates are
/// deferred to Milestone 3.
#[derive(Clone, Eq, PartialEq)]
pub struct RefSnapshot {
    repository_id: RepositoryId,
    manifest_id: ManifestId,
    state: GitRefState,
}

impl RefSnapshot {
    /// Creates one checked immutable ref snapshot.
    pub fn new(
        repository_id: RepositoryId,
        manifest_id: ManifestId,
        state: GitRefState,
    ) -> Result<Self> {
        validate_regular_refs(state.regular_refs(), ErrorKind::InvalidInput)?;
        validate_head(state.head(), ErrorKind::InvalidInput)?;
        Ok(Self {
            repository_id,
            manifest_id,
            state,
        })
    }

    /// Decodes one bounded V1 `YKRF` snapshot.
    pub fn decode(bytes: &[u8], limits: RefSnapshotReadLimits) -> Result<Self> {
        let length = u64::try_from(bytes.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "ref snapshot exceeds the byte limit",
            )
        })?;
        if length > limits.maximum_snapshot_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref snapshot exceeds the byte limit",
            ));
        }
        let mut decoder = CanonicalDecoder::new(bytes);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref snapshot has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref snapshot version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref snapshot uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref snapshot has an invalid repository ID",
            )
        })?;
        let manifest_id = ManifestId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref snapshot has an invalid manifest ID",
            )
        })?;
        let head = match decoder.read_u8()? {
            SYMBOLIC_HEAD_TAG => HeadState::Symbolic(decode_regular_ref_name(
                decoder.read_byte_string()?,
                "ref snapshot has an invalid symbolic HEAD",
            )?),
            DETACHED_HEAD_TAG => {
                HeadState::Detached(GitObjectId::from_bytes(decoder.read_fixed()?))
            }
            _ => {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "ref snapshot has an invalid HEAD state",
                ));
            }
        };
        let reference_count = usize::try_from(decoder.read_u64()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref snapshot reference count is invalid",
            )
        })?;
        if reference_count > limits.maximum_reference_entries {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "ref snapshot exceeds the reference-entry limit",
            ));
        }
        let mut regular_refs = BTreeMap::new();
        let mut previous = None;
        for _ in 0..reference_count {
            let name = decode_regular_ref_name(
                decoder.read_byte_string()?,
                "ref snapshot has an invalid regular ref",
            )?;
            if previous
                .as_ref()
                .is_some_and(|previous: &RefName| previous >= &name)
            {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "ref snapshot references are not strictly sorted",
                ));
            }
            previous = Some(name.clone());
            regular_refs.insert(name, GitObjectId::from_bytes(decoder.read_fixed()?));
        }
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref snapshot has invalid footer magic",
            ));
        }
        let checksum = decoder.read_fixed::<32>()?;
        decoder.finish()?;
        let checksum_offset = bytes.len().checked_sub(checksum.len()).ok_or_else(|| {
            Error::new(ErrorKind::CorruptData, "ref snapshot checksum is truncated")
        })?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "ref snapshot checksum does not match its bytes",
            ));
        }
        let state = GitRefState::new(regular_refs, head).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "ref snapshot contains an invalid ref state",
            )
        })?;
        Ok(Self {
            repository_id,
            manifest_id,
            state,
        })
    }

    /// Returns the repository identity bound by this snapshot.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns this immutable snapshot identity.
    pub const fn manifest_id(&self) -> ManifestId {
        self.manifest_id
    }

    /// Returns the preserved refs and `HEAD` state.
    pub const fn state(&self) -> &GitRefState {
        &self.state
    }

    /// Returns this snapshot's unique canonical byte encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_fixed(self.manifest_id.as_bytes());
        match self.state.head() {
            HeadState::Symbolic(name) => {
                encoder.write_u8(SYMBOLIC_HEAD_TAG);
                encoder.write_byte_string(name.as_bytes());
            }
            HeadState::Detached(id) => {
                encoder.write_u8(DETACHED_HEAD_TAG);
                encoder.write_fixed(id.as_bytes());
            }
        }
        encoder.write_u64(self.state.regular_refs().len() as u64);
        for (name, target) in self.state.regular_refs() {
            encoder.write_byte_string(name.as_bytes());
            encoder.write_fixed(target.as_bytes());
        }
        encoder.write_fixed(&FOOTER_MAGIC);
        let mut bytes = encoder.into_bytes();
        let checksum: [u8; 32] = Sha256::digest(&bytes).into();
        bytes.extend_from_slice(&checksum);
        bytes
    }
}

impl fmt::Debug for RefSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RefSnapshot")
            .field("repository_id", &self.repository_id)
            .field("manifest_id", &self.manifest_id)
            .field("state", &self.state)
            .finish()
    }
}

fn decode_regular_ref_name(bytes: &[u8], message: &'static str) -> Result<RefName> {
    let name =
        RefName::from_bytes(bytes).map_err(|_| Error::new(ErrorKind::CorruptData, message))?;
    if !name.as_bytes().starts_with(b"refs/") {
        return Err(Error::new(ErrorKind::CorruptData, message));
    }
    Ok(name)
}

fn validate_regular_refs(
    regular_refs: &BTreeMap<RefName, GitObjectId>,
    kind: ErrorKind,
) -> Result<()> {
    if regular_refs
        .keys()
        .any(|name| !name.as_bytes().starts_with(b"refs/"))
    {
        return Err(Error::new(kind, "ref state has an invalid regular ref"));
    }
    Ok(())
}

fn validate_head(head: &HeadState, kind: ErrorKind) -> Result<()> {
    if let HeadState::Symbolic(name) = head {
        if !name.as_bytes().starts_with(b"refs/") {
            return Err(Error::new(kind, "ref state has an invalid symbolic HEAD"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const MANIFEST_ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

    fn limits() -> RefSnapshotReadLimits {
        RefSnapshotReadLimits::new(8, 4_096, 8).expect("limits")
    }

    fn snapshot(head: HeadState) -> RefSnapshot {
        let mut refs = BTreeMap::new();
        refs.insert(
            RefName::from_bytes(b"refs/heads/main").expect("ref name"),
            GitObjectId::from_bytes([1; GitObjectId::BYTE_LENGTH]),
        );
        RefSnapshot::new(
            REPOSITORY_ID.parse().expect("repository ID"),
            MANIFEST_ID.parse().expect("manifest ID"),
            GitRefState::new(refs, head).expect("state"),
        )
        .expect("snapshot")
    }

    #[test]
    fn round_trips_symbolic_and_detached_head_snapshots() {
        for head in [
            HeadState::Symbolic(RefName::from_bytes(b"refs/heads/main").expect("ref name")),
            HeadState::Detached(GitObjectId::from_bytes([2; GitObjectId::BYTE_LENGTH])),
        ] {
            let snapshot = snapshot(head);
            assert_eq!(
                RefSnapshot::decode(&snapshot.encode(), limits()).expect("decode"),
                snapshot
            );
        }
    }

    #[test]
    fn rejects_tampering_invalid_refs_and_bounds() {
        let snapshot = snapshot(HeadState::Symbolic(
            RefName::from_bytes(b"refs/heads/main").expect("ref name"),
        ));
        let mut tampered = snapshot.encode();
        *tampered.last_mut().expect("checksum") ^= 1;
        assert_eq!(
            RefSnapshot::decode(&tampered, limits())
                .expect_err("tampered snapshot")
                .kind(),
            ErrorKind::CorruptData
        );
        assert_eq!(
            RefSnapshotReadLimits::new(0, 1, 1)
                .expect_err("zero byte limit")
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            GitRefState::new(
                BTreeMap::from([(
                    RefName::from_bytes(b"custom/main").expect("ref name"),
                    GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
                )]),
                HeadState::Detached(GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH])),
            )
            .expect_err("non-regular ref")
            .kind(),
            ErrorKind::InvalidInput
        );
    }

    #[test]
    fn ref_snapshot_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<GitRefState>();
        assert_send_sync::<HeadState>();
        assert_send_sync::<RefSnapshot>();
        assert_send_sync::<RefSnapshotReadLimits>();
    }
}
