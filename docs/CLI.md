# Yeokcham CLI reference

This document describes the implemented local command surface. It is a guide to
the current prototype, not a compatibility promise or a replacement for the
model and persistence contracts.

Run commands from the repository root or pass `--root PATH` where the command
accepts it:

```sh
dune exec bin/yeokcham.exe -- --help
```

The top-level help output is the authoritative list of command groups. All
commands either publish a checked immutable result through their documented
boundary or return a structured failure; they do not silently fabricate history.

## Terminal progress

Finite mutating commands render a spinner on an interactive stderr stream. The
spinner uses uv's current default indicatif frame sequence and clear-on-finish
behavior; normal command results still go to stdout and errors remain on
stderr. Inspection commands, dry runs, `watch`, `yeokchamd`, and `peer serve`
do not show progress.

When an operation reaches an exact, monotonic unit count, the spinner changes
to a labeled `█`/`░` progress bar with its completed/total count. This applies
to non-dry-run restore and workspace materialisation filesystem actions,
compaction cleanup candidates, and local peer-fetch object reconciliation.
Yeokcham does not estimate totals for scanning, validation, Git operations, or
SSH peer fetch, so those operations retain the spinner.

Pass `--no-progress` after the command or set `YEOKCHAM_NO_PROGRESS=1` to hide
the spinner. Non-interactive stderr also hides it automatically, so scripts,
pipes, and captured logs retain their ordinary output.

## Complete command forms

The following forms cover the current local command surface. Square brackets
are optional arguments; placeholders are supplied by the caller. Any
`yeokcham` form may additionally take `[--root <path>] [--no-progress]`.

```text
init
yeokchamd --root <path> --quiet-period-ms <positive-integer> \
  --max-latency-ms <positive-integer> [--runtime-dir <private-path>] [--recover-stale]
status
checkpoint
timeline --limit <count>
history --graph [--scratch | --capsules | --workspace <workspace-id> | --releases]
restore [--dry-run] <checkpoint-id>
pin <checkpoint-id>
unpin <checkpoint-id>
compact [--dry-run] [--explain] [--resume] [--prune]
watch --interval-ms <milliseconds> --debounce-ms <milliseconds>

capsule create --current --id <capsule-id> --title <title> --description <description> [--requires-capsule <capsule-id>] [--requires-revision <capsule-id>:<revision-id>] [--requires-release <release-id>] [--conflicts-with <capsule-id>] [--ordered-after <capsule-id>]
capsule list
capsule edit <capsule-id>
capsule fold <capsule-id> --from <editing-anchor> --to <checkpoint-id>
capsule retarget <capsule-id> --onto <snapshot-id>
capsule split <capsule-id> --left-id <capsule-id> --left-title <title> --left-description <description> --right-id <capsule-id> --right-title <title> --right-description <description> --left-indices <indices> --confirm
capsule combine --id <capsule-id> --title <title> --description <description> --source <capsule-id> --source <capsule-id> --confirm
capsule show <capsule-id>
capsule current-diff <capsule-id>
capsule history <capsule-id>

work explain-order --enable <capsule-id> --enable <capsule-id> [--order <revision-id>,<revision-id>]
work create --id <workspace-id> --base <snapshot-id> [--name <name>] [--description <description>]
work show <workspace-id>
work enable <workspace-id> <capsule-revision-id>
work disable <workspace-id> <capsule-id>
work reorder <workspace-id> --order <revision-id>,<revision-id>
work explain-order <workspace-id>
work materialise <workspace-id> [--dry-run]
conflict list <workspace-id>
conflict show <conflict-id>
conflict resolve <workspace-id> <conflict-id> --action skip

validation run --snapshot <snapshot-id> --exec <program> [--arg <argument>] [--cwd <relative-path>] [--timeout-ms <milliseconds>] [--max-stdout-bytes <bytes>] [--max-stderr-bytes <bytes>] [--env <name=value>] [--inherit-env] [--retain-output] [--retain-passing-checkpoints]
release create --workspace <workspace-id> [--parent <release-id>] [--message <text>] [--validation-exec <program> [--validation-arg <argument>] [--validation-cwd <relative-path>] [--validation-timeout-ms <milliseconds>] [--validation-max-stdout-bytes <bytes>] [--validation-max-stderr-bytes <bytes>] [--validation-env <name=value>] [--validation-inherit-env] [--validation-retain-output]]
release show <release-id>
release verify <release-id>
release list
storage stats
verify

git import tree --repository <absolute-git-directory> --tree <full-git-tree-id>
git import commit --repository <absolute-git-directory> --commit <full-git-commit-id>
git import tag --repository <absolute-git-directory> --tag <name>
git export release --repository <absolute-git-directory> --release <release-id> [--author-name <name> --author-email <email> --committer-name <name> --committer-email <email> --message <message>]
git export revisions --repository <absolute-git-directory> --revision <capsule-id>:<revision-id>:<stored-object-id> [--revision <capsule-id>:<revision-id>:<stored-object-id> ...]

peer publish capsule --capsule <capsule-id> --revision <capsule-revision-id>
peer publish release --release <release-id>
peer show <publication-id>
peer fetch --from <absolute-local-repository-root> --publication <publication-id>
peer fetch --ssh <user@host> --remote-root <absolute-remote-repository-root> --publication <publication-id>
peer serve --publication <publication-id>
peer integrate <publication-id> --as-capsule <new-capsule-id> --title <title> --description <description>
peer integration show <peer-integration-id>
```

