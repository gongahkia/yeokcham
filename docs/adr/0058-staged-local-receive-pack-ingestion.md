# ADR-0058: Stage local receive-pack before publishing a Yeokcham ref transition

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local helper already serves verified Yeokcham state through C Git `upload-pack`. Native `receive-pack` sends its final Git status after accepting refs, but a Yeokcham push must not be acknowledged before its objects are reconstructable and its canonical ref event is durable. Directly letting C Git modify an exported snapshot would neither import those objects nor serialize the later Yeokcham transition against the state advertised to the client.

## Decision

For `connect git-receive-pack`, export the verified canonical state into a private temporary bare repository. Relay only C Git's initial packet-line advertisement. Run C Git `receive-pack` against that staging repository with fixed policy: branch updates must be fast-forward, branch deletes remain enabled, and an isolated `update` hook permits tag creation but rejects tag move or delete. Drain the post-request response into a bounded 128 MiB private file.

After C Git exits successfully, reopen the staging repository through the isolated Git adapter and call the normal bounded Git import path with the exact ref state exported before staging. That path verifies reachable Git object IDs, stores objects according to the current blob policy, verifies the Yeokcham repository, and appends a ref event only if the canonical predecessor is unchanged. Only then relay the stored final receive-pack response. A C Git rejection is relayed without canonical mutation. An import, verification, or predecessor conflict failure relays no success response.

Use the repository UUID as the deterministic V1 writer identity for this local service. It is valid because repository UUIDs are RFC UUIDv4 values; it is not a device credential or authorization mechanism.

## Consequences

Git clients can push fast-forward branch creation, update, and deletion to a local store. Existing tags are immutable. C Git validates client-advertised old refs and pack connectivity; Yeokcham repeats object and ref-target verification before publishing its canonical journal transition.

If the canonical predecessor changes after staging, or any import check fails, immutable staged-object records may have been written but remain unreachable. The helper does not acknowledge those refs, does not overwrite another transition, and discards the temporary conventional Git repository. Crash injection and signed multi-device authorization remain separate work.

## Invariants

- The initial Git receive-pack advertisement reflects a verified complete canonical state.
- A successful push response is released only after a verified canonical transition is durable.
- Canonical refs are appended through exact-predecessor comparison, never replaced in place.
- Branch force updates and existing-tag changes are rejected by fixed staging policy.
- Temporary exports and receive-pack responses are not recovery data and are removed after the helper exits.
- The response collector keeps draining after its limit, so a malformed oversized response cannot block C Git while consuming unbounded disk.

## Compatibility and migration

This adds no canonical format field or migration. Existing local stores gain push support on the next helper invocation. The temporary Git export and response file are private disposable process data; cache entries are not used for receive-pack because each staged push must be isolated from the canonical predecessor check.

## Security and recovery

The helper clears Git path and configuration environment overrides, invokes fixed Git subcommands, and passes only helper-created staging paths. Default logging omits source bytes, ref names, object IDs, paths, and response data. C Git's standard quarantine and connectivity checks are relied upon for its temporary repository, while Yeokcham independently verifies imported object bytes and ref targets. The unsigned V1 writer must remain a single trusted local service until signature enforcement exists.

## Verification

Core tests prove a stale expected state rejects synchronization and that a later transition after revisiting a prior ref state stays linear through the device sequence chain. Remote-helper integration covers accepted fast-forward push, branch creation and deletion, tag creation, rejected forced tag and branch replacement, a fresh clone, `git fsck --full --strict`, and canonical verification. The checksum-pinned Git 2.54.0 and 2.55.0 CI matrix runs both clone/fetch and push integration tests.
