# Relay peer sync v1

Relay v1 is the filesystem-mailbox transport for the existing authenticated
peer-sync graph. It is current V3 work under issue #240 and implements no
capsule, workspace, release, scratch, or working-tree operation.

## Vertical slice

The slice publishes a signed immutable closure for one pinned destination,
lists signed current advertisements without trusting them, and imports a
matching package only through an existing pinned contact. The command surface
is `peer contact add ... --relay`, `peer relay publish`, `peer relay discover`,
and `peer sync relay`.

## Types and wire records

`Relay_package_v1` is canonical CBOR with these domain-separated signed bytes:

```text
[version, "yeokcham:peer-sync:relay-package:v1", repository-format-digest,
 sender-peer-identity, destination-peer-id, tracking-name, sync-head,
 head-object, issued-at, expires-at, nonce, sorted-[object-id, envelope-bytes]]
```

Its outer record adds the `ed25519` algorithm marker and a 64-byte signature.
The mailbox filename is a SHA-256 domain-separated digest of those exact outer
bytes. Every object ID is rechecked against its canonical Envelope-1 bytes
before it can enter staging.

`Relay_advertisement_v1` is a separate signed canonical CBOR record. It binds
the same repository-format digest, sender/destination identities, package ID,
tracking name, head, issued/expiry times, and nonce. Advertisements have at
most a seven-day lifetime and a five-minute future-clock allowance. Static
fixtures are [the package](../test/golden/peer-sync-relay-v1.package.hex) and
[the advertisement](../test/golden/peer-sync-relay-v1.advertisement.hex).

The mailbox layout is runtime data:

```text
<relay>/mailboxes/<destination-peer-id-hex>/<package-id-hex>.package
<relay>/mailboxes/<destination-peer-id-hex>/<package-id-hex>.advertisement
<relay>/mailboxes/<destination-peer-id-hex>/<package-id-hex>.receipt
```

Packages are written, fsynced, and hard-linked into their final name before
the advertisement is atomically published. A package without its advertisement
is therefore not discoverable or importable. An exact publication retry
recognizes the existing bytes; different bytes at the same final path fail.
Receipts are noncanonical replay markers written only after tracking advances.

## Invariants

- A relay path must be explicitly configured as an absolute `Relay` endpoint
  on the pinned contact. Listing does not create contacts, modify a public-key
  pin, write an object, or change tracking.
- Decoder, domain, algorithm, repository-format, signature, expiry, object-ID,
  and strict ordering checks happen before any destination object is written.
- Each accepted package is first written and validated in a temporary staging
  repository. Only a verified causal graph and byte-exact snapshot closure is
  copied to the destination; then only that contact's tracking ref may advance.
- Package corruption, an incomplete publication, a wrong destination, an
  unknown signer, a stale item, a bad signature, or a replay leaves tracking
  unchanged. Immutable object writes are not authoring/release refs and never
  materialise a worktree.

## Tests

`test_peer_sync_relay` covers discovery isolation, atomic/retry publication,
two-repository import, staging on corruption, untrusted signatures, replay,
and incomplete files. Its fixtures verify inverse canonical decoders and an
unknown top-level package version. `peer_sync_relay_property_test` adds
generated nonce/tracking canonical round trips. The aggregate check is
`make check`; the shared local runtime falls back to a short private socket
directory when a requested runtime path exceeds the platform Unix-socket bound.

## ADR impact

No ADR change is required. ADR-078 already specifies an untrusted filesystem
relay with pinned contacts as the only trust authority; this slice supplies its
v1 runtime format without adding a canonical relay record.
