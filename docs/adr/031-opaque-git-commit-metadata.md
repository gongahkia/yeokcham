# ADR-031 — Opaque Git commit metadata imports

- Status: Proposed
- Date: 2026-08-05
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-02 persists only a commit ID, declared tree, imported snapshot, and ordered
parent IDs in `Imported_transition_v1`. M8-04 must retain the source commit's
author identity, committer identity, timestamps/time zones contained in those
identities, and message without turning Git metadata into Paengi capsule,
revision, release, or authorial-intent semantics. Git commit objects include
parent IDs, author/committer identities with dates, and a log message; Git core
does not require commit messages to be UTF-8. [git-commit-tree](https://git-scm.com/docs/git-commit-tree)

The existing `Imported_transition_v1`, its logical ID, its binding, and
Git-mapping v1–v3 records are durable contracts. A metadata slice must preserve
v1 records byte-for-byte, must not overwrite a v1 transition binding, and must
remain bounded against malformed byte input.

## Decision drivers

- Preserve source metadata byte-exactly without a lossy text conversion or an
  unsupported identity/date parser.
- Make author, committer, time-zone/timestamp bytes, and message explicit
  provenance without treating them as Paengi meaning.
- Keep transition identity, content identity, physical object identity, and
  observational time distinct.
- Reuse durable publication only where existing binding semantics remain exact;
  retain mapping v1–v3 compatibility.
- Reject absent, duplicate, malformed, oversized, or unavailable metadata
  before transition visibility.

## Considered options

### Keep metadata outside persistent transition records

- Avoids a schema addition.
- Cannot reopen or verify provenance after the source Git repository changes or
  disappears.

### Parse identities/dates into normalized author fields

- Provides convenient query fields.
- Risks lossy handling of non-UTF-8 bytes and makes Paengi interpretation the
  canonical source instead of Git's raw representation.

### Add `Imported_transition_v2` with raw identity bytes and message Content

- Retains author and committer header values byte-for-byte, including their
  source timestamp/time-zone bytes, and keeps message bytes in immutable
  `Snapshot.Content`.
- Adds one versioned transition payload/identity decoder while leaving the
  existing Envelope type, binding format, IDs, and mapping schemas intact.

## Decision outcome

Select the third option.

`Imported_transition_v2` remains Envelope type 24 and uses the existing
type-distinct `Imported_transition_id` and `refs/imported-transitions/` binding.
It extends only the payload schema:

```text
imported-transition-v2 = [
  2, imported-transition-id, git-commit-id, git-tree-id, snapshot-id,
  [* ordered-parent-git-commit-id], author-identity-bytes,
  committer-identity-bytes, message-content-id
]
```

`author-identity-bytes` and `committer-identity-bytes` are the exact bytes
after raw `author ` and `committer ` prefixes. They remain bytes, not UTF-8
text. They include source timestamp/time-zone bytes; Paengi does not validate,
normalize, calculate with, or otherwise interpret those fields.
`message-content-id` addresses the exact bytes after the first commit-header
blank line through `Snapshot.Content`, including an empty message or invalid
UTF-8. It is source provenance, not a semantic sidecar.

M8-04 requires exactly one nonempty `author` and `committer` header before the
first blank line. It retains arbitrary non-NUL bytes in their values and accepts
unrelated standard/extension headers through M8-02 continuation handling.
Missing, duplicate, empty, NUL-containing, malformed, or
over-`max_commit_bytes` records return `Invalid_commit`; no parser assumes text
encoding. The existing bounded raw commit read remains the size limit for
identities and message.

The v2 logical identity is:

```text
SHA-256("paengi:imported-transition:v2\\000" ||
        encode([2, git-commit-id, git-tree-id, snapshot-id,
                [* parent-git-commit-id], author-identity-bytes,
                committer-identity-bytes, message-content-id]))
```

It excludes itself and observations. The existing v1 binding encoding continues
to bind one typed transition ID to one exact stored object, and may bind a v1 or
v2 record because the object payload decoder selects its schema. No mapping
payload change is required: Git-mapping v3 already permits
`import/commit -> imported-transition`, whose subject includes the typed ID and
verified physical object. New imports use mapping v3; v1/v2/v3 payloads,
identities, bindings, and goldens remain unchanged.

`paengi git import commit` continues to import one commit and declared tree. It
reports transition, snapshot, mapping, commit, parents, and metadata
content/byte identifiers in escaped or hex-safe form; it never prints untrusted
raw bytes directly. A future display command may define presentation policy.

## Consequences

- A v1 transition remains readable but has no synthetic metadata. Reimporting a
  commit after M8-04 creates a distinct v2 transition instead of mutating v1.
- Message Content can become visible before transition/mapping bindings; that is
  a retryable incomplete state under ADR-020.
- Timestamp display/interpretation, signature verification, encoding
  conversion, Git notes, trailers, and recursive graph import remain out of
  scope.

## Model and invariant impact

- `Imported_transition_v1` and `Imported_transition_v2` are distinct persistent
  forms sharing one typed external ID interface.
- A visible v2 transition has exactly one same-format commit/tree/parent set,
  one verified snapshot, nonempty raw author/committer bytes, and one loadable
  exact message Content object.
- Its logical ID changes for a provenance-field change; Snapshot/Content/
  Stored-object/Git IDs remain incompatible types.
- No metadata value can advance, substitute for, or redefine a checkpoint,
  capsule, revision, workspace, conflict, release, validation, or attestation.

## Persistent-format and migration impact

This is additive within Envelope type 24: add only the v2 payload and
domain-separated v2 logical ID decoder/encoder. Keep the v1 payload, v1
identity domain, v1 binding bytes, binding namespace, Envelope type, and every
Git-mapping v1–v3 byte unchanged. Existing repositories retain v1 bindings; no
record or ref is rewritten in place. Unknown transition versions reject.

## Verification

- Unit/golden fixtures for deterministic v2 SHA-1 payload/binding and retained
  v1 transition plus mapping v1–v3 goldens.
- Local fixtures for differing author/committer time zones, multiline/empty
  messages, invalid UTF-8 message bytes, reopen, and equal retry.
- Generated bounded raw identity/message bytes prove byte retention, v2 identity
  determinism, and snapshot identity independence from metadata.
- Failure tests cover missing/duplicate/empty/NUL metadata headers, content and
  transition/binding corruption, size limits, and interruption before bindings.
- Run `make check` and `make property-test PROPERTY_TEST_SEED=17`; benchmark
  separately. No retained identity/timestamp implies authenticity.

## CLI and user impact

The existing commit-import command gains safe inspectable metadata identifiers.
Users receive opaque Git provenance, not a Paengi author, release, capsule, or
claim that an identity/timestamp/message is trustworthy.
