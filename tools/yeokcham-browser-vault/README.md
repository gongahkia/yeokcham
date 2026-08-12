# Yeokcham browser passkey vault

This package is the V2-026 browser-local custody boundary, not a web
application or server authentication system. It stores one opaque encrypted
capability record in origin-scoped IndexedDB. Every unlock needs a fresh
user-verifying WebAuthn PRF assertion; the 32-byte PRF result is imported only
in memory as a non-extractable AES-256-GCM key.

The persisted public record is:

```text
(version, origin, rp-id, credential-id, prf-salt, aes-gcm-iv, ciphertext)
```

Plaintext capability bytes, PRF output, and AES key material are not persistent
and are never placed in localStorage. The canonical associated-data grammar is
in `golden/v2-browser-vault-aad-v1.hex`.

`BrowserVault` accepts injected storage, WebAuthn, and WebCrypto boundaries for
deterministic tests. Production callers should use `IndexedDbVaultStore` and
`browserWebAuthn` from a top-level HTTPS application context. It requires a
user-verifying resident passkey with the WebAuthn PRF extension. It has no
password, non-PRF, plaintext, or stored-`CryptoKey` fallback.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

The tests use a fake authenticator and Node WebCrypto. They do not establish
real-browser or hardware-passkey interoperability.
