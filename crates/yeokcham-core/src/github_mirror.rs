use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    str::FromStr,
};

use sha2::{Digest, Sha256};

use crate::{
    CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, GitObjectId, RefName, RepositoryId,
    Result,
};

const MAGIC: [u8; 4] = *b"YKGM";
const FOOTER_MAGIC: [u8; 4] = *b"YKGE";
const VERSION: u16 = 1;
const MAXIMUM_ENCODED_BYTES: usize = 1024 * 1024;
const MAXIMUM_RULES: usize = 128;
const MAXIMUM_CHECKPOINTS: usize = 2_048;
const MAXIMUM_OWNER_BYTES: usize = 39;
const MAXIMUM_REPOSITORY_BYTES: usize = 100;
const MAXIMUM_REF_BYTES: usize = 255;

/// One GitHub `owner/repository` target without transport credentials.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct GithubRepository {
    owner: String,
    repository: String,
}

impl GithubRepository {
    /// Validates one GitHub owner and repository name for an HTTPS GitHub target.
    pub fn new(owner: impl Into<String>, repository: impl Into<String>) -> Result<Self> {
        let owner = owner.into();
        let repository = repository.into();
        if !is_valid_component(&owner, MAXIMUM_OWNER_BYTES)
            || !is_valid_component(&repository, MAXIMUM_REPOSITORY_BYTES)
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub repository target is invalid",
            ));
        }
        Ok(Self { owner, repository })
    }

    /// Returns the configured GitHub owner name.
    pub fn owner(&self) -> &str {
        &self.owner
    }

    /// Returns the configured GitHub repository name.
    pub fn repository(&self) -> &str {
        &self.repository
    }
}

impl FromStr for GithubRepository {
    type Err = Error;

    /// Parses exactly one `owner/repository` target.
    fn from_str(value: &str) -> Result<Self> {
        let Some((owner, repository)) = value.split_once('/') else {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub repository target is invalid",
            ));
        };
        if repository.contains('/') {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub repository target is invalid",
            ));
        }
        Self::new(owner, repository)
    }
}

impl fmt::Debug for GithubRepository {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GithubRepository(<redacted>)")
    }
}

/// The permitted automatic direction for one GitHub mirror.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum GithubMirrorDirection {
    /// Publish selected Yeokcham refs to GitHub only.
    PublishOnly,
    /// Ingest selected GitHub refs into Yeokcham only.
    PullOnly,
    /// Exchange only fast-forward-compatible selected refs in both directions.
    BidirectionalFastForward,
    /// Record configuration but require a future explicit manual action for every change.
    Manual,
}

impl GithubMirrorDirection {
    /// Returns the stable configuration spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PublishOnly => "publish-only",
            Self::PullOnly => "pull-only",
            Self::BidirectionalFastForward => "bidirectional-fast-forward",
            Self::Manual => "manual",
        }
    }

    const fn binary_tag(self) -> u8 {
        match self {
            Self::PublishOnly => 1,
            Self::PullOnly => 2,
            Self::BidirectionalFastForward => 3,
            Self::Manual => 4,
        }
    }

    fn from_binary_tag(tag: u8) -> Result<Self> {
        match tag {
            1 => Ok(Self::PublishOnly),
            2 => Ok(Self::PullOnly),
            3 => Ok(Self::BidirectionalFastForward),
            4 => Ok(Self::Manual),
            _ => Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has an invalid direction",
            )),
        }
    }
}

impl FromStr for GithubMirrorDirection {
    type Err = Error;

    /// Parses one stable mirror-direction spelling.
    fn from_str(value: &str) -> Result<Self> {
        match value {
            "publish-only" => Ok(Self::PublishOnly),
            "pull-only" => Ok(Self::PullOnly),
            "bidirectional-fast-forward" => Ok(Self::BidirectionalFastForward),
            "manual" => Ok(Self::Manual),
            _ => Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub mirror direction is invalid",
            )),
        }
    }
}

/// The non-fast-forward policy for a configured GitHub mirror.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum GithubForceUpdatePolicy {
    /// Reject every non-fast-forward update.
    Reject,
    /// Permit a future update only when its remote checkpoint still matches exactly.
    RequireExactCheckpoint,
}

impl GithubForceUpdatePolicy {
    /// Returns the stable configuration spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Reject => "reject",
            Self::RequireExactCheckpoint => "require-exact-checkpoint",
        }
    }

    const fn binary_tag(self) -> u8 {
        match self {
            Self::Reject => 1,
            Self::RequireExactCheckpoint => 2,
        }
    }

    fn from_binary_tag(tag: u8) -> Result<Self> {
        match tag {
            1 => Ok(Self::Reject),
            2 => Ok(Self::RequireExactCheckpoint),
            _ => Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has an invalid force-update policy",
            )),
        }
    }
}

