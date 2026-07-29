# Observability and redaction

Yeokcham uses `tracing` for structured diagnostics. Executables install subscribers; library crates only emit spans and events. CLI diagnostics go to stderr, default to `warn`, and use `YEOKCHAM_LOG` for filter directives.

## Field policy

Event names and messages must be static. Field names use `snake_case` and must come from this allowlist:

- Operation and stage names from fixed enums or static strings.
- Error kind codes and redacted public messages.
- Format versions, feature flags, and record-type names.
- Counts, byte lengths, durations, retry numbers, and cache-hit booleans.
- Backend kinds and non-sensitive configuration modes.

Do not record:

- Source, object, chunk, manifest, pack, commit-message, or decrypted bytes.
- Filesystem paths, filenames, ref names, branch names, or remote URLs.
- Raw Git, repository, content, segment, manifest, device, or trace-linked identifiers unless an explicit diagnostic command documents the disclosure.
- Keys, passphrases, credentials, tokens, cookies, authorisation headers, signatures, nonces, salts, or encrypted envelopes.
- Error `Debug` output or source chains.
- Environment-variable values or command arguments that may contain sensitive data.

Use `#[instrument(skip_all)]` and add only allowlisted fields when instrumenting functions. Prefer omitting a sensitive field. If a fixed schema requires its presence, format it through `yeokcham_core::redact`, which emits only `<redacted>`.

## Error events

Record `error.code()` and `error.public_message()` only. Source-chain inspection is restricted to explicit diagnostic commands that apply their own disclosure policy. Normal logs never use `?error`, `%error.source()`, or interpolated dependency errors.

## Review and tests

Every new event must document why each field is safe. Tests covering errors, hostile inputs, or tracing must use sentinel secrets and assert they are absent from captured output. Verbose levels change event volume, not the redaction policy.
