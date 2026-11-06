# CLI experience design

Status: product priority agreed November 6, 2026 (D26 in
[Product design](PRODUCT_DESIGN.md)). Command and interaction defaults below were
selected under the user's subsequent delegation to settle remaining design
choices. They describe the target CLI, not commands already implemented. Exact
prose can improve through usability checks while preserving the stated behavior.

## Purpose

Someone unfamiliar with version control should be able to read an issue or
conflict and understand what happened, whether their work is safe, and what to
do next. Ordinary work should require few explicit actions. This requirement
applies to every feature from its first implementation, including error states;
it is not a final cosmetic pass or a requirement to build a graphical interface.

## Commands and ordinary use

- Use a small, consistent vocabulary based on user intentions. Make the normal
  path discoverable in help with short examples and useful next actions.
- Keep routine capture, backup, and retry automatic under the agreed policies.
  Avoid repeated prompts or successful-background-event noise.
- Expose available actions in context. An interactive flow may guide selection,
  while equivalent explicit arguments support experienced users and automation.
  Use the command families and journeys below; keep advanced diagnostics out of
  the ordinary help path.
- Explain consequences before applying work according to the configured preview
  preference. Safe cancellation or deciding later must not discard work.
- Show progress for long operations, including what is waiting and whether the
  user can continue editing. Cancellation follows the operation's recovery
  contract; never promise an instant rollback that the implementation lacks.

## Status must distinguish the states users care about

| State | Meaning to communicate |
| --- | --- |
| Saved on this device | A verified local capture exists for the reported files/state. Unsaved editor buffers are outside capture. |
| Privately backed up | The archive has acknowledged a complete backup of the reported state; teammates cannot read it. |
| Shared with the team | Selected work has been explicitly published. Private subsequent edits may still exist. |
| Accepted into the shared version | An explicit integration has recorded the result. State separately whether it is awaiting synchronization. |
| Available offline | The reported scope is verified locally, with its last successful synchronization and any missing data. |
| Needs attention | A specific action is blocked or needs a choice; explain which other work can continue. |

Do not collapse these into an unqualified "synced" or "everything is safe."
Report the state actually checked, including incomplete capture, interrupted
application, failed backup, and archived-only history. This matters when local
changes continue while another operation runs.

## Issues and conflicts

Lead with a short explanation and progressively reveal details. Supply:

1. What the user tried to do and why it could not finish.
2. The affected files and identifiable versions, people, or times where known.
3. What happened to current files, which copies are preserved and where, and
   anything whose state is still uncertain.
4. A concrete next action or a small set of meaningful choices, including how
   to defer the decision without losing recoverable work.
5. Optional technical details for diagnosis, with stable identifiers for support
   and automation. Ordinary understanding must not require interpreting hashes,
   internal record constructors, a stack trace, or generic "operation failed."

For conflicts, explain whether changes overlap, a file was deleted while another
version changed it, private edits conflict with incoming work, or an opaque file
needs a choice. Name the actual versions; labels such as "ours" and "theirs"
are insufficient on their own. Distinguish a file conflict from missing approval,
an expired preview, missing downloaded data, or an unavailable server.

Offer comparison and explicit selection/resolution when supported. Say when a
format cannot be automatically combined; preserve both candidates and allow an
externally combined replacement. Do not require AI to explain mechanical facts
or pretend to understand the semantic correctness of the result. Clearly state
whether a choice affects the shared version, private working files, or both.

Illustrative message for two downloaded shared document versions, before writes:

```text
We couldn't combine the changes to brochure.docx.
Sam and Riley each shared a different version of this file.

Your files haven't been changed. Both shared versions are saved on this device.

Next: compare the two versions, choose one for the shared version,
or provide a combined file. You can also leave this decision for later.
```

Only use those preservation claims when verified. An interruption after some
files changed needs an honest recovery message identifying that condition.
The implemented interface must provide usable actions or exact supported
commands alongside the explanation, using the command families below.

## Preferences, warnings, and required policies

Preview confirmation and renewed approval are independent, default-on safeguards
(D18/D27). Explain which setting is changing, whether it affects this user's
account/repository preference or team policy, what will happen afterward, and
how to restore the default. Show the effective setting and where it comes from.
Personal preferences cannot bypass required repository review policy.

Warn when disabling a safeguard. Do not recreate the disabled confirmation by
asking the same warning on every operation. Continue to report relevant facts,
such as "Later changes have not been reviewed; this repository allows proceeding."
Neither opt-out permits guessing a resolution, skipping plan validation, or
discarding private work. Keep warnings specific to the consequence of the action.

## Accessible terminal and automation behavior

Keep messages readable without color or icons and on narrow terminals. Explain
necessary terminology at first use and keep names, action labels, and wording
consistent. Escape untrusted paths, titles, and display names safely while
preserving enough information to identify them.

