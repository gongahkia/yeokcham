use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

use rusqlite::{
    Connection, Error as SqliteError, ErrorCode as SqliteErrorCode, OpenFlags, OptionalExtension,
    TransactionBehavior, params,
};

use crate::{
    BlobManifest, BlobManifestRepresentation, CanonicalDecoder, CanonicalEncoder, Error, ErrorKind,
    GitObject, GitObjectId, GitObjectKind, ManifestId, MetadataObjectManifest,
    MetadataObjectRecord, ReadSegment, ReadSegmentRecord, RepositoryFormat, RepositoryId, Result,
    SegmentId, SegmentIndex, SegmentReadLimits, SegmentReader,
};

const BOOTSTRAP_MAGIC: [u8; 4] = *b"YKRB";
const BOOTSTRAP_MAX_BYTES: u64 = 4096;
const BOOTSTRAP_PATH: &str = "format/repository.bin";
const METADATA_PATH: &str = "metadata.sqlite3";
const METADATA_APPLICATION_ID: i32 = 0x594b_4d44; // YKMD
const METADATA_SCHEMA_VERSION: i32 = 1;
const BLOB_MANIFEST_DIRECTORY: &str = "manifests/blobs";
const BLOB_MANIFEST_EXTENSION: &str = ".ykmf";
const BLOB_MANIFEST_STAGING_SUFFIX: &str = ".partial";
const PUBLISHED_BLOB_MANIFEST_MAX_BYTES: u64 = 4096;
const METADATA_OBJECT_MANIFEST_DIRECTORY: &str = "manifests/objects";
const METADATA_OBJECT_MANIFEST_EXTENSION: &str = ".ykom";
const METADATA_OBJECT_MANIFEST_STAGING_SUFFIX: &str = ".partial";
const PUBLISHED_METADATA_OBJECT_MANIFEST_MAX_BYTES: u64 = 4096;
const SEGMENT_INDEX_EXTENSION: &str = ".ykix";
const SEGMENT_INDEX_STAGING_SUFFIX: &str = ".partial";
const LAYOUT_DIRECTORIES: &[&str] = &[
    "format",
    "segments",
    "indexes",
    "manifests",
    "manifests/blobs",
    "manifests/generations",
    "journals",
    "journals/refs",
    "summaries",
    "summaries/current",
];

/// Verified local metadata for one Git object.
///
/// This is rebuildable local coordination state. It contains no object body,
/// storage mapping, or canonical recovery data.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GitObjectMetadata {
    id: GitObjectId,
    kind: GitObjectKind,
    size: u64,
}

/// Caller-selected bounds for scanning local immutable blob manifests.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct BlobManifestReadLimits {
    maximum_entries: usize,
    maximum_manifest_bytes: u64,
    maximum_plaintext_bytes: u64,
}

impl BlobManifestReadLimits {
    /// Validates bounds for one manifest-directory resolution scan.
    pub fn new(
        maximum_entries: usize,
        maximum_manifest_bytes: u64,
        maximum_plaintext_bytes: u64,
    ) -> Result<Self> {
        if maximum_entries == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "blob manifest entry limit must not be zero",
            ));
        }
        if maximum_manifest_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "blob manifest byte limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_entries,
            maximum_manifest_bytes,
            maximum_plaintext_bytes,
        })
    }

    /// Returns the maximum directory entries inspected during one scan.
    pub const fn maximum_entries(self) -> usize {
        self.maximum_entries
    }

    /// Returns the maximum bytes accepted from one manifest file.
    pub const fn maximum_manifest_bytes(self) -> u64 {
        self.maximum_manifest_bytes
    }

    /// Returns the maximum blob body length accepted from one manifest.
    pub const fn maximum_plaintext_bytes(self) -> u64 {
        self.maximum_plaintext_bytes
    }
}

/// Caller-selected bounds for resolving one immutable metadata-object manifest.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct MetadataObjectManifestReadLimits {
    maximum_manifest_bytes: u64,
    maximum_plaintext_bytes: u64,
}

impl MetadataObjectManifestReadLimits {
    /// Validates bounds for one direct metadata-object manifest lookup.
    pub fn new(maximum_manifest_bytes: u64, maximum_plaintext_bytes: u64) -> Result<Self> {
        if maximum_manifest_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "metadata-object manifest byte limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_manifest_bytes,
            maximum_plaintext_bytes,
        })
    }

    /// Returns the maximum bytes accepted from one metadata-object manifest file.
    pub const fn maximum_manifest_bytes(self) -> u64 {
        self.maximum_manifest_bytes
    }

    /// Returns the maximum object-body length accepted from one manifest.
    pub const fn maximum_plaintext_bytes(self) -> u64 {
        self.maximum_plaintext_bytes
    }
}

/// Caller-selected bounds for complete immutable local-storage verification.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RepositoryVerificationLimits {
    maximum_segment_entries: usize,
    maximum_segment_bytes: u64,
    segment_read_limits: SegmentReadLimits,
    maximum_index_entries: usize,
    maximum_index_bytes: u64,
    maximum_index_records: usize,
    maximum_index_stored_bytes: u64,
    blob_manifest_limits: BlobManifestReadLimits,
    maximum_metadata_object_manifest_entries: usize,
    metadata_object_manifest_limits: MetadataObjectManifestReadLimits,
}

impl RepositoryVerificationLimits {
    /// Validates bounds for one full local immutable-storage scan.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        maximum_segment_entries: usize,
        maximum_segment_bytes: u64,
        segment_read_limits: SegmentReadLimits,
        maximum_index_entries: usize,
        maximum_index_bytes: u64,
        maximum_index_records: usize,
        maximum_index_stored_bytes: u64,
        blob_manifest_limits: BlobManifestReadLimits,
        maximum_metadata_object_manifest_entries: usize,
        metadata_object_manifest_limits: MetadataObjectManifestReadLimits,
    ) -> Result<Self> {
        if maximum_segment_entries == 0
            || maximum_segment_bytes == 0
            || maximum_index_entries == 0
            || maximum_index_bytes == 0
            || maximum_index_records == 0
            || maximum_index_stored_bytes == 0
            || maximum_metadata_object_manifest_entries == 0
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "repository verification limit must not be zero",
            ));
        }
        Ok(Self {
            maximum_segment_entries,
            maximum_segment_bytes,
            segment_read_limits,
            maximum_index_entries,
            maximum_index_bytes,
            maximum_index_records,
            maximum_index_stored_bytes,
            blob_manifest_limits,
            maximum_metadata_object_manifest_entries,
            metadata_object_manifest_limits,
        })
    }

    /// Returns the maximum entries inspected in `segments/`.
    pub const fn maximum_segment_entries(self) -> usize {
        self.maximum_segment_entries
    }

    /// Returns the maximum accepted bytes for one `YKSG` file.
    pub const fn maximum_segment_bytes(self) -> u64 {
        self.maximum_segment_bytes
    }

    /// Returns nested `YKSG` decoding bounds.
    pub const fn segment_read_limits(self) -> SegmentReadLimits {
        self.segment_read_limits
    }

    /// Returns the maximum entries inspected in `indexes/`.
    pub const fn maximum_index_entries(self) -> usize {
        self.maximum_index_entries
    }

    /// Returns the maximum accepted bytes for one `YKIX` file.
    pub const fn maximum_index_bytes(self) -> u64 {
        self.maximum_index_bytes
    }

    /// Returns the maximum records decoded from one `YKIX` file.
    pub const fn maximum_index_records(self) -> usize {
        self.maximum_index_records
    }

    /// Returns the maximum aggregate stored bytes declared by one `YKIX` file.
    pub const fn maximum_index_stored_bytes(self) -> u64 {
        self.maximum_index_stored_bytes
    }

    /// Returns `YKMF` directory and body bounds.
    pub const fn blob_manifest_limits(self) -> BlobManifestReadLimits {
        self.blob_manifest_limits
    }

    /// Returns the maximum entries inspected in `manifests/objects/`.
    pub const fn maximum_metadata_object_manifest_entries(self) -> usize {
        self.maximum_metadata_object_manifest_entries
    }

    /// Returns `YKOM` file and body bounds.
    pub const fn metadata_object_manifest_limits(self) -> MetadataObjectManifestReadLimits {
        self.metadata_object_manifest_limits
    }
}

/// Counts returned only after complete immutable-storage verification succeeds.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub struct RepositoryVerificationReport {
    segment_count: usize,
    index_count: usize,
    blob_manifest_count: usize,
    metadata_object_manifest_count: usize,
}

impl RepositoryVerificationReport {
    /// Returns verified sealed `YKSG` file count.
    pub const fn segment_count(self) -> usize {
        self.segment_count
    }

    /// Returns verified published `YKIX` file count.
    pub const fn index_count(self) -> usize {
        self.index_count
    }

    /// Returns verified published `YKMF` file count.
    pub const fn blob_manifest_count(self) -> usize {
        self.blob_manifest_count
    }

    /// Returns verified published `YKOM` file count.
    pub const fn metadata_object_manifest_count(self) -> usize {
        self.metadata_object_manifest_count
    }
}

impl GitObjectMetadata {
    /// Returns the verified Git object ID.
    pub const fn id(&self) -> GitObjectId {
        self.id
    }

    /// Returns the Git object type.
    pub const fn kind(&self) -> GitObjectKind {
        self.kind
    }

    /// Returns the exact decompressed object-body size.
    pub const fn size(&self) -> u64 {
        self.size
    }
}

/// An opened V1 repository rooted on the local filesystem.
///
/// Creation accepts a path that does not exist whose parent already exists.
/// Opening validates the fixed layout and bounded bootstrap record before
/// returning this value. The repository contains no Git data until Milestone 1.
pub struct LocalRepository {
    root: PathBuf,
    id: RepositoryId,
    format: RepositoryFormat,
}

