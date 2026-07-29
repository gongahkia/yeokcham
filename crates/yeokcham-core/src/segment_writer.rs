use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};

use crate::{
    CompressionAlgorithm, Error, ErrorKind, RepositoryId, Result, SegmentId, TinyBlobAggregation,
    WholeBlobRecord, YeokchamContentId,
};

const MAGIC: [u8; 4] = *b"YKSG";
const FOOTER_MAGIC: [u8; 4] = *b"YKSF";
const VERSION: u16 = 1;

/// Typed payload family accepted by segment version 1.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[non_exhaustive]
pub enum SegmentRecordKind {
    /// One [`WholeBlobRecord`] encoding.
    WholeBlob,
    /// One [`TinyBlobAggregation`] encoding.
    TinyBlobAggregation,
}

impl SegmentRecordKind {
    const fn binary_tag(self) -> u8 {
        match self {
            Self::WholeBlob => 1,
            Self::TinyBlobAggregation => 2,
        }
    }
}

/// One verified version-1 record ready for immutable segment storage.
///
/// Constructors accept only existing verified Yeokcham record types. Stored
/// payload bytes and content identity are therefore bound before this wrapper
/// is created.
#[derive(Eq, PartialEq)]
pub struct SegmentRecord {
    kind: SegmentRecordKind,
    content_id: YeokchamContentId,
    stored_len: u64,
    payload: Vec<u8>,
}

impl SegmentRecord {
    /// Wraps a verified whole-blob record for segment storage.
    pub fn from_whole_blob(record: &WholeBlobRecord) -> Result<Self> {
        Self::new(
            SegmentRecordKind::WholeBlob,
            record.content_id(),
            record.encode(),
        )
    }

    /// Wraps a verified tiny-blob aggregation for segment storage.
    pub fn from_tiny_blob_aggregation(record: &TinyBlobAggregation) -> Result<Self> {
        Self::new(
            SegmentRecordKind::TinyBlobAggregation,
            record.content_id(),
            record.encode(),
        )
    }

    /// Returns the payload family encoded by this record.
    pub const fn kind(&self) -> SegmentRecordKind {
        self.kind
    }

    /// Returns the verified plaintext content identity for this record.
    pub const fn content_id(&self) -> YeokchamContentId {
        self.content_id
    }

    /// Returns the stored payload length for the current uncompressed codec.
    pub const fn stored_len(&self) -> u64 {
        self.stored_len
    }

    fn new(
        kind: SegmentRecordKind,
        content_id: YeokchamContentId,
        payload: Vec<u8>,
    ) -> Result<Self> {
        let stored_len = u64::try_from(payload.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "segment record payload is too large",
            )
        })?;
        Ok(Self {
            kind,
            content_id,
            stored_len,
            payload,
        })
    }
}

impl fmt::Debug for SegmentRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SegmentRecord")
            .field("kind", &self.kind)
            .field("content_id", &self.content_id)
            .field("stored_len", &self.payload.len())
            .field("payload", &"<redacted>")
            .finish()
    }
}

/// Explicit resource limits for one [`SegmentWriter`].
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SegmentWriteLimits {
    maximum_records: usize,
    maximum_stored_bytes: u64,
}

impl SegmentWriteLimits {
    /// Validates caller-selected bounds for one segment writer.
    pub fn new(maximum_records: usize, maximum_stored_bytes: u64) -> Result<Self> {
        if maximum_records == 0 || u32::try_from(maximum_records).is_err() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment record limit is invalid",
            ));
        }
        if maximum_stored_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment stored-byte limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_records,
            maximum_stored_bytes,
        })
    }

    /// Returns the maximum record count accepted by this writer.
    pub const fn maximum_records(self) -> usize {
        self.maximum_records
    }

    /// Returns the maximum aggregate stored-payload bytes accepted by this writer.
    pub const fn maximum_stored_bytes(self) -> u64 {
        self.maximum_stored_bytes
    }
}

