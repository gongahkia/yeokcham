//! Core types and repository logic for Yeokcham.

mod error;
mod git_object_id;
mod repository_id;
mod telemetry;

pub use error::{Error, ErrorKind, Result};
pub use git_object_id::GitObjectId;
pub use repository_id::RepositoryId;
pub use telemetry::{Redacted, redact};
