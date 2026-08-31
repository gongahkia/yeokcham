# V4 product contract

## Status

V4 is the only active Yeokcham product format and `yeokcham` is its only public
executable. It refuses an existing `.yeokcham` directory at initialization and
does not import, mutate, migrate, or provide command aliases for earlier
product tracks.

## Local recovery and composition

`init`, `save`, `status`, `timeline`, `restore`, `pin`, `unpin`, and `compact`
operate on exact snapshots. `status` reports the saved checkpoint, active
draft, shared changes, open decisions, deliveries, local display registrations,
capture mode, and uncaptured state. A save is recovery only; it becomes shared
only through `share`.

`log` and `graph` are read-only projections of persisted V4 work. `log` is a
stable ledger of current shared revisions and their explicit parent relation,
open decisions and candidates, signed resolutions and their target decisions,
delivery milestones, and deferred review-publication references. `graph` shows
the same domain as typed ASCII nodes and explicit edges; a delivery references
only the revision IDs stored in its record and never implies new ancestry.
Neither command scans or materialises the working tree, changes a state head,
or reads a remote.

`graph --authority` is a separate authority-epoch DAG. It shows epoch parent
edges, all current heads, multi-parent reconciliation, certificates/devices,
and epoch-specific revocations. It never combines concurrent authority heads
into an inferred effective policy. A project without signed authority state
refuses this view explicitly.

These views use complete identifiers, never prefixes. Their ordering is stable:
most records sort by their complete identifier, while delivery milestones sort
by creation time and then delivery ID. User-controlled text is quoted and
escaped to one terminal line; output has no ANSI controls. The CLI accepts a
valid `COLUMNS` value of at least 40, otherwise uses 80 columns. A row that
does not fit renders its kind and full primary ID first, then wraps the
remaining fields as indented detail rows. A single identifier may exceed the
width rather than be shortened.

`draft new`, `share`, `withdraw`, `resolve`, and `deliver` follow the pure V4
model. Overlap or stale base is a durable decision, not an automatic merge.
`decision show` / `inspect`, `decision diff`, and `decision materialize` are
read-only inspection surfaces. Candidate materialisation requires an existing
empty destination and uses a generated display-handle/rank child name, never a
raw revision identifier. `resolve --tree` references that isolated result; it
does not rewrite the live tree while deciding.

`decision propose` remains byte-exact and parser-free. A repository may name an
already-installed external LSP server with `semantic server add`; with one
enabled matching server, proposal inspection appends bounded local advice from
three disposable named snapshot workspaces. With several matches, a person must
use `--semantic-server NAME`. The server is untrusted and receives snapshot
bytes, never the live-worktree path. Its symbols, definitions, references, and
possible-overlap display are ephemeral evidence only: no result can compose
bytes, accept a proposal, resolve a decision, write a worktree, or enter V4
state, package, relay, bootstrap, authority, or delivery data. A missing or bad
server is reported as unavailable and leaves byte-only inspection usable.

In-place restore first captures a safety checkpoint then follows a canonical
Prepared → Applying → Materialized → Published journal. Before `Published`, it
writes one create-only local `restore-proof-v1` naming the exact safety and
target snapshots and verifies both closures. Restart replays the exact target
or completes that proof; `.git` and `.yeokcham` are outside source replacement.
Compaction can prune a published journal only after the matching proof exists.
The proof remains a named storage root until `restore forget --operation ID`.
`restore proofs` lists those records; `storage roots` validates and explains
all non-recent roots. `restore retain --operation ID` creates a proof for a
legacy completed journal. These records never enter package, bootstrap, relay,
authority, shared-change, or delivery state.

`storage gc --dry-run --explain` is a read-only object-store projection. It
lists every retained V4 object with the checkpoint or state-head reason that
reaches it, and lists only unreachable V4 snapshot/tree/content/manifest/chunk
and prior-state objects as candidates. Every checkpoint still named by current
state is retained, even when it has no special compaction reason. Unsupported
unreachable object categories are retained rather than collected.

`storage gc --apply` recomputes under the restore-retention and state-head
locks, then moves exact candidates into a local `gc-transaction-v1`
quarantine. It neither unlinks objects nor changes project state. `storage gc
status` makes transactions inspectable, `resume --id` completes interrupted
quarantine staging, and `restore --id` returns staged bytes before purge has
started. `purge --id` recomputes reachability before recording a durable marker
and unlinking each staged object. An interrupted purge is finishable on a
later explicit purge but intentionally cannot be restored: the marker records
the start of irreversible deletion. These commands do not scan or materialise
the working tree and never send, delete, or retain relay/package bytes.

`watch` is advisory foreground capture on Linux and macOS. After a one-second
quiet period (or thirty-second sustained-write maximum) it calls the same exact
`save` path. Linux uses inotify; macOS uses FSEvents with file-event and
root-watch notifications. An FSEvents rename is only a scan hint because it has
no trustworthy old/new path pair. Coalescing requests a whole-root exact scan;
dropped, wrapped, unmounted, or lost streams request a whole-root scan and then
restart. `.git` and `.yeokcham` ordinary events do not schedule capture. A root
that no longer exists fails plainly instead of retrying forever. Unsupported
systems fail explicitly. The real platform watcher-loop tests are part of the
active suite; evidence remains platform-specific in
`TESTING_AND_EXPERIMENTS.md`.

