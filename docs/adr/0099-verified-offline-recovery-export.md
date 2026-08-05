# ADR-0099: Verify local canonical storage before offline recovery export

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`export-git` creates a conventional Git repository from a local Yeokcham store. The recovery journey requires one explicit offline command that proves the canonical state before producing a handoff repository. Drive snapshot restoration is separate: it needs user-selected backend credentials, a recovery-key export, and an absent local destination.

## Decision drivers

- Make the offline recovery boundary explicit.
- Verify all canonical records before exporting refs or Git objects.
- Preserve the existing explicit Drive restore workflow.
- Avoid adding network, credential, or server-write authority to recovery export.

## Considered options

### Reuse `export-git` as recovery documentation

This does not make full pre-export verification observable or give the recovery journey a distinct command boundary.

### Add a server recovery endpoint

The native HTTP service is read-only and has no authority to select a filesystem destination, backend, or recovery key.

### Add a verified offline recovery-export command

This provides the required recovery handoff while keeping all destination and backend selection explicit at the CLI.

## Decision

Add `yeokcham recover --export-git <yeokcham-repo> <destination-git-repo>`. It opens the local repository, runs bounded complete canonical verification with the standard initial verification limits, and only then writes a new bare Git export using the established export limits.

The destination must not exist. `drive restore` remains the encrypted-backend restoration command; after it succeeds, `recover --export-git` exports the recovered local store. Neither command contacts a provider during the offline export step.

## Consequences

Recovery from an encrypted backend remains two explicit stages: restore canonical files locally, then verify and export Git data. Verification failure leaves the requested Git destination absent. A later general backend-agnostic restore selector requires a new credential and transport decision.

## Invariants

- No Git export begins before complete canonical verification succeeds.
- The export uses exact reconstructed Git objects and the established ref-restoration path.
- A recovery destination is never replaced or merged.
- The command does not load keys, contact a backend, or start the HTTP service.

## Compatibility and migration

This adds one CLI command and no repository, recovery-key, backend, or wire-format change. Existing `export-git` and `drive restore` behavior is unchanged.

## Security and recovery

Canonical data is checked before it becomes an ordinary Git repository. The CLI receives the repository and destination only from explicit command arguments; diagnostics do not print object bodies, keys, or credentials. A partial destination from a failed export is not canonical and must be discarded before retrying.

## Verification

The CLI test imports a real Git fixture, recovers it, and runs `git fsck --full --strict` on the output. It then corrupts a temporary canonical segment, confirms recovery fails, and confirms no destination was created. Parser tests require the exact `recover --export-git` form. Workspace CI runs fixtures, formatting, Clippy, tests, and documentation builds.
