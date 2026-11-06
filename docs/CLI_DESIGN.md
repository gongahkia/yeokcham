# CLI experience design

Status: product priority agreed November 6, 2026 (D26 in
[Product design](PRODUCT_DESIGN.md)). The requirements below turn that priority
into interaction and acceptance criteria. Example wording and action labels are
design drafts, not implemented commands or settled command syntax.

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
  Exact command names and menus still need design against the complete journey.
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
commands alongside the explanation; the example above does not settle syntax.

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
unless the caller has supplied an explicit, policy-permitted answer. Precise
schemas, exit codes, and flags remain technical design work.

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