`daemon start`, `status`, and `stop` provide that same capture behaviour with a
managed Linux process lifetime. There is at most one daemon per canonical
repository root. It requires a user-private, absolute `XDG_RUNTIME_DIR` and
keeps only disposable private lock, socket, log, and bounded `runtime-state-v1`
observability there; no runtime file is a project, authority, transport, or
credential record. A crash releases the owning kernel lock, so a later start
can safely replace a stale socket. There is no service-unit installation,
autostart, persistent scheduling configuration, or non-Linux fallback.

The daemon does not follow remotes. `daemon sync NAME` is an explicit request
using exactly the ordinary receive-first `sync` orchestration. It is serialized
with local capture, reports unavailable remotes, and never scans or
materialises the working tree during receipt. It does not select a publication
or authority head, retry by itself, or make authority depend on network state.

## Identity and authority

`device create` creates an Ed25519 key in the selected platform signer
provider. `device create --provider pkcs11` instead creates a sensitive,
non-extractable Ed25519 key on an explicitly selected token and saves a
local-only custody profile; `device attach --provider ssh-agent` selects one
already-loaded `ssh-ed25519` key. `device custody --device ID` reports the
local selector and provider availability. None of these commands enrols,
authorizes, revokes, or rotates a device. Device IDs derive from public keys.
`user register` and the username accepted by enrolment are local display
metadata only.

`init` creates a self-signed root administrator certificate, a root authority
epoch, a distinct recovery device, and an encrypted recovery package at
`.yeokcham/recovery-v1.cbor`. It prints exactly once:

- a deterministic 12-word BIP-39 root-verification phrase, for independent
  out-of-band comparison during `join`; and
- a random 24-word BIP-39 recovery mnemonic, which decrypts the package and
  must be recorded offline.

`device enroll` allows any current administrator to add a member or another
administrator. On one authority head, `device enroll`, `device revoke`, and
`device rotate` advance it normally. On a fork, each requires `--parent EPOCH`
to select exactly one current branch; omitting it fails without changing state.
`device rotate` atomically enrols the replacement and revokes the old local
device in that selected branch. `authority heads` exposes every head; it never
chooses one. `authority reconcile --parents EPOCH,EPOCH[,EPOCH]` is the only
ordinary multi-parent operation. Its parents must be a sorted, duplicate-free
list of current heads, and the local administrator must be active in each one.
Unselected concurrent heads remain active.

Signed `share`, signed `resolve`, and `package adopt` use the sole head when
there is one. On a fork they require `--authority EPOCH` to bind the new signed
record to one current branch. They do not select a branch from ordering or
merge authority states.

`recovery use` uses the existing encrypted package to create a replacement
administrator, revoke the nominated device, rotate the recovery key, and write
a new package exclusively at `--output` before it advances the state head.
`recovery refresh` makes an additional exclusively-written encrypted copy of
the current authority closure with the same supplied mnemonic and a fresh nonce;
it does not change authority. For both recovery commands, passing a mnemonic as
a command argument can expose it in shell history or process listings; use an
appropriate protected execution environment until a dedicated stdin/provider
interface exists.

V4 has no online authority coordination. An administrator active in a locally
verified current epoch may enrol, revoke, rotate, recover, share, resolve, or
adopt while disconnected. Relay state, a coordinator response, quorum,
threshold signature, lease, timestamp, witness, or remote observation cannot
approve, order, reject, select, or make those actions unavailable. Concurrent
epochs remain explicit until a valid reconciliation names selected heads.

An authority epoch is a canonical signed DAG node. Concurrent administrator
epochs remain separate heads. A normal successor has one explicitly selected
parent. An explicit reconciliation names two or more selected current parents
and requires an administrator active in every one; recovery can similarly
reconcile selected parents only when they share its active recovery device.
This never infers a union of branch permissions.

## Offline packages and review

`package create --destination PATH` writes a new directory with canonical
manifest, complete public authority closure, signed revisions, any public
exception records, and every referenced immutable snapshot object. It copies no
private capability or mutable head.

`join --from PACKAGE --verify-phrase "…"` reads and verifies the public
authority closure, compares the exact root phrase, and initializes an already
enrolled local device. It does not receive package objects or materialise a
working tree; run `receive` separately.

`bootstrap --remote NAME --url HTTPS_URL --repository ID --basis ID
--verify-phrase "…"` initializes a new enrolled replica from one explicit
immutable relay basis. The relay ID is only a locator: the client validates the
signed basis, its unchanged package-manifest-v1 closure, every shared-history
snapshot, active publisher, and independently compared root phrase before it
creates `.yeokcham`. It imports shared changes, signed resolutions, and delivery
history into one fresh local draft; it imports no source draft, scratch
checkpoint, pin, username, remote alias, credential, or private key. It neither
scans nor materialises ordinary files. The bearer token is prompted without echo
and is saved in the OS credential store only after this verification succeeds.