/// Immutable metadata returned after a segment is sealed to a final path.
#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub struct SealedSegment {
    segment_id: SegmentId,
    record_count: u32,
    total_plaintext_bytes: u64,
    total_stored_bytes: u64,
    checksum: [u8; 32],
}

impl SealedSegment {
    /// Returns the preallocated identity written to this segment header.
    pub const fn segment_id(self) -> SegmentId {
        self.segment_id
    }

    /// Returns the number of records written to this segment.
    pub const fn record_count(self) -> u32 {
        self.record_count
    }

    /// Returns the aggregate uncompressed payload length.
    pub const fn total_plaintext_bytes(self) -> u64 {
        self.total_plaintext_bytes
    }

    /// Returns the aggregate stored payload length.
    pub const fn total_stored_bytes(self) -> u64 {
        self.total_stored_bytes
    }

    /// Returns the SHA-256 integrity checksum over the segment prefix.
    pub const fn checksum(self) -> [u8; 32] {
        self.checksum
    }
}

impl fmt::Debug for SealedSegment {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SealedSegment")
            .field("segment_id", &self.segment_id)
            .field("record_count", &self.record_count)
            .field("total_plaintext_bytes", &self.total_plaintext_bytes)
            .field("total_stored_bytes", &self.total_stored_bytes)
            .field("checksum", &"<redacted>")
            .finish()
    }
}

/// Stages a bounded collection of verified records for immutable publication.
pub struct SegmentWriter {
    repository_id: RepositoryId,
    segment_id: SegmentId,
    limits: SegmentWriteLimits,
    records: Vec<SegmentRecord>,
    total_stored_bytes: u64,
}

impl SegmentWriter {
    /// Creates an empty segment writer bound to one repository and segment identity.
    pub fn new(
        repository_id: RepositoryId,
        segment_id: SegmentId,
        limits: SegmentWriteLimits,
    ) -> Self {
        Self {
            repository_id,
            segment_id,
            limits,
            records: Vec::new(),
            total_stored_bytes: 0,
        }
    }

    /// Returns the repository identity that will be written into the segment header.
    pub const fn repository_id(&self) -> RepositoryId {
        self.repository_id
    }

    /// Returns the segment identity that will be written into the segment header.
    pub const fn segment_id(&self) -> SegmentId {
        self.segment_id
    }

    /// Returns the immutable resource limits for this writer.
    pub const fn limits(&self) -> SegmentWriteLimits {
        self.limits
    }

    /// Returns the number of accepted records that are not yet sealed.
    pub fn record_count(&self) -> usize {
        self.records.len()
    }