Provide concise human output and structured results with stable outcome/error
codes, affected objects, preservation state, policy blockers, and available next
actions. Scripts must not need to parse explanatory prose. Noninteractive use
must not hang on a hidden prompt or assume consent; return the plan/needed choice
unless the caller has supplied an explicit, policy-permitted answer. Use the
structured output and exit-code defaults below.

## Default command vocabulary

All commands below are prefixed with `yeokcham`. The ordinary help screen shows
`init`, `clone`, `status`, `history`, `share`, and `integrate`, then links to
recovery, review, account, and advanced help. Bare `yeokcham` shows status in a
repository and a short getting-started guide outside one. Do not expose a command
for each internal record or require manual saves before normal operations.

| User intention | Default command and behavior |
| --- | --- |
| Start a local project | `init [PATH]` captures existing files privately, registers automatic capture, and reports service readiness. Works offline; no remote/account ceremony required. |
| Obtain an existing project | `clone URL [DIRECTORY]` uses a native remote, verifies and materializes the selected accepted version into a new/empty destination, and registers background work. Fetch all other shared history/branches in the background with honest coverage progress. No Git carryover is implied. |
| Configure private backup | `account setup --server URL` completes account/device/recovery setup; `remote add URL` connects the current repository. Explicitly choose the backup destination if multiple accounts are configured. |
| See current state | `status` shows local capture, private backup, team publication, accepted work, offline availability, and anything needing action. `status --details` adds diagnostics. |
| Find earlier work | `history` shows times, titles, paths, and alternate continuations. `history --all` includes archived history with availability labels. `diff STATE_A STATE_B` compares exact versions. |
| Recover local work | `undo`, `redo`, and `restore STATE` preview affected files and preserve current work before application. A branching redo asks which continuation. `restore STATE --to DIRECTORY` writes a separate copy into a new/empty directory. |
| Share selected work | `share [PATH...]` captures current disk contents and explicitly publishes only the selected changes; with no paths, all included current changes. `--title TEXT` names the change; otherwise generate a short file-based title. `--preview` only inspects; `--update CHANGE` explicitly publishes another revision of that change. |
| Accept shared work | `integrate CHANGE...` prepares, previews, confirms, and applies one exact plan. With no IDs, offer a contextual selection; select a sole eligible change automatically but still preview. `--all` explicitly selects all eligible work and dependencies on the current branch. |
| Browse shared branches | `branch list`, `branch create NAME`, and `switch NAME` expose shared branches. Switching preserves private edits or explains a conflict before changing files. Diverged heads require a choice/reconciliation. |
| Ask for review | `review open [PATH...]` captures/publishes selected work and opens its request in one action. `review update REQUEST` explicitly submits a new version to that request. |
| Review or discuss | `review list`, `review show REQUEST`, `review comment REQUEST`, `review approve REQUEST`, `review request-changes REQUEST`, and `review withdraw REQUEST` operate on exact inspected versions. `review close REQUEST` closes without deleting work; administrator-only `review dismiss EVENT --reason TEXT` clears a blocker with an auditable reason. `--version ID` binds automation to one version. |
| Resolve a conflict | `conflicts` lists named files and versions; `resolve CONFLICT --use VERSION` or `--file PATH` prepares an explicit resolution. Show whether it affects shared work, private files, or both. Resolution itself does not silently integrate or publish private edits. |
| Pause or retry background work | `pause`, `pause --all`, `resume`, and `sync` follow TC04. `sync` requests a transfer pass; it never accepts incoming changes. `--all-repos` expands the scope explicitly. |
| Inspect exclusions | `ignore explain PATH` identifies the matching native rule and its source. |
| Add/remove an account device | `account device add`, `account device approve REQUEST`, `account device list`, `account device revoke DEVICE`; `account recover --server URL` uses a private phrase-entry ceremony. |
| Configure behavior | `config show`, `config set KEY VALUE`, and `config reset KEY` show inheritance. `--account` changes personal defaults; `--repo` (the default) changes a personal repository override. Team rules use `policy show` / `policy set` and require repository administration authority. |
| Diagnose/recover an interrupted operation | `doctor` inspects without mutation; `operation show ID`, `operation resume ID`, and `operation recover ID` show the exact pending plan and safe next actions. |

Keep lower-level inspection/service commands in advanced help. Existing development
command aliases may be removed under D10; this design does not require a layer
preserving obsolete commands or a separate `deliver` action. Every mutating
command returns a concise account of the changes it actually completed.

Default setting names are `integration.confirm=true` (personal),
`reviews.required=false`, `reviews.minimum_approvals=1`, and
`reviews.require_renewed_approval=true` (repository policy). Disable warnings name
the setting and scope; `config reset` restores inheritance. A one-member repository
with required independent review explains the missing reviewer and administrator
policy options, rather than allowing the author to approve using another device.

## Default complete journeys

