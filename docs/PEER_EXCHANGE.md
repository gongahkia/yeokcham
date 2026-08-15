# Peer exchange

## Scope

Yeokcham’s V3 peer exchange sends selected native work directly between two
repositories without requiring Git, a hosted service, an account, or a daemon.
It is implemented by `yeokcham_peer` under
[ADR-077](adr/077-peer-publication-projections-and-explicit-integration.md).
This is a proposal transport, not a clone, branch/ref synchronisation protocol,
or automatic history-reconciliation system.

## Publication projection

`peer publish capsule` first verifies the selected native capsule revision.
`peer publish release` first verifies the native release. Either command creates
and binds a canonical `Peer_publication_v1` record under
`refs/peer-publications/<publication-id>`.

A capsule projection records source capsule/revision IDs, source title and
description, and the revision's declared-base/result snapshots. A release
projection records the source release ID, message/timestamp metadata, and
base/final snapshots. These source IDs are provenance only: they are not local
capsule or release identities at the receiver.

The publication records the exact sorted, duplicate-free closure of its named
snapshots. The closure may contain only Snapshot, Tree, Content, File_manifest,
and Chunk Envelope records. It cannot contain scratch checkpoints/events,
capsules, releases, workspaces, validation evidence, mutable refs, or another
peer record. The receiver recomputes that closure from the received snapshots
before making its binding visible.

## Transfer

For a local transfer, the caller selects both repository roots:

```sh
yeokcham peer fetch --from /absolute/source --publication <publication-id>
```

For SSH, the caller names a constrained SSH target and an absolute remote root:

```sh
yeokcham peer fetch --ssh user@example.test --remote-root /srv/yeokcham \
  --publication <publication-id>
```

The SSH client launches one non-interactive direct command equivalent to:

```text
ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ClearAllForwardings=yes -- \
  user@example.test "yeokcham peer --root /srv/yeokcham serve --publication <publication-id>"
```

The remote executable’s `peer serve` command speaks the same bounded
ADR-038-style immutable exchange frames over standard input/output. The peer
adapter inventories the publication object plus closure and sends only objects
the destination requests. Interrupted delivery may leave a valid immutable
prefix, but no peer-publication binding is visible until the complete
publication validates; retry is safe.

Neither transfer modifies sender state or receiver scratch head, workspace,
capsule-current binding, release binding, or working directory. It supplies no
identity proof, encryption, server setup, discovery, relay, NAT traversal,
background synchronisation, ref exchange, or merge policy.

## Explicit integration

The receiver may inspect a stored publication:

```sh
yeokcham peer show <publication-id>
```

Only a capsule projection supports adoption:

```sh
yeokcham peer integrate <publication-id> --as-capsule <new-capsule-id> \
  --title <receiver-title> --description <receiver-description>
```

This transition creates fresh detached receiver checkpoints from the projected
snapshots, verifies their byte-level operation replay, creates an ordinary
local capsule with the user-supplied identity and text, and stores a
`Peer_integration_v1` receipt under
`refs/peer-integrations/<integration-id>`. It does not replay a sender’s
scratch checkpoints or copy source capsule identity.

Release projections intentionally refuse this command. A native release needs
local workspace composition and validation evidence, so source release metadata
cannot truthfully become a receiver release without a separate decision.

## Verification boundary

Focused coverage includes publication/integration persistent-format goldens,
local capsule and release projections, missing-only transfer,
interruption/retry, closure absence rejection, explicit integration, and a
two-process framed exchange. A seeded property varies content, modes, and
already-present destination snapshots. The direct SSH argv test does not verify
an SSH server configuration, host identity, or transport authentication.
