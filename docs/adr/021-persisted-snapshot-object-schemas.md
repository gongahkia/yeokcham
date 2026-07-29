# ADR-021 — Persisted snapshot object schemas

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (approved continuation of Milestone 1 on 2026-07-30)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 0's in-memory snapshot payload intentionally embeds file bytes and remains a retained model fixture. Milestone 1 needs immutable content, tree, and snapshot objects that reference typed stored-object IDs without changing those existing model bytes.

## Decision drivers

- Preserve exact regular-file and symlink-target bytes.
- Make file content independently deduplicable and tree ordering canonical.
- Keep stored-object IDs distinct from semantic model identities.
- Define small versioned schemas compatible with Profile 1 and Envelope 1.

## Considered options

### Reuse the in-memory snapshot payload

- Retains existing fixtures unchanged.
- Embeds content in every snapshot and cannot represent independently stored trees or content.

### Store raw bytes outside Envelope 1

- Minimises content overhead.
- Bypasses typed envelope verification and creates a second integrity path.

### Versioned Content, Tree, and Snapshot Envelope 1 payloads

- Preserves exact bytes while making content and subtrees immutable and reusable.
- Adds explicit schema readers, fixtures, and reference validation.

## Decision outcome

All records below are Paengi CBOR Profile 1 arrays inside an Envelope 1 with object-format version `1` and mandatory-feature mask `0`.

```text
content-v1  = [1, bytes]
tree-v1     = [1, tree-entries-v1]
tree-entries-v1 = [*tree-entry-v1]
tree-entry-v1 = file-entry-v1 / directory-entry-v1
file-entry-v1 = [0, name-bytes, mode, content-object-id]
directory-entry-v1 = [1, name-bytes, tree-object-id]
snapshot-v1 = [1, root-tree-object-id]
```

`name-bytes` is one nonempty path component; it rejects `/`, NUL, `.`, and `..`. Tree entries are strictly ascending bytewise lexical `name-bytes` and unique. `mode` is `0` regular, `1` executable, or `2` symlink. Every referenced stored-object ID is exactly 32 raw bytes in the payload and maps to the abstract `Stored_object_id` type. Content, tree, and snapshot wrapper IDs remain type-distinct in the OCaml API even though all resolve through the generic immutable store.

The scanner stores a symlink target as content bytes and does not follow the link. It excludes the root `.paengi` directory. The initial `.paengiignore` syntax is deliberately narrow: each non-empty, non-comment line is one exact safe relative path; it ignores that path and descendants, supports no globbing, and rejects unsafe paths.

## Consequences

- Existing Milestone 0 snapshot envelopes and golden fixtures are not modified or reinterpreted.
- Identical file bytes and identical subtrees reuse the same stored objects.
- Files larger than the currently bounded inline object size return a structured error until the later manifest/chunk slice; no byte-correct large-file claim is made yet.
- Unsupported filesystem node kinds return structured scan errors rather than being silently omitted.

## Model and invariant impact

- `Content_id`, `Tree_id`, and persisted `Snapshot_id` are distinct wrappers over `Stored_object_id`.
- A tree decoder rejects noncanonical names, duplicate or unordered entries, invalid modes, malformed IDs, unknown versions, and wrong object types.
- A snapshot decoder rejects every payload except one version and one root-tree ID.
- Scanning the same directory state under the same ignore rules yields the same stored snapshot identity; timestamps do not contribute.

## Persistent-format and migration impact

This adds new Envelope-1 object payload schemas at object-format version `1`; no prior persistent content/tree/snapshot schema exists. Existing model payload schemas remain supported as separate, retained test fixtures. A future schema change increments the scoped object-format version or introduces a new object type with a new ADR, retained v1 fixtures, and coexistence or migration publication.

## Verification

- Golden Envelope-1 fixtures for content, tree, and snapshot objects.
- Unit tests for canonical order, exact bytes/modes/symlink targets, ignored paths, `.paengi` exclusion, and object-type rejection.
- Bounded deterministic properties for scan determinism and content/tree reuse.
- Failure tests for malformed schema payloads, invalid ignore entries, unreadable/unsupported nodes, and invalid reference IDs.
- Materialisation round-trip tests are required in the following vertical slice.

## CLI and user impact

No CLI command is introduced. The adapter exposes structured scan and schema errors; future scan/status commands can report ignored paths and unsupported node kinds.
