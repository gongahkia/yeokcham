# ADR-078 — Native Git lineage and authenticated peer synchronization

- Status: Accepted
- Date: 2026-08-16
- Deciders: maintainer, under the explicit product direction in #237 and #238
- Governing issues: [#237](https://github.com/gongahkia/yeokcham/issues/237) and [#238](https://github.com/gongahkia/yeokcham/issues/238)
- Supersedes: None
- Superseded by: None

## Context and problem statement

V3 preservation can reconstruct the selected Git graph exactly, but its native
records retain parent IDs as opaque provenance. Direct peer publication moves a
selected snapshot closure, but it is deliberately neither an authenticated
replication protocol nor a synchronization history. Those limits prevent a
Git user from inspecting a migrated graph as a Yeokcham value and prevent
Yeokcham repositories from safely converging without an external VCS.

The remedy must not erase the distinction that makes Yeokcham useful. A Git
merge is not evidence of capsule intent, workspace composition, conflict
resolution, or release validation. Likewise, a synchronized peer head must
not silently advance scratch, a capsule, a workspace, a release, or a working
tree.

## Decision drivers

- Preserve arbitrary selected Git commit topology, including ordered merge
  parents, as inspectable immutable native records.
- Keep the preserved archive as the exact Git exit authority.
- Require explicit trust, freshness, and protocol binding before any remote
  tracking ref changes.
- Permit offline relay operation without reintroducing a hosted account or
  service as a product dependency.
- Reconcile exact snapshots automatically only where the result is provable;
  make every ambiguity a persistent conflict.
- Keep private key material and daemon state outside canonical repository
  objects.

## Considered options

### Translate every Git commit into a capsule or release

- Provides familiar commit-by-commit presentation.
- Invents intent and semantic merge meaning that Git does not carry.

### Retain Git topology only in a bundle

- Is lossless for Git exit and needs no new graph type.
- Leaves native inspection, migration mapping, and migration-scoped graph
  operations unavailable.

### Use a native migration-lineage graph, plus a separate peer-sync graph

- Preserves foreign topology exactly while making its role explicit.
- Gives synchronization an immutable causal history without contaminating
  authoring and release records.
- Adds persistent records and protocol surface that must be tested carefully.

## Decision outcome

Adopt two additive, type-distinct graph families.

`Git_lineage_node_v1` names one imported Git commit within one immutable
archive. It carries the imported-transition and mapping object identities, the
exact snapshot, and its ordered parent lineage IDs. `Git_lineage_v1` names one
archive-wide materialization and maps every archive ref to either a lineage
head (when Git peels it to a commit) or an explicit non-commit foreign target.
The import performs a bounded topological traversal of all selected reachable
commit heads. It rejects malformed, missing, duplicate, cross-format, or
cyclic links before publishing the lineage binding. Nodes never become
checkpoints, capsules, workspaces, conflicts, or releases. The archive bundle
remains the only exact Git exit representation.

`Peer_identity_v1` is a public Ed25519 identity. A separately configured
contact pins the identity public key and one or more direct/relay endpoints;
there is no trust-on-first-use. The private signing capability is supplied from
an owner-readable Unix file or process-local test capability and is never a
canonical object. Every session, advertisement, signed ref event, and sync
node uses a versioned, domain-separated preimage containing repository format,
both identities, endpoint-independent nonce/challenge data, and a bounded
protocol transcript. Direct SSH remains a transport only; SSH host
authentication does not replace Yeokcham peer authentication.

The protocol has two exchange paths. A direct path uses the existing bounded
immutable-object transport after mutual authentication. A directory relay is a
filesystem mailbox of immutable signed packages and advertisements. Listing a
relay discovers candidates, but does not trust them. A Unix-only background
runner processes explicitly configured contacts and relays; its socket,
schedule, retry state, and status are noncanonical runtime data.

`Peer_sync_node_v1` is a signed immutable causal node over one exact snapshot
and ordered parent sync-node IDs. Namespaced peer-tracking refs may advance
only after authenticated object transfer, identity pinning, event verification,
and causal validation. Fast-forward is automatic. Divergent heads are
reconciled with a byte-exact three-way tree merge: unchanged-vs-one-side changes
select the changed side; disjoint path changes compose; incompatible changes,
file/directory collisions, mode/content disagreement, and unavailable merge
bases produce `Peer_sync_conflict_v1`. A clean reconciliation creates a
locally signed merge sync node. Neither outcome is an automatic capsule,
workspace, release, scratch, or working-directory mutation.

## Consequences

- Git users can inspect every selected reachable commit and its ordered
  parentage natively, without a false semantic conversion claim.
- Existing archive/adoption and direct-publication records remain readable and
  retain their prior meanings.
- Peer synchronization is usable through direct peers or a shared relay
  directory, but this decision does not provide hosted discovery, NAT
  traversal, anonymous routing, accounts, or automatic user-worktree edits.
- A clean peer merge is exact at the snapshot level, not a text merge or an
  inference of author intent. Conflicts are durable native values.

## Model and invariant impact

The additive conceptual types are:

```ocaml
type git_lineage_id
type git_lineage_node_id
type peer_id
type peer_contact_id
type peer_sync_node_id
type peer_sync_conflict_id
```

1. A lineage node has exactly one archive, imported transition, snapshot, and
   ordered list of parent lineage nodes. Its Git commit and every parent match
   the transition exactly.
2. A lineage graph has an exact sorted archive-ref map and is acyclic. It does
   not give a foreign edge native intent or release semantics.
3. A peer identity public key determines its peer ID. A contact trusts only its
   pinned peer ID/key combination; advertisements never expand that trust.
4. A signed protocol statement is valid only once for its protocol domain,
   repository format, identities, nonce, transcript, and canonical payload.
5. Peer tracking refs name only verified peer-sync nodes. No sync transition
   writes authoring/release refs or materializes a filesystem snapshot.
6. A clean reconcile result is the deterministic exact three-way merge of a
   verified common ancestor and verified snapshots. Otherwise a conflict
   retains all candidates and cannot silently select a winner.

## Persistent-format and migration impact

Envelope types after existing V3 records are additive and versioned:
`Git_lineage_node`, `Git_lineage`, `Peer_identity`, `Peer_contact`,
`Peer_advertisement`, `Peer_sync_node`, and `Peer_sync_conflict`. Each logical
identity has a distinct SHA-256 domain. Bindings are create-only or
compare-and-swap only in the dedicated peer-tracking namespace. Decoder paths
retain all previous V3 payload versions and reject unknown mandatory features,
wrong types, malformed ordering, bad identity lengths, unsupported algorithms,
and noncanonical payload bytes before mutable state changes. Private keys,
relay delivery markers, and daemon status are not in the canonical object
store and can be discarded/rebuilt.

## Verification

- Unit and golden fixtures for every new identity, payload, binding, signature
  preimage, and inverse decoder.
- Bounded generated Git DAGs covering roots, ordinary commits, octopus merges,
  multiple selected roots, ordering, reopen, and retry.
- Real Git archive fixtures that prove `git fsck --full`, exact ref inventory,
  and archive exit after migration materialization.
- Two-repository direct and relay integration tests for identity pinning,
  challenge replay, signature tampering, object corruption, wrong repository,
  missing closure, interruption/retry, and non-mutation of authoring refs.
- Property and failure tests for fast-forward, convergence, byte-exact
  three-way merges, path conflicts, restart, and concurrent tracking-ref CAS.
- A daemon test that shows an explicit configured poll performs sync without
  canonical daemon state or working-directory mutation.

## CLI and user impact

The resulting commands are equivalent to:

```text
yeokcham git archive materialize-lineage <archive-id>
yeokcham git lineage show <lineage-id> --graph
yeokcham peer identity init --key <private-key-file>
yeokcham peer contact add <name> --peer <public-identity> --direct <endpoint>
yeokcham peer relay discover <directory>
yeokcham peer sync <contact>
yeokcham peer reconcile <tracking-ref>
yeokcham peer daemon run
```

Commands report whether a value is foreign migration provenance, a signed
remote-tracking result, a clean exact reconciliation, or a conflict. They do
not describe those values as native user intent or release history.

## References

- [Git data model](https://git-scm.com/docs/gitdatamodel)
- [Git commit-tree](https://git-scm.com/docs/git-commit-tree)
- [Git bundle](https://git-scm.com/docs/git-bundle)
- [RFC 8032: Edwards-curve Digital Signature Algorithm](https://datatracker.ietf.org/doc/rfc8032/)
- [RFC 6762: Multicast DNS](https://datatracker.ietf.org/doc/html/rfc6762.html)
- [RFC 6763: DNS-Based Service Discovery](https://datatracker.ietf.org/doc/html/rfc6763)
