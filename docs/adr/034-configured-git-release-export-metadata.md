# ADR-034 — Configured Git release-export metadata

- Status: Proposed
- Date: 2026-08-05
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-10 must let a caller configure author, committer, and message metadata for
one exported immutable Paengi release. ADR-009 keeps Git as interchange;
ADR-028 supplies immutable export mappings; and ADR-032 deliberately fixed
release-export metadata and ref naming to preserve deterministic retry. Allowing
metadata that changes a Git commit requires a new policy for validation,
metadata identity, target refs, retry, and the boundary between Git presentation
and Paengi identity.

Current milestone: M8 Git Bridge. Vertical slice: one verified release, one
existing absolute Git repository, one optional explicit complete metadata
triple, one Git root commit, one deterministic metadata-qualified Git ref, and
one existing ADR-028 `Exported_release` mapping. It excludes configured
capsule-revision export, metadata persistence in Paengi, source author
inference, signatures, tags, remotes, and arbitrary Git configuration.

## Decision drivers

- Configured fields must become exact Git commit fields or fail structurally.
- A metadata choice must not change a Paengi release ID, stored object, final
  snapshot, current ref, or release semantics.
- Different metadata choices must not collide on ADR-032's release-only ref.
- Retry with the same release and metadata must reproduce the same commit,
  external ref, and mapping; ambient Git author, committer, clock, encoding,
  hooks, filters, and configuration must not decide output.
- Existing default M8-08 commit IDs, refs, mappings, schemas, and goldens must
  remain byte-identical.

## Considered options

### Change the existing release ref for every metadata choice

- Minimal implementation.
- A new configured commit collides with an existing default or differently
  configured export of the same release and makes legitimate retry ambiguous.

### Persist a Paengi export-policy object

- Makes a presentation policy durable and shareable.
- Adds new canonical storage and lifecycle semantics before the first explicit
  caller-selected metadata slice needs them.

### Use explicit invocation metadata and a metadata-qualified external ref

- Preserves deterministic repeatability for an exact invocation without making
  Git presentation input Paengi state.
- Requires callers to repeat the same metadata on retry and defers shared or
  named policies to a later ADR.

## Decision outcome

Select the third option.

M8-10 adds these non-persistent values:

```ocaml
type git_identity = { name : string; email : string }

type release_export_metadata = {
  author : git_identity;
  committer : git_identity;
  message : string;
}
```

`export_release` accepts either no metadata, retaining ADR-032 exactly, or one
complete `release_export_metadata` value. A partial CLI configuration is an
error. The CLI spelling is `--author-name`, `--author-email`,
`--committer-name`, `--committer-email`, and `--message`; all five must occur
once to select explicit metadata. The configured names and emails are bounded,
nonempty, and reject NUL, CR, LF, angle brackets, and invalid mailbox shape.
The message is bounded by the existing Git commit limit and may contain exact
non-NUL bytes. Invalid values fail before Git objects, refs, or mappings are
published.

For an explicit value, Git author and committer headers are exactly
`<name> <email> <release-created-at> +0000`, using the separately configured
author and committer pairs and the release's existing nonnegative `created_at`
timestamp. The Git message is exactly the supplied message bytes. The exporter
uses direct argv and explicit environment only, reads the produced commit back,
and verifies tree, zero parents, both metadata headers, and message bytes
before publication. The headers are Git presentation metadata, not Paengi
authorship, intent, signature, or validation evidence.

The existing default target ref remains
`refs/heads/paengi/release-<release-id>`. An explicit metadata invocation uses
`refs/heads/paengi/release-<release-id>-metadata-<sha256-hex>`. The suffix is
SHA-256 of a domain-separated, length-delimited canonical concatenation of
author name/email, committer name/email, and message bytes. It is an external
ref selector only, not a Paengi ID, object, ref, or assertion. Both ref forms
are create-only unless they already name the exact computed commit. Therefore
the same release can have distinct inspectable Git exports for distinct
metadata, while an identical retry is idempotent.

The existing ADR-028 `Exported_release` mapping remains unchanged: it names the
release ID, release object ID, final snapshot ID, Git object format, and exact
commit ID. Different metadata produces a different Git commit and therefore a
different mapping ID without changing the source release. Ref and mapping
publication remain separately visible and retryable as in ADR-032.

M8-10 does not alter `export_revisions`; ADR-033's fixed revision metadata and
sequence ref policy remain in force. Configured per-revision metadata requires
a separate ordered metadata policy and decision.

## Consequences

- Configured release metadata is exact, explicit, and deterministic for the
  exact invocation.
- Default M8-08 export output and ref naming remain compatible.
- Retry with changed metadata is a distinct external export, not a mutation of
  a previous export or a Paengi release.
- Paengi cannot later reconstruct caller-selected metadata from canonical
  storage alone; Git commit/mapping inspection remains the evidence.
- Sharing, naming, or defaulting an export policy is deferred.

## Model and invariant impact

The pure result remains `release_export_result`; its target-ref value is now
selected by `metadata : release_export_metadata option`.

- `release`, `release_object`, `snapshot`, `tree`, `commit`, and `mapping`
  remain type-distinct.
- Absent metadata reproduces ADR-032's metadata, commit, ref, and mapping.
- Present metadata affects only Git commit presentation, external ref selection,
  and the resulting mapping's Git object; it cannot alter Paengi data.
- A visible configured export commit has no parents, the exact final snapshot
  tree, the exact configured headers/message, and the metadata-qualified ref.
- Retry cannot overwrite a Git ref, a mapping, or a Paengi release.

## Persistent-format and migration impact

No Paengi persistent object, ref, schema, or mapping payload is added. ADR-027
release v1, ADR-028 mapping v1-v3, binding encodings, and all current goldens
stay byte-identical. Metadata input, its ref suffix, temporary message/index
files, and Git objects are invocation or external interchange artifacts.

## Verification

After acceptance, implementation must add focused fixtures for default-output
compatibility; independently configured author/committer/message bytes; empty
and bounded messages; invalid/partial configuration; metadata-qualified ref
determinism and collision; default/explicit noncollision; restart;
pre-ref/pre-mapping interruption; mapping corruption; `git fsck --full`; and
checkout equivalence. A bounded generated property must vary valid metadata and
prove exact headers/message, deterministic retry, unchanged release identity,
and distinct metadata ref/commit output. `make format`, `make check`, and
`make property-test PROPERTY_TEST_SEED=17` are required before issue closure.

## CLI and user impact

After acceptance:

```text
paengi git export release --repository <absolute-git-directory> \
  --release <release-id> \
  --author-name <name> --author-email <email> \
  --committer-name <name> --committer-email <email> \
  --message <message>
```

The command reports the selected metadata policy, exact external ref, and
mapping ID. It does not claim to change release authorship, infer a user, use
ambient Git configuration, or configure capsule-revision exports.