impl FromStr for GithubForceUpdatePolicy {
    type Err = Error;

    /// Parses one stable force-update policy spelling.
    fn from_str(value: &str) -> Result<Self> {
        match value {
            "reject" => Ok(Self::Reject),
            "require-exact-checkpoint" => Ok(Self::RequireExactCheckpoint),
            _ => Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub mirror force-update policy is invalid",
            )),
        }
    }
}

/// One selected standard GitHub reference namespace or exact reference.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum GithubPublicationRule {
    /// Select every `refs/heads/*` branch.
    Heads,
    /// Select every `refs/tags/*` tag.
    Tags,
    /// Select one exact standard branch or tag reference.
    Exact(RefName),
}

impl GithubPublicationRule {
    /// Reports whether this rule selects one reference.
    pub fn matches(&self, reference: &RefName) -> bool {
        match self {
            Self::Heads => reference.as_bytes().starts_with(b"refs/heads/"),
            Self::Tags => reference.as_bytes().starts_with(b"refs/tags/"),
            Self::Exact(expected) => expected == reference,
        }
    }

    fn validate(&self, kind: ErrorKind) -> Result<()> {
        let Self::Exact(reference) = self else {
            return Ok(());
        };
        let bytes = reference.as_bytes();
        if bytes.len() > MAXIMUM_REF_BYTES || !bytes.is_ascii() || !is_standard_reference(bytes) {
            return Err(Error::new(kind, "GitHub publication rule is invalid"));
        }
        Ok(())
    }

    fn binary_tag(&self) -> u8 {
        match self {
            Self::Heads => 1,
            Self::Tags => 2,
            Self::Exact(_) => 3,
        }
    }
}

impl FromStr for GithubPublicationRule {
    type Err = Error;

    /// Parses `heads`, `tags`, or one exact `refs/heads/*` or `refs/tags/*` name.
    fn from_str(value: &str) -> Result<Self> {
        let rule = match value {
            "heads" => Self::Heads,
            "tags" => Self::Tags,
            _ => Self::Exact(value.parse()?),
        };
        rule.validate(ErrorKind::InvalidInput)?;
        Ok(rule)
    }
}

impl fmt::Debug for GithubPublicationRule {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GithubPublicationRule(<redacted>)")
    }
}

/// The last confirmed local and GitHub object IDs for one selected reference.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct GithubMirrorCheckpoint {
    local_object_id: GitObjectId,
    remote_reference: RefName,
    remote_object_id: GitObjectId,
    observed_at_unix_seconds: u64,
}

impl GithubMirrorCheckpoint {
    /// Creates one confirmed checkpoint supplied by a future GitHub transport operation.
    pub const fn new(
        local_object_id: GitObjectId,
        remote_reference: RefName,
        remote_object_id: GitObjectId,
        observed_at_unix_seconds: u64,
    ) -> Self {
        Self {
            local_object_id,
            remote_reference,
            remote_object_id,
            observed_at_unix_seconds,
        }
    }

    /// Returns the locally observed Git object ID.
    pub const fn local_object_id(&self) -> GitObjectId {
        self.local_object_id
    }

    /// Returns the GitHub-observed Git object ID.
    pub const fn remote_object_id(&self) -> GitObjectId {
        self.remote_object_id
    }

    /// Returns the GitHub reference confirmed by the transport operation.
    pub const fn remote_reference(&self) -> &RefName {
        &self.remote_reference
    }

    /// Returns the caller-recorded Unix timestamp of the confirmed observation.
    pub const fn observed_at_unix_seconds(&self) -> u64 {
        self.observed_at_unix_seconds
    }
}

impl fmt::Debug for GithubMirrorCheckpoint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GithubMirrorCheckpoint(<redacted>)")
    }
}

/// Versioned, token-free GitHub mirror policy and persisted checkpoints.
#[derive(Clone, Eq, PartialEq)]
pub struct GithubMirrorConfiguration {
    repository_id: RepositoryId,
    target: GithubRepository,
    direction: GithubMirrorDirection,
    force_update_policy: GithubForceUpdatePolicy,
    publication_rules: BTreeSet<GithubPublicationRule>,
    checkpoints: BTreeMap<RefName, GithubMirrorCheckpoint>,
}

