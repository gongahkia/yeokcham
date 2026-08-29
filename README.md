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
  retained safety checkpoint.
- Explicit drafts, shared immutable revisions, conservative composition, and
  conflict records that can be inspected and materialised outside the working
  tree before an explicit resolution.
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
yeokcham package create --destination ../outgoing
yeokcham remote add team https://relay.example.invalid
yeokcham remote login team
yeokcham sync team
yeokcham bootstrap publish team
```

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

For synchronization, run `yeokcham relay serve --storage PATH --listen
127.0.0.1:8080 --token-file PATH` behind an operator-managed HTTPS reverse
proxy. The relay is only an immutable byte courier; `sync` verifies received
packages before updating local state and reports upload failures as pending
retry work.

## Boundaries

Linux `watch` is implemented as advisory capture after debounce. Its real
inotify loop must still be run on Linux; macOS and WSL watchers are not
implemented. Relay synchronization is available only for already-equivalent
replicas through an operator-managed HTTPS reverse proxy. A new replica instead
needs an explicit immutable bootstrap basis ID, public repository ID, enrolled
local device, and independently compared root phrase; it starts with fresh
local scratch state and never materialises its working tree. The relay is an
untrusted byte courier and stored payloads are not end-to-end encrypted. There
is no general clone, Git import/export, semantic parsing, CI-backed delivery,
signing agent, hardware-key support, or blob GC. Those are deliberate future
work, not hidden product behaviour.

Read [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) for the philosophy,
[FORMAL_MODEL.md](FORMAL_MODEL.md) for invariants, and
[docs/V4_PRODUCT_CONTRACT.md](docs/V4_PRODUCT_CONTRACT.md) for the command and
trust contract.
