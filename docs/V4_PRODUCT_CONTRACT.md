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

`draft new`, `share`, `withdraw`, `resolve`, and `deliver` follow the pure V4
model. Overlap or stale base is a durable decision, not an automatic merge.
`decision show` / `inspect`, `decision diff`, and `decision materialize` are
read-only inspection surfaces. Candidate materialisation requires an existing
empty destination and uses a generated display-handle/rank child name, never a
raw revision identifier. `resolve --tree` references that isolated result; it
does not rewrite the live tree while deciding.

In-place restore first publishes a retained safety checkpoint then follows a
canonical Prepared → Applying → Materialized → Published journal. Restart
replays the exact target; `.git` and `.yeokcham` are outside source replacement.

`watch` is Linux-only advisory capture. After a one-second quiet period (or
thirty-second sustained-write maximum) it calls the same exact `save` path.
Unsupported systems fail explicitly. The real Linux watcher-loop test remains
an outstanding proof described in `TESTING_AND_EXPERIMENTS.md`.

## Identity and authority

`device create` creates an Ed25519 key in the selected platform signer
provider. Device IDs derive from public keys. `user register` and the username
accepted by enrolment are local display metadata only.

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

## Persistent-format rules

All records use canonical CBOR and explicit schema versions. Object identity is
derived from exact canonical envelope bytes. Unknown mandatory features and
noncanonical encodings are rejected. An immutable object is written before the
single `v4-project-state` compare-and-swap head changes. No state transition
mutates the only copy in place.

## Exclusions

There is no blob GC, durable `capture=`, immortal restore safety after journal
prune, network/SSH/HTTP transport, Git bridge, semantic parser or merge,
hardware/non-exportable signer, signing agent, macOS/WSL watcher, or CI-backed
delivery. These are separate design work and must reuse the current model and
receipt boundaries when introduced.