    /// Adds one verified record while enforcing duplicate and resource bounds.
    pub fn add(&mut self, record: SegmentRecord) -> Result<()> {
        if self.records.len() == self.limits.maximum_records {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment exceeds the record limit",
            ));
        }
        if self
            .records
            .iter()
            .any(|existing| existing.content_id == record.content_id)
        {
            return Err(Error::new(
                ErrorKind::Conflict,
                "segment already contains the content identity",
            ));
        }
        let total_stored_bytes = self
            .total_stored_bytes
            .checked_add(record.stored_len())
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "segment exceeds the stored-byte limit",
                )
            })?;
        if total_stored_bytes > self.limits.maximum_stored_bytes {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "segment exceeds the stored-byte limit",
            ));
        }
        self.total_stored_bytes = total_stored_bytes;
        self.records.push(record);
        Ok(())
    }

    /// Seals this writer to an absent final path without replacing an existing entry.
    ///
    /// The final path is created by a same-directory hard link only after the
    /// fully written staging file has been synchronized. On Unix, the parent
    /// directory is also synchronized after publication. The destination's
    /// parent must already be a non-symlink directory.
    pub fn seal_to(self, destination: impl AsRef<Path>) -> Result<SealedSegment> {
        if self.records.is_empty() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment requires at least one record",
            ));
        }
        let destination = destination.as_ref();
        let parent = destination.parent().unwrap_or_else(|| Path::new("."));
        validate_destination_parent(parent)?;
        if destination.file_name().is_none() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment destination must name a file",
            ));
        }

        let (mut staging_file, staging_path) = create_staging_file(parent)?;
        let checksum = match self.write_staging_file(&mut staging_file) {
            Ok(checksum) => checksum,
            Err(error) => {
                drop(staging_file);
                let _ = fs::remove_file(&staging_path);
                return Err(error);
            }
        };
        if let Err(error) = staging_file.sync_all() {
            drop(staging_file);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "segment staging file could not be synchronized",
            ));
        }
        drop(staging_file);
        if let Err(error) = fs::hard_link(&staging_path, destination) {
            let _ = fs::remove_file(&staging_path);
            return Err(if error.kind() == io::ErrorKind::AlreadyExists {
                Error::new(ErrorKind::Conflict, "sealed segment already exists")
            } else {
                io_error(error, "sealed segment could not be published")
            });
        }
        sync_directory(parent)?;
        let _ = fs::remove_file(&staging_path);
        let _ = sync_directory(parent);

        Ok(SealedSegment {
            segment_id: self.segment_id,
            record_count: u32::try_from(self.records.len()).expect("validated record limit"),
            total_plaintext_bytes: self.total_stored_bytes,
            total_stored_bytes: self.total_stored_bytes,
            checksum,
        })
    }

    fn write_staging_file(&self, file: &mut File) -> Result<[u8; 32]> {
        let mut checksum = Sha256::new();
        write_and_hash(file, &mut checksum, &MAGIC)?;
        write_and_hash(file, &mut checksum, &VERSION.to_be_bytes())?;
        write_and_hash(file, &mut checksum, &0u64.to_be_bytes())?;
        write_and_hash(file, &mut checksum, &0u64.to_be_bytes())?;
        write_and_hash(file, &mut checksum, self.repository_id.as_bytes())?;
        write_and_hash(file, &mut checksum, self.segment_id.as_bytes())?;
        write_and_hash(
            file,
            &mut checksum,
            &u32::try_from(self.records.len())
                .expect("validated record limit")
                .to_be_bytes(),
        )?;
        for record in &self.records {
            write_and_hash(file, &mut checksum, &[record.kind.binary_tag()])?;
            write_and_hash(
                file,
                &mut checksum,
                &[record.content_id.algorithm().binary_tag()],
            )?;
            write_and_hash(file, &mut checksum, record.content_id.digest())?;
            write_and_hash(
                file,
                &mut checksum,
                &[CompressionAlgorithm::None.binary_tag()],
            )?;
            write_and_hash(file, &mut checksum, &record.stored_len().to_be_bytes())?;
            write_and_hash(file, &mut checksum, &record.stored_len().to_be_bytes())?;
            write_and_hash(file, &mut checksum, &record.payload)?;
        }
        write_and_hash(file, &mut checksum, &FOOTER_MAGIC)?;
        write_and_hash(file, &mut checksum, &self.total_stored_bytes.to_be_bytes())?;
        write_and_hash(file, &mut checksum, &self.total_stored_bytes.to_be_bytes())?;
        let checksum: [u8; 32] = checksum.finalize().into();
        file.write_all(&checksum)
            .map_err(|error| io_error(error, "segment staging file could not be written"))?;
        Ok(checksum)
    }
}

impl fmt::Debug for SegmentWriter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SegmentWriter")
            .field("repository_id", &self.repository_id)
            .field("segment_id", &self.segment_id)
            .field("limits", &self.limits)
            .field("record_count", &self.records.len())
            .field("total_stored_bytes", &self.total_stored_bytes)
            .field("records", &"<redacted>")
            .finish()
    }
}