## Inspect a repository

```sh
dune exec bin/yeokcham.exe -- status
dune exec bin/yeokcham.exe -- timeline --limit 32
dune exec bin/yeokcham.exe -- storage stats
dune exec bin/yeokcham.exe -- verify
```

`status` reports the current local repository state. `timeline` includes each
checkpoint’s timestamp, changed paths, materialised content-byte total,
retention-derived tags, validation state, and retention reasons. `storage stats`
groups on-disk object bytes by storage domain; retained checkpoint bytes are a
separate non-additive physical-storage subtotal. `verify` reads and hash-verifies
stored objects, reachability, capsule revisions and declared dependencies,
workspaces, and releases. Inspection commands do not repair or mutate state.

`history --graph` renders an ASCII map of retained native records. With no
selector, it combines scratch checkpoints, capsule revisions, workspace
revisions, conflicts, and releases; selectors provide a focused view. It uses
typed labels rather than a Git-style universal commit graph: a checkpoint,
capsule revision, workspace revision, and release remain different objects.
The graph does not include Git or peer provenance, and it is not an event log:
compacted scratch history and command executions that create no durable record
are absent.

## Recover scratch work

```sh
dune exec bin/yeokcham.exe -- init
dune exec bin/yeokcham.exe -- checkpoint
dune exec bin/yeokcham.exe -- pin <checkpoint-id>
dune exec bin/yeokcham.exe -- unpin <checkpoint-id>
dune exec bin/yeokcham.exe -- restore --dry-run <checkpoint-id>
dune exec bin/yeokcham.exe -- restore <checkpoint-id>
dune exec bin/yeokcham.exe -- compact --dry-run --explain
dune exec bin/yeokcham.exe -- compact --explain
```

`restore` safety-checkpoints divergent work, validates its plan immediately
before application, and moves `scratch-head` only after exact result
verification. It is not crash-atomic for a populated working directory: after a
reported partial failure, restore the reported safety checkpoint.

Compaction retains logical checkpoint IDs while an active generation maps them
to verified physical records. `compact --dry-run --explain` prints the planned
cleanup IDs and stored-object bytes. `compact --prune` permanently removes a
previous generation’s quarantined history and is irreversible. The compaction
contract, budget meaning, and inverse reduction are documented in
[compaction inverses](COMPACTION_INVERSES.md),
[compaction budget](COMPACTION_BUDGET.md), and
[validation retention](VALIDATION_RETENTION.md).

## Curate capsules and compose workspaces

```sh
dune exec bin/yeokcham.exe -- capsule create --current --id <capsule-id> --title <title> --description <description>
dune exec bin/yeokcham.exe -- capsule list
dune exec bin/yeokcham.exe -- capsule show <capsule-id>
dune exec bin/yeokcham.exe -- capsule history <capsule-id>
dune exec bin/yeokcham.exe -- capsule retarget <capsule-id> --onto <snapshot-id>
dune exec bin/yeokcham.exe -- work create --id <workspace-id> --base <snapshot-id>
dune exec bin/yeokcham.exe -- work enable <workspace-id> <capsule-revision-id>
dune exec bin/yeokcham.exe -- work explain-order <workspace-id>
dune exec bin/yeokcham.exe -- work materialise <workspace-id> --dry-run
dune exec bin/yeokcham.exe -- conflict list <workspace-id>
```

Capsules have a stable caller-supplied ID, immutable revisions, and explicit
dependencies. `capsule create` also accepts `--requires-capsule`,
`--requires-revision`, `--requires-release`, `--conflicts-with`, and
`--ordered-after` declarations. Creating a capsule from an unchanged snapshot
returns `no-changes` without publication.

