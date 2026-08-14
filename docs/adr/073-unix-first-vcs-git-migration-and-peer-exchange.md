# ADR-073 — Unix-first native VCS, Git migration, and direct peer exchange

- Status: Accepted
- Date: 2026-08-15
- Deciders: maintainer
- Governing issues: [#233](https://github.com/gongahkia/yeokcham/issues/233), [#234](https://github.com/gongahkia/yeokcham/issues/234), [#235](https://github.com/gongahkia/yeokcham/issues/235), and [#236](https://github.com/gongahkia/yeokcham/issues/236)
- Supersedes: the V2 hosted, team, web, mesh, and MLS delivery direction
- Superseded by: None

## Context and problem statement

Yeokcham is intended to become a usable alternative VCS, not a hosted Git
integration product. Its distinct model is the separation of bounded recovery
history, curated intent, and immutable release history. The existing local V2
root implements much of that core and remains the current CLI substrate. The
V2 programme also added user/device authority, MLS, hosted services, review,
web UI, relay infrastructure, and IDE integration before proving a coherent
user workflow. That expansion is larger than the supported product direction
and does not make a Unix CLI easier to adopt.

Adoption nevertheless requires an honest Git boundary. A user must be able to
preserve a selected Git history before trying Yeokcham, explicitly turn chosen
Git work into Yeokcham intent, and later resume ordinary Git work from an
export. This is a preservation and projection problem, not a claim that a Git
commit, branch, or merge has the same meaning as a Yeokcham capsule,
workspace, conflict, or release.

Native sharing is also required for Yeokcham to become a VCS in its own right.
It must begin as deliberate peer repository exchange, however, rather than as
a hosted service or an internet mesh.

## Decision drivers

- Keep the primary product small enough to inspect, test, and use locally on
  macOS and Linux.
- Preserve the scratch, intent, and release distinction through every adapter.
- Give a Git user a safe entry and exit path without making Git canonical.
- Make peer exchange explicit, failure-aware, and useful without discovery,
  relays, accounts, or a web service.
- Use documented, stable Git interfaces rather than depending on `.git` pack
  layout or private configuration.

## Considered options

### Complete the V2 encrypted hosted platform

- Provides an ambitious collaboration and security programme.
- Couples the local CLI to identity, encryption, MLS, service, browser, and
  relay work that is not needed for the selected product.

### Make Git the collaboration runtime

- Reuses existing hosting and transport infrastructure.
- Reduces Yeokcham to a history-authoring front end and loses its native VCS
  boundary.

### Unix local core, explicit Git migration, then direct peer exchange

- Proves the differentiated model before distribution.
- Gives adopters a reversible path and keeps network topology replaceable.
- Requires disciplined, explicit mapping limits instead of pretending to offer
  automatic semantic equivalence.

## Decision outcome

Select the Unix local core, explicit Git migration, and direct peer exchange
option.

The supported core is a local CLI on macOS and Linux. Its canonical source of
truth remains exact bytes and the existing versioned portable local object
model, currently rooted in the V2 local format. That implementation detail does
not revive the retired hosted/MLS roadmap. Automatic scratch capture may use a
scanner or an advisory watcher, but a hosted account, network endpoint, or Git
repository is not a prerequisite for the supported local workflow.

Git is a compatibility and migration adapter with three explicit operations:

1. **Preserve** a selected Git ref set and its reachable commit, tree, blob,
   annotated-tag, and ref provenance as immutable foreign evidence. Original
   Git IDs and ref names stay Git identities; they are never Yeokcham logical
   identities.
2. **Adopt** only a user-selected subset of that evidence into capsules,
   workspaces, and releases. No importer infers that a Git commit represents
   a logical capsule or that a Git merge resolves a Yeokcham conflict.
3. **Exit** by reconstructing a valid Git repository with the preserved Git
   archive and separately named exports of selected Yeokcham releases or
   ordered capsule revisions. An exported standard Git history is a projection
   and cannot recover Yeokcham-only semantics by itself.

The import adapter uses documented Git plumbing and validates source capability
before it publishes Yeokcham state. Git's documented bundle format can carry
reachable Git objects and refs for offline transfer, but it excludes working
tree, index, configuration, and hooks; Yeokcham makes the same boundary
explicit rather than claiming a complete `.git` directory clone.

Native peer exchange transfers only explicitly published capsule revisions and
releases. Scratch checkpoints remain local by default. The initial transports
are a local filesystem path and SSH on Unix. A peer transfer inventories
immutable objects, requests missing verified objects, and returns an explicit
integration proposal. A divergent publication is an inspectable value; neither
peer silently selects a head, overwrites a ref, or materialises a workspace.

## Consequences

- The V2 hosted, browser, MLS, mesh, and IDE roadmap is retired. The tested V2
  local-root, storage, restore, and authoring implementation remains the
  current substrate until a separately approved format change replaces it.
- The local model is the first implementation milestone, Git migration follows
  it, and native peer exchange follows the migration boundary.
- Git interoperability is broader than the prior object-level bridge, but its
  guarantees are deliberately layered: supported checkout bytes and selected
  reachable Git provenance can be preserved; Yeokcham semantics cannot be
  reconstructed from ordinary Git commits alone.
- Peer exchange is native Yeokcham behaviour, but first-release networking is
  intentionally not peer discovery, NAT traversal, relay fallback, automatic
  background synchronisation, web review, or organisation policy.

## Model and invariant impact

The V3 extension introduces the following conceptual values before an adapter
chooses their concrete encodings:

```ocaml
type git_archive_id
type publication_id
type peer_id

type publication_target =
  | Published_capsule_revision of capsule_id * capsule_revision_id
  | Published_release of release_id

type integration_outcome =
  | Ready_for_explicit_integration of publication_id
  | Publication_divergence of publication_id list
  | Rejected_peer_publication of string
```

Required invariants are:

1. A Git archive records source provenance separately from canonical
   Yeokcham history. Loss or absence of a mapping never changes a Yeokcham
   object into a Git object or vice versa.
2. Adoption is a new explicit Yeokcham transition with a declared source and
   selected target. It cannot manufacture capsule identity, user intent,
   conflict resolution, or release validation from Git metadata.
3. An exit repository contains only verified preserved Git objects and
   explicitly represented Yeokcham exports. A failed or interrupted exit never
   overwrites an existing unrelated Git ref.
4. A publication names only immutable, verified objects reachable from one
   selected capsule revision or release. Scratch checkpoints and mutable local
   state are absent unless a future user explicitly selects another policy.
5. Receiving a peer publication cannot mutate a local publication selection,
   workspace, or working directory. Integration is a separate explicit
   transition.
6. Incompatible formats, malformed objects, incomplete transfers, and
   divergent publications are typed outcomes, never implicit repair or
   authority decisions.

## Persistent-format and migration impact

The existing V2 local root remains readable and is the supported V3 runtime
base. The earlier V1 format remains a legacy/cutover format and must never be
silently opened or overwritten. V3 records for Git archives, adoption receipts,
publications, and integration proposals must be additive, versioned,
canonically ordered, and separately golden-tested. They must reject unknown
mandatory features and use create-only publication; no existing object or sole
copy is overwritten in place.

Git archive support preserves selected reachable Git objects and refs, not
working-tree state, indexes, reflogs, configuration, hooks, credential files,
or remote service state. Unsupported source capabilities are reported before
adoption; they are not silently dropped or reinterpreted.

## Verification

- V3-001 requires unit, generated, persistence-failure, and golden coverage
  for local transitions and storage, including exact restore and compaction.
- V3-002 requires fixtures covering SHA-1 and SHA-256 Git repositories,
  multiple parents, annotated tags, selected refs, capability reports,
  interruption/retry, preservation/exit, and `git fsck` of the exit result.
- V3-003 requires two-repository local-path and SSH fixtures covering missing
  object selection, bad data, interruption/retry, incompatible formats,
  explicit publication selection, and divergence without working-tree mutation.
- V3-004 requires documented manual installation/startup evidence on each
  supported Unix platform. It must label any unavailable signing, notarisation,
  or platform verification honestly.

## CLI and user impact

The local commands remain inspectable (`status`, `timeline`, `restore`,
`capsule`, `work`, `release`, and `verify`). Git migration and peer commands
must make their effect and their limits visible, with names equivalent to:

```text
yeokcham git import <repository> --refs <selection>
yeokcham git adopt <archive> <selection>
yeokcham git export <selection> <destination>
yeokcham peer publish <capsule-revision-or-release>
yeokcham peer fetch <path-or-ssh-peer>
yeokcham peer integrate <publication>
```

Exact spellings are deferred to the corresponding vertical slices. No command
may present Git provenance as Yeokcham intent or make a received publication
part of a workspace without an explicit user decision.

## References

- [Git bundle documentation](https://git-scm.com/docs/git-bundle)
- [Git clone documentation](https://git-scm.com/docs/git-clone)
- [Git fast-export documentation](https://git-scm.com/docs/git-fast-export)
- [Git fast-import documentation](https://git-scm.com/docs/git-fast-import)
