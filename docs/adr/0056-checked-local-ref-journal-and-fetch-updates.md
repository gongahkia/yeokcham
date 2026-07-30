# ADR-0056: Append checked local ref transitions for fetch updates

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0051, ADR-0055
- Superseded by: None

## Context

The initial store had one immutable `YKRF` ref snapshot. A remote helper could clone it, but could not expose an updated or deleted ref without overwriting that snapshot, violating immutable-record and no-silent-last-writer-wins invariants.

## Decision

Keep `YKRF` as the immutable initial state. A controlled `yeokcham sync --from-git <source> <store> --device <uuid>` imports only new verified reachable objects, then appends a versioned immutable `YKRE` V1 event under `journals/refs/`.

Each event binds the repository UUID, writer UUIDv4, strictly positive per-device sequence, preceding event SHA-256 identity, expected predecessor ref-state SHA-256 identity, complete successor `GitRefState`, footer, and SHA-256 checksum. Its filename redundantly binds sequence, device, and event identity. Readers accept only one complete continuation from the initial snapshot; absent continuations, competing continuations, bad sequence links, malformed filenames, or unmatched predecessor states fail closed. Files are never removed or replaced, so rejected or divergent evidence remains inspectable through `yeokcham inspect refs`.

The first event upgrades the bootstrap atomically from repository format V1 to V2 before event publication. V1 binaries reject V2 rather than ignore journal records and serve stale refs. A crash before the event leaves a valid V2 repository at the old snapshot; a crash after the event leaves a complete immutable event whose targets were reconstructed and verified before append.

## Consequences

Ordinary Git can clone the local helper, then fetch updated branches and prune deleted refs after a successful `sync`. The helper still delegates pack synthesis to C Git from a temporary verified export. `sync` is not `git push`, receives no Git pack protocol, and does not implement ref-level push policy.

V1 events provide bounded canonical parsing and integrity checks only. They are not signatures or writer authorization: use a single trusted local writer and retain the chosen device UUID. ADR-0059 adds optional caller-supplied signed V2 events but deliberately does not add key registration, writer authorization, or revocation. Ref-event policy, fault injection, and recovery repair remain future work.

## Invariants

- A transition verifies every direct successor ref target before publication.
- The event's expected predecessor state must still match at append time; a stale sync fails rather than overwriting a newer ref state.
- The per-device chain is contiguous and bound by prior event identity.
- Every stored event must participate in the sole materialized continuation; ambiguity is a conflict, not an order-dependent choice.
- Bootstrap V2 is durable before any journal event is acknowledged.

## Compatibility and migration

V1 repositories with no event remain readable. The first sync atomically upgrades only its bootstrap to V2 and adds immutable `YKRE` V1 files; segments, indexes, and object manifests do not change. Older V1-only binaries reject the V2 bootstrap. V2 readers retain conventional export and do not depend on SQLite.

## Security and recovery

Journal names and bytes are hostile input. Readers bound directory entries and event bytes, reject symlinks and non-regular files, validate every filename and checksum, and reconstruct each effective ref target before trust. Checksums detect corruption but do not authenticate a hostile writer; signed events are required before any multi-device or untrusted-backend claim.

## Verification

Core tests cover canonical event decoding, tampering, V1-to-V2 upgrade, object ingestion, branch update and deletion, idempotent sync, stale expected-state rejection, divergent-event preservation, conventional export, and `git fsck`. The remote-helper integration test proves ordinary Git clone, update fetch, prune, checkout equivalence, and fsck. The refs fuzz target covers `RefEvent` decoding.
