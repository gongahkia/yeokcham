# ADR-079 — V1 small-team change composer

- Status: Accepted
- Date: 2026-08-27

## Context

Earlier Yeokcham experiments separated more concepts than the daily V1 user
model needs. V1 targets solo developers and small multidisciplinary teams that
want recovery and collaboration without Git procedure.

## Decision

V1 is a side-by-side, native repository format governed by
[`V1_PRODUCT_CONTRACT.md`](../V1_PRODUCT_CONTRACT.md).  Its primary user model
is saved, shared, needs-a-decision, and delivered.  It has one active explicit
draft, project-wide explicit sharing, live immutable revisions, conservative
non-overlap composition, durable decisions, and manual delivery.

Exact snapshots, canonical storage, guarded restore, retention, Linux watcher
normalisation, and property-test practices may be retained behind V1
interfaces. Capsules, workspaces, Git interchange, and prior ledger/MLS
records do not define the V1 core model; Git interchange is not a V1
capability. Transport is a future adapter boundary;
V1 currently supports only verified local directory packages.

The first V1 persistent adapter uses the proven immutable object store only as
a storage substrate. It reserves `V1_project_state` and one `v1-project-state`
compare-and-swap head. V1 initialization refuses an existing `.yeokcham`
directory, so a V1 command never treats a previous Yeokcham format as V1 state.

## Consequences

The V1 core starts as pure OCaml transitions and generated tests.  Persistent
V1 records need a new versioned format and golden fixtures; no existing
Yeokcham repository is migrated in place.  End-to-end transport is substantial:
membership removal and device enrollment require explicit epoch and key-rotation
semantics.  Named work areas, named administrators, validation gates, Git
compatibility, and semantic merge are deferred.

## Verification

The V1 contract lists the required unit, property, failure, fixture, exchange,
and CLI evidence.  No persistent V1 object or transport adapter is accepted
without those tests.