impl LocalRepository {
    /// Creates an empty V1 repository with a fresh repository identity.
    pub fn create(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        match fs::symlink_metadata(root) {
            Ok(_) => {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "repository path already exists",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(io_error(
                    error,
                    "repository directory could not be inspected",
                ));
            }
        }

        fs::create_dir(root).map_err(create_root_error)?;
        for relative_path in LAYOUT_DIRECTORIES {
            fs::create_dir(root.join(relative_path))
                .map_err(|error| io_error(error, "repository layout could not be created"))?;
        }

        let id = RepositoryId::generate();
        let format = RepositoryFormat::initial();
        let bootstrap_path = root.join(BOOTSTRAP_PATH);
        let mut bootstrap = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&bootstrap_path)
            .map_err(|error| io_error(error, "repository bootstrap could not be created"))?;
        bootstrap
            .write_all(&encode_bootstrap(id, format))
            .map_err(|error| io_error(error, "repository bootstrap could not be written"))?;
        bootstrap
            .sync_all()
            .map_err(|error| io_error(error, "repository bootstrap could not be synchronized"))?;
        sync_directory(&root.join("format"))?;
        sync_directory(root)?;

        Self::open(root)
    }

    /// Opens an existing repository after validating its V1 bootstrap record.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        validate_directory(root, true)?;
        for relative_path in LAYOUT_DIRECTORIES {
            validate_directory(&root.join(relative_path), false)?;
        }
        validate_optional_directory(&root.join(METADATA_OBJECT_MANIFEST_DIRECTORY))?;

        let (id, format) = read_bootstrap(root)?;
        Ok(Self {
            root: root.to_path_buf(),
            id,
            format,
        })
    }

    /// Opens and validates a repository at the current supported format.
    ///
    /// V1 is the first persisted format, so migration currently performs no
    /// write. Future migrations must be copy-on-write and leave the prior
    /// bootstrap readable until finalization.
    pub fn migrate(root: impl AsRef<Path>) -> Result<Self> {
        Self::open(root)
    }

    /// Returns the repository root path.
    pub fn path(&self) -> &Path {
        &self.root
    }

    /// Returns the validated opaque repository identity.
    pub const fn id(&self) -> RepositoryId {
        self.id
    }

    /// Returns the validated persistent format declaration.
    pub const fn format(&self) -> RepositoryFormat {
        self.format
    }

    /// Returns the canonical final path for one sealed local segment.
    ///
    /// Callers pass this absent path to [`SegmentWriter`](crate::SegmentWriter)
    /// before publishing a manifest that references the segment.
    pub fn segment_path(&self, id: SegmentId) -> PathBuf {
        self.root.join("segments").join(id.to_string())
    }

    /// Records verified metadata for `object` in the local SQLite database.
    ///
    /// This verifies the object's canonical Git ID before any database is
    /// opened. Repeating an identical record is idempotent; a conflicting
    /// existing record fails without replacement. The database is local
    /// coordination state and is not a recovery source.
    pub fn record_object_metadata(&self, object: &GitObject) -> Result<()> {
        object.verify_id()?;
        let size = i64::try_from(object.data().len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "Git object metadata size is too large",
            )
        })?;
        let mut connection = self.open_metadata_database()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(metadata_error)?;
        let changed = transaction
            .execute(
                "INSERT INTO object_metadata (git_object_id, kind, size) \
                 VALUES (?1, ?2, ?3) ON CONFLICT(git_object_id) DO NOTHING",
                params![
                    object.id().as_bytes().as_slice(),
                    object_kind_code(object.kind()),
                    size
                ],
            )
            .map_err(metadata_error)?;
        if changed == 0 {
            let (kind, existing_size): (i64, i64) = transaction
                .query_row(
                    "SELECT kind, size FROM object_metadata WHERE git_object_id = ?1",
                    params![object.id().as_bytes().as_slice()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(metadata_error)?;
            if object_kind_from_code(kind)? != object.kind() || existing_size != size {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "Git object metadata conflicts with an existing record",
                ));
            }
        }
        transaction.commit().map_err(metadata_error)
    }

    /// Returns local metadata for `id`, or `None` when no record exists.
    ///
    /// Returned data is local acceleration state only and must never be used
    /// as evidence that the object bytes are available or recoverable.
    pub fn object_metadata(&self, id: GitObjectId) -> Result<Option<GitObjectMetadata>> {
        let connection = self.open_metadata_database()?;
        let row: Option<(i64, i64)> = connection
            .query_row(
                "SELECT kind, size FROM object_metadata WHERE git_object_id = ?1",
                params![id.as_bytes().as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(metadata_error)?;
        let Some((kind, size)) = row else {
            return Ok(None);
        };
        let size = u64::try_from(size).map_err(|_| {
            Error::new(
                ErrorKind::CorruptData,
                "object metadata contains an invalid size",
            )
        })?;
        Ok(Some(GitObjectMetadata {
            id,
            kind: object_kind_from_code(kind)?,
            size,
        }))
    }

    /// Publishes one immutable blob manifest without replacing an existing ID.
    ///
    /// The manifest must belong to this repository. Repeating byte-identical
    /// publication is idempotent; a different value under the same manifest ID
    /// fails as a conflict. This portable file is the recovery source; SQLite
    /// is intentionally not involved.
    pub fn publish_blob_manifest(&self, manifest: &BlobManifest) -> Result<()> {
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "blob manifest belongs to a different repository",
            ));
        }
        let bytes = manifest.encode();
        let bytes_len = u64::try_from(bytes.len()).map_err(|_| {
            Error::new(
                ErrorKind::Unsupported,
                "blob manifest is too large to publish",
            )
        })?;
        if bytes_len > PUBLISHED_BLOB_MANIFEST_MAX_BYTES {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "blob manifest is too large to publish",
            ));
        }
        let directory = self.root.join(BLOB_MANIFEST_DIRECTORY);
        validate_directory(&directory, false)?;
        let destination = directory.join(blob_manifest_filename(manifest.manifest_id()));
        match fs::symlink_metadata(&destination) {
            Ok(_) => return self.verify_existing_blob_manifest(&destination, manifest, &bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(io_error(
                    error,
                    "blob manifest destination could not be inspected",
                ));
            }
        }

        let (mut staging, staging_path) = create_blob_manifest_staging(&directory)?;
        if let Err(error) = staging.write_all(&bytes) {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "blob manifest staging file could not be written",
            ));
        }
        if let Err(error) = staging.sync_all() {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "blob manifest staging file could not be synchronized",
            ));
        }
        drop(staging);
        match fs::hard_link(&staging_path, &destination) {
            Ok(()) => {
                sync_directory(&directory)?;
                let _ = fs::remove_file(&staging_path);
                let _ = sync_directory(&directory);
                Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&staging_path);
                self.verify_existing_blob_manifest(&destination, manifest, &bytes)
            }
            Err(error) => {
                let _ = fs::remove_file(&staging_path);
                Err(io_error(error, "blob manifest could not be published"))
            }
        }
    }

    /// Resolves one Git blob ID to its only published manifest, if present.
    ///
    /// A blob may validly acquire multiple immutable representations. This
    /// method rejects that ambiguity instead of selecting one implicitly.
    pub fn resolve_blob_manifest(
        &self,
        git_object_id: GitObjectId,
        limits: BlobManifestReadLimits,
    ) -> Result<Option<BlobManifest>> {
        let directory = self.root.join(BLOB_MANIFEST_DIRECTORY);
        validate_directory(&directory, false)?;
        let entries = fs::read_dir(&directory)
            .map_err(|error| io_error(error, "blob manifest directory could not be read"))?;
        let mut inspected_entries = 0usize;
        let mut resolved = None;
        for entry in entries {
            let entry = entry
                .map_err(|error| io_error(error, "blob manifest directory could not be read"))?;
            inspected_entries = inspected_entries.checked_add(1).ok_or_else(|| {
                Error::new(
                    ErrorKind::Unsupported,
                    "blob manifest directory exceeds the entry limit",
                )
            })?;
            if inspected_entries > limits.maximum_entries {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "blob manifest directory exceeds the entry limit",
                ));
            }
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "blob manifest directory has an invalid entry name",
                )
            })?;
            if is_blob_manifest_staging_filename(name) {
                continue;
            }
            let manifest_id = parse_blob_manifest_filename(name)?;
            let manifest = self.read_blob_manifest(
                &entry.path(),
                manifest_id,
                limits.maximum_manifest_bytes,
                limits.maximum_plaintext_bytes,
            )?;
            if manifest.git_object_id() != git_object_id {
                continue;
            }
            if resolved.replace(manifest).is_some() {
                return Err(Error::new(
                    ErrorKind::Conflict,
                    "multiple blob manifests match the Git object ID",
                ));
            }
        }
        Ok(resolved)
    }

    /// Resolves and verifies the typed segment record named by one manifest.
    ///
    /// The manifest must belong to this repository. The segment's repository
    /// ID, segment ID, checksum, outer record identity, and selected blob
    /// metadata must all match before the verified record is returned.
    pub fn resolve_manifest_record(
        &self,
        manifest: &BlobManifest,
        maximum_segment_bytes: u64,
        limits: SegmentReadLimits,
    ) -> Result<ReadSegmentRecord> {
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "blob manifest belongs to a different repository",
            ));
        }
        if maximum_segment_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment byte limit must not be zero",
            ));
        }
        let directory = self.root.join("segments");
        validate_directory(&directory, false)?;
        let bytes = read_bounded_segment_file(
            &self.segment_path(manifest.segment_id()),
            maximum_segment_bytes,
        )?;
        let segment = SegmentReader::decode(&bytes, limits)?;
        if segment.repository_id() != self.id
            || segment.segment_id() != manifest.segment_id()
            || segment.checksum() != manifest.segment_checksum()
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment does not match the blob manifest",
            ));
        }
        let mut matching = segment.into_records().into_iter().filter(|record| {
            record.content_id() == manifest.record_content_id()
                && manifest_representation_matches(manifest.representation(), record)
        });
        let record = matching.next().ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "segment does not contain the manifest record",
            )
        })?;
        if matching.next().is_some() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment contains duplicate manifest records",
            ));
        }
        verify_manifest_record(manifest, &record)?;
        Ok(record)
    }

    /// Reconstructs the exact blob body selected by one verified manifest.
    ///
    /// This returns only raw Git blob body bytes. Callers that need a Git
    /// object identity must perform final object verification separately.
    pub fn reconstruct_blob_bytes(
        &self,
        manifest: &BlobManifest,
        maximum_segment_bytes: u64,
        limits: SegmentReadLimits,
    ) -> Result<Vec<u8>> {
        let record = self.resolve_manifest_record(manifest, maximum_segment_bytes, limits)?;
        match manifest.representation() {
            BlobManifestRepresentation::WholeBlob => record
                .as_whole_blob()
                .map(|record| record.data().to_vec())
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "segment record type does not match the blob manifest",
                    )
                }),
            BlobManifestRepresentation::TinyBlobAggregation => record
                .as_tiny_blob_aggregation()
                .and_then(|aggregation| {
                    aggregation
                        .entries()
                        .iter()
                        .find(|entry| entry.git_object_id() == manifest.git_object_id())
                })
                .map(|entry| entry.data().to_vec())
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "tiny-blob aggregation does not contain the manifest blob",
                    )
                }),
        }
    }

    /// Reconstructs and verifies one Git blob named by a manifest.
    ///
    /// The returned object has the manifest's Git ID only after its canonical
    /// Git header and exact reconstructed body verify that identity.
    pub fn reconstruct_blob(
        &self,
        manifest: &BlobManifest,
        maximum_segment_bytes: u64,
        limits: SegmentReadLimits,
    ) -> Result<GitObject> {
        verified_reconstructed_blob(
            manifest.git_object_id(),
            self.reconstruct_blob_bytes(manifest, maximum_segment_bytes, limits)?,
        )
    }

    /// Publishes one immutable non-blob object manifest without using SQLite.
    ///
    /// The manifest must belong to this repository. Repeating identical bytes
    /// is idempotent; a distinct manifest at the same Git object ID conflicts.
    pub fn publish_metadata_object_manifest(
        &self,
        manifest: &MetadataObjectManifest,
    ) -> Result<()> {
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "metadata-object manifest belongs to a different repository",
            ));
        }
        let directory = self.ensure_metadata_object_manifest_directory()?;
        let destination =
            directory.join(metadata_object_manifest_filename(manifest.git_object_id()));
        let bytes = manifest.encode();
        if let Ok(metadata) = fs::symlink_metadata(&destination) {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "metadata-object manifest destination is not a regular file",
                ));
            }
        }

        let (mut staging, staging_path) = create_metadata_object_manifest_staging(&directory)?;
        if let Err(error) = staging.write_all(&bytes) {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "metadata-object manifest staging file could not be written",
            ));
        }
        if let Err(error) = staging.sync_all() {
            drop(staging);
            let _ = fs::remove_file(&staging_path);
            return Err(io_error(
                error,
                "metadata-object manifest staging file could not be synchronized",
            ));
        }
        drop(staging);
        match fs::hard_link(&staging_path, &destination) {
            Ok(()) => {
                sync_directory(&directory)?;
                let _ = fs::remove_file(&staging_path);
                let _ = sync_directory(&directory);
                Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&staging_path);
                self.verify_existing_metadata_object_manifest(&destination, manifest, &bytes)
            }
            Err(error) => {
                let _ = fs::remove_file(&staging_path);
                Err(io_error(
                    error,
                    "metadata-object manifest could not be published",
                ))
            }
        }
    }

    /// Resolves one Git tree, commit, or tag ID to its published manifest.
    pub fn resolve_metadata_object_manifest(
        &self,
        git_object_id: GitObjectId,
        limits: MetadataObjectManifestReadLimits,
    ) -> Result<Option<MetadataObjectManifest>> {
        let directory = self.root.join(METADATA_OBJECT_MANIFEST_DIRECTORY);
        match fs::symlink_metadata(&directory) {
            Ok(_) => validate_directory(&directory, false)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(io_error(
                    error,
                    "metadata-object manifest directory could not be inspected",
                ));
            }
        }
        let path = directory.join(metadata_object_manifest_filename(git_object_id));
        match fs::symlink_metadata(&path) {
            Ok(_) => self
                .read_metadata_object_manifest(
                    &path,
                    git_object_id,
                    limits.maximum_manifest_bytes,
                    limits.maximum_plaintext_bytes,
                )
                .map(Some),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io_error(
                error,
                "metadata-object manifest file could not be inspected",
            )),
        }
    }

    /// Resolves and verifies the metadata-object segment record named by a manifest.
    pub fn resolve_metadata_object_record(
        &self,
        manifest: &MetadataObjectManifest,
        maximum_segment_bytes: u64,
        limits: SegmentReadLimits,
    ) -> Result<MetadataObjectRecord> {
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "metadata-object manifest belongs to a different repository",
            ));
        }
        if maximum_segment_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "segment byte limit must not be zero",
            ));
        }
        let directory = self.root.join("segments");
        validate_directory(&directory, false)?;
        let bytes = read_bounded_segment_file(
            &self.segment_path(manifest.segment_id()),
            maximum_segment_bytes,
        )?;
        let segment = SegmentReader::decode(&bytes, limits)?;
        if segment.repository_id() != self.id
            || segment.segment_id() != manifest.segment_id()
            || segment.checksum() != manifest.segment_checksum()
        {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment does not match the metadata-object manifest",
            ));
        }
        let mut matching = segment.into_records().into_iter().filter_map(|record| {
            record
                .as_metadata_object()
                .is_some_and(|stored| stored.content_id() == manifest.content_id())
                .then(|| match record {
                    ReadSegmentRecord::MetadataObject(record) => record,
                    _ => unreachable!("metadata-object accessor and enum variant disagree"),
                })
        });
        let record = matching.next().ok_or_else(|| {
            Error::new(
                ErrorKind::CorruptData,
                "segment does not contain the metadata-object manifest record",
            )
        })?;
        if matching.next().is_some() {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "segment contains duplicate metadata-object manifest records",
            ));
        }
        verify_metadata_object_manifest_record(manifest, &record)?;
        Ok(record)
    }

    /// Reconstructs and verifies one Git tree, commit, or annotated tag.
    pub fn reconstruct_metadata_object(
        &self,
        manifest: &MetadataObjectManifest,
        maximum_segment_bytes: u64,
        limits: SegmentReadLimits,
    ) -> Result<GitObject> {
        let record =
            self.resolve_metadata_object_record(manifest, maximum_segment_bytes, limits)?;
        verified_reconstructed_metadata_object(
            manifest.git_object_id(),
            manifest.kind(),
            record.data().to_vec(),
        )
    }

    fn verify_existing_blob_manifest(
        &self,
        path: &Path,
        manifest: &BlobManifest,
        bytes: &[u8],
    ) -> Result<()> {
        let existing = self.read_blob_manifest(
            path,
            manifest.manifest_id(),
            PUBLISHED_BLOB_MANIFEST_MAX_BYTES,
            u64::MAX,
        )?;
        if existing.encode() == bytes {
            Ok(())
        } else {
            Err(Error::new(
                ErrorKind::Conflict,
                "blob manifest conflicts with an existing manifest ID",
            ))
        }
    }

    fn read_blob_manifest(
        &self,
        path: &Path,
        expected_id: ManifestId,
        maximum_manifest_bytes: u64,
        maximum_plaintext_bytes: u64,
    ) -> Result<BlobManifest> {
        let bytes = read_bounded_regular_file(path, maximum_manifest_bytes)?;
        let manifest = BlobManifest::decode(&bytes, maximum_plaintext_bytes)?;
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest belongs to a different repository",
            ));
        }
        if manifest.manifest_id() != expected_id {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest filename does not match its identity",
            ));
        }
        Ok(manifest)
    }

    fn ensure_metadata_object_manifest_directory(&self) -> Result<PathBuf> {
        let directory = self.root.join(METADATA_OBJECT_MANIFEST_DIRECTORY);
        match fs::create_dir(&directory) {
            Ok(()) => {
                sync_directory(&self.root.join("manifests"))?;
                Ok(directory)
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                validate_directory(&directory, false)?;
                Ok(directory)
            }
            Err(error) => Err(io_error(
                error,
                "metadata-object manifest directory could not be created",
            )),
        }
    }

    fn verify_existing_metadata_object_manifest(
        &self,
        path: &Path,
        manifest: &MetadataObjectManifest,
        bytes: &[u8],
    ) -> Result<()> {
        let existing = self.read_metadata_object_manifest(
            path,
            manifest.git_object_id(),
            PUBLISHED_METADATA_OBJECT_MANIFEST_MAX_BYTES,
            u64::MAX,
        )?;
        if existing.encode() == bytes {
            Ok(())
        } else {
            Err(Error::new(
                ErrorKind::Conflict,
                "metadata-object manifest conflicts with an existing Git object ID",
            ))
        }
    }

    fn read_metadata_object_manifest(
        &self,
        path: &Path,
        expected_id: GitObjectId,
        maximum_manifest_bytes: u64,
        maximum_plaintext_bytes: u64,
    ) -> Result<MetadataObjectManifest> {
        let bytes = read_bounded_metadata_object_manifest_file(path, maximum_manifest_bytes)?;
        let manifest = MetadataObjectManifest::decode(&bytes, maximum_plaintext_bytes)?;
        if manifest.repository_id() != self.id {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest belongs to a different repository",
            ));
        }
        if manifest.git_object_id() != expected_id {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest filename does not match its identity",
            ));
        }
        Ok(manifest)
    }

    fn open_metadata_database(&self) -> Result<Connection> {
        let root = fs::canonicalize(&self.root)
            .map_err(|error| io_error(error, "repository directory could not be resolved"))?;
        let path = root.join(METADATA_PATH);
        validate_metadata_file(&path)?;
        let mut connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .map_err(metadata_error)?;
        connection
            .busy_timeout(Duration::ZERO)
            .map_err(metadata_error)?;
        connection
            .pragma_update(None, "trusted_schema", false)
            .map_err(metadata_error)?;
        initialize_metadata_schema(&mut connection)?;
        Ok(connection)
    }
}

