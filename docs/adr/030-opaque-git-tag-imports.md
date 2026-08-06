# ADR-030 — Opaque Git tag imports

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-03 must import Git tag references without allowing Git labels to redefine
Yeokcham releases, capsules, or histories. Git distinguishes a lightweight tag,
which is a reference directly naming an object, from an annotated tag object
with a target, a tagger, a message, and possibly a signature. [git-tag](https://git-scm.com/docs/git-tag)

ADR-028 deliberately supports only tree and commit mapping kinds. ADR-029 adds
opaque commit provenance but intentionally defers tags. A tag import must retain
the exact reference name and target identity, preserve annotated tag bytes
without parsing metadata into Yeokcham intent, and keep v1/v2 mappings unchanged.

## Decision drivers

- Preserve lightweight and annotated tag provenance without creating a Yeokcham
  release or inferring authorial intent.
- Retain annotated tagger/message/signature bytes exactly and boundedly.
- Keep tag names and Git IDs type-distinct from Yeokcham identifiers and local
  paths.
- Reject malformed refs, malformed tag headers, unsupported target kinds, and
  process/size failures before canonical visibility.
- Preserve ADR-028 v1 and ADR-029 v2 payloads, identities, bindings, and
  goldens byte-for-byte.

## Considered options

### Reuse Yeokcham release or capsule records

- Makes a familiar user-visible label available immediately.
- Fabricates Yeokcham release/capsule meaning from a Git label and violates
  ADR-009.

### Store only a Git mapping to the resolved target

- Requires no new persistent record.
- Loses the tag name and cannot preserve annotated wrapper bytes or distinguish
  a lightweight ref from an annotated tag object.

### Add opaque imported-tag records and Git-mapping v3

- Preserves a tag reference, its exact object provenance, and annotated bytes
  while remaining outside Yeokcham histories and releases.
- Adds a typed record, binding, mapping kind/subject, v3 decoder, and retained
  compatibility coverage.

## Decision outcome

Select the third option.

Add Envelope type `Imported_tag = 25`, a type-distinct `Imported_tag_id`, and
`Git_tag` object kind code `3` for mappings. An `Imported_tag_v1` records a
byte-exact tag name, the object directly named by `refs/tags/<name>`, and one
of these representations:

```text
imported-tag-v1 = [
  1, imported-tag-id, tag-name-bytes, ref-object-id, tag-representation
]

lightweight-tag-v1 = [0, target-kind]
annotated-tag-v1 = [1, tagged-object-id, target-kind, annotation-content-id]
target-kind = 1 / 2 / 3                 ; commit / tree / blob
```

For a lightweight tag, `ref-object-id` is its target and `target-kind` is the
exact verified Git object type. For an annotated tag, `ref-object-id` is the
Git tag-object ID, `tagged-object-id` and `target-kind` come from exactly one
raw `object` and `type` header, and `annotation-content-id` references the
exact raw `cat-file tag` bytes through `Snapshot.Content`. The raw bytes retain
the `tag` header, tagger, message, and any signature without claiming their
meaning or validity. The raw `tag` header must occur exactly once and equal the
imported tag-name bytes. Signed tags are retained but never signature-verified
by this slice.

Only direct commit, tree, and blob targets are supported. A ref resolving to a
tag object is imported as its annotated-tag object representation, so a
requested ref name differing from the raw `tag` header rejects. Nested annotated
targets, tag deletion/rewrites, symbolic refs, and signature verification reject
or remain future work. Git permits annotated and lightweight tags to name general
objects; this restriction is deliberate. [git-tag](https://git-scm.com/docs/git-tag)

The logical identity is:

```text
SHA-256("yeokcham:imported-tag:v1\\000" ||
        encode([1, tag-name-bytes, ref-object-id, tag-representation]))
```

The record excludes itself and observation data. Its physical
`Stored_object_id` remains ADR-020's Envelope identity. Its sole visibility
point is a create-only, checksummed binding:

```text
.yeokcham/refs/imported-tags/<lowercase-imported-tag-id-hex>
imported-tag-binding-v1 =
  [1, imported-tag-id, imported-tag-object-id, checksum]
checksum = SHA-256("yeokcham:imported-tag-binding:v1\\000" ||
                 encode([1, imported-tag-id, imported-tag-object-id]))
```

Add `Git_mapping_v3` in Envelope type 23. It retains every v1/v2 subject and
adds only:

```text
imported-tag-v1-subject = [5, imported-tag-id, imported-tag-object-id]
import/tag -> imported-tag-v1-subject
```

`Git_mapping_id` v3 uses domain separator `"yeokcham:git-mapping:v3\\000"`; its
versioned binding uses a v3 checksum domain. A v1 decoder accepts only v1
records, a v2 decoder accepts only v2 records, and a v3 decoder accepts only
the v3 forms. No pre-v3 record, identity, binding, or golden byte changes.

M8-03 resolves exactly one `refs/tags/<name>` through bounded direct-argv Git
plumbing, compares the returned ref name byte-for-byte, and verifies every
referenced object type with `cat-file -t`. Annotated tag raw bytes are bounded
by `max_tag_bytes` before `Snapshot.Content.store` and publication. The command
is `yeokcham git import tag --repository <absolute-git-directory> --tag <name>`.

## Consequences

- Imported tags are inspectable opaque provenance, not releases, capsules,
  branches, or mutable Yeokcham refs.
- A tag target can be recorded before an associated tree or commit is imported.
- Annotated metadata and signatures are retained as raw bytes but are not parsed
  as canonical Yeokcham fields and carry no authenticity claim.
- A tag ref can change in Git; each distinct observed imported-tag record stays
  immutable and visible by its own ID rather than rewriting a prior record.
- Importing raw annotation content, publishing the tag record, and publishing
  the mapping are separate immutable visibility points; retry verifies/reuses
  exact objects or reports a structured mismatch.

## Model and invariant impact

- `imported_tag_id`, Git IDs, content IDs, stored-object IDs, and Yeokcham history
  IDs remain incompatible types.
- A visible tag record has one valid raw tag name, one direct ref Git ID, and a
  representation consistent with its exact object types.
- Lightweight targets and annotated tagged targets are commit, tree, or blob
  IDs in the same Git hash format as the direct ref object.
- Annotated raw bytes load exactly from `annotation-content-id`; their header
  target, type, and name agree with the record and requested ref.
- No imported tag can advance, substitute for, or redefine a checkpoint,
  capsule, revision, workspace, conflict, release, or release attestation.

## Persistent-format and migration impact

This is additive: Envelope type 25, `Imported_tag_v1`, one binding namespace,
`Git_tag` mapping kind, and `Git_mapping_v3` are new. Existing Envelope types
1–24, mapping v1/v2 records, bindings, and goldens remain byte-identical.
Existing repositories have no imported-tag bindings. No object or ref is
rewritten in place. Unknown mandatory features remain rejected.

## Verification

- Completed: lightweight and annotated SHA-1 unit/reopen/retry tests, raw
  annotation-byte retention, imported-tag and mapping-v3 golden fixtures,
  malformed tag-data rejection, corrupt binding rejection, and generated
  lightweight/annotated tag retries with bounded names.
- Completed: `make check`, `make property-test PROPERTY_TEST_SEED=17`, and the
  tag-focused generated property suite with seed 17.
- Pending separately: SHA-256 fixtures, commit/tree/blob target coverage,
  signature-like/nested-name fixtures, duplicate headers, target/type mismatch,
  size limits, corrupt content/record, and interruption coverage. No retained
  signature implies correctness or authenticity.

## CLI and user impact

`yeokcham git import tag --repository <absolute-git-directory> --tag <name>`
reports imported-tag, mapping, direct Git object, and representation IDs. For
annotated tags it reports that raw annotation bytes were retained but the tag is
not a Yeokcham release and its signature was not verified.
