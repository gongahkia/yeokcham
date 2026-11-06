# Native review workflow

Status: design in progress, November 6, 2026. Product direction is agreed in
[Product design](PRODUCT_DESIGN.md), D18 and D21-D27. The interaction below is a
design baseline. The user delegated remaining default choices; the
[technical contracts](TECHNICAL_CONTRACTS.md) and [CLI design](CLI_DESIGN.md) now
specify record/evaluation and interaction defaults. No review feature is
implemented by this document.

## Purpose and default behavior

Every trusted repository member can integrate work by default, using the agreed
preview and confirmation. Creating a review request is optional. A repository
may opt into requiring approval before shared integration; that is a team policy,
not a personal setting that an individual can bypass.

Provide the useful PR-style flow without requiring an extra ceremony for every
change. This is a new native collaboration capability. Existing conflict
resolution proposals and authority-related late-review flags are not already
a peer-review workflow.

## Ordinary and reviewed paths

Ordinary path: edit and capture automatically, explicitly share chosen work,
then preview and confirm integration. There is no review request or delivery
recording step required merely to use the default path.

Reviewed path:

1. Request review of a chosen change or revision set, with a title, description,
   and target shared version. If that work has not yet been shared, the explicit
   review request can prepare and publish the selected revisions in the same
   user action. Never publish the entire private undo history implicitly.
2. Other trusted members inspect the diff/opaque-file summary and comment,
   approve, or request changes. Review artifacts are repository data available
   through the CLI and structured interfaces; a new web application is not a
   prerequisite for the initial implementation.
3. The author can publish an updated revision into the same request. Preserve
   the discussion and clearly show which version each review concerns.
4. A trusted member previews and confirms integration when the work is ready
   and any required review policy is satisfied. Successful integration marks
   the request integrated; no separate delivery step follows.

A request may also be closed without integration. Closing it does not delete
its shared revisions or the author's private history. Use simple open,
integrated, and closed states; current approval/change-request status is shown
separately so updating a revision does not erase the request's history.

## Exact review scope

Review decisions identify the exact request version, selected immutable revision
IDs, and comparison/target context the reviewer inspected. Never interpret an
approval as approval of all later edits to a mutable change name.

If submitted content changes, retain old reviews as history but do not count
them as approval of the new version. By default, if the base or integration plan
changes, check whether the reviewed content/context still matches; a changed effective
diff or manual conflict resolution needs approval of that new result when
approval is required. An unrelated target advance does not require another review
when the submitted revision and relevant file/path context are unchanged. The
[integration contract](TECHNICAL_CONTRACTS.md) defines that coverage boundary.
The configurable renewed-approval policy below changes whether a new review is
required, never the historical contents or meaning of an old approval.

Review approval and integration preview confirmation serve different roles.
Approval establishes review of a version; confirmation establishes the
integrator's choice to apply a particular plan. One does not substitute for
the other.

## Optional repository approval policy

Review is advisory by default. A request or change-request comment does not by
itself turn an otherwise optional repository into an approval-gated repository;
show outstanding feedback to the integrator without adding a mandatory gate.

An authorized repository administrator can enable required approval through a
versioned repository policy. Chosen initial rule: at least one other trusted
member approves the current review version (or eligible earlier work under an
explicit renewed-approval opt-out), with no unresolved blocking
change-request review applicable to that version. A second device belonging to an
author is not another reviewer. TC06 binds devices to administrator-admitted
member principals and excludes submitted-work authors from the approval count.

In required mode, work must have a review request and satisfy the policy before
integration. The interface should offer to create the request from the selected
work rather than making the user reconstruct it in a separate manual sequence.
Comment-only discussion is not automatically a blocking review. Updated or
withdrawn reviews must have explicit, auditable meaning.

Disabling personal preview confirmation does not disable required approval.
Direct integration without a request cannot bypass required mode, and the
relay's administrative access cannot fabricate an authorized approval. Team
policy changes require appropriate repository authority; editing a local
personal preference is insufficient.

The minimum-reviewer rule above is the chosen initial mechanism, not a mandate
for a broader governance system. Code-owner rules, compulsory CI checks, merge
queues, branch-specific approval counts, and complex reviewer hierarchies are
not implied by this feature. Discuss such additions if their value justifies
their extra workflow or configuration.

