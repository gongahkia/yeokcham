# ADR-097 — V1 exact working-tree inspection

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: [#263](https://github.com/gongahkia/yeokcham/issues/263)

## Context

`status` answers whether the current exact scan differs from the active draft's
latest saved checkpoint, but does not identify the paths or exact snapshot
entries. A person evaluating daily local recovery needs that observation before
deciding whether to save, restore, share, or do nothing.

The observation must not collapse filesystem change into intent, turn source
into text patches, or masquerade as a generic repository verification command.
It must preserve the V1 boundary between local scratch and explicit shared
history.

## Current milestone and vertical slice

V1 onboarding and exact local inspection. The slice adds one local observation
adapter, `yeokcham changes`, plus documentation and command discovery. It adds
no model transition, persistent record, package format, authority rule, relay
request, semantic parser, Git interchange, clone workflow, or delivery state.

## Decision

`changes` loads the active draft's latest checkpoint, obtains an exact current
snapshot through the same scanner as `status`, and compares their canonical
tree entries in stable path order. Its result is:

```text
working_tree_comparison = {
  saved_checkpoint : snapshot_id;
  observed_snapshot : snapshot_id;
  differences : path_difference list;
}

path_difference = {
  path : path;
  before : snapshot_entry option;
  after : snapshot_entry option;
}
```

A snapshot entry is either a directory or a file with its exact mode and
content-object identity. An absent side denotes create/delete; a changed file
or mode has both sides. The command emits an explicit unchanged result when the
list is empty. It reports no inferred moves, textual patches, semantic meaning,
or intent.

The scanner excludes root `.yeokcham` and `.git`, as `status` does. Scanning
may store immutable unreferenced objects for the observed snapshot. This is not
a state-head update and those objects remain eligible for ordinary local
collection. The adapter never writes source, creates a checkpoint, changes a
draft, signs, shares, resolves, delivers, imports a package, or contacts a
relay.

## Invariants

1. `saved_checkpoint` is the latest checkpoint of the active draft loaded from
   the current state head; `observed_snapshot` is the exact scan result.
2. Every difference is a canonical path and a complete before/after exact
   entry. Equal entries are absent; output is stable path order.
3. An empty difference list is an explicit comparison outcome, not inferred
   user intent or a hidden save.
4. Apart from immutable unreferenced scan objects already permitted by
   `status`, inspection changes no repository state, source byte, custody,
   authority, package, relay, delivery, or semantic sidecar.
5. `changes` is deliberately a local comparison, not a generic `verify` or
   scan command.

## Persistent-format impact

None. The view reuses existing snapshot objects and canonical tree traversal;
it adds no persisted record, schema version, or golden fixture.

## Verification

Service and CLI tests cover unchanged, create, delete, file-content change,
mode change, directory entries, stable path ordering, help/version success,
invalid invocation failure, state-head preservation, and working-tree byte
preservation. The repository-wide suite remains the final integration check.
