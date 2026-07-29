//! Core types and repository logic for Yeokcham.

mod error;
mod telemetry;

pub use error::{Error, ErrorKind, Result};
pub use telemetry::{Redacted, redact};
