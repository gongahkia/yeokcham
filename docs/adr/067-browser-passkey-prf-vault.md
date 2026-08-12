# ADR-067 — browser passkey PRF vault and origin-bound local custody

- Status: Accepted
- Date: 2026-08-13
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#148](https://github.com/gongahkia/yeokcham/issues/148)
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#146](https://github.com/gongahkia/yeokcham/issues/146), [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

V2 needs a browser-local capability boundary that survives browser restart but
does not persist a plaintext repository key. A successful ordinary WebAuthn
assertion alone is not a symmetric key: local code cannot safely turn an
assertion signature into a stable vault key, and storing a separately generated
browser `CryptoKey` would not make access depend on each passkey assertion.

WebAuthn Level 3's `prf` extension is expressly designed to evaluate a
credential-bound 32-byte pseudo-random function, including for local symmetric
encryption. It is the narrow standard mechanism that provides the required
passkey-gated key material without exporting the passkey private key.

## Decision drivers

- Browser restart must require a fresh successful passkey assertion before
  decrypting the local capability.
- IndexedDB and local storage must never contain plaintext repository key
  bytes, PRF output, or an exportable vault key.
- The vault must reject a changed origin, RP ID, credential ID, corrupted
  record, unavailable WebAuthn API, unavailable PRF, missing user presence, or
  missing user verification before exposing a capability.
- Use browser WebAuthn and WebCrypto primitives, not custom cryptography or a
  fake signature-to-key construction.
- Logout must discard library-held plaintext without deleting the encrypted
  vault or changing a repository authority record.

## Considered options

### Store a non-extractable WebCrypto key in IndexedDB

The WebCrypto specification allows `CryptoKey` structured cloning, but the key
would be retrievable without a fresh passkey assertion. It does not satisfy the
required gate and is rejected.

### Derive a key from a WebAuthn assertion signature

Assertion signatures are not a defined symmetric-key interface and can differ
between assertions. This would invent an unsupported cryptographic protocol.
It is rejected.

### Require the WebAuthn PRF extension and import its output directly as AES-GCM

After a user-verified assertion, `prf.results.first` is exactly 32 bytes. It is
imported as a non-extractable AES-256-GCM key, used only in memory for one
enrolment or unlock, and discarded. This is selected.

## Decision outcome

`yeokcham-browser-vault` is a small browser-facing JavaScript boundary with an
injected WebAuthn client, WebCrypto provider, and vault store. Its production
store uses one origin-scoped IndexedDB database and stores only this public
version-1 envelope:

```text
Browser_vault_v1 = (
  version, origin, rp-id, credential-id, prf-salt, aes-gcm-iv, ciphertext
)
```

`origin`, `rp-id`, `credential-id`, `prf-salt`, and IV are public. The
repository capability is AES-256-GCM ciphertext, using canonical UTF-8
associated data over all public binding fields. The plaintext, PRF output, and
AES key never enter local storage, localStorage, repository objects, request
arguments, logs, fixtures, or a server response.

Enrolment first rejects an existing local record, creates a user-verifying
resident WebAuthn credential for the configured HTTPS origin/RP ID, then makes
an explicit user-verifying assertion with `prf.evalByCredential`. It checks the
credential ID, `clientDataJSON` type/challenge/exact origin/no cross-origin
flag, RP ID SHA-256 from authenticator data, and user-presence and
user-verification flags before it accepts the PRF output. The resulting
encrypted record is inserted create-only into IndexedDB. An interruption can
leave an unused passkey credential but cannot publish a plaintext vault or
overwrite a different record.

Opening follows the same fresh assertion path. It derives the AES-GCM key only
after those checks and rejects AES-GCM authentication failure as corruption.
The local implementation relies on the browser/user agent and authenticator to
perform the WebAuthn ceremony; it does not claim a server-verifiable assertion
or create a user, repository, membership, join, revocation, or recovery record.

`logout` clears the vault object's currently held byte buffer. [Inference]
This reduces the lifetime of the library-owned copy, but JavaScript callers,
the runtime, and garbage collector can retain independent copies; it is not a
secure-memory guarantee. `remove` deletes only the local IndexedDB record and
also logs out; it does not mutate any signed repository authority.

## Consequences

- Browsers without WebAuthn, a secure matching origin, a user-verifying
  credential, or PRF support report structured unavailable/refusal results.
- PRF support is intentionally required rather than falling back to a stored
  WebCrypto key, password, localStorage secret, or plaintext file.
- The first browser implementation is a local vault boundary, not the Svelte
  application, OIDC UX, server authentication, passkey recovery, MLS state, or
  remote authorization planned in later issues.
- Browser data copied to another origin cannot pass the exact-origin check or
  AES-GCM associated-data authentication.

## Model and invariant impact

```text
Vault_public = (origin, rp-id, credential-id, salt, iv, version)
Vault_key = AES-256-GCM-import(PRF(user-verified assertion, salt))
Vault_ciphertext = AEAD_encrypt(Vault_key, AAD(Vault_public), Capability)
```

1. `Vault_key`, PRF output, and capability plaintext are never persistent.
2. The exact expected origin, RP ID, and credential ID are checked before
   decryption and are authenticated as associated data.
3. Each unlock needs a newly generated challenge and a fresh user-verifying
   passkey assertion; a process restart contains no active plaintext state.
4. Unknown record version, noncanonical public encoding, malformed base64url,
   wrong field sizes, unexpected WebAuthn response, and authenticated-decryption
   failure are explicit refusal states.
5. Enrolment/removal affect browser-local storage/credential state only and are
   separate from signed join/removal transitions.

## Persistent-format and migration impact

The IndexedDB record is local browser state, not a Yeokcham repository object.
Its public associated-data grammar has a deterministic vector; no fixture
contains repository key bytes, a PRF output, or ciphertext derived from a real
credential. Unknown versions and malformed fields fail closed. There is no
migration reader or legacy localStorage import.

## Verification

- Focused tests cover public associated-data vector, encrypted restart open,
  origin/RP/credential mismatch, WebAuthn/PRF unavailability, corrupt ciphertext,
  missing user-verification flags, create-only collision, and removal/logout
  without repository mutation.
- A seeded generated suite varies public origins, credential IDs, salts, and
  capability bytes and proves a restart requires a fresh assertion to recover
  the exact bytes.
- Browser-bound code uses injected fakes for ordinary deterministic tests;
  an opt-in browser integration test remains required once the Svelte shell is
  available. It must not claim a hardware/passkey run from Node alone.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## References

- [WebAuthn Level 3 PRF extension](https://www.w3.org/TR/webauthn-3/#prf-extension)
- [WebCrypto AES-GCM](https://www.w3.org/TR/webcrypto-2/#aes-gcm)
- [WebAuthn extensions on MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Authentication_API/WebAuthn_extensions)
