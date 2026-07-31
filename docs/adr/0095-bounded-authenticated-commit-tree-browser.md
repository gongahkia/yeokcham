# ADR-0095: Render bounded authenticated commit and tree metadata

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The initial V1 browser exposes only repository/ref/HEAD metadata. Milestone 9 separately requires commit and tree viewing, but arbitrary Git object bodies and filenames are hostile input. Rendering complete commit messages or unbounded trees can exceed the service response limit, and rendering blobs would create a source-browser surface beyond this milestone.

## Decision drivers

- Reconstruct and verify every viewed object before parsing it.
- Keep browser navigation authenticated, loopback-only, static, and token-free.
- Preserve dynamic Git bytes without HTML injection or lossy UTF-8 replacement.
- Bound parsing memory and rendered output for wide trees and oversized metadata.
- Do not create a blob, write, export, session, or public-serving feature.

## Considered options

### Render exact complete commit and tree bodies

This exceeds the bounded HTTP/browser response model for valid large commits and trees.

### Add pagination and JavaScript state

This needs a new route/query contract and creates client-side state, form, script, and cache policy decisions.

### Render bounded static metadata previews

This gives useful object navigation while preserving the existing single-request static browser model.

## Decision

Add authenticated `GET /commits/<40-lowercase-sha1>` and `GET /trees/<40-lowercase-sha1>`. Each route uses the existing bounded reconstruction path, which verifies the requested Git identity before content parsing. A missing object returns `404`; a different verified object kind or malformed commit/tree payload returns generic `422` without raw object data.

Commit pages show the ID, linked tree, first 1,024 parent IDs, author/committer previews limited to 4 KiB, and a message preview limited to 64 KiB. Tree pages validate binary modes, path components, NUL delimiters, and 20-byte IDs, then show the first 10,000 entries in stored order with 1 KiB filename previews. Dynamic valid UTF-8 text is HTML-escaped; dynamic invalid UTF-8 bytes are lowercase `hex:`. Child tree IDs link to tree pages; blobs, symlinks, and gitlinks remain non-linked metadata.

## Consequences

Users can navigate a commit's parents and tree, then nested stored trees, without adding a source viewer. The browser may display an explicit truncation marker for values beyond its preview bounds. A submodule gitlink can name a commit unavailable in this repository, so it has no commit link. Ref targets remain metadata rather than assumed commit links.

## Invariants

- No commit or tree bytes are trusted before reconstructed Git-ID verification.
- Every parsed tree consumes complete bounded object bytes and rejects malformed entry boundaries or unsafe path components.
- Dynamic text never enters markup unescaped; binary data has a lossless hexadecimal representation within the preview cap.
- HTML response construction remains below the existing 64 MiB limit.
- No page reveals a token, renders a blob, mutates a repository, or expands the listener scope.

## Compatibility and migration

No repository, storage, recovery, or native wire-format change. The two additive authenticated V1 routes are documented in [`native-http-v1.md`](../native-http-v1.md). They extend the repository page authorized by ADR-0094 without changing its Basic/Bearer token lifecycle.

## Security and recovery

Commit metadata and messages, tree filenames, and object IDs are repository content disclosed only to the already-authorized local reader. Escaping, hexadecimal fallback, parser validation, static response headers, and preview limits prevent HTML injection and resource growth from hostile stored inputs. The pages are read-only; server loss or token rotation does not affect repository recovery.

## Verification

The V1 integration test serves a real imported commit and tree through both Basic and Bearer authentication, checks escaped message and filename output plus tree navigation, and rejects kind mismatches. Parser tests cover valid continued commit headers, malformed commit IDs, valid binary tree entries, and unsafe tree names. Workspace CI verifies formatting, Clippy, tests, and documentation.