fn object_kind_code(kind: GitObjectKind) -> i64 {
    match kind {
        GitObjectKind::Blob => 1,
        GitObjectKind::Tree => 2,
        GitObjectKind::Commit => 3,
        GitObjectKind::Tag => 4,
    }
}

fn object_kind_from_code(code: i64) -> Result<GitObjectKind> {
    match code {
        1 => Ok(GitObjectKind::Blob),
        2 => Ok(GitObjectKind::Tree),
        3 => Ok(GitObjectKind::Commit),
        4 => Ok(GitObjectKind::Tag),
        _ => Err(Error::new(
            ErrorKind::CorruptData,
            "object metadata contains an invalid kind",
        )),
    }
}

fn blob_manifest_filename(id: ManifestId) -> String {
    format!("{id}{BLOB_MANIFEST_EXTENSION}")
}

fn metadata_object_manifest_filename(id: GitObjectId) -> String {
    format!("{id}{METADATA_OBJECT_MANIFEST_EXTENSION}")
}

fn parse_blob_manifest_filename(name: &str) -> Result<ManifestId> {
    let id = name.strip_suffix(BLOB_MANIFEST_EXTENSION).ok_or_else(|| {
        Error::new(
            ErrorKind::CorruptData,
            "blob manifest directory has an invalid entry name",
        )
    })?;
    if id.is_empty() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "blob manifest directory has an invalid entry name",
        ));
    }
    id.parse().map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "blob manifest directory has an invalid entry name",
        )
    })
}

