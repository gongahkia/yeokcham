//! Core types and repository logic for Yeokcham.

#![deny(missing_docs)]

mod canonical;
mod device_id;
mod error;
mod git_object;
mod git_object_id;
mod git_repository;
mod manifest_id;
mod ref_name;
mod repository;
mod repository_format;
mod repository_id;
mod segment_id;
mod telemetry;
mod tiny_blob_aggregation;
mod whole_blob_record;
mod yeokcham_content_id;

pub use canonical::{CanonicalDecoder, CanonicalEncoder};
pub use device_id::DeviceId;
pub use error::{Error, ErrorKind, Result};
pub use git_object::{GitObject, GitObjectKind};
pub use git_object_id::GitObjectId;
pub use git_repository::GitRepository;
pub use manifest_id::ManifestId;
pub use ref_name::RefName;
pub use repository::{GitObjectMetadata, LocalRepository};
pub use repository_format::{RepositoryFeatureFlags, RepositoryFormat, RepositoryFormatVersion};
pub use repository_id::RepositoryId;
pub use segment_id::SegmentId;
pub use telemetry::{Redacted, redact};
pub use tiny_blob_aggregation::{
    MAX_TINY_BLOB_AGGREGATION_ENTRIES, TinyBlobAggregation, TinyBlobEntry,
};
pub use whole_blob_record::WholeBlobRecord;
pub use yeokcham_content_id::{ContentHashAlgorithm, YeokchamContentId};
