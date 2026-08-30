# ADR-094 — V4 private relay payloads

- Status: Accepted — implementation gated on a vetted HPKE dependency
- Date: 2026-08-30
- Specifies: GitHub issue #257 (`V4-TRANSPORT-ENCRYPTION-001`)

## Context

ADR-085 deliberately made the relay an untrusted integrity-only courier. It
can store and read a signed publication, package manifest, and object closure;
the client verifies those bytes before receipt. TLS protects the connection to
the relay but does not prevent the relay from reading its stored payloads.

V4 now needs a privacy boundary without turning encryption into authority,
membership, intent, a clone protocol, or a new history graph. In particular,
the design must not expose the publisher, certificate, package/object IDs, or
feed parents to the relay; it must preserve feed forks and the existing staged,
atomic, no-working-tree receipt boundary.

The current OCaml dependency set has X25519 and AEAD primitives but no vetted
HPKE package. The public OCaml HPKE candidate available at this decision's date
states that it is not production-ready and has not received an independent
cryptographic audit. V4 does not implement HPKE from low-level primitives as a
substitute. This ADR is consequently a complete protocol decision and test
contract, not evidence that current relay payloads are encrypted.

## Decision

### Trust and privacy boundary

The relay continues to authenticate repository-scoped read/write access under
ADR-087 and to store immutable bytes under ADR-085. Those credentials are not
encryption keys and encryption does not grant repository access or authority.

For an encrypted remote, the relay may observe only its repository routing
identifier, opaque parcel IDs, byte sizes, recipient-envelope count as implied
by byte size, and request timing. It must not receive plaintext source bytes,
package manifests, object IDs, publisher device IDs, certificate IDs, feed
parents, signed publication bytes, or encryption-key records. Traffic-analysis
resistance, anonymous access, and hiding the existence of a repository are not
claimed.

Existing `transport-publication-v1` history and endpoints remain plaintext.
V4 must not silently rewrite, migrate, or call that history encrypted. A person
explicitly enables a new encrypted remote and creates an encrypted bootstrap to
share selected prior history with a new or replacement device. The original
plaintext relay bytes remain visible until the relay operator removes them
under its own storage policy.

### Sealed transport records

The future encrypted relay surface stores only immutable
`transport-sealed-parcel-v1` records. A parcel's SHA-256 ID is the digest of
its complete canonical CBOR bytes and is the only parcel ID accepted by the
relay route. The record has these fields, in this canonical order:

1. schema version `1`;
2. the visible relay routing identifier;
3. a fresh, uniformly random 32-byte parcel identifier;
4. a fresh 96-bit payload nonce;
5. a sorted, duplicate-free list of anonymous recipient envelopes; and
6. the payload ciphertext and 16-byte authentication tag.

The clear header is the first four fields. It is canonical CBOR and is the
associated data for both the payload AEAD and every recipient envelope. A
receiver rejects an unsupported version, noncanonical encoding, empty or
oversized field, malformed routing identifier, duplicate envelope, more than
64 envelopes, or a route that differs from the clear routing identifier before
any state import.

The sender creates one fresh random 32-byte content key and encrypts the
canonical `transport-sealed-content-v1` bytes with ChaCha20-Poly1305 and the
fresh 96-bit nonce. A content key is used for one parcel only; the nonce is
therefore never reused with the same content key. A recipient envelope contains
only an RFC 9180 Base-mode encapsulated key and ciphertext that seal that
content key. It contains no recipient handle, device ID, certificate ID, or key
generation. Envelope order is the lexicographic order of their complete
canonical bytes.

The fixed HPKE suite is DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, and
ChaCha20-Poly1305. The `info` value is the ASCII domain separation label
`yeokcham/v4/transport-sealed-parcel/recipient-key/v1`; the associated data is
the exact clear-header bytes. The payload uses the same exact header bytes as
associated data. Receivers use one local private key to try envelopes in their
canonical order and normalize all peer-controlled decapsulation and payload
authentication failures to an opaque receipt failure. A successful envelope is
not sufficient: the decrypted content must pass every ordinary V4 validation.

`transport-sealed-content-v1` is canonical CBOR with a schema version,
repository ID, a content kind, and its canonical body. A `publication` body
contains exact signed `transport-publication-v1` bytes and the complete exact
V4 package artifact (manifest bytes plus sorted object ID/bytes). A
`key-directory` body contains a sorted, duplicate-free list of
`transport-key-record-v1` bytes and no publication or package. No semantic
sidecar replaces canonical source or object bytes.

`transport-key-record-v1` contains a schema version, repository ID, device ID,
monotonically increasing key generation, 32-byte X25519 public key, and the
device's Ed25519 signature over the domain-separated preceding fields. It is
private payload data, not an authority certificate, membership grant, recovery
record, signing capability, or project transition. A receiver accepts it only
when its device ID matches the signer, its signing certificate is active in a
locally verified authority epoch, its repository matches, and its generation
is newer than the locally accepted record for that device. Older and duplicate
records are harmless replay inputs, not a reason to roll a key back.

### Key distribution, rotation, and recovery

Every device has a separate locally held X25519 transport private key. It is
not an Ed25519 signing key conversion and it never enters authority, packages,
bootstrap bases, local custody profiles, diagnostics, or the working tree.

