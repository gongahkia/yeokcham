# ADR-079 — V4 small-team change composer

- Status: Accepted
- Date: 2026-08-27

## Context

Yeokcham V3 separates scratch, capsules, workspaces, and releases.  That is a
useful research model, but it exposes too many daily concepts for the target
audience: solo developers and small multidisciplinary teams that want recovery
and collaboration without Git procedure.

## Decision

V4 is a side-by-side, native repository format governed by
[`V4_PRODUCT_CONTRACT.md`](../V4_PRODUCT_CONTRACT.md).  Its primary user model
is saved, shared, needs-a-decision, and delivered.  It has one active explicit
draft, project-wide explicit sharing, live immutable revisions, conservative
non-overlap composition, durable decisions, and manual delivery.

Exact snapshots, canonical storage, guarded restore, retention, Linux watcher
normalisation, and property-test practices may be retained behind V4
interfaces.  Capsules, workspaces, Git interchange, and V2 ledger/MLS records
do not define the V4 core model.  Transport is an adapter boundary; trusted,
direct, managed, and end-to-end encrypted delivery of the same signed change
records are supported without changing source-control semantics.

The first V4 persistent adapter uses the proven immutable object store only as
a storage substrate. It reserves `V4_project_state` and one `v4-project-state`
compare-and-swap head. V4 initialization refuses an existing `.yeokcham`
directory, so a V4 command never treats a previous Yeokcham format as V4 state.

## Consequences

The V4 core starts as pure OCaml transitions and generated tests.  Persistent
V4 records need a new versioned format and golden fixtures; no existing
Yeokcham repository is migrated in place.  End-to-end transport is substantial:
membership removal and device enrollment require explicit epoch and key-rotation
semantics.  Named work areas, named administrators, validation gates, Git
compatibility, and semantic merge are deferred.

## Verification

The V4 contract lists the required unit, property, failure, fixture, exchange,
and CLI evidence.  No persistent V4 object or transport adapter is accepted
without those tests.
