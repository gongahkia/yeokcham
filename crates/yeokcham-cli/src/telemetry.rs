use std::env;
use std::io;

use tracing_subscriber::EnvFilter;
use yeokcham_core::{Error, ErrorKind, Result};

pub(crate) fn init() -> Result<()> {
    let directives = match env::var("YEOKCHAM_LOG") {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => "warn".to_owned(),
        Err(env::VarError::NotUnicode(_)) => {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "YEOKCHAM_LOG is not valid Unicode",
            ));
        }
    };
    let filter = EnvFilter::try_new(directives).map_err(|source| {
        Error::with_source(
            ErrorKind::InvalidInput,
            "invalid YEOKCHAM_LOG filter",
            source,
        )
    })?;
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(false)
        .with_target(true)
        .with_writer(io::stderr)
        .try_init()
        .map_err(|source| {
            Error::with_boxed_source(ErrorKind::Internal, "failed to initialize tracing", source)
        })
}
