# ADR-0076: Publish selected GitHub refs through standard Git credentials

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The mirror policy from ADR-0075 selects exactly which Git refs may reach GitHub but intentionally contains no credential. Publication must preserve that boundary while ensuring the remote accepted the exact verified local object IDs before a checkpoint is trusted.

## Decision drivers

- Reuse mature Git HTTPS and SSH authentication.
- Never persist, print, or trace a GitHub credential.
- Refuse partial selected-ref publication and unconfirmed remote state.
- Permit non-fast-forward branch replacement only under an explicit exact checkpoint.

## Considered options

### Option 1: Yeokcham-managed GitHub token flow

An OAuth or personal-token API would require credential lifecycle, secure storage, revocation, and additional GitHub API behaviour outside the storage boundary.

### Option 2: Standard Git credential helper or SSH agent

Run C Git against the configured GitHub HTTPS or SSH URL and let its existing standard credential helper or SSH agent authenticate. Yeokcham has no credential material to store or recover.

## Decision

Use Option 2. `yeokcham github publish <repo> --apply [--transport https|ssh]` reconstructs a verified temporary bare export, reads only selected remote refs, and calls C Git with explicit selected refspecs, `--atomic`, and `--porcelain`. HTTPS is the default and uses the standard Git credential helper; SSH uses the standard agent. Terminal and askpass prompting are disabled. Git/SSH command overrides are removed from the child environment, while normal Git configuration and `SSH_AUTH_SOCK` remain available.

After a successful push, reread exactly the selected remote refs. Persist checkpoints together only when each remote ID equals the selected verified local ID and every local ref still equals that ID. Reject existing tag replacement. Under `require-exact-checkpoint`, add an exact `--force-with-lease` only for a branch whose current remote ID matches its stored remote checkpoint; otherwise let ordinary Git reject a non-fast-forward update.

## Consequences

The operator must configure a credential helper or SSH agent before publishing. The command has no interactive credential prompt and no GitHub token configuration. The remote must support atomic pushes; unsupported servers fail closed. The CLI does not yet fetch GitHub refs or create pull-request branch mappings.

## Invariants

- No unselected refspec is passed to C Git.
- Remote object IDs are read before and after the push; only exact post-push IDs are acknowledged.
- A failed or stale local checkpoint batch cannot partially replace persisted checkpoints.
- Tag replacement is rejected regardless of configured branch force policy.
- A forced branch update uses only a current exact remote checkpoint lease.

## Compatibility and migration

No persistent format changes. The existing `YKGM` checkpoint record is updated through its existing atomic replacement procedure. Rollback removes the publish command but leaves valid checkpoint records; export remains standard Git-compatible.

## Security and recovery

Credentials remain external to Yeokcham and are not included in repository files, encrypted recovery snapshots, diagnostics, or command output. The configured target and selected references remain repository-local metadata as documented by ADR-0075. Temporary exports contain ordinary Git objects but are removed before successful command completion; interrupted-process cleanup remains a local operational concern.

## Verification

Tests use a real local bare C Git remote to prove selected main/tag publication, exclusion of an unselected branch, exact post-push remote confirmation, and atomic checkpoint persistence. Unit tests require `--apply`, parse HTTPS/SSH selection, issue a branch force lease only for an exact checkpoint, and reject tag replacement. Full workspace CI runs formatting, checks, lint, tests, docs, and fixture verification. No test contacts GitHub or a user credential helper/agent.