impl GithubMirrorConfiguration {
    /// Creates a checked GitHub mirror policy without any checkpoints.
    pub fn new(
        repository_id: RepositoryId,
        target: GithubRepository,
        direction: GithubMirrorDirection,
        force_update_policy: GithubForceUpdatePolicy,
        publication_rules: impl IntoIterator<Item = GithubPublicationRule>,
    ) -> Result<Self> {
        let publication_rules = publication_rules.into_iter().collect();
        let configuration = Self {
            repository_id,
            target,
            direction,
            force_update_policy,
            publication_rules,
            checkpoints: BTreeMap::new(),
        };
        configuration.validate(ErrorKind::InvalidInput)?;
        Ok(configuration)
    }

    /// Returns the repository identity bound to this policy.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the configured GitHub target.
    pub const fn target(&self) -> &GithubRepository {
        &self.target
    }

    /// Returns the configured automatic mirror direction.
    pub const fn direction(&self) -> GithubMirrorDirection {
        self.direction
    }

    /// Returns the configured force-update policy.
    pub const fn force_update_policy(&self) -> GithubForceUpdatePolicy {
        self.force_update_policy
    }

    /// Returns the selected standard Git reference rules.
    pub const fn publication_rules(&self) -> &BTreeSet<GithubPublicationRule> {
        &self.publication_rules
    }

    /// Returns every persisted checkpoint by exact reference name.
    pub const fn checkpoints(&self) -> &BTreeMap<RefName, GithubMirrorCheckpoint> {
        &self.checkpoints
    }

    /// Reports whether a reference is selected for publication and future mirror work.
    pub fn selects_reference(&self, reference: &RefName) -> bool {
        self.publication_rules
            .iter()
            .any(|rule| rule.matches(reference))
    }