fn is_blob_manifest_staging_filename(name: &str) -> bool {
    name.strip_prefix('.')
        .and_then(|name| name.strip_suffix(BLOB_MANIFEST_STAGING_SUFFIX))
        .is_some_and(|id| id.parse::<ManifestId>().is_ok())
}

fn create_blob_manifest_staging(parent: &Path) -> Result<(File, PathBuf)> {
    for _ in 0..16 {
        let path = parent.join(format!(
            ".{}{}",
            ManifestId::generate(),
            BLOB_MANIFEST_STAGING_SUFFIX
        ));
        match OpenOptions::new().create_new(true).write(true).open(&path) {
            Ok(file) => return Ok((file, path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(
                    error,
                    "blob manifest staging file could not be created",
                ));
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "blob manifest staging path could not be allocated",
    ))
}

fn create_metadata_object_manifest_staging(parent: &Path) -> Result<(File, PathBuf)> {
    for _ in 0..16 {
        let path = parent.join(format!(
            ".{}{}",
            SegmentId::generate(),
            METADATA_OBJECT_MANIFEST_STAGING_SUFFIX
        ));
        match OpenOptions::new().create_new(true).write(true).open(&path) {
            Ok(file) => return Ok((file, path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(
                    error,
                    "metadata-object manifest staging file could not be created",
                ));
            }
        }
    }
    Err(Error::new(
        ErrorKind::Conflict,
        "metadata-object manifest staging path could not be allocated",
    ))
}

fn manifest_representation_matches(
    representation: BlobManifestRepresentation,
    record: &ReadSegmentRecord,
) -> bool {
    match representation {
        BlobManifestRepresentation::WholeBlob => record.as_whole_blob().is_some(),
        BlobManifestRepresentation::TinyBlobAggregation => {
            record.as_tiny_blob_aggregation().is_some()
        }
    }
}

fn verify_manifest_record(manifest: &BlobManifest, record: &ReadSegmentRecord) -> Result<()> {
    match manifest.representation() {
        BlobManifestRepresentation::WholeBlob => {
            let whole = record.as_whole_blob().ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "segment record type does not match the blob manifest",
                )
            })?;
            if whole.git_object_id() != manifest.git_object_id()
                || whole.content_id() != manifest.content_id()
                || u64::try_from(whole.data().len()).ok() != Some(manifest.plaintext_bytes())
            {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "whole-blob record does not match the blob manifest",
                ));
            }
        }
        BlobManifestRepresentation::TinyBlobAggregation => {
            let aggregation = record.as_tiny_blob_aggregation().ok_or_else(|| {
                Error::new(
                    ErrorKind::CorruptData,
                    "segment record type does not match the blob manifest",
                )
            })?;
            let entry = aggregation
                .entries()
                .iter()
                .find(|entry| entry.git_object_id() == manifest.git_object_id())
                .ok_or_else(|| {
                    Error::new(
                        ErrorKind::CorruptData,
                        "tiny-blob aggregation does not contain the manifest blob",
                    )
                })?;
            if entry.content_id() != manifest.content_id()
                || u64::try_from(entry.data().len()).ok() != Some(manifest.plaintext_bytes())
            {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "tiny-blob entry does not match the blob manifest",
                ));
            }
        }
    }
    Ok(())
}

fn verified_reconstructed_blob(id: GitObjectId, data: Vec<u8>) -> Result<GitObject> {
    let object = GitObject::new(id, GitObjectKind::Blob, data);
    object.verify_id()?;
    Ok(object)
}

fn verify_metadata_object_manifest_record(
    manifest: &MetadataObjectManifest,
    record: &MetadataObjectRecord,
) -> Result<()> {
    if record.git_object_id() != manifest.git_object_id()
        || record.kind() != manifest.kind()
        || record.content_id() != manifest.content_id()
        || u64::try_from(record.data().len()).ok() != Some(manifest.plaintext_bytes())
    {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "metadata-object record does not match its manifest",
        ));
    }
    Ok(())
}

fn verified_reconstructed_metadata_object(
    id: GitObjectId,
    kind: GitObjectKind,
    data: Vec<u8>,
) -> Result<GitObject> {
    if kind == GitObjectKind::Blob {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "metadata-object manifest has an invalid Git object kind",
        ));
    }
    let object = GitObject::new(id, kind, data);
    object.verify_id()?;
    Ok(object)
}

fn read_bounded_regular_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::CorruptData, "blob manifest file is missing")
        } else {
            io_error(error, "blob manifest file could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "blob manifest file is not a regular file",
        ));
    }
    if metadata.len() > maximum_bytes {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "blob manifest file exceeds the byte limit",
        ));
    }
    let length = usize::try_from(metadata.len()).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "blob manifest file exceeds the byte limit",
        )
    })?;
    let mut file = File::open(path)
        .map_err(|error| io_error(error, "blob manifest file could not be opened"))?;
    let mut bytes = vec![0; length];
    file.read_exact(&mut bytes).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            Error::new(ErrorKind::CorruptData, "blob manifest file is truncated")
        } else {
            io_error(error, "blob manifest file could not be read")
        }
    })?;
    let mut extra = [0; 1];
    match file.read(&mut extra) {
        Ok(0) => {}
        Ok(_) => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "blob manifest file changed while being read",
            ));
        }
        Err(error) => return Err(io_error(error, "blob manifest file could not be read")),
    }
    Ok(bytes)
}

fn read_bounded_metadata_object_manifest_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest file is missing",
            )
        } else {
            io_error(
                error,
                "metadata-object manifest file could not be inspected",
            )
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "metadata-object manifest file is not a regular file",
        ));
    }
    if metadata.len() > maximum_bytes {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "metadata-object manifest file exceeds the byte limit",
        ));
    }
    let length = usize::try_from(metadata.len()).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "metadata-object manifest file exceeds the byte limit",
        )
    })?;
    let mut file = File::open(path)
        .map_err(|error| io_error(error, "metadata-object manifest file could not be opened"))?;
    let mut bytes = vec![0; length];
    file.read_exact(&mut bytes).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            Error::new(
                ErrorKind::CorruptData,
                "metadata-object manifest file is truncated",
            )
        } else {
            io_error(error, "metadata-object manifest file could not be read")
        }
    })?;
    let mut extra = [0; 1];
    match file.read(&mut extra) {
        Ok(0) => Ok(bytes),
        Ok(_) => Err(Error::new(
            ErrorKind::CorruptData,
            "metadata-object manifest file changed while being read",
        )),
        Err(error) => Err(io_error(
            error,
            "metadata-object manifest file could not be read",
        )),
    }
}

