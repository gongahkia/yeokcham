use crate::{CanonicalDecoder, CanonicalEncoder, Error, ErrorKind, Result};

const MAGIC: [u8; 4] = *b"YKDP";
const HEADER_BYTES: usize = 16;
const LENGTH_PREFIX_BYTES: usize = 4;
const REQUEST_DIRECTION: u8 = 1;
const RESPONSE_DIRECTION: u8 = 2;
const PING_TAG: u8 = 1;
const SHUTDOWN_TAG: u8 = 2;

/// The only supported local daemon wire-protocol version.
pub const DAEMON_PROTOCOL_VERSION: u16 = 1;

/// Maximum encoded daemon frame body length, excluding its four-byte length prefix.
pub const MAXIMUM_DAEMON_FRAME_BYTES: usize = 64 * 1024;

/// A V1 local-daemon control request.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum DaemonRequest {
    /// Checks that a daemon accepts the V1 protocol.
    Ping,
    /// Requests an orderly daemon shutdown.
    Shutdown,
}

/// A V1 local-daemon control response.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum DaemonResponse {
    /// Acknowledges a [`DaemonRequest::Ping`] request.
    Pong,
    /// Acknowledges a [`DaemonRequest::Shutdown`] request.
    ShutdownAccepted,
}

/// One direction-tagged local-daemon protocol message.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum DaemonMessage {
    /// A client-to-daemon message.
    Request(DaemonRequest),
    /// A daemon-to-client message.
    Response(DaemonResponse),
}

/// One length-prefixed, versioned local-daemon protocol frame.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct DaemonProtocolFrame {
    request_id: u64,
    message: DaemonMessage,
}

impl DaemonProtocolFrame {
    /// Builds one caller-correlated request frame.
    pub fn request(request_id: u64, request: DaemonRequest) -> Result<Self> {
        Self::new(request_id, DaemonMessage::Request(request))
    }

    /// Builds one request-correlated response frame.
    pub fn response(request_id: u64, response: DaemonResponse) -> Result<Self> {
        Self::new(request_id, DaemonMessage::Response(response))
    }

    /// Returns the nonzero client-chosen request correlation identifier.
    pub const fn request_id(self) -> u64 {
        self.request_id
    }

    /// Returns the direction-tagged control message.
    pub const fn message(self) -> DaemonMessage {
        self.message
    }

    /// Serializes one canonical length-prefixed V1 frame.
    pub fn encode(self) -> Vec<u8> {
        let mut body = CanonicalEncoder::new();
        body.write_fixed(&MAGIC);
        body.write_u16(DAEMON_PROTOCOL_VERSION);
        body.write_u8(self.message.direction_tag());
        body.write_u8(self.message.message_tag());
        body.write_u64(self.request_id);

        debug_assert_eq!(body.as_bytes().len(), HEADER_BYTES);
        let mut encoded = CanonicalEncoder::new();
        encoded.write_u32(body.as_bytes().len() as u32);
        encoded.write_fixed(body.as_bytes());
        encoded.into_bytes()
    }

    /// Decodes one complete, bounded, length-prefixed V1 frame.
    pub fn decode(encoded: &[u8]) -> Result<Self> {
        if encoded.len() > LENGTH_PREFIX_BYTES + MAXIMUM_DAEMON_FRAME_BYTES {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "daemon frame exceeds the maximum size",
            ));
        }

        let mut outer = CanonicalDecoder::new(encoded);
        let body_length = usize::try_from(outer.read_u32()?)
            .map_err(|_| Error::new(ErrorKind::CorruptData, "daemon frame length is invalid"))?;
        if !(HEADER_BYTES..=MAXIMUM_DAEMON_FRAME_BYTES).contains(&body_length) {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "daemon frame length is invalid",
            ));
        }
        let body = outer.read_raw_bytes(body_length)?;
        outer.finish()?;

        let mut decoder = CanonicalDecoder::new(body);
        if decoder.read_fixed::<4>()? != MAGIC {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "daemon frame has an invalid magic value",
            ));
        }
        if decoder.read_u16()? != DAEMON_PROTOCOL_VERSION {
            return Err(Error::new(
                ErrorKind::Unsupported,
                "daemon protocol version is unsupported",
            ));
        }
        let direction = decoder.read_u8()?;
        let message_tag = decoder.read_u8()?;
        let request_id = decoder.read_u64()?;
        decoder.finish()?;
        let message = DaemonMessage::from_tags(direction, message_tag)?;
        Self::new(request_id, message)
    }

    fn new(request_id: u64, message: DaemonMessage) -> Result<Self> {
        if request_id == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "daemon request identifier is invalid",
            ));
        }
        Ok(Self {
            request_id,
            message,
        })
    }
}

