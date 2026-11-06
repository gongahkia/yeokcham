# Implementation handoff workflow

Status: authorized workflow, November 6, 2026. Implementation is ready to start
in bounded stages. This document prepares the handoffs; creating it does not
start any implementation goal. The starting design commit is
`d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.

## How to use the chain

1. Open [Implementation progress](IMPLEMENTATION_PROGRESS.md) and copy the next
   ready goal file into Codex in this repository. Run one implementation agent
   at a time, directly on `main`.
2. That agent reads this workflow, the phase prompt, and its referenced design
   contracts, then implements and verifies only that phase. It updates the
   progress document and creates small commits for independently coherent work.
3. At completion it writes a report under `docs/implementation/reports/`, commits
   the report/progress update, and returns two copyable blocks: the report and
   the next `/goal` prompt. Printing the next prompt does not execute it.
4. Paste the report into the coordinating conversation when an audit/update is
   wanted, or give the next prompt to a fresh Codex session in the same checkout.
   The next agent verifies the predecessor's actual commits, report, and gates.
   It must not trust a completion claim without repository evidence.
5. If the phase is incomplete, return a continuation of that same phase with its
   exact remaining work. Do not advance the chain because time/context ran out.

The repository tracker is the durable shared state. A conversation cannot observe
another session's progress automatically; each implementation agent maintains the
tracker as it works, and the coordinator reconciles it when reports/repo evidence
are available. Goals themselves are thread-scoped. Use a Codex build with `/goal`
support, and finish or explicitly stop the previous writer before starting another.
See the [official Goals guide](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)
for the command's outcome/evidence model.

## Binding instructions for every implementation goal

### Repository and design

- Work on `main` in this repository. Do not create branches/worktrees or move
  implementation to another checkout. A temporary read-only source export for
  baseline benchmarking is allowed; it is not a second implementation workspace.
- Native validation on another OS may use that machine's checkout of the same
  `main` commits. Verify ancestry/revision, transfer committed work through the
  user's normal process, and keep only one writer active. Missing commits cannot
  be reconstructed from a prose report alone.
- Read applicable `AGENTS.md`, this workflow, the progress tracker, the phase
  prompt, its predecessor report, and the relevant design sections. Preserve
  D01-D29 and TC01-TC08. The chosen defaults need no new preference questionnaire.
- Inspect current files and history before deciding what to change. Documentation
  describes the target; it does not prove runtime features already exist.
- Honor the phase boundary. Routine details and additive implementation choices
  may be resolved autonomously and recorded. A material change to privacy,
  recovery, accepted contents, default policy, or fidelity requires an explicit
  design amendment; do not silently weaken the contract to make a test pass.
- Keep edits on `main` serialized. Do not spawn additional implementation agents
  or keep another writing session active. No push, release, deployment, or message
  to another person is authorized by these handoff prompts.
- README policy: leave `README.md` alone unless adding a concise accurate section
  or correcting something demonstrably wrong/outdated because of landed work.
  No broad rewrites, reorganization, styling churn, or speculative feature claims.
  Explain every README hunk in the completion report. Prefer detailed docs under
  `docs/` for new workflows. This is the user's latest README instruction.
- No old Yeokcham artifact migrations/compatibility layers (D10), initial Git
  carryover, managed hosting, or mandatory AI dependency. Protect current working
  data and recovery roots even when development formats change.

### Before changing files

Record `git branch --show-current`, `git status --short`, `git rev-parse HEAD`,
the design baseline, and the predecessor report/implementation commits. Verify
prerequisite commits are ancestors of the current `main` using `git merge-base
--is-ancestor`; the exact old HEAD need not remain the tip if unrelated safe work
has landed. Revalidate affected assumptions if the tree has changed.

If on another branch, switch to `main` only when doing so is safe; never discard
changes to force the switch. Preserve pre-existing staged and unstaged work.
Stage/commit explicit files or hunks owned by this phase; never sweep unrelated
work into `git add -A` or `git commit -a`. If overlapping external work prevents
safe progress, report the concrete conflict instead of resetting/stashing it.

Set the phase to `in_progress`, record its starting commit/session label, and
keep a short checkpoint list in the tracker as meaningful work completes. The
tracker is an audit record, not a lock: still check that no other writer is active.

### Implementation and verification

Produce the phase's concrete artifact or working feature, not just another plan.
Expose useful structured errors and plain-language explanations alongside each
feature. Pure foundation phases supply typed outcome/error data for later CLI
consumers; user-facing phases wire real behavior, without placeholder success.

Use the existing Makefile/toolchain: local OCaml 5.5.0, Dune, and ocamlformat 0.29.0.
Read current build files rather than assuming those versions can never change.
Set up documented local dependencies as needed. Existing CI lists additional
test tools such as OpenSSL, socat, SoftHSM, zsh, and fish; missing tools are not
passing tests. Do not install unrelated software or change global settings.

For code changes, run affected module/property/CLI tests plus `make build` and
`make lint`. Run `make ci` at the phase completion boundary. For docs-only work,
`make docs-check` and `git diff --check` are sufficient unless a changed workflow
requires its own check. Use actual targets from `test/dune`, for example
`opam exec -- dune exec test/test_v1_model.exe`; register focused targets for new
modules. Do not write trivial tests that merely repeat the implementation.

Record the exact commands, exit outcomes, tested commit/tree, platform, and
artifact locations. Resolve regressions caused by the phase. Pre-existing failures
must be reproduced at the recorded baseline and distinguished from new failures;
never suppress tests or edit expected values merely to hide a defect.

A phase may defer only the evidence explicitly assigned to a later phase, such
as a full extended benchmark or another OS's native run. Record each deferral in
the coverage ledger with its owning phase. A missing required check for the
current phase means incomplete/blocked, not complete. Native platform claims,
final performance claims, and whole-project completion require actual evidence.

Use disposable fixture repositories outside this checkout. Do not run destructive
history/retention/recovery experiments against the user's live project. Large
fixtures, generated archives, secrets, and full logs stay outside Git; commit
small manifests, commands, hashes, result summaries, and reproducible generators.

### Atomic commits and rollback

Commit one coherent concern at a time, including the focused tests and necessary
documentation that make that change reviewable. Keep each code commit buildable;
avoid both one giant phase commit and deliberately broken intermediate commits.
Do not mix unrelated refactors, formatting, or README cleanup into feature work.
Before each commit inspect the staged diff and run the appropriate checks. Keep
the existing history: no amend, rebase, force push, or hard reset.

Record every implementation commit and purpose in the report. After implementation
commits, make a small separate handoff commit for the report/progress update.
The report lists implementation hashes; it does not need to embed its own future
commit hash. The final response can add the actual handoff commit hash after it
exists. Locate that commit later with `git log -1 --format=%H -- REPORT_PATH`.

Give a rollback order using exact implementation hashes, normally newest first
with `git revert`. Reverting dependent phases may be required before an older
foundation. State format/data implications: reverting source does not undo data
written by the new code. Do not execute rollback automatically. If rollback is
requested later, update progress and invalidate affected downstream evidence.

### Reports, progress, and the next prompt

Use [Report template](implementation/REPORT_TEMPLATE.md). Save reports as
`docs/implementation/reports/GNN-attempt-NN.md`, starting with attempt 01;
preserve earlier attempt reports. Each tracker row links its latest report and
lists implementation hashes, unresolved work, and the next eligible phase.

`complete` means every acceptance criterion and current-phase check has evidence.
`blocked` means a named external dependency prevents completion after reasonable
attempts; state precisely what would unblock it. `in_progress` is appropriate
for resumable unfinished work. These tracker labels do not override the host's
goal-lifecycle rules. Never mark the whole project complete while coverage gates
or mandatory phase criteria remain open.

At closeout:

1. Audit acceptance criteria against code, tests, and evidence; update the phase
   row, coverage ledger, report, and remaining-work summary together.
   Mark the successor ready only after its prerequisites pass; leave it unstarted
   until invoked. Verification by the next agent/coordinator is not an extra user
   approval ceremony.
2. Commit the report/progress update without unrelated changes. Record any
   remaining working-tree changes rather than falsely claiming a clean tree.
3. Return the report in a fenced Markdown block, followed by a separate fenced
   text block containing the next copyable `/goal` prompt. Read the next goal file
   verbatim and append the predecessor report path and implementation hashes.
4. If incomplete, return the current phase prompt with a continuation note and
   remaining checklist instead. If all phases and gates passed, return the final
   completion report and state that no next implementation goal is needed.
5. End work on this phase. Do not execute the printed next goal automatically.

No token/time budget is specified by this workflow. Honor any budget the user or
host actually supplies, and report unfinished work truthfully when it is reached.

## Coordinator reconciliation

When a report is pasted back, inspect the current `main`, the named report and
commits, changed files, and validation artifacts. Re-run focused checks when
changes or missing evidence justify it. Correct tracker claims that disagree
with the repository, preserving the earlier report and recording why. Update
remaining work and issue the next eligible prompt or a scoped correction prompt.
Do not infer background progress in a session that has not reported or written
evidence to this repository.