Offline enrollment carries the enrolling device's signed transport-key record
to the enrolling administrator. After independently verifying the enrollment,
an active member creates a key-directory parcel addressed to every currently
active device, including the new device. A sender may publish ordinary private
work only when it has one current validated transport public key for every
currently active device; absence or staleness is an explicit upload refusal,
never silent recipient omission.

A device changes its transport key by issuing a higher signed key generation.
The new record is distributed first; later parcels use the newest accepted key.
Replacing a device remains the existing authority rotation process, followed
by an explicit key-directory parcel and, when historical sharing is wanted, an
explicit encrypted bootstrap. Recovery material does not recover, derive, or
re-wrap an old transport private key. A person who has lost that key can only
receive history that an active sender deliberately includes in a new bootstrap.

### Relay and receipt boundary

The future relay adds create-only sealed-parcel storage and paginated parcel
listing below the existing repository route. It does not parse, authorize from,
index, or generate encrypted contents. It may reject malformed outer route and
digest values exactly as it rejects existing immutable routes; its listing
remains an untrusted hint.

Receipt stages an entire sealed parcel before changing state. It checks outer
canonical bytes and route binding, opens one anonymous recipient envelope,
authenticates and decodes the payload, then delegates exact package, signed
publication, authority, signature, causal-parent, late-adoption, and model
validation to the existing verifier. A key-directory receipt validates and
atomically records only private local transport-directory state; it has no
project-model, authority, object-store, or working-tree transition. A valid
publication receipt reuses the existing atomic package/state/cursor path.

No ciphertext or successful decryption is an acceptance, delivery, authority,
membership, review, or conflict-resolution event. Feed forks remain preserved
inside the signed publication data. Replay is idempotent only after a complete
validated receipt has recorded the parcel and its inner publication or key
generation; an interrupted, failed, malformed, wrong-route, wrong-key, or
causally incomplete parcel records nothing.

## Invariants

1. At most 64 active recipient envelopes are present in one parcel, and no
   envelope identifies its recipient in outer bytes.
2. The payload's route, schema, parcel identifier, and nonce are authenticated
   as associated data; altered protected fields or ciphertext cannot produce a
   valid payload.
3. The relay is neither an encryption-key directory nor an authority input.
   Only inner device signatures plus locally verified authority establish a
   usable recipient key.
4. An active device without a current key record blocks private upload rather
   than being excluded. Revoked devices receive no future parcel.
5. Receipt never imports an object, advances project or transport state, or
   materialises the working tree until outer, decryption, canonical, package,
   authority, and causal checks succeed for the complete staged batch.
6. Existing plaintext relay records remain distinguishable and are never
   presented as private transport.

## Persistent-format and implementation gate

No released persistent bytes, relay route, local state, CLI, or test fixture is
changed by this ADR. The new records are future version-1 records alongside,
not migrations of, the final existing V4 formats.

Before code is accepted, the project must select and pin a maintained OCaml
HPKE dependency that supports the fixed suite, publishes RFC 9180 vector
results, has a documented security process, and has completed an independent
cryptographic audit. The dependency review must record version, provenance,
license, supported algorithms, audit reference, vulnerability-response policy,
and the result of reproducing its pinned official vectors. If any criterion is
missing, V4 keeps this ADR but does not ship encryption code or make an
end-to-end-encryption claim.

## Required verification before #257 can close

- Pin and reproduce RFC 9180 vectors for the exact suite, then add V4 canonical
  golden and inverse fixtures for every sealed record and key record.
- Property-test canonical ordering, parcel identity, key-generation monotonicity,
  the 64-recipient bound, and absence of known device/certificate identifiers
  in outer parcel bytes.
- Exercise two-replica ordinary receipt, offline-enrolled key registration,
  explicit encrypted bootstrap, key rotation, replacement, replay, retry, and
  feed-fork receipt without any working-tree mutation.
- Attack the full listener and receipt path with wrong keys, altered header,
  nonce, recipient envelope, ciphertext, digest, route, repository, version,
  canonical bytes, signature, authority, key generation, package closure, and
  causal parent. Each failure must prove unchanged destination objects,
  project-state head, transport state, cursor, and working tree.
- Demonstrate that relay listings and stored bytes expose only the declared
  outer metadata and cannot be used as authority, recipient selection, or
  acceptance evidence.
- Run `opam exec -- dune build @all` and `opam exec -- dune runtest` with the
  vetted dependency and all new fixtures enabled.

## Non-goals

This is not encrypted transport implementation, an anonymity system, traffic
padding, searchable encryption, general clone, automatic re-encryption of old
relay history, automatic recipient recovery, sender authentication supplied by
HPKE, relay-side key management, online authority coordination, semantic
inspection, or a change to the scratch/change/decision/delivery model.

## References

- [RFC 9180 — Hybrid Public Key Encryption](https://www.rfc-editor.org/rfc/rfc9180.html)
- [RFC 5116 — Authenticated Encryption with Associated Data](https://www.rfc-editor.org/rfc/rfc5116.html)
- [RFC 8439 — ChaCha20 and Poly1305](https://www.rfc-editor.org/rfc/rfc8439.html)
- [ocaml-hpke security status](https://github.com/thevilledev/ocaml-hpke/blob/main/SECURITY.md)
