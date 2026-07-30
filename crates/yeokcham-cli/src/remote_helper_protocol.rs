use std::io::Read;

use yeokcham_core::{Error, ErrorKind, Result};

/// Maximum bytes accepted before the newline terminating one helper command.
pub const MAXIMUM_COMMAND_BYTES: usize = 8 * 1024;

/// The supported subset of the Git remote-helper command stream.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteHelperCommand {
    /// Ask the helper for its supported capabilities.
    Capabilities,
    /// Connect Git directly to the upload-pack service.
    ConnectUploadPack,
    /// End the command stream.
    End,
}

/// Reads one newline-terminated, caller-bounded helper command.
///
/// Empty input returns `Ok(None)`. EOF after any command byte is corrupt;
/// commands longer than [`MAXIMUM_COMMAND_BYTES`] are unsupported.
pub fn read_command_line(input: &mut impl Read) -> Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match input.read(&mut byte).map_err(|error| {
            Error::with_source(
                ErrorKind::Io,
                "remote-helper command stream could not be read",
                error,
            )
        })? {
            0 if line.is_empty() => return Ok(None),
            0 => {
                return Err(Error::new(
                    ErrorKind::CorruptData,
                    "remote-helper command stream is truncated",
                ));
            }
            _ if byte[0] == b'\n' => return Ok(Some(line)),
            _ if line.len() == MAXIMUM_COMMAND_BYTES => {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "remote-helper command exceeds the byte limit",
                ));
            }
            _ => line.push(byte[0]),
        }
    }
}

/// Parses one complete helper command without normalizing or logging it.
pub fn parse_command(line: &[u8]) -> Result<RemoteHelperCommand> {
    if line.is_empty() {
        return Ok(RemoteHelperCommand::End);
    }
    if line == b"capabilities" {
        return Ok(RemoteHelperCommand::Capabilities);
    }
    if line == b"connect git-upload-pack" {
        return Ok(RemoteHelperCommand::ConnectUploadPack);
    }
    if line.starts_with(b"connect ") {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "remote helper only supports git-upload-pack",
        ));
    }
    Err(Error::new(
        ErrorKind::Unsupported,
        "remote-helper command is unsupported",
    ))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn parses_the_supported_command_subset() {
        assert_eq!(
            parse_command(b"capabilities").expect("capabilities"),
            RemoteHelperCommand::Capabilities
        );
        assert_eq!(
            parse_command(b"connect git-upload-pack").expect("connect"),
            RemoteHelperCommand::ConnectUploadPack
        );
        assert_eq!(parse_command(b"").expect("end"), RemoteHelperCommand::End);
        assert_eq!(
            parse_command(b"connect git-receive-pack")
                .expect_err("receive-pack is deferred")
                .kind(),
            ErrorKind::Unsupported
        );
        assert_eq!(
            parse_command(b"fetch 0000000000000000000000000000000000000000 refs/heads/main")
                .expect_err("fetch must use the upload-pack connection")
                .kind(),
            ErrorKind::Unsupported
        );
    }

    #[test]
    fn bounds_and_validates_command_lines() {
        let mut empty = Cursor::new(Vec::<u8>::new());
        assert_eq!(read_command_line(&mut empty).expect("empty stream"), None);

        let mut complete = Cursor::new(b"capabilities\n".to_vec());
        assert_eq!(
            read_command_line(&mut complete).expect("complete command"),
            Some(b"capabilities".to_vec())
        );

        let mut truncated = Cursor::new(b"capabilities".to_vec());
        assert_eq!(
            read_command_line(&mut truncated)
                .expect_err("missing newline")
                .kind(),
            ErrorKind::CorruptData
        );

        let mut oversized = Cursor::new(vec![b'x'; MAXIMUM_COMMAND_BYTES + 1]);
        assert_eq!(
            read_command_line(&mut oversized)
                .expect_err("oversized command")
                .kind(),
            ErrorKind::Unsupported
        );
    }
}
