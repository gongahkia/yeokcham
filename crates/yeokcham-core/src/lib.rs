//! Core types and repository logic for Yeokcham.

#![deny(missing_docs)]

mod blob_manifest;
mod canonical;
mod chunk_record;
mod chunked_blob_record;
mod compression;
mod content_defined_chunking;
mod device_id;
mod error;
mod git_object;
mod git_object_id;
mod git_repository;
mod manifest_id;
mod metadata_object_manifest;
mod metadata_object_record;
mod ref_name;
mod ref_snapshot;
mod repository;
mod repository_format;
mod repository_id;
mod segment_id;
mod segment_index;
mod segment_reader;
mod segment_writer;
mod telemetry;
mod tiny_blob_aggregation;
mod whole_blob_record;
mod yeokcham_content_id;

pub use blob_manifest::{BlobManifest, BlobManifestRepresentation, BlobStoragePolicyDecision};
pub use canonical::{CanonicalDecoder, CanonicalEncoder};
pub use chunk_record::ChunkRecord;
pub use chunked_blob_record::{ChunkReference, ChunkedBlobRecord};
pub use compression::{CompressionAlgorithm, CompressionCodec};
pub use content_defined_chunking::{
    ContentDefinedChunk, ContentDefinedChunker, ContentDefinedChunkingParameters,
};
pub use device_id::DeviceId;
pub use error::{Error, ErrorKind, Result};
pub use git_object::{GitObject, GitObjectKind};
pub use git_object_id::GitObjectId;
pub use git_repository::GitRepository;
pub use manifest_id::ManifestId;
pub use metadata_object_manifest::MetadataObjectManifest;
pub use metadata_object_record::MetadataObjectRecord;
pub use ref_name::RefName;
pub use ref_snapshot::{GitRefState, HeadState, RefSnapshot, RefSnapshotReadLimits};
pub use repository::{
    BlobManifestReadLimits, ChunkedBlobStorageLimits, GitImportLimits, GitImportReport,
    GitObjectMetadata, LocalRepository, LooseObjectExportLimits, LooseObjectExportReport,
    MetadataObjectManifestReadLimits, RefSnapshotPublicationLimits, RepositoryVerificationLimits,
    RepositoryVerificationReport,
};
pub use repository_format::{RepositoryFeatureFlags, RepositoryFormat, RepositoryFormatVersion};
pub use repository_id::RepositoryId;
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
pub use whole_blob_record::WholeBlobRecord;
pub use yeokcham_content_id::{ContentHashAlgorithm, YeokchamContentId};