    /// Replaces one selected reference checkpoint after a confirmed transport operation.
    pub fn record_checkpoint(
        &mut self,
        reference: RefName,
        checkpoint: GithubMirrorCheckpoint,
    ) -> Result<()> {
        if !self.selects_reference(&reference) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub mirror checkpoint reference is not selected",
            ));
        }
        if !is_standard_reference(checkpoint.remote_reference.as_bytes()) {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "GitHub mirror checkpoint remote reference is invalid",
            ));
        }
        if !self.checkpoints.contains_key(&reference)
            && self.checkpoints.len() >= MAXIMUM_CHECKPOINTS
        {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub mirror checkpoint limit is exceeded",
            ));
        }
        self.checkpoints.insert(reference, checkpoint);
        Ok(())
    }

    /// Encodes this configuration as one canonical `YKGM` version-1 record.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&MAGIC);
        encoder.write_u16(VERSION);
        encoder.write_u64(0);
        encoder.write_u64(0);
        encoder.write_fixed(self.repository_id.as_bytes());
        encoder.write_byte_string(self.target.owner().as_bytes());
        encoder.write_byte_string(self.target.repository().as_bytes());
        encoder.write_u8(self.direction.binary_tag());
        encoder.write_u8(self.force_update_policy.binary_tag());
        encoder.write_u32(self.publication_rules.len() as u32);
        for rule in &self.publication_rules {
            encoder.write_u8(rule.binary_tag());
            if let GithubPublicationRule::Exact(reference) = rule {
                encoder.write_byte_string(reference.as_bytes());
            }
        }
        encoder.write_u32(self.checkpoints.len() as u32);
        for (reference, checkpoint) in &self.checkpoints {
            encoder.write_byte_string(reference.as_bytes());
            encoder.write_fixed(checkpoint.local_object_id.as_bytes());
            encoder.write_byte_string(checkpoint.remote_reference.as_bytes());
            encoder.write_fixed(checkpoint.remote_object_id.as_bytes());
            encoder.write_u64(checkpoint.observed_at_unix_seconds);
        }
        encoder.write_fixed(&FOOTER_MAGIC);
        let checksum: [u8; 32] = Sha256::digest(encoder.as_bytes()).into();
        encoder.write_fixed(&checksum);
        encoder.into_bytes()
    }

    /// Decodes and validates one bounded canonical `YKGM` version-1 record.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAXIMUM_ENCODED_BYTES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub mirror configuration exceeds the byte limit",
            ));
        }
        let checksum_offset = bytes.len().checked_sub(32).ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration checksum is truncated",
            )
        })?;
        let checksum: [u8; 32] = bytes[checksum_offset..].try_into().map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration checksum is truncated",
            )
        })?;
        let actual_checksum: [u8; 32] = Sha256::digest(&bytes[..checksum_offset]).into();
        if checksum != actual_checksum {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration checksum does not match its bytes",
            ));
        }
        let mut decoder = CanonicalDecoder::new(&bytes[..checksum_offset]);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has invalid magic",
            ));
        }
        if decoder.read_u16()? != VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub mirror configuration version is unsupported",
            ));
        }
        if decoder.read_u64()? != 0 || decoder.read_u64()? != 0 {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "GitHub mirror configuration uses unsupported features",
            ));
        }
        let repository_id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has an invalid repository ID",
            )
        })?;
        let owner = decode_utf8_string(&mut decoder, MAXIMUM_OWNER_BYTES)?;
        let repository = decode_utf8_string(&mut decoder, MAXIMUM_REPOSITORY_BYTES)?;
        let target = GithubRepository::new(owner, repository).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has an invalid target",
            )
        })?;
        let direction = GithubMirrorDirection::from_binary_tag(decoder.read_u8()?)?;
        let force_update_policy = GithubForceUpdatePolicy::from_binary_tag(decoder.read_u8()?)?;
        let rule_count = decode_count(
            &mut decoder,
            MAXIMUM_RULES,
            "GitHub mirror rule limit is exceeded",
        )?;
        let mut publication_rules = BTreeSet::new();
        for _ in 0..rule_count {
            let rule = match decoder.read_u8()? {
                1 => GithubPublicationRule::Heads,
                2 => GithubPublicationRule::Tags,
                3 => GithubPublicationRule::Exact(decode_ref_name(&mut decoder)?),
                _ => {
                    return Err(Error::new(
                        ErrorKind::CorruptData,
                        "GitHub mirror configuration has an invalid publication rule",
                    ));
                }
            };
            rule.validate(ErrorKind::CorruptData)?;
            if !publication_rules.insert(rule) {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "GitHub mirror configuration has duplicate publication rules",
                ));
            }
        }
        let checkpoint_count = decode_count(
            &mut decoder,
            MAXIMUM_CHECKPOINTS,
            "GitHub mirror checkpoint limit is exceeded",
        )?;
        let mut checkpoints = BTreeMap::new();
        for _ in 0..checkpoint_count {
            let reference = decode_ref_name(&mut decoder)?;
            let checkpoint = GithubMirrorCheckpoint::new(
                GitObjectId::from_bytes(decoder.read_fixed()?),
                decode_ref_name(&mut decoder)?,
                GitObjectId::from_bytes(decoder.read_fixed()?),
                decoder.read_u64()?,
            );
            if checkpoints.insert(reference, checkpoint).is_some() {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "GitHub mirror configuration has duplicate checkpoints",
                ));
            }
        }
        if decoder.read_fixed::<4>()? != FOOTER_MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "GitHub mirror configuration has invalid footer magic",
            ));
        }
        decoder.finish()?;
        let configuration = Self {
            repository_id,
            target,
            direction,
            force_update_policy,
            publication_rules,
            checkpoints,
        };
        configuration.validate(ErrorKind::CorruptData)?;
        Ok(configuration)
    }

    fn validate(&self, kind: ErrorKind) -> Result<()> {
        if self.publication_rules.is_empty() || self.publication_rules.len() > MAXIMUM_RULES {
            return Err(Error::new(
                kind,
                "GitHub mirror publication rules are invalid",
            ));
        }
        if self.checkpoints.len() > MAXIMUM_CHECKPOINTS {
            return Err(Error::new(
                kind,
                "GitHub mirror checkpoint limit is exceeded",
            ));
        }
        for rule in &self.publication_rules {
            rule.validate(kind)?;
        }
        for (reference, checkpoint) in &self.checkpoints {
            if !self.selects_reference(reference) {
                return Err(Error::new(
                    kind,
                    "GitHub mirror checkpoint reference is not selected",
                ));
            }
            if !is_standard_reference(checkpoint.remote_reference.as_bytes()) {
                return Err(Error::new(
                    kind,
                    "GitHub mirror checkpoint remote reference is invalid",
                ));
            }
        }
        Ok(())
    }
}

impl fmt::Debug for GithubMirrorConfiguration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GithubMirrorConfiguration(<redacted>)")
    }
}

fn is_valid_component(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && value != "."
        && value != ".."
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn is_standard_reference(bytes: &[u8]) -> bool {
    bytes.starts_with(b"refs/heads/") || bytes.starts_with(b"refs/tags/")
}

fn decode_utf8_string(decoder: &mut CanonicalDecoder<'_>, maximum_bytes: usize) -> Result<String> {
    let bytes = decoder.read_byte_string()?;
    if bytes.len() > maximum_bytes {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "GitHub mirror configuration string exceeds the byte limit",
        ));
    }
    String::from_utf8(bytes.to_vec()).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "GitHub mirror configuration string is invalid",
        )
    })
}