fn write_and_hash(file: &mut File, checksum: &mut Sha256, bytes: &[u8]) -> Result<()> {
    file.write_all(bytes)
        .map_err(|error| io_error(error, "segment staging file could not be written"))?;
    checksum.update(bytes);
    Ok(())
}

fn validate_destination_parent(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(
                ErrorKind::NotFound,
                "segment destination directory does not exist",
            )
        } else {
            io_error(
                error,
                "segment destination directory could not be inspected",
            )
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "segment destination parent is not a directory",
        ));
    }
    Ok(())
}

fn create_staging_file(parent: &Path) -> Result<(File, PathBuf)> {
    for _ in 0..16 {
        let path = parent.join(format!(".yeokcham-{}.partial", SegmentId::generate()));
        match OpenOptions::new().create_new(true).write(true).open(&path) {
            Ok(file) => return Ok((file, path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(error, "segment staging file could not be created"));
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "segment staging path could not be allocated",
    ))
}

fn io_error(error: io::Error, message: &'static str) -> Error {
    Error::with_source(ErrorKind::Io, message, error)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .map_err(|error| io_error(error, "segment directory could not be synchronized"))?
        .sync_all()
        .map_err(|error| io_error(error, "segment directory could not be synchronized"))
}

#[cfg(not(unix))]
fn sync_directory(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use uuid::Uuid;

    use super::*;
    use crate::{GitObject, GitObjectId, GitObjectKind};

    const REPOSITORY_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const SEGMENT_ID: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    const EMPTY_BLOB_ID: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const CANONICAL_SEGMENT_HEX: &str = concat!(
        "594b5347",
        "0001",
        "0000000000000000",
        "0000000000000000",
        "550e8400e29b41d4a716446655440000",
        "6ba7b8149dad41d180b400c04fd430c8",
        "00000001",
        "01",
        "03",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "00",
        "0000000000000055",
        "0000000000000055",
        "594b5742",
        "0001",
        "0000000000000000",
        "0000000000000000",
        "01",
        "00",
        "03",
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "0000000000000000",
        "594b5346",
        "0000000000000055",
        "0000000000000055",
        "97160ea32704d51e1dfef8f72545deb44255c4d900aa4c9962f71757280fa98c"
    );

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-segment-{}", Uuid::new_v4()));
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

    fn repository_id() -> RepositoryId {
        REPOSITORY_ID.parse().expect("repository ID")
    }

    fn segment_id() -> SegmentId {
        SEGMENT_ID.parse().expect("segment ID")
    }

    fn limits(maximum_records: usize, maximum_stored_bytes: u64) -> SegmentWriteLimits {
        SegmentWriteLimits::new(maximum_records, maximum_stored_bytes).expect("valid limits")
    }

    fn empty_whole_blob() -> WholeBlobRecord {
        let object = GitObject::new(
            EMPTY_BLOB_ID.parse::<GitObjectId>().expect("empty blob ID"),
            GitObjectKind::Blob,
            Vec::new(),
        );
        WholeBlobRecord::from_verified_blob(&object).expect("whole blob")
    }

    fn whole_blob_record() -> SegmentRecord {
        SegmentRecord::from_whole_blob(&empty_whole_blob()).expect("segment record")
    }

    fn writer(maximum_records: usize, maximum_stored_bytes: u64) -> SegmentWriter {
        SegmentWriter::new(
            repository_id(),
            segment_id(),
            limits(maximum_records, maximum_stored_bytes),
        )
    }

    #[test]
    fn seals_one_canonical_whole_blob_segment() {
        let directory = TestDirectory::new();
        let destination = directory.path().join("segment");
        let record = whole_blob_record();
        let mut writer = writer(1, record.stored_len());
        writer.add(record).expect("add record");
        let sealed = writer.seal_to(&destination).expect("seal segment");
        let bytes = fs::read(&destination).expect("read segment");

        assert_eq!(sealed.segment_id(), segment_id());
        assert_eq!(sealed.record_count(), 1);
        assert_eq!(sealed.total_plaintext_bytes(), 85);
        assert_eq!(sealed.total_stored_bytes(), 85);
        assert_eq!(hex::encode(bytes), CANONICAL_SEGMENT_HEX);
    }

    #[test]
    fn rejects_invalid_limits_empty_segments_duplicates_and_overflow() {
        for limits in [SegmentWriteLimits::new(0, 1), SegmentWriteLimits::new(1, 0)] {
            let error = limits.expect_err("invalid limits");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
        }

        let directory = TestDirectory::new();
        let empty = writer(1, 1)
            .seal_to(directory.path().join("empty"))
            .expect_err("empty segment must fail");
        assert_eq!(empty.kind(), ErrorKind::InvalidInput);

        let record = whole_blob_record();
        let mut duplicate_writer = writer(2, record.stored_len() * 2);
        duplicate_writer.add(record).expect("first record");
        let duplicate = duplicate_writer
            .add(whole_blob_record())
            .expect_err("duplicate content ID");
        assert_eq!(duplicate.kind(), ErrorKind::Conflict);

        let record = whole_blob_record();
        let mut limited_writer = writer(1, record.stored_len() - 1);
        let limited = limited_writer.add(record).expect_err("stored-byte limit");
        assert_eq!(limited.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn refuses_existing_destination_without_replacement_and_cleans_staging() {
        let directory = TestDirectory::new();
        let destination = directory.path().join("segment");
        let record = whole_blob_record();
        let mut first = writer(1, record.stored_len());
        first.add(record).expect("first record");
        first.seal_to(&destination).expect("first seal");
        let original = fs::read(&destination).expect("original segment");

        let record = whole_blob_record();
        let mut second = writer(1, record.stored_len());
        second.add(record).expect("second record");
        let error = second
            .seal_to(&destination)
            .expect_err("existing final path must fail");

        assert_eq!(error.kind(), ErrorKind::Conflict);
        assert_eq!(fs::read(&destination).expect("unchanged segment"), original);
        assert!(
            fs::read_dir(directory.path())
                .expect("read directory")
                .all(|entry| !entry
                    .expect("directory entry")
                    .file_name()
                    .to_string_lossy()
                    .contains(".partial"))
        );
    }

    #[test]
    fn rejects_missing_destination_directory_without_disclosing_payload() {
        let directory = TestDirectory::new();
        let record = whole_blob_record();
        let mut writer = writer(1, record.stored_len());
        writer.add(record).expect("record");
        let error = writer
            .seal_to(directory.path().join("missing").join("segment"))
            .expect_err("missing parent");

        assert_eq!(error.kind(), ErrorKind::NotFound);
        assert!(!error.to_string().contains("private"));
    }

    #[test]
    fn debug_output_redacts_payloads_and_segment_metadata() {
        let source = GitObject::new(
            GitObjectId::from_bytes([3; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Blob,
            b"private segment payload".to_vec(),
        );
        let provisional = GitObject::new(
            source.recompute_id(),
            GitObjectKind::Blob,
            source.data().to_vec(),
        );
        let record = SegmentRecord::from_whole_blob(
            &WholeBlobRecord::from_verified_blob(&provisional).expect("whole blob"),
        )
        .expect("segment record");
        let writer = writer(1, record.stored_len());

        assert!(!format!("{record:?}").contains("private segment payload"));
        assert!(!format!("{writer:?}").contains(REPOSITORY_ID));
        assert!(!format!("{writer:?}").contains(SEGMENT_ID));
    }

    #[test]
    fn segment_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<SegmentRecordKind>();
        assert_send_sync::<SegmentRecord>();
        assert_send_sync::<SegmentWriteLimits>();
        assert_send_sync::<SealedSegment>();
        assert_send_sync::<SegmentWriter>();
    }
}