fn read_bounded_segment_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::NotFound, "manifest segment is missing")
        } else {
            io_error(error, "manifest segment could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "manifest segment is not a regular file",
        ));
    }
    if metadata.len() > maximum_bytes {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "manifest segment exceeds the byte limit",
        ));
    }
    let length = usize::try_from(metadata.len()).map_err(|_| {
        Error::new(
            ErrorKind::Unsupported,
            "manifest segment exceeds the byte limit",
        )
    })?;
    let mut file = File::open(path)
        .map_err(|error| io_error(error, "manifest segment could not be opened"))?;
    let mut bytes = vec![0; length];
    file.read_exact(&mut bytes).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            Error::new(ErrorKind::CorruptData, "manifest segment is truncated")
        } else {
            io_error(error, "manifest segment could not be read")
        }
    })?;
    let mut extra = [0; 1];
    match file.read(&mut extra) {
        Ok(0) => {}
        Ok(_) => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "manifest segment changed while being read",
            ));
        }
        Err(error) => return Err(io_error(error, "manifest segment could not be read")),
    }
    Ok(bytes)
}

fn validate_metadata_file(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(Error::new(
                ErrorKind::CorruptData,
                "object metadata database is not a regular file",
            ))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(
            error,
            "object metadata database could not be inspected",
        )),
    }
}

fn initialize_metadata_schema(connection: &mut Connection) -> Result<()> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(metadata_error)?;
    let application_id: i32 = transaction
        .pragma_query_value(None, "application_id", |row| row.get(0))
        .map_err(metadata_error)?;
    let version: i32 = transaction
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(metadata_error)?;
    match (application_id, version) {
        (0, 0) => {
            transaction
                .execute_batch(
                    "CREATE TABLE object_metadata (
                        git_object_id BLOB PRIMARY KEY NOT NULL CHECK (length(git_object_id) = 20),
                        kind INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 4),
                        size INTEGER NOT NULL CHECK (size >= 0)
                    ) WITHOUT ROWID;",
                )
                .map_err(metadata_error)?;
            transaction
                .pragma_update(None, "application_id", METADATA_APPLICATION_ID)
                .map_err(metadata_error)?;
            transaction
                .pragma_update(None, "user_version", METADATA_SCHEMA_VERSION)
                .map_err(metadata_error)?;
        }
        (METADATA_APPLICATION_ID, METADATA_SCHEMA_VERSION) => {}
        (METADATA_APPLICATION_ID, _) => {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "object metadata database schema version is unsupported",
            ));
        }
        _ => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "object metadata database has an invalid identity",
            ));
        }
    }
    transaction.commit().map_err(metadata_error)
}

fn metadata_error(error: SqliteError) -> Error {
    let (kind, message) = match &error {
        SqliteError::SqliteFailure(error, _) => match error.code {
            SqliteErrorCode::DatabaseBusy | SqliteErrorCode::DatabaseLocked => {
                (ErrorKind::Conflict, "object metadata database is busy")
            }
            SqliteErrorCode::DatabaseCorrupt
            | SqliteErrorCode::NotADatabase
            | SqliteErrorCode::SchemaChanged
            | SqliteErrorCode::ConstraintViolation
            | SqliteErrorCode::TypeMismatch => (
                ErrorKind::CorruptData,
                "object metadata database is corrupt",
            ),
            _ => (
                ErrorKind::Io,
                "object metadata database could not be accessed",
            ),
        },
        SqliteError::FromSqlConversionFailure(..)
        | SqliteError::IntegralValueOutOfRange(..)
        | SqliteError::InvalidColumnType(..) => (
            ErrorKind::CorruptData,
            "object metadata database is corrupt",
        ),
        _ => (
            ErrorKind::Io,
            "object metadata database could not be accessed",
        ),
    };
    Error::with_source(kind, message, error)
}

fn encode_bootstrap(id: RepositoryId, format: RepositoryFormat) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.write_fixed(&BOOTSTRAP_MAGIC);
    encoder.write_u16(format.version().as_u16());
    encoder.write_u64(format.features().required_bits());
    encoder.write_u64(format.features().optional_bits());
    encoder.write_fixed(id.as_bytes());
    encoder.into_bytes()
}

fn read_bootstrap(root: &Path) -> Result<(RepositoryId, RepositoryFormat)> {
    let path = root.join(BOOTSTRAP_PATH);
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::CorruptData, "repository bootstrap is missing")
        } else {
            io_error(error, "repository bootstrap could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "repository bootstrap is not a regular file",
        ));
    }
    if metadata.len() > BOOTSTRAP_MAX_BYTES {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "repository bootstrap exceeds the size limit",
        ));
    }
    let mut bootstrap = File::open(path)
        .map_err(|error| io_error(error, "repository bootstrap could not be opened"))?;
    let length = usize::try_from(metadata.len()).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "repository bootstrap exceeds the size limit",
        )
    })?;
    let mut bytes = vec![0; length];
    bootstrap.read_exact(&mut bytes).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            Error::new(ErrorKind::CorruptData, "repository bootstrap is truncated")
        } else {
            io_error(error, "repository bootstrap could not be read")
        }
    })?;
    let mut extra = [0; 1];
    match bootstrap.read(&mut extra) {
        Ok(0) => {}
        Ok(_) => {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "repository bootstrap changed while being read",
            ));
        }
        Err(error) => return Err(io_error(error, "repository bootstrap could not be read")),
    }
    decode_bootstrap(&bytes)
}

fn decode_bootstrap(bytes: &[u8]) -> Result<(RepositoryId, RepositoryFormat)> {
    let mut decoder = CanonicalDecoder::new(bytes);
    let magic = decoder.read_fixed::<4>()?;
    if magic != BOOTSTRAP_MAGIC {
        return Err(Error::new(
            ErrorKind::CorruptData,
            "repository bootstrap has invalid magic",
        ));
    }
    let format = RepositoryFormat::from_raw(
        decoder.read_u16()?,
        decoder.read_u64()?,
        decoder.read_u64()?,
    )?;
    let id = RepositoryId::from_bytes(decoder.read_fixed()?).map_err(|_| {
        Error::new(
            ErrorKind::CorruptData,
            "repository bootstrap contains an invalid repository ID",
        )
    })?;
    decoder.finish()?;
    Ok((id, format))
}

fn validate_directory(path: &Path, root: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if root && error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::NotFound, "repository does not exist")
        } else if !root && error.kind() == io::ErrorKind::NotFound {
            Error::new(ErrorKind::CorruptData, "repository layout is incomplete")
        } else {
            io_error(error, "repository layout could not be inspected")
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::new(
            if root {
                ErrorKind::InvalidInput
            } else {
                ErrorKind::CorruptData
            },
            if root {
                "repository path is not a directory"
            } else {
                "repository layout contains an invalid entry"
            },
        ));
    }
    Ok(())
}

fn validate_optional_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => validate_directory(path, false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(
            error,
            "repository optional layout could not be inspected",
        )),
    }
}

fn create_root_error(error: io::Error) -> Error {
    if error.kind() == io::ErrorKind::AlreadyExists {
        Error::with_source(ErrorKind::Conflict, "repository path already exists", error)
    } else {
        io_error(error, "repository directory could not be created")
    }
}

fn io_error(error: io::Error, message: &'static str) -> Error {
    Error::with_source(ErrorKind::Io, message, error)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .map_err(|error| io_error(error, "repository directory could not be synchronized"))?
        .sync_all()
        .map_err(|error| io_error(error, "repository directory could not be synchronized"))
}

