# ADR-0077: Publish one selected branch to an explicit pull-request branch

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Selected-ref publication maps each local ref to the identical remote ref. A pull-request workflow needs an explicit remote review branch without widening publication to unselected local refs or introducing a GitHub pull-request API client.

## Decision drivers

- Preserve the selected-ref privacy boundary.
- Use the verified standard Git publication path from ADR-0076.
- Record the actual local-to-remote relation for later force checks.
- Avoid token/API lifecycle and repository-hosting features.

## Considered options

### Option 1: Publish every selected branch under its original name

This already permits some pull-request workflows but cannot deliberately map one selected source to a separate review branch.

### Option 2: Add a GitHub pull-request API client

An API client could create a pull request after publication but adds credential scope, API state, and hosted-service semantics that are not needed to publish a review branch.

### Option 3: Explicit one-branch Git ref mapping

Require the caller to name a selected local branch and one remote branch, then publish exactly that refspec through the checked transport.

## Decision

Use Option 3. `yeokcham github publish-pr <repo> --source <refs/heads/branch> --branch <remote-branch> --apply [--transport https|ssh]` maps the source to `refs/heads/<remote-branch>`. The source must be a selected, acknowledged standard branch. The remote branch is validated before transport. Publication reuses ADR-0076's verified export, atomic push, post-push exact ID confirmation, force lease policy, and checkpoint persistence. The checkpoint records the explicit remote branch.

The command does not create, update, or merge a GitHub pull request. The operator opens the published branch through ordinary GitHub UI/API workflows.

## Consequences

Review branches can be published without selecting every local branch or storing a persistent branch-mapping rule. Repeating the command is explicit. A later full selected-ref publish may update the checkpoint for that same local source to its same-name remote mapping.

## Invariants

- The source ref is `refs/heads/*`, selected, and currently acknowledged before a remote command runs.
- The remote ref is exactly one valid standard `refs/heads/*` name.
- One command passes one refspec only; unselected refs are not published as a side effect.
- The checkpoint's remote reference is the confirmed remote review branch, not an inferred local name.

## Compatibility and migration

No repository-format change. Existing `YKGM` checkpoint encoding already represents the explicit local-to-remote pair. Rollback removes the command but leaves valid checkpoint data and standard Git remote branches.

## Security and recovery

This workflow has the same external credential boundary as ADR-0076. It stores no token and does not expose object bodies. The source and remote branch names are operator-supplied metadata and appear only in explicit command output after successful publication.

## Verification

A local-bare C Git test imports a selected main branch, publishes it to a distinct review branch, proves the same-name remote branch is absent, rejects an unselected source, and verifies the checkpoint's local and remote IDs plus remote name. Parser tests require `--apply`, validate branch source syntax, and verify SSH transport parsing. Full workspace CI verifies the implementation without contacting GitHub.
