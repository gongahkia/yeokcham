# ADR-099 — V2 compressed and resumable relay transfer

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: TRANSPORT-002

## Context

V4's V1 relay stores and transfers canonical immutable object bytes, but a
failed transfer restarts the whole object. That is poor operational behaviour
for large snapshot closures and does not let a receiver state exactly which
objects it still needs. Any improvement must preserve the receipt boundary:
relay transfer is byte courier work, not authority selection, project-model
mutation, revision creation, or working-tree materialisation.

## Current milestone and vertical slice

TRANSPORT-002 adds a relay-only V2 protocol alongside V1. Its pure types are
`Capability`, `Object_offer`, `Missing_set`, `Range`, `Segment`,
`Transfer_session`, `Session_progress`, and classified `Transfer_error`.
They plan one object's raw ranges, validate monotonic segment progress, and
decide completion without filesystem, socket, or credential-secret access.

The persistent adapter is a versioned canonical local relay-session record and
a scoped temporary raw-byte file. V2 endpoints negotiate a capability document,
create or resume an upload session, accept independently zstd-compressed raw
ranges, and download only complete immutable objects. Client receipt still
stages and verifies complete raw objects through the existing package/receipt
boundary; it never scans or writes ordinary source paths.

## Decision

### Raw identity and wire encoding

An object ID always identifies its existing, canonical uncompressed bytes.
Neither compressed frames nor a transfer session are V4 objects, package data,
feed entries, bootstrap data, model state, or authority input. V2 divides an
offered raw byte string into contiguous 1 MiB ranges, except for the final
short range. Each range is compressed separately into exactly one zstd frame.
The sender and receiver validate the claimed raw offset and raw length before
any temporary-file write; the receiver accepts decoded output only when it is
exactly the claimed range length and no larger than the configured
decompression budget. This prohibits frame-size or expansion claims from
driving allocation.

V2 capability negotiation names protocol version 2, zstd support, the maximum
segment size, maximum in-flight segments, and the receiver's canonical sorted
missing object IDs. The intersection takes the lower supported size/count and
requires both sides' zstd support. A mismatch, malformed capability, range,
frame, canonical-byte, or identity failure is terminal and is never retried.

### Sessions, quotas, and recovery

An upload session is bound to project ID, immutable object ID, raw total size,
credential safe ID (never its bearer secret), requested scope, expiry, fixed
segment ranges, and a segment bitmap. The relay creates its scoped temporary
file with exclusive permissions and persists each accepted bitmap transition
atomically. Duplicate receipt of an identical already-complete segment is
idempotent; overlap, a changed duplicate, a gap at completion, expired session,
quota excess, bad scope, and malformed records are typed refusals.

Session temporary bytes are bounded by a per-project quota and live sessions
by a per-credential cap. Explicit cleanup reports counts/bytes by project and
safe credential ID only; it removes expired session metadata and temporary
files, never immutable published objects. Restart recovery reloads only
canonical complete session records. It may resume incomplete sessions, but it
cannot publish them.

When all ranges are complete, the relay rereads the full temporary raw object,
checks the canonical envelope and raw object ID, and then performs one existing
immutable create-only publish. It records completion only after that publish.
Downloads use an independently staged temporary file and make no V4-store
write until all frames/ranges and the final raw identity validate.

### Retry and concurrency

The client defaults to four in-flight segments and accepts only 1 through 8.
It makes at most four total attempts for a transient transport failure or HTTP
5xx, with bounded delays of 250 ms, 1 s, 4 s, and 10 s. Authentication,
authorisation, capability, range, compression/decompression, canonical-byte,
identity, quota, and all other 4xx/protocol failures are non-retryable. V1
routes and behaviour remain isolated and available during development; V2
fallback is explicit when capability negotiation shows V2 unavailable.

### zstd binding and packaging

V2 uses opam package `zstd` version 0.4, a BSD-3-Clause binding whose release
archive has a pinned SHA-256 in the opam repository. It depends on `conf-zstd`,
which checks `pkg-config libzstd >= 1.3.8`. This choice avoids the alternative
`zstandard` package's Jane Street Core/PPX dependency and Linux-only
availability, while remaining compatible with the project's OCaml 5.5 source
build. Fedora 43 supplies the required development metadata as
`libzstd-devel`; development and RPM source builds must declare that build
requirement, while a dynamically linked runtime needs `libzstd`. The project
pins the opam binding version and preserves the generated opam lock evidence;
the system library remains an explicit distribution prerequisite rather than a
vendored persistent format dependency.

Per-frame decompression always uses the negotiated raw range length as an
application allocation ceiling, validates exact output length, and rejects
unknown/invalid frames. No dictionary or streaming frame spans ranges, so a
range can resume independently and zstd use has no effect on canonical bytes
or object IDs.

## Invariants and verification

- ranges cover `[0, raw_total_size)` without overlap; the only short range is
  final;
- session bitmap progress is monotonic and duplicates are idempotent;
- a session cannot publish before every range and final raw envelope/ID check;
- immutable relay objects are never changed by session cleanup or failure;
- receive, sync, bootstrap, relay, verification, and repair paths keep ordinary
  source files unchanged; and
- V1 regression, V2 capability, bounded retry, quota, expiry, restart,
  decompression corruption/expansion, and incomplete-object tests are required
  before the milestone is complete.

The evidence plan includes golden canonical capability/session bytes,
property/fuzz-style segment-order cases, HTTPS interrupted transfer journeys,
and a documented scaled benchmark if the 5 GiB/100,000-path target is not
practical on the available host. Measurements state hardware, network, CPU,
memory, wall time, wire bytes, and resume work avoided; they make no
cross-system performance claim.

## References

- [opam `zstd` 0.4 package](https://opam.ocaml.org/packages/zstd/)
- [opam `conf-zstd` package definition](https://github.com/ocaml/opam-repository/tree/master/packages/conf-zstd)
- [Zstandard manual: bounded decompression and frame headers](https://facebook.github.io/zstd/zstd_manual.html)
- [Zstandard source license](https://github.com/facebook/zstd/blob/dev/LICENSE)
- [RFC 8878: Zstandard Compression and the application/zstd media type](https://www.rfc-editor.org/rfc/rfc8878.html)