fn decode_count(
    decoder: &mut CanonicalDecoder<'_>,
    maximum: usize,
    message: &'static str,
) -> Result<usize> {
    let count = usize::try_from(decoder.read_u32()?)
        .map_err(|_| Error::new(ErrorKind::CorruptData, message))?;
    if count > maximum {
        return Err(Error::new(ErrorKind::Unsupported, message));
    }
    Ok(count)
}

fn decode_ref_name(decoder: &mut CanonicalDecoder<'_>) -> Result<RefName> {
    let bytes = decoder.read_byte_string()?;
    if bytes.len() > MAXIMUM_REF_BYTES || !bytes.is_ascii() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "GitHub mirror configuration has an invalid reference",
        ));
    }
    RefName::from_bytes(bytes).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "GitHub mirror configuration has an invalid reference",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repository_id() -> RepositoryId {
        "67e55044-10b1-426f-9247-bb680e5fe0c8"
            .parse()
            .expect("repository ID")
    }

    fn object_id(value: u8) -> GitObjectId {
        GitObjectId::from_bytes([value; GitObjectId::BYTE_LENGTH])
    }

    fn configuration() -> GithubMirrorConfiguration {
        GithubMirrorConfiguration::new(
            repository_id(),
            "yeokcham/example".parse().expect("target"),
            GithubMirrorDirection::BidirectionalFastForward,
            GithubForceUpdatePolicy::Reject,
            [
                GithubPublicationRule::Heads,
                "refs/tags/v1.0".parse().expect("tag rule"),
            ],
        )
        .expect("configuration")
    }

    #[test]
    fn round_trips_a_bound_checkpointed_configuration() {
        let mut configuration = configuration();
        let reference: RefName = "refs/heads/main".parse().expect("reference");
        let checkpoint = GithubMirrorCheckpoint::new(
            object_id(1),
            "refs/heads/mirror-main".parse().expect("remote reference"),
            object_id(2),
            1_720_000_000,
        );
        configuration
            .record_checkpoint(reference.clone(), checkpoint.clone())
            .expect("checkpoint");
        let decoded = GithubMirrorConfiguration::decode(&configuration.encode()).expect("decode");

        assert_eq!(decoded, configuration);
        assert!(decoded.selects_reference(&reference));
        assert!(decoded.selects_reference(&"refs/tags/v1.0".parse().expect("tag")));
        assert!(!decoded.selects_reference(&"refs/notes/private".parse().expect("note")));
        assert_eq!(decoded.checkpoints().get(&reference), Some(&checkpoint));
        assert!(!format!("{decoded:?}").contains("yeokcham/example"));
    }

    #[test]
    fn rejects_invalid_targets_rules_and_unselected_checkpoints() {
        assert!(
            "owner/repository/extra"
                .parse::<GithubRepository>()
                .is_err()
        );
        assert!(GithubRepository::new("owner", "private repo").is_err());
        assert!(
            "refs/notes/private"
                .parse::<GithubPublicationRule>()
                .is_err()
        );
        assert!(
            GithubMirrorConfiguration::new(
                repository_id(),
                "yeokcham/example".parse().expect("target"),
                GithubMirrorDirection::PublishOnly,
                GithubForceUpdatePolicy::Reject,
                [],
            )
            .is_err()
        );
        let mut configuration = configuration();
        let error = configuration
            .record_checkpoint(
                "refs/notes/private".parse().expect("note"),
                GithubMirrorCheckpoint::new(
                    object_id(1),
                    "refs/heads/main".parse().expect("remote reference"),
                    object_id(2),
                    0,
                ),
            )
            .expect_err("unselected checkpoint");
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        let error = configuration
            .record_checkpoint(
                "refs/heads/main".parse().expect("branch"),
                GithubMirrorCheckpoint::new(
                    object_id(1),
                    "refs/notes/private".parse().expect("remote note"),
                    object_id(2),
                    0,
                ),
            )
            .expect_err("invalid remote reference");
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn rejects_corrupt_encodings_without_disclosing_configuration() {
        let mut encoded = configuration().encode();
        encoded[20] ^= 1;
        let error = GithubMirrorConfiguration::decode(&encoded).expect_err("checksum");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains("yeokcham/example"));

        let error = GithubMirrorConfiguration::decode(&vec![0; MAXIMUM_ENCODED_BYTES + 1])
            .expect_err("oversized");
        assert_eq!(error.kind(), ErrorKind::Unsupported);
    }
}
