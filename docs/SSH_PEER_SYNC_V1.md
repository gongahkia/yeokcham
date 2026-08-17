# SSH peer-sync v1

This is the #239 vertical slice of the peer-sync milestone. It transports an
already-defined peer-sync graph over OpenSSH; it does not add a canonical
transport record, SSH host key, private key, socket, retry state, capsule,
workspace, release, conflict resolution, or working-tree mutation.

## Types

The noncanonical wire protocol has a bounded, canonical request containing the
configured remote repository root, pinned remote peer ID, local responder
identity, requested remote sync head, tracking name, and a fresh 32-byte
challenge. The response contains the remote Ed25519 session proof and the
physical object ID for the requested head. Both records are versioned and use
length-prefixed canonical CBOR frames.

The remote command is the fixed string `yeokcham peer sync ssh-serve`.
Untrusted endpoint root data travels in the first framed request, never in the
remote command string. The serving host reads its signing capability from
`<repository>/.yeokcham/bootstrap/peer-sync-ed25519`; it must be an
owner-readable regular 32-byte Ed25519 private-key file. Operators create it
explicitly with the existing `peer identity init --key` command. This file is
runtime capability data rather than a canonical repository object.

## Invariants

1. The SSH command line has a fixed remote command, no PTY or forwarding, batch
   mode, and `StrictHostKeyChecking=yes`; a caller supplies an explicit
   known-hosts file as noncanonical transport configuration.
2. The server signs a domain-separated session that binds the repository format,
   pinned remote identity, local responder identity, fresh challenge, requested
   head, and tracking name. The local peer verifies that proof before accepting
   any exchange frame.
3. The object exchange remains bounded and content-addressed. Before its
   tracking ref changes, the receiver reconstructs the requested graph from the
   received closure, verifies identities, signatures, causal parents, and every
   snapshot tree/content object.
4. A failed handshake, malformed frame, bad signature, wrong format, incomplete
   closure, SSH failure, or interrupted exchange does not advance a tracking
   ref and does not touch authoring, release, or working-tree state.

## Verification

The slice requires canonical-wire and negative protocol tests, failure tests
for the tracking boundary, and a two-repository OpenSSH fixture with an
explicit known-host entry and a forced static command. The fixture runs the
same Yeokcham executable on both sides. `make check` and the peer property
tests remain required before #239 closes.

## ADR impact

No ADR decision changes: this implements the transport-only SSH path already
chosen in ADR-078.