An existing replica publishes such an immutable basis explicitly with
`bootstrap publish REMOTE`. The command uploads closure objects, then the
ordinary package manifest, then the separately signed basis. There is no
implicit latest-basis selection and no general clone command.

`receive --from PACKAGE` validates the repository root, canonical bytes,
membership/authority closure, signatures, causal parents, and exact object
closure in a temporary store. Only then can it import immutable objects and
publish one state-head update. It never scans, resolves, or writes the working
tree. A signed resolution carries its target decision in its own signed bytes;
receipt applies it only as that decision's resolution, never as ordinary shared
work.

Revocation is forward-looking. A revision signed under its historical active
epoch remains valid proof. If it is new to the receiving project and any current
head causally descends from that epoch and revokes its signer, automatic receipt
stops. `receive --review` gives the exact revision and signer without state or
object changes. A current administrator with one authority head may run
`package adopt --from PACKAGE --revision ID`; this persists an exact signed
adoption and the record’s public authority closure, still without importing the
package. A later `receive` accepts only that adopted record. The adoption does
not grant membership, a general exception, or delivery.

## Relay synchronization

Relay synchronization is only for already-equivalent V4 replicas. An operator
starts the byte-only backend with `relay serve --storage PATH --listen
ADDRESS:PORT` and terminates TLS in a separate HTTPS reverse proxy. Before use,
the operator issues a repository-scoped `read`, `write`, or `read,write` access
secret with `relay access issue --storage PATH --repository ID --scope SCOPE`.
Secrets expire after thirty days unless `--expires-in SECONDS` says otherwise;
`relay access rotate` replaces one by safe credential ID and `relay access
revoke` disables one without restart. Issue and rotation require a controlling
terminal and display the secret there once, never on standard output.

The relay access registry is local operator policy. It stores only verifiers,
safe IDs, scope, repository, timing, and status; it is not V4 authority,
membership, model state, package, publication, or a trust root. The relay has
no signing capability, authority state, model state, or working-tree access;
it stores readable immutable package bytes only.

`remote add NAME HTTPS_URL` stores a local alias under `.yeokcham`; `remote
login NAME` reads a relay access secret with terminal echo disabled and stores it
in the Linux Secret Service. Neither aliases nor credentials are signed,
packaged, exported, or authority data. `remote remove NAME` removes the alias.

`sync NAME` uses only HTTPS. It fetches signed publication records, manifests,
and their declared immutable object closure into temporary package directories.
It verifies the entire feed batch, package authority closure, signatures,
canonical bytes, and snapshot closure before importing any destination object
or advancing the state head. Receipt stores the remote cursor and verified
publication references with the V4 collaboration state. A late record from a
now-revoked signer is verified into the local review inbox and reported as a
deferred publication; it is not automatically applied.

`daemon sync NAME` has the same transport and receipt semantics as `sync NAME`;
the difference is solely that the already-running local Linux daemon owns the
explicit request. The daemon never synchronizes unless that command is issued.

After durable receipt, `sync` publishes locally unannounced work as an exact
package closure: objects first, then the manifest, then its signed publication.
The publication is marked announced only after the relay acknowledges it. An
upload failure is reported as pending work; it does not roll back received
records or claim cross-machine atomicity. Sync never materialises or scans the
working tree.

Both offline `receive` and relay-batch receipt execute through the dedicated
receipt boundary. That component has no snapshot scanning or materialisation
dependency and may only validate staged bytes, import verified immutable
objects, and publish one collaborative state head. Any change to that boundary
requires an ADR update and working-tree sentinel tests.

### Receipt review checklist

- Does the proposed receive, sync, or bootstrap path call only staged-byte,
  immutable-object, and collaborative-state APIs?
- Do ordinary receipt, signed resolution, feed-fork, late-review, malformed
  input, and retry tests prove the ordinary working tree is byte-for-byte
  unchanged?
- If any receipt-time working-tree inspection or materialisation is proposed,
  stop and create a superseding ADR and a separate issue before implementation.

## Persistent-format rules

All records use canonical CBOR and explicit schema versions. Object identity is
derived from exact canonical envelope bytes. The released V4 project record,
authority-backed collaboration state, signed revision, and package manifest
each have one final schema tagged version 1. Pre-release V4 encodings are
rejected; they are not migration inputs and are never silently re-saved. Unknown
mandatory features and noncanonical encodings are rejected. An immutable object
is written before the single `v4-project-state` compare-and-swap head changes.
No state transition mutates the only copy in place.

## Exclusions

There is no general clone protocol, automatic or relay GC, durable command metadata, Git bridge
or interchange, in-process semantic parser or merge,
end-to-end payload encryption, external relay identity or proof-of-possession,
macOS daemon/runtime, WSL support (which is not planned), or CI-backed
delivery. These are separate design work and must reuse the current model and
receipt boundaries when introduced.