#[cfg(not(unix))]
fn sync_directory(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    use sha2::{Digest, Sha256};
    use uuid::Uuid;

    use super::*;
    use crate::{
        SegmentReadLimits, SegmentReader, SegmentRecord, SegmentWriteLimits, SegmentWriter,
        TinyBlobAggregation, WholeBlobRecord,
    };

    const TEST_ID: &str = "550e8400-e29b-41d4-a716-446655440000";
    const MANIFEST_ID_A: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";
    const MANIFEST_ID_B: &str = "7d444840-9dc0-41d1-b245-5ffdce74fad2";
    const SEGMENT_ID_A: &str = "6ba7b814-9dad-41d1-80b4-00c04fd430c8";
    const SEGMENT_ID_B: &str = "123e4567-e89b-42d3-a456-426614174000";
    const SEGMENT_ID_C: &str = "67e55044-10b1-426f-9247-bb680e5fe0c8";

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("yeokcham-core-{}", Uuid::new_v4()));
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

    fn bootstrap_path(root: &Path) -> PathBuf {
        root.join(BOOTSTRAP_PATH)
    }

    fn bootstrap_with(id: [u8; 16], version: u16, required: u64, optional: u64) -> Vec<u8> {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_fixed(&BOOTSTRAP_MAGIC);
        encoder.write_u16(version);
        encoder.write_u64(required);
        encoder.write_u64(optional);
        encoder.write_fixed(&id);
        encoder.into_bytes()
    }

    fn verified_object(kind: GitObjectKind, data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            kind,
            data.to_vec(),
        );
        GitObject::new(provisional.recompute_id(), kind, data.to_vec())
    }

    fn metadata_path(root: &Path) -> PathBuf {
        root.join(METADATA_PATH)
    }

    fn manifest_path(root: &Path, id: ManifestId) -> PathBuf {
        root.join(BLOB_MANIFEST_DIRECTORY)
            .join(blob_manifest_filename(id))
    }

    fn metadata_object_manifest_path(root: &Path, id: GitObjectId) -> PathBuf {
        root.join(METADATA_OBJECT_MANIFEST_DIRECTORY)
            .join(metadata_object_manifest_filename(id))
    }

    fn manifest_limits() -> BlobManifestReadLimits {
        BlobManifestReadLimits::new(8, 4_096, 4_096).expect("manifest limits")
    }

    fn metadata_object_manifest_limits() -> MetadataObjectManifestReadLimits {
        MetadataObjectManifestReadLimits::new(4_096, 4_096).expect("metadata manifest limits")
    }

    fn segment_limits() -> SegmentReadLimits {
        SegmentReadLimits::new(4, 4_096, 4_096, 4_096, 4_096, 4_096).expect("segment limits")
    }

    fn whole_blob_manifest(
        repository: &LocalRepository,
        manifest_id: ManifestId,
        segment_id: SegmentId,
        data: &[u8],
    ) -> BlobManifest {
        let object = verified_object(GitObjectKind::Blob, data);
        let record = WholeBlobRecord::from_verified_blob(&object).expect("whole record");
        let segment_record = SegmentRecord::from_whole_blob(&record).expect("segment record");
        let path = repository.segment_path(segment_id);
        let mut writer = SegmentWriter::new(
            repository.id(),
            segment_id,
            SegmentWriteLimits::new(1, segment_record.stored_len()).expect("write limits"),
        );
        writer.add(segment_record).expect("add record");
        writer.seal_to(&path).expect("seal segment");
        let bytes = fs::read(path).expect("read segment");
        let segment = SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(1, 4_096, 4_096, 4_096, 4_096, 4_096).expect("read limits"),
        )
        .expect("read segment");
        BlobManifest::from_whole_blob(manifest_id, &segment, &record).expect("manifest")
    }

    fn tiny_blob_manifest(
        repository: &LocalRepository,
        manifest_id: ManifestId,
        segment_id: SegmentId,
    ) -> (BlobManifest, GitObjectId) {
        let first = verified_object(GitObjectKind::Blob, b"first");
        let selected = verified_object(GitObjectKind::Blob, b"\0selected\xff");
        let selected_id = selected.id();
        let aggregation =
            TinyBlobAggregation::from_verified_blobs(&[first, selected]).expect("aggregation");
        let segment_record =
            SegmentRecord::from_tiny_blob_aggregation(&aggregation).expect("segment record");
        let path = repository.segment_path(segment_id);
        let mut writer = SegmentWriter::new(
            repository.id(),
            segment_id,
            SegmentWriteLimits::new(1, segment_record.stored_len()).expect("write limits"),
        );
        writer.add(segment_record).expect("add record");
        writer.seal_to(&path).expect("seal segment");
        let bytes = fs::read(path).expect("read segment");
        let segment = SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(1, 4_096, 4_096, 4_096, 4_096, 4_096).expect("read limits"),
        )
        .expect("read segment");
        (
            BlobManifest::from_tiny_blob_aggregation(
                manifest_id,
                &segment,
                &aggregation,
                selected_id,
            )
            .expect("manifest"),
            selected_id,
        )
    }

    fn metadata_object_manifest(
        repository: &LocalRepository,
        segment_id: SegmentId,
        kind: GitObjectKind,
        data: &[u8],
    ) -> MetadataObjectManifest {
        let object = verified_object(kind, data);
        let record =
            MetadataObjectRecord::from_verified_object(&object).expect("metadata object record");
        let segment_record = SegmentRecord::from_metadata_object(&record).expect("segment record");
        let path = repository.segment_path(segment_id);
        let mut writer = SegmentWriter::new(
            repository.id(),
            segment_id,
            SegmentWriteLimits::new(1, segment_record.stored_len()).expect("write limits"),
        );
        writer.add(segment_record).expect("add record");
        writer.seal_to(&path).expect("seal segment");
        let bytes = fs::read(path).expect("read segment");
        let segment = SegmentReader::decode(
            &bytes,
            SegmentReadLimits::new(1, 4_096, 4_096, 4_096, 1, 1).expect("read limits"),
        )
        .expect("read segment");
        MetadataObjectManifest::from_metadata_object(&segment, &record).expect("manifest")
    }

    #[test]
    fn bootstrap_encoding_is_canonical() {
        let id: RepositoryId = TEST_ID.parse().expect("valid test ID");

        assert_eq!(
            encode_bootstrap(id, RepositoryFormat::initial()),
            [
                b'Y', b'K', b'R', b'B', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x55,
                0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00,
                0x00,
            ]
        );
    }

    #[test]
    fn creates_reopens_and_migrates_an_empty_repository() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");

        let created = LocalRepository::create(&root).expect("create repository");
        for relative_path in LAYOUT_DIRECTORIES {
            assert!(root.join(relative_path).is_dir(), "missing {relative_path}");
        }
        let before_migration = fs::read(bootstrap_path(&root)).expect("read bootstrap");
        let reopened = LocalRepository::open(&root).expect("reopen repository");
        let migrated = LocalRepository::migrate(&root).expect("migrate repository");

        assert_eq!(created.path(), root);
        assert_eq!(created.id(), reopened.id());
        assert_eq!(created.format(), reopened.format());
        assert_eq!(reopened.id(), migrated.id());
        assert_eq!(
            before_migration,
            fs::read(bootstrap_path(&root)).expect("read bootstrap")
        );
    }

    #[test]
    fn rejects_existing_or_missing_repository_paths() {
        let temporary = TestDirectory::new();
        let existing = temporary.path().join("existing");
        fs::create_dir(&existing).expect("create existing directory");

        let create_error = LocalRepository::create(&existing)
            .err()
            .expect("existing path must fail");
        let open_error = LocalRepository::open(temporary.path().join("missing"))
            .err()
            .expect("missing path must fail");

        assert_eq!(create_error.kind(), ErrorKind::Conflict);
        assert_eq!(open_error.kind(), ErrorKind::NotFound);
    }

    #[test]
    fn rejects_incomplete_and_corrupt_bootstraps() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        LocalRepository::create(&root).expect("create repository");
        fs::remove_dir(root.join("segments")).expect("remove layout entry");
        let incomplete_error = LocalRepository::open(&root)
            .err()
            .expect("incomplete layout must fail");
        assert_eq!(incomplete_error.kind(), ErrorKind::CorruptData);

        fs::create_dir(root.join("segments")).expect("restore layout entry");
        let id: RepositoryId = TEST_ID.parse().expect("valid test ID");
        for bytes in [
            vec![],
            vec![0; BOOTSTRAP_MAX_BYTES as usize + 1],
            {
                let mut bytes = bootstrap_with(id.into_bytes(), 1, 0, 0);
                bytes[0] = b'X';
                bytes
            },
            bootstrap_with([0; 16], 1, 0, 0),
            {
                let mut bytes = bootstrap_with(id.into_bytes(), 1, 0, 0);
                bytes.push(0);
                bytes
            },
        ] {
            fs::write(bootstrap_path(&root), bytes).expect("replace bootstrap");
            let error = LocalRepository::open(&root)
                .err()
                .expect("corrupt bootstrap must fail");
            assert_eq!(error.kind(), ErrorKind::CorruptData);
        }
    }

    #[test]
    fn rejects_unsupported_bootstrap_version_and_required_features() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        LocalRepository::create(&root).expect("create repository");
        let id: RepositoryId = TEST_ID.parse().expect("valid test ID");

        for bytes in [
            bootstrap_with(id.into_bytes(), 2, 0, 0),
            bootstrap_with(id.into_bytes(), 1, 1, 0),
        ] {
            fs::write(bootstrap_path(&root), bytes).expect("replace bootstrap");
            let error = LocalRepository::open(&root)
                .err()
                .expect("unsupported bootstrap must fail");
            assert_eq!(error.kind(), ErrorKind::Unsupported);
        }
    }

    #[test]
    fn accepts_unknown_optional_features_without_rewriting_them() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        LocalRepository::create(&root).expect("create repository");
        let id: RepositoryId = TEST_ID.parse().expect("valid test ID");
        let bootstrap = bootstrap_with(id.into_bytes(), 1, 0, 1 << 63);
        fs::write(bootstrap_path(&root), &bootstrap).expect("replace bootstrap");

        let repository = LocalRepository::migrate(&root).expect("open optional feature");

        assert_eq!(repository.format().features().optional_bits(), 1 << 63);
        assert_eq!(
            fs::read(bootstrap_path(&root)).expect("read bootstrap"),
            bootstrap
        );
    }

    #[test]
    fn records_verified_object_metadata_and_reopens_it() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let objects = [
            verified_object(GitObjectKind::Blob, b"blob body"),
            verified_object(GitObjectKind::Tree, b"tree body"),
            verified_object(GitObjectKind::Commit, b"commit body"),
            verified_object(GitObjectKind::Tag, b"tag body"),
        ];

        assert!(!metadata_path(&root).exists());
        for object in &objects {
            repository
                .record_object_metadata(object)
                .expect("record metadata");
            repository
                .record_object_metadata(object)
                .expect("repeat metadata record");
            assert_eq!(
                repository
                    .object_metadata(object.id())
                    .expect("read metadata"),
                Some(GitObjectMetadata {
                    id: object.id(),
                    kind: object.kind(),
                    size: object.data().len() as u64,
                })
            );
        }
        assert!(metadata_path(&root).is_file());

        let reopened = LocalRepository::open(&root).expect("reopen repository");
        for object in &objects {
            assert_eq!(
                reopened
                    .object_metadata(object.id())
                    .expect("read persisted metadata"),
                Some(GitObjectMetadata {
                    id: object.id(),
                    kind: object.kind(),
                    size: object.data().len() as u64,
                })
            );
        }
        assert_eq!(
            reopened
                .object_metadata(GitObjectId::from_bytes([9; GitObjectId::BYTE_LENGTH]))
                .expect("read absent metadata"),
            None
        );
    }

    #[test]
    fn rejects_unverified_object_metadata_without_creating_a_database() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let object = GitObject::new(
            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
                .parse()
                .expect("empty blob ID"),
            GitObjectKind::Blob,
            b"altered body".to_vec(),
        );

        let error = repository
            .record_object_metadata(&object)
            .expect_err("unverified object must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            error.public_message(),
            "Git object ID does not match its bytes"
        );
        assert!(!metadata_path(&root).exists());
    }

    #[test]
    fn rejects_corrupt_and_conflicting_object_metadata() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let object = verified_object(GitObjectKind::Blob, b"body");
        repository
            .record_object_metadata(&object)
            .expect("record metadata");

        let connection = Connection::open(metadata_path(&root)).expect("open metadata database");
        connection
            .execute(
                "UPDATE object_metadata SET kind = ?1 WHERE git_object_id = ?2",
                params![
                    object_kind_code(GitObjectKind::Tree),
                    object.id().as_bytes().as_slice()
                ],
            )
            .expect("change metadata kind");
        drop(connection);
        let conflict = repository
            .record_object_metadata(&object)
            .expect_err("conflicting metadata must fail");
        assert_eq!(conflict.kind(), ErrorKind::Conflict);

        let connection = Connection::open(metadata_path(&root)).expect("reopen metadata database");
        connection
            .execute_batch(
                "PRAGMA ignore_check_constraints = ON; UPDATE object_metadata SET kind = 99;",
            )
            .expect("corrupt metadata kind");
        drop(connection);
        let corrupt = repository
            .object_metadata(object.id())
            .expect_err("invalid metadata kind must fail");
        assert_eq!(corrupt.kind(), ErrorKind::CorruptData);
        assert_eq!(
            corrupt.public_message(),
            "object metadata contains an invalid kind"
        );
    }

    #[test]
    fn rejects_unsupported_object_metadata_schema() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let object = verified_object(GitObjectKind::Blob, b"body");
        repository
            .record_object_metadata(&object)
            .expect("record metadata");

        let connection = Connection::open(metadata_path(&root)).expect("open metadata database");
        connection
            .pragma_update(None, "user_version", METADATA_SCHEMA_VERSION + 1)
            .expect("set future schema version");
        drop(connection);
        let error = repository
            .object_metadata(object.id())
            .expect_err("future schema must fail");

        assert_eq!(error.kind(), ErrorKind::Unsupported);
        assert_eq!(
            error.public_message(),
            "object metadata database schema version is unsupported"
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_bootstrap() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        LocalRepository::create(&root).expect("create repository");
        let replacement = temporary.path().join("replacement");
        fs::write(&replacement, b"not a bootstrap").expect("write replacement");
        fs::remove_file(bootstrap_path(&root)).expect("remove bootstrap");
        symlink(&replacement, bootstrap_path(&root)).expect("link bootstrap");

        let error = LocalRepository::open(&root)
            .err()
            .expect("symlink must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            error.public_message(),
            "repository bootstrap is not a regular file"
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_object_metadata_database() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let replacement = temporary.path().join("replacement");
        fs::write(&replacement, b"not metadata").expect("write replacement");
        symlink(&replacement, metadata_path(&root)).expect("link metadata database");

        let error = repository
            .record_object_metadata(&verified_object(GitObjectKind::Blob, b"body"))
            .expect_err("symlink must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            error.public_message(),
            "object metadata database is not a regular file"
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_metadata_object_manifest_directory_at_open() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        LocalRepository::create(&root).expect("create repository");
        let replacement = temporary.path().join("replacement");
        fs::create_dir(&replacement).expect("create replacement");
        symlink(&replacement, root.join(METADATA_OBJECT_MANIFEST_DIRECTORY))
            .expect("link manifest directory");

        let error = LocalRepository::open(&root)
            .err()
            .expect("symlink must fail");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn publishes_and_resolves_one_blob_manifest_without_sqlite() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"\0private body\xff",
        );
        let git_object_id = manifest.git_object_id();

        assert_eq!(
            repository
                .resolve_blob_manifest(git_object_id, manifest_limits())
                .expect("resolve absent"),
            None
        );
        assert!(!metadata_path(&root).exists());
        repository
            .publish_blob_manifest(&manifest)
            .expect("publish manifest");
        repository
            .publish_blob_manifest(&manifest)
            .expect("repeat manifest");
        assert!(manifest_path(&root, manifest.manifest_id()).is_file());
        assert_eq!(
            repository
                .resolve_blob_manifest(git_object_id, manifest_limits())
                .expect("resolve manifest")
                .as_ref(),
            Some(&manifest)
        );

        let reopened = LocalRepository::open(&root).expect("reopen repository");
        assert_eq!(
            reopened
                .resolve_blob_manifest(git_object_id, manifest_limits())
                .expect("resolve after reopen")
                .as_ref(),
            Some(&manifest)
        );
        assert!(!metadata_path(&root).exists());
    }

    #[test]
    fn publishes_resolves_and_reconstructs_commit_tree_and_tag_objects() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");

        for (kind, body, segment_id) in [
            (
                GitObjectKind::Tree,
                b"100644 file\0\x01\xff".as_slice(),
                SEGMENT_ID_A,
            ),
            (
                GitObjectKind::Commit,
                b"tree \0commit\xff\n".as_slice(),
                SEGMENT_ID_B,
            ),
            (
                GitObjectKind::Tag,
                b"object \xff\0tag".as_slice(),
                SEGMENT_ID_C,
            ),
        ] {
            let manifest = metadata_object_manifest(
                &repository,
                segment_id.parse().expect("segment ID"),
                kind,
                body,
            );
            assert_eq!(
                repository
                    .resolve_metadata_object_manifest(
                        manifest.git_object_id(),
                        metadata_object_manifest_limits(),
                    )
                    .expect("resolve absent"),
                None
            );
            repository
                .publish_metadata_object_manifest(&manifest)
                .expect("publish manifest");
            repository
                .publish_metadata_object_manifest(&manifest)
                .expect("repeat manifest");
            assert!(metadata_object_manifest_path(&root, manifest.git_object_id()).is_file());
            assert_eq!(
                repository
                    .resolve_metadata_object_manifest(
                        manifest.git_object_id(),
                        metadata_object_manifest_limits(),
                    )
                    .expect("resolve manifest")
                    .as_ref(),
                Some(&manifest)
            );
            let record = repository
                .resolve_metadata_object_record(&manifest, 4_096, segment_limits())
                .expect("resolve metadata record");
            assert_eq!(record.kind(), kind);
            assert_eq!(record.git_object_id(), manifest.git_object_id());
            assert_eq!(record.data(), body);
            let object = repository
                .reconstruct_metadata_object(&manifest, 4_096, segment_limits())
                .expect("reconstruct object");
            assert_eq!(object.id(), manifest.git_object_id());
            assert_eq!(object.kind(), kind);
            assert_eq!(object.data(), body);
            object.verify_id().expect("verify reconstructed object");
        }
        assert!(!metadata_path(&root).exists());

        let reopened = LocalRepository::open(&root).expect("reopen repository");
        assert!(
            reopened
                .resolve_metadata_object_manifest(
                    verified_object(GitObjectKind::Commit, b"tree \0commit\xff\n").id(),
                    metadata_object_manifest_limits(),
                )
                .expect("resolve after reopen")
                .is_some()
        );
    }

    #[test]
    fn rejects_conflicting_limited_and_tampered_metadata_object_storage() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let first = metadata_object_manifest(
            &repository,
            SEGMENT_ID_A.parse().expect("segment ID"),
            GitObjectKind::Commit,
            b"private metadata body",
        );
        let conflict = metadata_object_manifest(
            &repository,
            SEGMENT_ID_B.parse().expect("segment ID"),
            GitObjectKind::Commit,
            b"private metadata body",
        );
        repository
            .publish_metadata_object_manifest(&first)
            .expect("publish manifest");
        let conflict = repository
            .publish_metadata_object_manifest(&conflict)
            .expect_err("conflicting manifest");
        assert_eq!(conflict.kind(), ErrorKind::Conflict);

        let limited = repository
            .resolve_metadata_object_manifest(
                first.git_object_id(),
                MetadataObjectManifestReadLimits::new(1, 4_096).expect("limits"),
            )
            .expect_err("manifest limit");
        assert_eq!(limited.kind(), ErrorKind::Unsupported);

        let path = repository.segment_path(first.segment_id());
        let mut tampered = fs::read(&path).expect("read segment");
        let final_byte = tampered.len() - 1;
        tampered[final_byte] ^= 1;
        fs::write(&path, tampered).expect("tamper segment");
        let tampered = repository
            .resolve_metadata_object_record(&first, 4_096, segment_limits())
            .expect_err("tampered segment");
        assert_eq!(tampered.kind(), ErrorKind::CorruptData);
        assert!(!tampered.to_string().contains("private metadata body"));
    }

    #[test]
    fn rejects_reconstructed_metadata_bytes_that_do_not_match_the_final_git_id() {
        let expected = verified_object(GitObjectKind::Tree, b"expected tree");
        let error = verified_reconstructed_metadata_object(
            expected.id(),
            GitObjectKind::Tree,
            b"altered private metadata body".to_vec(),
        )
        .expect_err("mismatched final Git ID");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains("altered private metadata body"));
    }

    #[test]
    fn rejects_manifest_conflicts_and_ambiguous_blob_resolution() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let first = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"same blob",
        );
        let first_git_object_id = first.git_object_id();
        let conflicting_id = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_B.parse().expect("segment ID"),
            b"different blob",
        );
        repository
            .publish_blob_manifest(&first)
            .expect("publish first manifest");
        let conflict = repository
            .publish_blob_manifest(&conflicting_id)
            .expect_err("conflicting manifest ID");
        assert_eq!(conflict.kind(), ErrorKind::Conflict);
        assert_eq!(
            repository
                .resolve_blob_manifest(first_git_object_id, manifest_limits())
                .expect("resolve first manifest")
                .as_ref(),
            Some(&first)
        );

        let duplicate_representation = whole_blob_manifest(
            &repository,
            MANIFEST_ID_B.parse().expect("manifest ID"),
            "67e55044-10b1-426f-9247-bb680e5fe0c8"
                .parse()
                .expect("segment ID"),
            b"same blob",
        );
        repository
            .publish_blob_manifest(&duplicate_representation)
            .expect("publish second manifest");
        let ambiguous = repository
            .resolve_blob_manifest(first_git_object_id, manifest_limits())
            .expect_err("ambiguous manifests");
        assert_eq!(ambiguous.kind(), ErrorKind::Conflict);
    }

    #[test]
    fn rejects_corrupt_foreign_and_out_of_bound_blob_manifests() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"private body",
        );
        repository
            .publish_blob_manifest(&manifest)
            .expect("publish manifest");

        let too_small = BlobManifestReadLimits::new(8, 1, 4_096).expect("limits");
        let limit = repository
            .resolve_blob_manifest(manifest.git_object_id(), too_small)
            .expect_err("manifest byte limit");
        assert_eq!(limit.kind(), ErrorKind::Unsupported);

        fs::write(manifest_path(&root, manifest.manifest_id()), b"corrupt")
            .expect("corrupt manifest");
        let corrupt = repository
            .resolve_blob_manifest(manifest.git_object_id(), manifest_limits())
            .expect_err("corrupt manifest");
        assert_eq!(corrupt.kind(), ErrorKind::CorruptData);

        let foreign_root = temporary.path().join("foreign-repository");
        let foreign = LocalRepository::create(&foreign_root).expect("create foreign repository");
        let foreign_manifest = whole_blob_manifest(
            &foreign,
            MANIFEST_ID_B.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"foreign",
        );
        let foreign_error = repository
            .publish_blob_manifest(&foreign_manifest)
            .expect_err("foreign manifest");
        assert_eq!(foreign_error.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn ignores_staging_files_and_rejects_invalid_manifest_directory_entries() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"body",
        );
        let git_object_id = manifest.git_object_id();
        repository
            .publish_blob_manifest(&manifest)
            .expect("publish manifest");
        fs::write(
            root.join(BLOB_MANIFEST_DIRECTORY)
                .join(".123e4567-e89b-42d3-a456-426614174000.partial"),
            b"partial",
        )
        .expect("write staging");
        let entry_limit = BlobManifestReadLimits::new(1, 4_096, 4_096).expect("entry limit");
        let entry_limit = repository
            .resolve_blob_manifest(git_object_id, entry_limit)
            .expect_err("entry limit");
        assert_eq!(entry_limit.kind(), ErrorKind::Unsupported);
        assert_eq!(
            repository
                .resolve_blob_manifest(git_object_id, manifest_limits())
                .expect("ignore staging")
                .as_ref(),
            Some(&manifest)
        );

        fs::write(
            root.join(BLOB_MANIFEST_DIRECTORY).join("unexpected"),
            b"invalid",
        )
        .expect("write invalid entry");
        let invalid = repository
            .resolve_blob_manifest(git_object_id, manifest_limits())
            .expect_err("invalid entry");
        assert_eq!(invalid.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn resolves_verified_whole_and_tiny_manifest_records_from_segments() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let whole = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"\0whole\xff",
        );
        let whole_record = repository
            .resolve_manifest_record(&whole, 4_096, segment_limits())
            .expect("resolve whole record");
        let whole_record = whole_record.as_whole_blob().expect("whole record type");
        assert_eq!(whole_record.git_object_id(), whole.git_object_id());
        assert_eq!(whole_record.content_id(), whole.content_id());
        assert_eq!(whole_record.data(), b"\0whole\xff");

        let (tiny, selected_id) = tiny_blob_manifest(
            &repository,
            MANIFEST_ID_B.parse().expect("manifest ID"),
            SEGMENT_ID_B.parse().expect("segment ID"),
        );
        let tiny_record = repository
            .resolve_manifest_record(&tiny, 4_096, segment_limits())
            .expect("resolve tiny record");
        let entry = tiny_record
            .as_tiny_blob_aggregation()
            .expect("tiny aggregation type")
            .entries()
            .iter()
            .find(|entry| entry.git_object_id() == selected_id)
            .expect("selected entry");
        assert_eq!(entry.content_id(), tiny.content_id());
        assert_eq!(entry.data(), b"\0selected\xff");
    }

    #[test]
    fn reconstructs_exact_whole_and_tiny_blob_bytes() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let whole = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"\0whole\xff\n",
        );
        assert_eq!(
            repository
                .reconstruct_blob_bytes(&whole, 4_096, segment_limits())
                .expect("reconstruct whole blob"),
            b"\0whole\xff\n"
        );

        let (tiny, _) = tiny_blob_manifest(
            &repository,
            MANIFEST_ID_B.parse().expect("manifest ID"),
            SEGMENT_ID_B.parse().expect("segment ID"),
        );
        assert_eq!(
            repository
                .reconstruct_blob_bytes(&tiny, 4_096, segment_limits())
                .expect("reconstruct tiny blob"),
            b"\0selected\xff"
        );
    }

    #[test]
    fn reconstructs_and_verifies_final_git_blob_ids() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"\0verified\xff",
        );

        let object = repository
            .reconstruct_blob(&manifest, 4_096, segment_limits())
            .expect("reconstruct verified blob");
        assert_eq!(object.id(), manifest.git_object_id());
        assert_eq!(object.kind(), GitObjectKind::Blob);
        assert_eq!(object.data(), b"\0verified\xff");
        object.verify_id().expect("verify final blob ID");
    }

    #[test]
    fn rejects_reconstructed_bytes_that_do_not_match_the_final_git_blob_id() {
        let expected = verified_object(GitObjectKind::Blob, b"expected");
        let error = verified_reconstructed_blob(expected.id(), b"altered private body".to_vec())
            .expect_err("mismatched final Git ID");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert!(!error.to_string().contains("altered private body"));
    }

    #[test]
    fn reconstruction_returns_segment_resolution_errors_without_body_disclosure() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"private reconstruction body",
        );
        fs::remove_file(repository.segment_path(manifest.segment_id())).expect("remove segment");

        let error = repository
            .reconstruct_blob_bytes(&manifest, 4_096, segment_limits())
            .expect_err("missing segment");
        assert_eq!(error.kind(), ErrorKind::NotFound);
        assert!(!error.to_string().contains("private reconstruction body"));
    }

    #[test]
    fn rejects_missing_limited_tampered_and_mismatched_manifest_segments() {
        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"body",
        );
        let zero_limit = repository
            .resolve_manifest_record(&manifest, 0, segment_limits())
            .expect_err("zero segment limit");
        let byte_limit = repository
            .resolve_manifest_record(&manifest, 1, segment_limits())
            .expect_err("segment byte limit");
        assert_eq!(zero_limit.kind(), ErrorKind::InvalidInput);
        assert_eq!(byte_limit.kind(), ErrorKind::Unsupported);

        let path = repository.segment_path(manifest.segment_id());
        let mut tampered = fs::read(&path).expect("read segment");
        let final_byte = tampered.len() - 1;
        tampered[final_byte] ^= 1;
        fs::write(&path, &tampered).expect("tamper segment");
        let tampered = repository
            .resolve_manifest_record(&manifest, 4_096, segment_limits())
            .expect_err("tampered segment");
        assert_eq!(tampered.kind(), ErrorKind::CorruptData);

        let mut mismatched = fs::read(&path).expect("read tampered segment");
        mismatched[38..54].copy_from_slice(
            &SEGMENT_ID_B
                .parse::<SegmentId>()
                .expect("segment ID")
                .into_bytes(),
        );
        let checksum_offset = mismatched.len() - 32;
        let checksum: [u8; 32] = Sha256::digest(&mismatched[..checksum_offset]).into();
        mismatched[checksum_offset..].copy_from_slice(&checksum);
        fs::write(&path, mismatched).expect("rewrite mismatched segment");
        let mismatched = repository
            .resolve_manifest_record(&manifest, 4_096, segment_limits())
            .expect_err("mismatched segment ID");
        assert_eq!(mismatched.kind(), ErrorKind::CorruptData);

        fs::remove_file(path).expect("remove segment");
        let missing = repository
            .resolve_manifest_record(&manifest, 4_096, segment_limits())
            .expect_err("missing segment");
        assert_eq!(missing.kind(), ErrorKind::NotFound);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_blob_manifests() {
        use std::os::unix::fs::symlink;

        let temporary = TestDirectory::new();
        let root = temporary.path().join("repository");
        let repository = LocalRepository::create(&root).expect("create repository");
        let manifest = whole_blob_manifest(
            &repository,
            MANIFEST_ID_A.parse().expect("manifest ID"),
            SEGMENT_ID_A.parse().expect("segment ID"),
            b"body",
        );
        let replacement = temporary.path().join("replacement");
        fs::write(&replacement, manifest.encode()).expect("write replacement");
        symlink(&replacement, manifest_path(&root, manifest.manifest_id())).expect("link manifest");

        let error = repository
            .resolve_blob_manifest(manifest.git_object_id(), manifest_limits())
            .expect_err("symlink manifest");
        assert_eq!(error.kind(), ErrorKind::CorruptData);
    }

    #[test]
    fn local_repository_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_eq!(
            BlobManifestReadLimits::new(0, 1, 1)
                .expect_err("zero entry limit")
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            BlobManifestReadLimits::new(1, 0, 1)
                .expect_err("zero byte limit")
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            MetadataObjectManifestReadLimits::new(0, 1)
                .expect_err("zero byte limit")
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_send_sync::<LocalRepository>();
        assert_send_sync::<BlobManifestReadLimits>();
        assert_send_sync::<MetadataObjectManifestReadLimits>();
    }
}
