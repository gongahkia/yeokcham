# ADR-075 — Git archive selection and capability provenance

- Status: Accepted
- Date: 2026-08-15
- Deciders: maintainer
- Governing issue: [#234](https://github.com/gongahkia/yeokcham/issues/234)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-074 introduced a self-contained Git bundle archive. The first implementation
archived every visible ref and retained only its object format. That is a useful
safe default, but it does not satisfy a migration user who deliberately chooses
a subset of refs, nor does it preserve the inspected source capability report
as foreign provenance.

Changing a previously published `Git_archive_v1` payload in place would make old
bytes ambiguous or unreadable. The extension therefore needs an additive,
versioned record rather than a reinterpretation of V1.

## Decision outcome

New archives use `Git_archive_v2`.

Creation accepts either no ref selection, which means all currently enumerated
refs, or an explicit nonempty set of exact ref names. The implementation
enumerates the source with replace refs disabled, rejects an absent, duplicate,
or malformed requested name before it writes archive content, and passes the
selected names to `git bundle create`. The sorted selected inventory is checked
again after bundle creation to detect a source-ref change.

V2 records the source capability report as:

```text
git-archive-capability-v1 = [is-bare-repository, git-object-format]
git-archive-identity-v2 = [2, git-archive-capability-v1, [* git-archive-ref-v1]]
git-archive-v2 = [
  2, git-archive-id, git-archive-capability-v1, bundle-content-object-id,
  [* git-archive-ref-v1]
]
```

`is-bare-repository` is a Boolean obtained from Git's documented
`rev-parse --is-bare-repository`; `git-object-format` is the existing SHA-1 or
SHA-256 code. Neither a source path nor user configuration, remotes, hooks,
credentials, indexes, reflogs, or working-tree state is retained.

The V2 logical ID uses its own `yeokcham:git-archive:v2\000` domain. V1 decode
and its `yeokcham:git-archive:v1\000` identity remain supported. A loaded V1
archive reports an unavailable capability report rather than inventing one.
The create-only archive binding remains V1 because its contents already bind a
logical archive ID to one immutable physical object and need no schema change.

## Consequences

- Git users can preserve only the refs they chose, while the all-refs default
  remains inspectable and safe.
- A capability report describes the source without turning source-local
  operational state into Yeokcham state.
- Existing V1 archive bytes remain readable; newly created V2 records never
  replace them.
- Explicit native adoption is defined by ADR-076; selection and archive
  provenance do not infer capsule or release intent.

## Verification

- Golden fixtures and decode coverage for both V1 and V2 archive records.
- Real Git fixtures for all-ref and selected-ref archives, including absent and
  duplicate requested refs before publication.
- Preservation/exit tests compare the selected inventory and run `git fsck`.
- Generated archive/exit tests retain byte and executable-mode coverage.
