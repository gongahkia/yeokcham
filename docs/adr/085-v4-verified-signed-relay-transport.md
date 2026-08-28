# ADR-085 — V4 verified signed relay transport

- Status: Accepted
- Date: 2026-08-28
- Implements: GitHub issue #246 (`V4-TRANSPORT-001`)

## Context

V4 already exchanges a complete canonical directory package and verifies it in
staging before importing immutable objects or advancing the sole mutable state
head. Network transport must not create a second history format, turn a relay
into authority, or make an observed arrival look like user intent. Earlier
product-track peer protocols are retired with the V4-only cutover and are not a
compatibility target or implementation substrate.

## Current milestone and vertical slice

The current milestone is **V4 verified signed relay synchronization for
already-equivalent replicas**. This slice adds, in order: (1) a pure canonical
`transport-publication-v1` and feed validator; (2) a bounded bearer-authenticated
HTTP relay; (3) a client that obtains verified package closures from the relay;
and (4) local-only remote configuration, credential custody, and atomically
saved receipt/publication state.

The user surface is `remote add`, `remote remove`, `remote login`, and `sync`.
A relay listener binds only to an explicit local address; an operator terminates
HTTPS in a reverse proxy. Clients accept only `https://` URLs and use an
`Authorization: Bearer` credential retrieved from a platform credential
adapter.

## Decision

### Publication and feed types

`transport-publication-v1` is canonical CBOR. Its unsigned body contains the
V4 repository ID, publisher device ID, publisher certificate ID, canonical
sorted parent publication IDs from that publisher's feed, and the SHA-256 ID of
one canonical V4 package manifest. Its enclosing record adds an Ed25519
signature over the domain-separated unsigned bytes. The publication ID is the
SHA-256 digest of the complete canonical encoded record.

The invariants are:

- digest IDs are exactly 64 lowercase hexadecimal characters;
- parents are sorted, duplicate-free, non-self-referential, and from the same
  signed publisher feed;
- declared publication ID, route ID, and exact encoded bytes agree;
- the publisher device is the subject of the named certificate and is active in
  authority data carried by the referenced package closure; and
- a feed may fork. Discovery preserves every valid publication and never
  selects a head.

Publications are courier-integrity records only. They do not grant membership,
authorise revisions, resolve decisions, select authority, or create delivery.

### Relay, receipt, and state boundary

The relay has idempotent create-only routes for immutable snapshot/object
envelopes, package manifests, and publications, plus paginated publication
discovery. Every route validates its fixed-format SHA-256 ID and recomputes the
digest of submitted bytes. It stores bytes only; its listings are untrusted.
The relay may read stored payloads and is not end-to-end encrypted.

Transport fetches a publication, manifest, and complete declared object list
into a temporary package directory. It delegates canonical manifest, authority
closure, revision signature, causal-parent, exact snapshot/object closure,
late-adoption, and model-transition checks to the existing package verifier.
Package verification is neither duplicated nor relaxed.

The client verifies an entire discovered batch before importing a destination
object or publishing a project-state update. A late record is placed in a local
review inbox only when the whole batch otherwise validates; it is not imported.
A valid batch atomically publishes V4 state with its cursor, seen-publication
IDs, announced artifact IDs, and inbox references through the existing
compare-and-swap head.

`sync NAME` receives first. After receipt is durable it creates a delta package
for locally unannounced signed work, uploads object closure then manifest then
signed publication, and marks it announced only after acknowledgement. Upload
failure is reported as partial success: received work stays local and the next
sync retries idempotently. There is no cross-machine atomicity claim.

Remote aliases/URLs and bearer credentials are local configuration and
credential-store data. They are not signed, packaged, a trust root, or part of
the V4 collaboration model. Test-only credential injection requires an
explicit test switch and is unavailable in normal production invocation.

## Persistent-format impact

`transport-publication-v1` and transport-local state are independently
versioned canonical CBOR. Collaborative-state version 3 appends its local
transport section to version 2; version 1 and version 2 fixtures remain
decodable and re-save as version 3 with empty transport state. No package
exports this section and no only copy is mutated in place.

## Non-goals

Clone/bootstrap, Git protocol compatibility, HTTP/TLS termination by the relay
process, end-to-end payload encryption, relay-side authorisation policy, online
authority consensus, automatic merge, daemon scheduling, delivery/CI
integration, and working-tree mutation are out of scope.

## Verification

- golden/inverse/canonical-ID/signature/parent/publisher-certificate/feed-fork
  tests plus generated feed validation;
- relay bounds, digest, authentication, idempotency, pagination, and no
  overwrite tests;
- two-replica receive-first tests for signed revisions and resolutions,
  decisions, feed forks, late-review inboxes, retries, and no tree mutation;
- corrupt, incomplete, wrong-repository, wrong-route, causal-failure, and
  post-receive upload-interruption tests;
- retained V1/V2 and a new V3 state fixture; and
- `opam exec -- dune build @all` and `opam exec -- dune runtest`.

## References

- [RFC 8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2)
- [RFC 9110 §13](https://www.rfc-editor.org/rfc/rfc9110.html#section-13)
- [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html)
- [RFC 8032 §8.3](https://www.rfc-editor.org/rfc/rfc8032.html#section-8.3)
