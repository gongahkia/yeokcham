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
- Optional configured external-LSP observations for a decision proposal. They
  inspect disposable named snapshots only, remain untrusted and ephemeral, and
  can flag possible overlap but cannot merge, resolve, or write source.
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
- Explicit local device custody: existing platform stores, one exact
  `ssh-ed25519` SSH-agent key, or an Ed25519 PKCS#11 token key. Provider
  metadata is never authority or shared history.

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

To move an existing device to a token, create its local custody profile, inspect
the public device ID, then use the ordinary explicit authority rotation. The
token alone grants nothing:

```sh
yeokcham device create --provider pkcs11 --root . --module /path/to/pkcs11.so \
  --token-label TEAM --key-label yeokcham-alice --key-id 01a2
yeokcham device custody --root . --device NEW_DEVICE_ID
yeokcham device rotate --root . --device NEW_DEVICE_ID --public-key PUBLIC_KEY_HEX
```

An SSH-agent key is attached rather than generated:

```sh
yeokcham device attach --root . --provider ssh-agent --public-key ~/.ssh/yeokcham.pub
```

The local profile stores no PIN or private key. Use a dedicated agent key and
avoid SSH agent forwarding where it would let another host request signatures.

To inspect an open decision with an already-installed language server, configure
it explicitly for this repository. The server receives disposable copies of the
named snapshots, so do this only when that disclosure is appropriate:

```sh
yeokcham semantic server add ocaml --program /usr/bin/ocamllsp --arg --stdio \
  --extension .ml --extension .mli
yeokcham decision propose --decision DECISION_ID --left LEFT_REV --right RIGHT_REV
```

The resulting semantic section is advisory only. If more than one configured
server matches, select one visibly with `--semantic-server NAME`; disabling or
removing a server restores byte-only proposals.

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
`daemon` is Linux-only and requires a private `XDG_RUNTIME_DIR`; macOS watchers
and runtimes are not implemented, and WSL is unsupported and not planned. Relay synchronization is available only for already-equivalent
replicas through an operator-managed HTTPS reverse proxy. A new replica instead
needs an explicit immutable bootstrap basis ID, public repository ID, enrolled
local device, and independently compared root phrase; it starts with fresh
local scratch state and never materialises its working tree. The relay is an
untrusted byte courier and stored payloads are not end-to-end encrypted. There
is no online authority coordinator, general clone, Git interchange, in-process
semantic parsing or merge, or CI-backed delivery. An explicitly configured
external LSP server is advisory tooling, not a Yeokcham parser or trust source.
There is
no relay, package, or automatic blob GC; local collection is only the explicit
quarantine-and-purge workflow above. Those are deliberate boundaries, not
hidden product behaviour.

Source-release signatures are a separate maintainer/consumer provenance check;
they do not enter V4 authority or history. See
[docs/RELEASING.md](docs/RELEASING.md) for the future source-release
verification procedure.

Read [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) for the philosophy,
[FORMAL_MODEL.md](FORMAL_MODEL.md) for invariants, and
[docs/V4_PRODUCT_CONTRACT.md](docs/V4_PRODUCT_CONTRACT.md) for the command and
trust contract.
