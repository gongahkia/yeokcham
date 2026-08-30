# Yeokcham

Yeokcham is an experimental, model-first, local-first VCS for small trusted
teams. Its central distinction is between automatic scratch recovery, explicit
shared changes, unresolved decisions, and delivery history. It never turns a
filesystem event, conflict, device name, or CI result into user intent.

The sole supported command is `yeokcham`. It creates a new V4 repository and
does not read, upgrade, or mutate repositories from earlier product tracks.

## What it has

- Exact byte, mode, directory, and symlink snapshots; `save`, `timeline`,
  pins, bounded checkpoint retention, and journaled in-place restore with a
  local durable safety/target proof that remains until explicit forget.
- Inspectable local object collection: `storage gc --dry-run --explain` shows
  retained closure and candidates, `--apply` moves candidates into a local
  quarantine, and only an explicit `purge` unlinks them.
- Explicit drafts, shared immutable revisions, conservative composition, and
  conflict records that can be inspected and materialised outside the working
  tree before an explicit resolution.
- Read-only `log` and `graph` views that keep revisions, unresolved decisions,
  resolutions, delivery milestones, and concurrent authority heads distinct
  instead of presenting a synthetic commit history.
- Local username registrations for display only. Device identity and authority
  are Ed25519 keys and signed authority epochs, never usernames.
- Offline directory packages, signed relay publications, and explicit signed
  bootstrap bases with complete
  snapshot closure verification before any destination object or state-head
  update. Receive and sync never materialise a working tree.
- Multi-administrator enrolment, revocation, atomic local-device rotation,
  explicit authority-fork reconciliation, 12-word root comparison during join,
  and ChaCha20-Poly1305 recovery packages protected by a 24-word BIP-39 secret.

## Fast start

```sh
yeokcham init --username alice --draft first-task --title "first task"
yeokcham status
yeokcham save
yeokcham share --change first-change --revision r1
yeokcham log
yeokcham graph
yeokcham graph --authority
yeokcham package create --destination ../outgoing
yeokcham remote add team https://relay.example.invalid
yeokcham remote login team
yeokcham sync team
yeokcham bootstrap publish team
```

On Linux, automatic scratch capture can run independently of the terminal:

```sh
yeokcham daemon start
yeokcham daemon status
yeokcham daemon sync team  # explicit; the daemon never polls remotes itself
yeokcham daemon stop
```

The runtime uses a private, disposable `XDG_RUNTIME_DIR`; it is not a service
unit, a persistent project format, or an authority mechanism.

`init` prints a 12-word public root-verification phrase and a 24-word recovery
mnemonic. Compare the phrase with a prospective device owner over an
independent channel. Record the mnemonic offline; it decrypts the recovery
package and is not an account password.

For an arrival signed before its author was revoked, inspect before receive:

```sh
yeokcham receive --from ../incoming --review
yeokcham package adopt --from ../incoming --revision r1
yeokcham receive --from ../incoming
```

The adoption is a durable, domain-separated approval for that exact signed
revision. It grants neither general membership nor a broad exception.

An in-place restore (`restore --checkpoint ID` without `--destination`) prints
a `restore-proof` operation ID. Its pre-restore and target snapshots remain
recoverable across compaction until `restore forget --operation ID`; use
`restore proofs` and `storage roots` to inspect those local recovery roots.

After checkpoint compaction, storage collection is deliberately a separate
local operation. Review it first, then choose whether to quarantine, restore,
or irreversibly purge its exact transaction:

```sh
yeokcham storage gc --dry-run --explain
yeokcham storage gc --apply
yeokcham storage gc status
yeokcham storage gc restore --id TRANSACTION_ID  # before purge begins
yeokcham storage gc purge --id TRANSACTION_ID
```

The collector never contacts a relay or edits the working tree. `--apply` does
not reclaim space; it only moves immutable unreachable bytes into a local,
recoverable quarantine. `purge` first rechecks current roots. Once purge has
durably begun, a restart can finish it but cannot restore that transaction.

For synchronization, an operator first issues a repository-scoped access
secret, then runs the relay behind an operator-managed HTTPS reverse proxy:

```sh
yeokcham relay access issue --storage PATH --repository REPOSITORY_ID \
  --scope read,write
yeokcham relay serve --storage PATH --listen 127.0.0.1:8080
```

The issue command shows the secret only once through the controlling terminal;
the client enters it with `remote login`. The relay is only an immutable byte
courier; `sync` verifies received packages before updating local state and
reports upload failures as pending retry work.

## Boundaries

Linux `watch` and `daemon` are implemented as advisory capture after debounce.
`daemon` is Linux-only and requires a private `XDG_RUNTIME_DIR`; macOS and WSL
watchers/runtimes are not implemented. Relay synchronization is available only for already-equivalent
replicas through an operator-managed HTTPS reverse proxy. A new replica instead
needs an explicit immutable bootstrap basis ID, public repository ID, enrolled
local device, and independently compared root phrase; it starts with fresh
local scratch state and never materialises its working tree. The relay is an
untrusted byte courier and stored payloads are not end-to-end encrypted. There
is no online authority coordinator, general clone, Git import/export, semantic
parsing, CI-backed delivery, signing agent, or hardware-key support. There is
no relay, package, or automatic blob GC; local collection is only the explicit
quarantine-and-purge workflow above. Those are deliberate boundaries, not
hidden product behaviour.

Read [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) for the philosophy,
[FORMAL_MODEL.md](FORMAL_MODEL.md) for invariants, and
[docs/V4_PRODUCT_CONTRACT.md](docs/V4_PRODUCT_CONTRACT.md) for the command and
trust contract.
