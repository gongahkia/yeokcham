# ADR-092 — V4 exact decision-proposal assistance

- Status: Accepted
- Date: 2026-08-30
- Deciders: maintainers
- Implements: [#260](https://github.com/gongahkia/yeokcham/issues/260)
- Depends on: ADR-079 and the V4 decision/resolution model

## Context

An open V4 decision is durable evidence that visible shared revisions cannot
be composed under the conservative model.  It is not an error to be hidden,
nor permission for a tool to guess the team's intent.  Existing `decision
show`, `decision diff`, and `decision materialize` make the alternatives
inspectable, but leave a person to compare every path by hand.

The useful narrow assistance is to identify the paths whose exact snapshot
entries can be combined without inventing a byte, and to name the paths that
still need judgment.  A traditional three-way merge is not this boundary:
even `diff3` reports overlapping changes as conflicts rather than deciding
them. [GNU diffutils: diff3 merging](https://www.gnu.org/s/diffutils/manual/html_node/diff3-Merging.html)

## Decision

V4 adds a parser-free, ephemeral proposal calculation for a pair of revisions
in one currently open decision.

### Inputs and provenance

Each calculated proposal carries, and displays, the complete provenance tuple:

- open decision ID;
- current projection baseline snapshot ID;
- ordered left and right revision IDs;
- each revision's declared base and exact result snapshot IDs.

There is no project-wide "best" proposal and no score used to rank authors,
revisions, or pairs.  For a decision with more than two revisions, the CLI
lists the available pairs and requires the person to name the pair they want
to inspect.  This makes the comparison choice visible rather than accidental.

The calculation has no persistent proposal ID or lifecycle record.  It is
re-derived from the current open decision on every inspection and again
immediately before materialisation.  A past display is stale, and is refused,
when its decision is no longer open, either named revision is no longer a
candidate of that decision, their bases differ, or their common base is no
longer the current projection baseline.

### Exact, non-semantic composition

The engine compares all paths in the base, left result, and right result as
opaque exact entries: directory; or file mode plus content-object identity.
For every path it reports the three input entries and one of:

- unchanged base entry;
- take the left entry;
- take the right entry;
- identical left/right change; or
- a refusal reason, including competing creation, delete-versus-modify,
  file-versus-directory, mode mismatch, or different content identities.

It uses only this conservative rule:

1. Equal left and right entries are safe to select.
2. If one side equals the base, the other side is safe to select.
3. If both sides differ from the base and from each other, the path is not
   composed.

No source text is parsed; binary content, symlink target bytes, executable
mode, empty files, deletions, and directories follow the same rule.  The
engine never emits conflict markers or synthesized file bytes.  A ready
proposal therefore has `exact-source` confidence: every selected file byte and
mode is exactly from the named base, left, or right snapshot.  This confidence
describes mechanical byte provenance only.  It does not express confidence in
the user's intent.  Any refused proposal has no confidence value.

### Side information, materialisation, and human choice

Proposal data is non-canonical local convenience information.  It never enters
the V4 project state, signed revision, resolution record, package, relay,
bootstrap basis, authority graph, delivery, or transport receipt.  The tool
may create deduplicated immutable snapshot/tree objects solely to use the
existing safe materialiser; they are unnamed local objects, have no retention
promise, and are collectible.  No proposal object is a source of history or
intent.

Inspection is read-only.  `decision materialize-proposal` writes a ready
proposal only into a supplied empty destination outside the live working tree;
it rechecks the complete provenance before any destination write.  A refusal,
missing closure object, malformed snapshot, or stale input leaves the
destination and project head untouched.

There is deliberately **no accept-proposal event** and no reject-proposal
event.  A person may discard a suggestion by doing nothing.  If they judge the
materialised bytes appropriate, they separately invoke the existing explicit
`resolve --tree …` flow (or construct another tree).  That invocation creates
a new resolution revision and is the only durable record of the choice.  It
does not mutate either candidate and remains subject to ordinary signature and
resolution checks.

Semantic parsing and any richer structural assistance remain coordinated with
[#254](https://github.com/gongahkia/yeokcham/issues/254).  Parser output cannot
be authoritative, canonical, or a substitute for exact source bytes.

## Consequences

The feature can make a mixed decision easier to read: it identifies which
paths are mechanically unambiguous while preserving every unresolved path for
human judgment.  It cannot automatically combine independent textual hunks in
one file, infer rename intent, decide an ordering, repair a stale revision, or
select a delivery.  Those refusals are deliberate information, not failed
process state.

Because the proposal is recomputed rather than stored, it adds no protocol,
retention root, garbage-collection record, package compatibility rule, or
proposal replication problem.  The cost is that users must re-run the command
after the decision changes; this is preferable to presenting an old local hint
as current process state.

## Verification

- pure deterministic path classification and generated exact-source
  properties;
- competing-pair overview, same-candidate refusal, unequal-base refusal, and
  current-baseline staleness coverage;
- files, directories, deletion/modification, competing creation, mode,
  symlink, binary, empty-tree, and malformed/missing-closure cases;
- ready proposal materialisation, refusal-before-write, stale-before-write,
  no-live-working-tree mutation, and explicit later `resolve --tree` journey;
- CLI output that exposes provenance, confidence, every path outcome, and the
  absence of proposal acceptance or rejection commands.
