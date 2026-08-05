# ADR-0075: Store token-free GitHub mirror policy and checkpoints canonically

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

GitHub mirroring needs an explicit selected-ref policy and durable observation checkpoints before any transport can safely decide whether a remote update is current. Repository-local configuration must neither contain credentials nor become an unverified recovery gap.

## Decision

Store one optional `mirrors/github.ykgm` canonical `YKGM` version-1 record per repository. Bind it to the repository UUID and include a validated `owner/repository` target, selected branch/tag rules, mirror direction, force-update policy, and bounded checkpoints. Each checkpoint maps a selected local ref to a standard remote branch/tag ref with their Git object IDs and observation time. Use a SHA-256 checksum, create-new staging, atomic replacement, and directory synchronization.

The default force policy is `reject`; `require-exact-checkpoint` is an explicit policy for a future transport implementation. Configuration requires no token, performs no network I/O, and has no GitHub credential API.

## Consequences

`yeokcham github configure` and `yeokcham github inspect` provide a usable local policy workflow. The CLI reports directions, policies, and counts rather than target/ref metadata. Publishing, remote ingestion, pull-request publication, and GitHub authentication remain separate work.

## Invariants

- Configuration belongs to exactly one repository UUID.
- Only `refs/heads/*`, `refs/tags/*`, `heads`, and `tags` are selectable.
- A checkpoint local ref must be selected and still equal the acknowledged local ref target.
- A checkpoint records its remote ref explicitly; local and remote object IDs are not conflated.
- Corrupt, truncated, oversized, symlinked, or unexpected configuration entries fail closed.
- A stale local ref cannot replace a checkpoint.

## Compatibility and migration

The optional file does not change the repository bootstrap format; repositories without it remain readable. `YKGM` version 1 has fixed canonical ordering and reserved feature bits. A later incompatible record requires a new version and reader migration. Existing backups remain valid; a configured record becomes one allowlisted canonical recovery file.

## Security and recovery

The record stores no token or source content, but its target and selected refs are local metadata. A SHA-256 checksum detects unkeyed corruption; it is not an authorization signature. Encrypted recovery snapshots include the exact record and restore validation rechecks its bound repository ID and checksum. Future credentials must live in OS credential storage.

## Verification

Core tests round-trip the format, reject invalid targets/rules/unselected checkpoints and corruption, persist/reopen repository-bound configuration, verify tamper detection, and reject stale checkpoints. CLI parser and process tests configure and inspect a policy without echoing its target.
