//! Core types and repository logic for Yeokcham.

#![deny(missing_docs)]

mod backend;
mod backend_wrappers;
mod blob_manifest;
mod canonical;
mod chunk_record;
mod chunked_blob_record;
mod ciphertext_cache;
mod compression;
mod content_defined_chunking;
mod device_id;
mod device_registry;
mod encrypted_backend;
mod error;
mod filesystem_backend;
mod git_object;
mod git_object_id;
mod git_repository;
mod github_mirror;
mod google_drive_backend;
mod google_drive_credentials;
mod google_drive_oauth;
mod key_export;
mod manifest_id;
mod metadata_object_manifest;
mod metadata_object_record;
mod ref_event;
mod ref_name;
mod ref_snapshot;
mod remote_ref_journal;
mod repository;
mod repository_format;
mod repository_id;
mod repository_key;
mod segment_id;
mod segment_index;
mod segment_reader;
mod segment_writer;
mod telemetry;
mod tiny_blob_aggregation;
mod tiny_blob_group_manifest;
mod whole_blob_record;
mod yeokcham_content_id;

pub use backend::{
    Backend, BackendByteRange, BackendCursor, BackendFuture, BackendKey, BackendListEntry,
    BackendListLimits, BackendListPage, BackendObjectMetadata, BackendPrefix, BackendPutResult,
    BackendReadLimits, BackendReadRequest, BackendResumablePutStart, BackendUploadSession,
};
pub use backend_wrappers::{
    BackendMetrics, BackendOperation, BackendOperationMetrics, FaultInjectingBackend,
    MetricsBackend,
};
pub use blob_manifest::{BlobManifest, BlobManifestRepresentation, BlobStoragePolicyDecision};
pub use canonical::{CanonicalDecoder, CanonicalEncoder};
pub use chunk_record::ChunkRecord;
pub use chunked_blob_record::{ChunkReference, ChunkedBlobRecord};
pub use ciphertext_cache::{CachedBackend, CiphertextCache, CiphertextCacheMetrics};
pub use compression::{CompressionAlgorithm, CompressionCodec};
pub use content_defined_chunking::{
    ContentDefinedChunk, ContentDefinedChunker, ContentDefinedChunkingParameters,
};
pub use device_id::DeviceId;
pub use device_registry::{
    DeviceRegistration, DeviceRegistry, DeviceRegistryEvent, DeviceRegistryReadLimits,
};
pub use encrypted_backend::EncryptedBackend;
pub use error::{Error, ErrorKind, Result};
pub use filesystem_backend::FilesystemBackend;
pub use git_object::{GitObject, GitObjectKind};
pub use git_object_id::GitObjectId;
pub use git_repository::GitRepository;
pub use github_mirror::{
    GithubForceUpdatePolicy, GithubMirrorCheckpoint, GithubMirrorConfiguration,
    GithubMirrorDirection, GithubPublicationRule, GithubRepository,
};
pub use google_drive_backend::{
    DriveAccessTokenProvider, DriveBackend, DriveFolderId, DriveHttpMethod, DriveHttpRequest,
    DriveHttpResponse, DriveHttpTransport, DriveRetryPolicy, DriveSleeper,
    StoredDriveAccessTokenProvider, SystemDriveSleeper, UreqDriveHttpTransport,
};
pub use google_drive_credentials::{
    DriveCredentialStore, DriveStoredCredential, KeyringDriveCredentialStore,
};
pub use google_drive_oauth::{
    DRIVE_FILE_SCOPE, DriveAccessToken, DriveOAuthConfiguration, DriveOAuthHttpResponse,
    DriveOAuthLoopback, DriveOAuthToken, DriveOAuthTransport, UreqDriveOAuthTransport,
};
pub use key_export::RepositoryKeyExport;
pub use manifest_id::ManifestId;
pub use metadata_object_manifest::MetadataObjectManifest;
pub use metadata_object_record::MetadataObjectRecord;
pub use ref_event::{RefEvent, RefEventReadLimits, RefEventSigningKey, RefEventVerifyingKey};
pub use ref_name::RefName;
pub use ref_snapshot::{GitRefState, HeadState, RefSnapshot, RefSnapshotReadLimits};
pub use remote_ref_journal::{
    RemoteDeviceRegistry, RemoteRefJournal, RemoteRefJournalDivergence, RemoteRefJournalLimits,
    RemoteRefJournalReconciliation, fetch_remote_device_registry, fetch_remote_ref_journal,
    publish_device_registry_event, publish_remote_ref_event,
};
pub use repository::{
    BlobManifestReadLimits, ChunkedBlobStorageLimits, EncryptedRepositoryRecoveryLimits,
    EncryptedRepositoryRecoveryReport, GitImportLimits, GitImportReport, GitObjectMetadata,
    LocalRepository, LooseObjectExportLimits, LooseObjectExportReport,
    MetadataObjectManifestReadLimits, RefSnapshotPublicationLimits, RepositoryVerificationLimits,
    RepositoryVerificationReport,
};
pub use repository_format::{RepositoryFeatureFlags, RepositoryFormat, RepositoryFormatVersion};
pub use repository_id::RepositoryId;
pub use repository_key::{DriveObjectName, DriveObjectNamingKey, RepositoryEncryptionKey};
pub use segment_id::SegmentId;
pub use segment_index::{SegmentIndex, SegmentIndexEntry};
pub use segment_reader::{
    ReadSegment, ReadSegmentRecord, SegmentReadLimits, SegmentReader, SegmentRecordLocation,
};
pub use segment_writer::{
    SealedSegment, SegmentRecord, SegmentRecordKind, SegmentWriteLimits, SegmentWriter,
};
pub use telemetry::{Redacted, redact};
pub use tiny_blob_aggregation::{
    MAX_TINY_BLOB_AGGREGATION_ENTRIES, TinyBlobAggregation, TinyBlobEntry,
};
pub use tiny_blob_group_manifest::{TinyBlobGroupManifest, TinyBlobGroupManifestEntry};
pub use whole_blob_record::WholeBlobRecord;
pub use yeokcham_content_id::{ContentHashAlgorithm, YeokchamContentId};
