# ADR-069 — bounded local secure-runtime IPC contract

- Status: Superseded by ADR-073
- Date: 2026-08-13
- Superseded by: ADR-073
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#150](https://github.com/gongahkia/yeokcham/issues/150)
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#151](https://github.com/gongahkia/yeokcham/issues/151), [#195](https://github.com/gongahkia/yeokcham/issues/195), [#196](https://github.com/gongahkia/yeokcham/issues/196), and [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

Later V2 work needs an OCaml control plane to invoke a Rust secure runtime for
MLS, device-cryptography, and mesh work. Reusing repository frames would give
the runtime repository meaning and make version/error handling implicit. An
unbounded local stream would also allow malformed or stale traffic to consume
memory or be treated as a retryable operation.

## Decision

Define a version-1, local-stream protocol with a four-byte big-endian frame
length followed by one canonical CBOR item. A frame is at most 64 KiB and an
opaque operation payload is at most 48 KiB. The CBOR item is an exact,
re-encodable array:

```text
Frame_v1 = (frame-version, kind, body, mandatory-features)
Hello = (session-id, supported-versions, required-capabilities,
         optional-capabilities)
Hello_ack = (session-id, selected-version, selected-capabilities)
Request = (session-id, sequence, operation-kind, opaque-payload)
Response = (session-id, sequence, operation-kind, result-kind, opaque-payload)
```

`session-id` is a caller-created 32-byte random identity. The handshake chooses
the greatest common protocol version, requires every requested required
capability, and returns only a sorted subset of the caller's required/optional
capabilities. Both peers validate the acknowledgement before treating the
session as negotiated. V1 capabilities and operation kinds are the closed set
`MLS`, `device-crypto`, and `mesh`; unknown mandatory feature bits, versions,
kinds, duplicates, noncanonical CBOR, and values outside the bounds reject.

An in-memory runtime session records the next expected sequence number. A
request must use the negotiated session, its matching capability, and exactly
that next number. Unknown, restarted, duplicate, or gapped session traffic is
a typed refusal; a process restart deliberately drops all sessions rather than
inferring a retry. A response is valid only for the exact outstanding request's
session, sequence, and operation kind.

The wire carries an opaque byte payload and does not define repository IDs,
objects, refs, authority decisions, recovery secrets, root-key persistence, or
key derivation. It is neither encrypted nor a replacement for operating-system
peer authentication: a future owned Unix-socket listener must establish the
local endpoint and peer boundary explicitly. The protocol never persists a
frame, session, payload, or secret, and it creates no custom cryptography.

## Invariants

1. No message is processed before a mutually compatible handshake pins its
   session, version, and capability set.
2. Canonical bounded frames are the only accepted wire values; decoder or I/O
   failure yields no partial message.
3. A runtime restart invalidates every prior session and never replays an
   operation implicitly.
4. The contract exposes only operation categories plus opaque bytes; canonical
   repository semantics remain in OCaml-defined formats.
5. This contract provides no network transport, Unix-socket ownership,
   peer authentication, MLS implementation, key storage, or repository state.

## Verification

- Canonical Hello, acknowledgement, request, and response vectors decode and
  re-encode exactly.
- Unit/adversarial cases reject unknown features, incompatible capabilities,
  malformed/noncanonical/oversized frames, stale sessions, sequence gaps, and
  mismatched responses.
- A seeded property varies bounded opaque payloads, session IDs, capabilities,
  and operation kinds while proving one legal sequence advances exactly once
  and a duplicate is refused.
- Unix `socketpair` framing coverage proves exact request/response transport,
  truncation, and oversize failure. A restart test proves that an old request
  is refused until a new handshake establishes a new session.

## References

- [RFC 8949 — Concise Binary Object Representation](https://www.rfc-editor.org/rfc/rfc8949.html)
