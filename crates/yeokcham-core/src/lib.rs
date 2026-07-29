//! Core types and repository logic for Yeokcham.

mod error;
mod repository_id;
mod telemetry;

pub use error::{Error, ErrorKind, Result};
pub use repository_id::RepositoryId;
pub use telemetry::{Redacted, redact};