impl DaemonMessage {
    const fn direction_tag(self) -> u8 {
        match self {
            Self::Request(_) => REQUEST_DIRECTION,
            Self::Response(_) => RESPONSE_DIRECTION,
        }
    }

    const fn message_tag(self) -> u8 {
        match self {
            Self::Request(DaemonRequest::Ping) | Self::Response(DaemonResponse::Pong) => PING_TAG,
            Self::Request(DaemonRequest::Shutdown)
            | Self::Response(DaemonResponse::ShutdownAccepted) => SHUTDOWN_TAG,
        }
    }

    fn from_tags(direction: u8, message_tag: u8) -> Result<Self> {
        match (direction, message_tag) {
            (REQUEST_DIRECTION, PING_TAG) => Ok(Self::Request(DaemonRequest::Ping)),
            (REQUEST_DIRECTION, SHUTDOWN_TAG) => Ok(Self::Request(DaemonRequest::Shutdown)),
            (RESPONSE_DIRECTION, PING_TAG) => Ok(Self::Response(DaemonResponse::Pong)),
            (RESPONSE_DIRECTION, SHUTDOWN_TAG) => {
                Ok(Self::Response(DaemonResponse::ShutdownAccepted))
            }
            (REQUEST_DIRECTION | RESPONSE_DIRECTION, _) => Err(Error::new(
                ErrorKind::Unsupported,
                "daemon message is unsupported",
            )),
            _ => Err(Error::new(
                ErrorKind::CorruptData,
                "daemon frame direction is invalid",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_canonical_request_and_response_frames() {
        let request = DaemonProtocolFrame::request(7, DaemonRequest::Ping).expect("request");
        let response = DaemonProtocolFrame::response(7, DaemonResponse::Pong).expect("response");

        assert_eq!(
            request.encode(),
            [
                0,
                0,
                0,
                16,
                b'Y',
                b'K',
                b'D',
                b'P',
                0,
                1,
                REQUEST_DIRECTION,
                PING_TAG,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                7,
            ]
        );
        assert_eq!(
            DaemonProtocolFrame::decode(&request.encode()).expect("decode"),
            request
        );
        assert_eq!(
            DaemonProtocolFrame::decode(&response.encode()).expect("decode"),
            response
        );
    }

    #[test]
    fn rejects_invalid_identifiers_and_unrecognized_frames() {
        let zero = DaemonProtocolFrame::request(0, DaemonRequest::Ping)
            .expect_err("zero request identifier must fail");
        let mut invalid_direction = DaemonProtocolFrame::request(1, DaemonRequest::Ping)
            .expect("frame")
            .encode();
        invalid_direction[10] = 3;
        let direction = DaemonProtocolFrame::decode(&invalid_direction)
            .expect_err("invalid direction must fail");
        let mut unsupported_message = DaemonProtocolFrame::request(1, DaemonRequest::Ping)
            .expect("frame")
            .encode();
        unsupported_message[11] = 3;
        let message = DaemonProtocolFrame::decode(&unsupported_message)
            .expect_err("unsupported message must fail");

        assert_eq!(zero.kind(), ErrorKind::InvalidInput);
        assert_eq!(direction.kind(), ErrorKind::CorruptData);
        assert_eq!(message.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn rejects_malformed_oversized_and_unknown_version_frames() {
        let truncated =
            DaemonProtocolFrame::decode(&[0, 0, 0, 16]).expect_err("truncated frame must fail");
        let invalid_length =
            DaemonProtocolFrame::decode(&[0, 0, 0, 15]).expect_err("short body length must fail");
        let oversized = DaemonProtocolFrame::decode(&vec![0; MAXIMUM_DAEMON_FRAME_BYTES + 5])
            .expect_err("oversized frame must fail");
        let mut version = DaemonProtocolFrame::request(1, DaemonRequest::Ping)
            .expect("frame")
            .encode();
        version[8] = 2;
        let unsupported_version =
            DaemonProtocolFrame::decode(&version).expect_err("unknown version must fail");

        assert_eq!(truncated.kind(), ErrorKind::CorruptData);
        assert_eq!(invalid_length.kind(), ErrorKind::CorruptData);
        assert_eq!(oversized.kind(), ErrorKind::CorruptData);
        assert_eq!(unsupported_version.kind(), ErrorKind::Unsupported);
    }

    #[test]
    fn protocol_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<DaemonRequest>();
        assert_send_sync::<DaemonResponse>();
        assert_send_sync::<DaemonMessage>();
        assert_send_sync::<DaemonProtocolFrame>();
    }
}
