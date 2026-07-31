# Local daemon protocol V1

The local daemon protocol is a binary request/response protocol. V1 is for a per-user Unix-domain stream listener only; it is not a network protocol and provides no authentication.

## Frame

Every complete frame is exactly:

| Bytes | Field | Encoding |
| --- | --- | --- |
| 4 | body length | unsigned big-endian `u32`; excludes this prefix; 16 through 65,536 inclusive |
| 4 | magic | ASCII `YKDP` |
| 2 | protocol version | unsigned big-endian `u16`; exactly `1` |
| 1 | direction | `1` request, `2` response |
| 1 | message | see below |
| 8 | request ID | nonzero unsigned big-endian `u64` |

The V1 body is always 16 bytes. A stream implementation reads the length prefix, rejects a value outside the stated bound before allocating, then reads exactly that many body bytes. Extra bytes are the next frame, never part of the current frame.

## Messages

| Direction | Tag | Meaning | Required response |
| --- | --- | --- | --- |
| request | `1` | `ping` | `pong` with the same request ID |
| response | `1` | `pong` | response to `ping` |
| request | `2` | `shutdown` | `shutdown-accepted` with the same request ID |
| response | `2` | `shutdown-accepted` | response to `shutdown`; listener then begins orderly shutdown |

Clients choose unique nonzero request IDs for concurrent requests. A daemon sends one response per accepted request and must echo its ID. It closes the connection on malformed frames; it does not echo payload bytes or parser details.

## Compatibility and limits

V1 rejects unknown magic, versions, directions, tags, zero request IDs, short frames, mismatched lengths, and frame bodies larger than 64 KiB. Any command that needs path, repository, cache, or operational data requires a later documented version or compatible extension; V1 does not reinterpret unknown bytes.

The Rust codec is `yeokcham_core::{DaemonProtocolFrame, DaemonRequest, DaemonResponse}`. It is transport-neutral so it can be tested independently of the Unix listener.
