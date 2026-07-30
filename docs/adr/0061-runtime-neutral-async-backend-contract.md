# ADR-0061: Define a runtime-neutral async backend contract

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Local disk, Google Drive, and future stores need one narrow object-store boundary. The backend must be weak enough for eventually consistent remote providers, avoid unbounded read allocation, and remain dynamically injectable for testing, metrics, and provider selection. Native `async fn` trait methods are not dyn-compatible, so they cannot directly provide the required trait-object boundary on the supported toolchain.

## Decision drivers

- Support runtime-independent local and network implementations.
- Keep the trait dynamically injectable.
- Preserve immutable create-only publication semantics.
- Bound reads and listing work before bytes enter repository recovery paths.
- Reserve deletion for explicit maintenance only.

## Considered options

### Option 1: boxed sendable futures

Return `Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>` from object-safe trait methods. This allocates once per backend call but supports `dyn Backend` without selecting an async runtime.

### Option 2: native async trait methods

Use `async fn` directly in the trait. This has a simpler surface but is not dyn-compatible, preventing the planned wrapper and provider boundary.

### Option 3: select a runtime and use its stream traits

Adopt a runtime and streaming stack before a network backend exists. This adds a broad dependency and policy choice prematurely.

## Decision

Use Option 1. `Backend` exposes create-only `put_if_absent`, bounded `get`, `head`, bounded paginated `list`, maintenance-only `delete`, and explicit resumable upload session operations. All methods return the runtime-neutral `BackendFuture` alias.

`BackendKey` accepts a nonempty bounded safe ASCII slash-delimited key. `BackendPrefix` also accepts the empty root and one trailing slash. Key and cursor debug output is redacted. Reads require a caller maximum and may request an inclusive-start/exclusive-end range. Listing requires both page and scan bounds. A create-only put reports either `Created` or `AlreadyExists` metadata and never mutates an existing object.

Resumable sessions bind the destination key, opaque session ID, and total length. Backends must accept only contiguous writes at the declared offset and publish only a complete session without replacing a preexisting destination. Session persistence and visibility are explicitly backend-specific.

## Consequences

The trait introduces a small allocation per operation and returns complete bounded byte vectors rather than streams. This is deliberate until provider-specific streaming and cancellation behavior are designed. The contract does not assert transactionality, ordered listings, cross-object visibility, locks, or immediate global consistency.

Backend bytes are not yet connected to repository publication and remain plaintext until the encryption milestone. Callers must continue to verify format, signature, checksum, and Git identity after reads; backend metadata is not trust evidence.

## Invariants

- Existing backend objects are never overwritten by create-only or resumable completion.
- Every materialized read is caller-bounded.
- Backend key validation rejects path-traversal syntax before filesystem mapping.
- List cursors are opaque and ordering is not a cross-backend guarantee.
- Delete is never used to publish or advance ref state.

## Compatibility and migration

The contract creates no persistent repository data. It is a new public core API; later streaming or multipart extensions require additive methods or a new trait rather than changing current semantics.

## Security and recovery

Default diagnostics redact keys, cursors, and resumable session IDs. Key validation prevents filesystem traversal in the initial backend. A successful backend operation does not authenticate data or make it safe to return; existing recovery verification remains mandatory. No private key material is accepted by this interface.

## Verification

Unit tests cover path-safe bounded keys and prefixes, invalid ranges and list limits, redacted diagnostics, and dynamic trait compatibility. The Rust documentation confirms that traits containing `async fn` are not dyn-compatible; the boxed-future contract preserves that boundary without an async runtime dependency.