Exact `capsule retarget` replays the current complete revision on the selected
snapshot. On success it CAS-publishes a new immutable revision with provenance;
on conflict it leaves the current capsule ref unchanged. Semantic adapters are
not used by this command.

Workspace selection stores exact physical revision objects. Materialisation
creates a complete or partial immutable attempt. Conflicts remain inspectable;
the only v1 resolution is `conflict resolve <workspace-id> <conflict-id> --action
skip`, which never guesses content, modes, or paths. The capsule, workspace,
and conflict demos show the full workflow:
[capsules](DEMO_CAPSULE.md), [workspaces](DEMO_WORKSPACE.md), and
[conflicts](DEMO_CONFLICT.md).

## Validate and release

```sh
dune exec bin/yeokcham.exe -- validation run --snapshot <snapshot-id> --exec <program>
dune exec bin/yeokcham.exe -- release create --workspace <workspace-id>
dune exec bin/yeokcham.exe -- release show <release-id>
dune exec bin/yeokcham.exe -- release verify <release-id>
dune exec bin/yeokcham.exe -- release list
```

Validation materialises only the named immutable snapshot in a fresh temporary
directory before direct-argv execution. Output and execution are bounded;
captured evidence is immutable. It never validates the live working directory
or advances a canonical ref.

Release creation replays the current workspace inputs, rejects unresolved
conflicts, runs required validation, and publishes through a create-only
binding. Production release signing is deferred. The only included signer is a
deterministic test helper and does not authenticate releases. See
[ADR-027](adr/027-validation-evidence-releases-and-attestations.md) and the
[release demo](DEMO_RELEASE.md).

## Git interchange

```sh
dune exec bin/yeokcham.exe -- git import tree --repository <absolute-git-directory> --tree <full-git-tree-id>
dune exec bin/yeokcham.exe -- git import commit --repository <absolute-git-directory> --commit <full-git-commit-id>
dune exec bin/yeokcham.exe -- git import tag --repository <absolute-git-directory> --tag <name>
dune exec bin/yeokcham.exe -- git export release --repository <absolute-git-directory> --release <release-id>
dune exec bin/yeokcham.exe -- git export revisions --repository <absolute-git-directory> --revision <capsule-id>:<revision-id>:<stored-object-id>
```

The bridge uses one absolute local Git repository, bounded direct argv, and a
documented subset of Git representations. Import preserves supported snapshot
bytes and opaque provenance; it does not infer a Yeokcham capsule, workspace,
or release. Export uses create-only refs and records a mapping only after both
sides validate. Full supported and rejected behaviour is in the
[Git interchange contract](GIT_INTERCHANGE.md).

## Peer exchange

```sh
dune exec bin/yeokcham.exe -- peer publish capsule --capsule <capsule-id> --revision <capsule-revision-id>
dune exec bin/yeokcham.exe -- peer fetch --from <absolute-local-repository-root> --publication <publication-id>
dune exec bin/yeokcham.exe -- peer show <publication-id>
dune exec bin/yeokcham.exe -- peer integrate <publication-id> --as-capsule <new-capsule-id> --title <title> --description <description>
```

`peer publish` derives a stable `Peer_publication_v1` projection from a
verified native capsule revision or release. It includes source IDs and
metadata for provenance, the exact base/result snapshots, and only the sorted
snapshot-storage closure. `peer fetch` transfers the publication record and
the closure's missing objects through bounded exchange frames, validates the
whole closure, then publishes an inspectable local binding. It does not copy
scratch history, alter a scratch head, choose a workspace, create a local
capsule/release, or materialise files.

`--from` is a caller-selected local repository. `--ssh` invokes one direct SSH
command with a constrained target and absolute remote root; the remote host
must make the same `yeokcham` executable available. `peer serve` is the
corresponding one-shot framed endpoint and writes protocol bytes to standard
output, so it is not a normal interactive command.

Only a capsule projection can be integrated. The user supplies a new local
capsule ID, title, and description; Yeokcham makes fresh detached local
checkpoints, creates a normal durable capsule, and records a
`Peer_integration_v1` receipt. A release projection remains inspectable source
provenance because it cannot establish the local workspace and validation
composition needed for a native release. The complete contract is in
[peer exchange](PEER_EXCHANGE.md).

## Authenticated peer sync (experimental)

