# ADR-093 — V4 local device-custody providers

- Status: Accepted
- Date: 2026-08-30

## Context

ADR-083 made an Ed25519 public key the sole device identity and placed signing
behind a provider boundary. Its first providers retained private bytes in a
platform store. That is adequate for ordinary local use but does not cover a
key deliberately held by an SSH agent or a PKCS#11 token, where V4 must be able
to sign without acquiring private-key bytes.

Custody is not authority. A token label, hardware serial number, operating
system account, SSH comment, and provider availability describe a local way to
use a key. None may enrol a device, select an authority head, revoke a device,
adopt a late record, resolve a decision, or deliver work. Conversely, an
enrolled public device remains the same device when its local custody changes.

## Decision

The trust core accepts an opaque signing capability: its verified Ed25519
public key and an operation that signs already-domain-separated bytes. The core
still constructs every canonical record, verifies every resulting signature,
and derives the device ID solely from the public key. Canonical certificates,
epochs, signed revisions, authorizations, and adoptions do not contain a
provider reference and keep their existing bytes.

V4 supports three local custody paths:

1. The existing native macOS Keychain and Linux Secret Service providers remain
   the default for existing devices.
2. An explicit `ssh-agent` attachment selects one exact `ssh-ed25519` public
   key through `SSH_AUTH_SOCK`. The adapter speaks the bounded agent protocol,
   requests that exact key only, accepts only a raw 64-byte `ssh-ed25519`
   signature, and verifies it before returning it to the trust core.
3. An explicit PKCS#11 profile selects an absolute module path, token label,
   binary key ID, and exact public key. V4 creates Ed25519 token keys with
   sensitive, non-extractable private material and uses `CKM_EDDSA` directly.
   It requires exactly one matching public/private key pair; ambiguous selectors
   fail rather than choosing a token object. A token PIN is read only from the
   controlling terminal for production commands and is neither saved nor logged.

An external provider must be configured deliberately. `device attach` first
checks the provider's discovered public key against the requested key, then
writes a local-only canonical `custody-v1` profile under
`.yeokcham/custody-v1/`. The profile is mode 0600, size-bounded,
create-only/atomic, and contains only a provider selector and public key. It is
not project state, an immutable object, a package entry, relay content,
bootstrap material, recovery material, or a credential. A missing, malformed,
insecure, or noncanonical profile fails closed.

`device create --provider pkcs11` creates a new local token key and profile;
it does not make that key a repository member. To change a current device, an
active administrator must inspect the new public ID and use the ordinary
explicit `device rotate` authority transition. The transition enrolls the
replacement and revokes the old local device atomically. A provider denial or
token failure occurs before that state publication, so no partial rotation is
valid. Recovery remains the existing public-authority/recovery-capability path
and is not redirected through token metadata.

Errors are intentionally distinct: unavailable provider, missing key,
ambiguous selector, locked or denied token, SSH-agent protocol failure,
unsupported Ed25519 mechanism, and discovered-public-key mismatch. They are
local custody outcomes, not authority evidence. Automated tests may use a
disposable software token to exercise the PKCS#11 boundary; that demonstrates
the interface and non-extractable attribute path, not possession of a physical
device.

## Invariants

1. Device ID is derived only from the exact 32-byte Ed25519 public key.
2. Provider metadata and local custody profiles never enter V4 signed records,
   project state, packages, relay requests, bootstrap, or recovery packages.
3. A provider signs bytes chosen and domain-separated by the trust core; the
   returned signature must verify against the configured public key.
4. Private-key bytes from SSH-agent and PKCS#11 capabilities are unavailable to
   callers, state, diagnostics, and fixtures.
5. Provider discovery is explicit and checks the exact public key before a
   profile is saved; a selector matching multiple token keys fails closed.
6. A failed or declined signing operation publishes no authority or project
   state update and does not modify the working tree.
7. SSH-agent forwarding is not a V4 trust mechanism. Operators should use a
   dedicated agent key and disable forwarding where that would expose signing
   authority to another host.

## Consequences

V4 can use a non-exportable PKCS#11 Ed25519 key for normal shared revisions,
decision resolutions, authority actions, and late-record adoptions without
changing the history or authority model. PKCS#11 providers differ in their
Ed25519 support, so V4 detects unsupported mechanisms at use time rather than
claiming generic hardware compatibility. A configured token or agent may be
absent; that makes signing unavailable, not the device revoked.

Existing native devices remain usable. Moving an existing local authority to a
token is an explicit two-step ceremony: create or attach the locally held key,
then rotate to its independently inspectable public device ID. This preserves
the old authority until the signed rotation succeeds.

## Verification

Focused tests prove the canonical profile fixture and restrictive mode,
non-exportability, exact SSH-agent selection, PKCS#11 signing for every V4
record purpose, wrong-PIN denial, provider absence, public-key mismatch, and a
declined external rotation leaving every repository byte unchanged. The PKCS#11
test uses a disposable SoftHSM token only when its module path is explicitly
provided; CI prepares that disposable token on Linux and macOS.

## References

- [PKCS #11 v3.1](https://docs.oasis-open.org/pkcs11/pkcs11-spec/v3.1/os/pkcs11-spec-v3.1-os.html)
- [OpenSSH agent protocol](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.agent)
- [RFC 8032](https://www.rfc-editor.org/info/rfc8032/)