## Configurable renewed approval: D27

Personal preview confirmation (D18) and the repository's requirement for renewed
approval after relevant changes both default on. Required reviews as a whole
remain opt-in (D25). Advisory reviews still report which work was reviewed
without blocking ordinary integration.

An authorized repository administrator can disable renewed approval through
versioned policy after a warning. State the repository scope and consequence:
changes made after an approval, including new conflict resolutions, may enter
the accepted version without a reviewer inspecting them. This relaxation does
not itself disable preview confirmation. A personal preference cannot relax
the repository's review rules.

Chosen eligibility rule for this opt-out: an otherwise valid approval
of an earlier version in the same review request's explicit version ancestry
can satisfy the policy's prior-review requirement. Do not borrow approval from
an unrelated request, a changed author-principal set, or an unproven concurrent
version. Missing approvals,
withdrawn approvals, invalid reviewer authority, and applicable blocking review
decisions still follow the repository's other rules. An opt-out only relaxes
the need for renewed approval; it is not a general review-policy bypass.

Use causal reviewer-event ancestry to interpret updates. Concurrent conflicting
decisions by one reviewer do not count as an approval until reconciled. A blocking
change request survives descendant versions until its reviewer clears it or an
administrator explicitly dismisses it with a recorded reason. Publishing another
version cannot by itself erase a blocking review. Ordinary comments stay advisory.

Continue to compute coverage and display a distinction such as "An earlier
version was approved; later changes have not been reviewed. This repository
allows proceeding." Keep approval records bound to the actual reviewed work.
Acceptance records carry the policy and evidence used, not a false claim that
new contents were approved. Restoring the default requires current coverage on
subsequent integrations and leaves previous history intact.

Both settings off still require an explicit integration request, valid authority,
an exact current plan, preserved private work, and resolved file conflicts.
The risk warning concerns missed mistakes or incompatible behavior; turning
off a review pause does not turn off detection of conflicting file edits.

## Offline behavior and synchronization

Use downloaded review data offline. Members can prepare requests, comments, and
reviews locally and queue signed records for synchronization. Clearly identify
records not yet observed on the remote and the policy/authority state used.

In optional mode, direct local integration can proceed offline under the normal
rules. In required mode, approval evidence satisfying the effective repository
policy must be locally available and verifiable. A missing approval does not
stop editing, capture, or preparing a request; it blocks integration under a
policy that requires that approval.

On reconnect, retain concurrent reviews and submitted versions without treating
arrival order as authority. If a policy, authorization, request version, or
target has changed incompatibly, expose the discrepancy and re-evaluate the
integration against the effective policy. Never silently relabel stale approval
as approval of current content, including under a renewed-approval opt-out. The
TC06 admission rules govern these checks and divergent accepted histories.

## Acceptance scenarios

- A trusted member integrates directly in the default repository without being
  forced to create a review request, while preview confirmation still applies.
- Requesting review publishes only selected work and can be completed as one
  action; private scratch history remains private.
- A request survives updates, comments, approval, requested changes, closure,
  and successful integration, with each review bound to its actual version.
- Updating submitted contents does not inherit an old version's approval.
- Required mode blocks missing approval and, by default, uncovered changes even
  when preview confirmation is disabled or the caller attempts direct integration
  without a review request.
- Renewed approval defaults on. Authorized opt-out warns about unreviewed later
  changes, records policy and earlier evidence, and never relabels new work as
  approved. Missing/withdrawn approval and other policy blockers still apply.
- Either safeguard can be disabled without disabling the other. Both disabled
  still block unresolved file conflicts and invalid or stale integration plans.
- A member cannot satisfy another-reviewer policy using their own second device.
- Cached, valid approval supports offline integration; unavailable or invalid
  approval blocks only the gated integration, not local editing and history.
- Concurrent review and integration records survive synchronization in either
  order without silently erasing feedback, content, or policy conflicts.
- Opaque files can be reviewed using exact file/version summaries; absence of
  a format-specific visual diff does not bypass the approval boundary.

All of these flows follow the [CLI design](CLI_DESIGN.md), with clear explanations
of which version was reviewed, what remains unreviewed, and the next available
action. They must preserve D18's preview behavior, current-work recovery,
and the signed membership/authority boundaries. Further restrictions that add
material friction should be discussed with the user before extending this scope.