```sh
dune exec bin/yeokcham.exe -- peer identity init --key /absolute/path/to/peer.key
dune exec bin/yeokcham.exe -- peer contact add alice \
  --peer-public-key <64-hex-character-ed25519-public-key> \
  --direct /absolute/path/to/alice-repository
dune exec bin/yeokcham.exe -- peer contact add alice \
  --peer-public-key <64-hex-character-ed25519-public-key> \
  --ssh alice@example.test --remote-root /absolute/path/to/alice-repository
dune exec bin/yeokcham.exe -- peer contact add alice \
  --peer-public-key <64-hex-character-ed25519-public-key> \
  --relay /absolute/path/to/shared-relay
dune exec bin/yeokcham.exe -- peer contact show <contact-id>
```

`peer identity init` creates one Ed25519 private-key file at the requested
absolute path with mode `0600`; only its public identity is written to the
repository. It refuses a key file that already exists. `peer contact add` pins
the supplied public key and endpoint. It never trusts a key discovered from a
network location.

The first executable vertical slice supports an explicitly local, source-run
transfer:

```sh
dune exec bin/yeokcham.exe -- peer sync snapshot
dune exec bin/yeokcham.exe -- peer sync node create \
  --identity <source-peer-id> --key /absolute/path/to/source.key \
  --snapshot <snapshot-id>
dune exec bin/yeokcham.exe -- peer sync local \
  --to /absolute/path/to/destination \
  --contact <destination-contact-id> \
  --destination-identity <destination-peer-id> \
  --source-key /absolute/path/to/source.key \
  --head <source-sync-node-id> \
  --tracking main
dune exec bin/yeokcham.exe -- peer sync ssh \
  --contact <contact-id> \
  --identity <local-peer-id> \
  --known-hosts /absolute/path/to/known_hosts \
  [--ssh-config /absolute/path/to/ssh_config] \
  --head <source-sync-node-id> \
  --tracking main
dune exec bin/yeokcham.exe -- peer relay publish \
  --identity <source-peer-id> --key /absolute/path/to/source.key \
  --destination-public-key <64-hex-character-ed25519-public-key> \
  --relay /absolute/path/to/shared-relay \
  --head <source-sync-node-id> --tracking main
dune exec bin/yeokcham.exe -- peer relay discover \
  --relay /absolute/path/to/shared-relay
dune exec bin/yeokcham.exe -- peer sync relay \
  --contact <contact-id> --identity <local-peer-id> \
  --relay /absolute/path/to/shared-relay --tracking main
```

`peer sync snapshot` records an exact working-tree snapshot while excluding
`.yeokcham`; `peer sync node create` signs it into the separate peer-sync graph.
Neither command makes a scratch checkpoint, capsule, workspace, or release.

`peer sync local` authenticates the source against the destination's pinned
contact, transfers and verifies the immutable sync-node closure, and changes
only the destination contact's tracking reference. A failed transfer leaves
that tracking reference unchanged. `peer reconcile` accepts two verified
sync-node IDs plus the local identity/key and reports either a causal
fast-forward, a new exact snapshot merge node, or a durable conflict.

`peer sync ssh` selects the contact's configured SSH endpoint. It requires an
explicit known-hosts file and enforces `StrictHostKeyChecking=yes`; SSH host
authentication protects the transport but never replaces the pinned Yeokcham
Ed25519 contact. The remote command is fixed as `yeokcham peer sync
ssh-serve`; the configured remote root travels in a bounded framed request,
not a shell command. The remote host keeps its own `0600` signing capability
at `<repository>/.yeokcham/bootstrap/peer-sync-ed25519`, created explicitly by
`peer identity init --key`; no private key crosses SSH or enters a canonical
object. The server signs the local challenge before the immutable closure is
accepted, so replay, bad signatures, malformed frames, unavailable hosts, and
interrupted transfers leave the tracking reference unchanged. Relay discovery,
relay delivery uses a configured shared filesystem mailbox. `peer relay
discover` reports only syntactically valid, signed, current advertisements; it
does not add a contact or trust a discovered key. `peer sync relay` accepts one
advertisement only when it names the selected pinned contact, the local
identity, repository format, and tracking name. It validates the package in an
isolated staging repository before copying an immutable closure and advancing
only the matching contact tracking ref. Relay files and receipts are runtime
state, not canonical history. The remaining background daemon work is tracked
under [#238](https://github.com/gongahkia/yeokcham/issues/238).

## Further reading

For model boundaries, use the [architecture walkthrough](ARCHITECTURE_WALKTHROUGH.md).
For all project documentation, return to the [documentation index](README.md).