1. **Start and edit:** `init` records private files and starts capture. The user
   edits normally; `status` reports the last durable capture. `account setup`
   adds private backup later without reinitializing local history.
2. **Join and work offline:** `clone` materializes the selected shared version,
   shows what is available now and what is still downloading, then works locally
   after disconnect. `switch` to an unavailable version explains missing content
   before touching current files. Reconnection resumes downloads automatically.
3. **Share and accept:** `share --title "Update brochure"` returns the exact
   published change ID and states whether transfer is pending. `integrate ID`
   previews accepted changes and private-workspace effects, then confirms once.
   Success states local acceptance and any queued synchronization separately.
4. **Handle a document conflict:** `integrate ID` names both versions and leaves
   files intact. `conflicts` offers comparison/copy-out and exact selection or a
   replacement file. `resolve` prepares that result; another `integrate` produces
   the new preview and applies current review requirements. Deciding later is safe.
5. **Use required review:** `review open` shares the selected version and gives
   teammates the request ID. `review approve` displays the exact version/context;
   if it changes while being inspected, do not approve its replacement. The
   integrator follows the ordinary preview with the applicable policy evidence.
6. **Recover work or an interruption:** `history` finds an earlier state and
   `restore STATE` shows both preservation of current work and restoration effects.
   If an operation was interrupted, ordinary writes stop at its journal boundary;
   `operation show` explains what is already changed and whether resume or recovery
   is available. Commands never advise deleting the journal to clear the problem.

## Confirmation and automation defaults

Interactive confirmations default to cancel. Entering a valid explicit command
such as `share` authorizes that selected publication; no extra recurring approval
prompt is introduced for ordinary capture/backup/sharing. Review approval and
integration confirmation remain different decisions. `review approve` requires
an explicit `--version ID` or an interactive preview/confirmation of the resolved
version before signing. Noninteractive approval without a version returns a
choice-required result; it never signs a floating latest version. High-consequence account
revocation, recovery, and safeguard disablement explain their effects before the
explicit confirmation described by their contracts.

`--preview` never applies or publishes an acceptance. `--yes` supplies the caller's
confirmation for the exact freshly validated plan, not permission to bypass a
review/conflict check. `--plan ID --yes` binds an automation step to a previously
prepared plan. Changed inputs return a stale-plan result; do not silently apply
a replacement under that ID. An interactive command can offer a refreshed preview.
Without a configured opt-out or explicit answer, noninteractive commands return
the needed choice instead of waiting or guessing. Selection ambiguity never
disappears merely because `--yes` was supplied.

Every command supports a stable JSON result except private phrase ceremonies,
which refuse JSON before mutation and provide a secret-safe automation entrypoint
using a dedicated file descriptor/provider. No secrets in argv/environment or
normal result objects. JSON has `schema_version`, `command`, `outcome`, `code`,
`message`, `data`, `warnings`, `next_actions`, and optional `operation_id`/`plan_id`.
Each action carries an argument array, explanation, applicability, and whether
confirmation is needed. Put no terminal styling/progress on JSON stdout; use
stderr for human progress. Large histories use cursor pagination, default 50 rows.

| Exit | Meaning for the requested command |
| --- | --- |
| 0 | Completed, including explicitly reported queued synchronization or unchanged/no-op results. |
| 1 | Unexpected/internal failure with an operation reference when available. |
| 2 | Invalid command, arguments, or configuration syntax. |
| 3 | User choice/confirmation needed, or a stale plan requiring a new preview. |
| 4 | Unresolved content/workspace conflict. |
| 5 | Required content, connectivity, space, or credential provider unavailable. |
| 6 | Integrity/unsupported-format failure. |
| 7 | Authentication, authorization, or repository review policy blocks the action. |
| 8 | Interrupted operation needs recovery before the requested write can proceed. |

`status`, `history`, and other successful inspection commands return 0 even when
they report a blocked background task. Distinguish that task's state in data;
do not make scripts confuse successful inspection with successful synchronization.

## Acceptance and handoff requirements

Every feature handoff includes normal, blocked, interrupted, and recovery
interactions alongside its domain API. Core components must return enough facts
for truthful messages; a renderer cannot invent whether data is safe.

Before calling the CLI design complete, exercise representative journeys with
people who are unfamiliar with version-control terminology: initial setup,
ordinary editing, offline work, finding/restoring an older state, a text conflict,
a binary/document conflict, review requirements, and an interrupted operation.
Check whether they can explain what happened, identify the affected work, tell
what is preserved, choose the next action, and understand its consequences without
developer translation. Record confusing terms, dead ends, and unnecessary steps.
These are planned usability checks, not completed research or measured results.

Use focused scenario tests for materially different state/action outcomes and
structured contracts. Avoid brittle tests that merely freeze every prose string.
The integrated-experience work package validates consistency across features;
usable commands, factual status, and actionable errors are required throughout.
