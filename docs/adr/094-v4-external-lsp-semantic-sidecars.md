# ADR-094 — V4 external LSP semantic sidecars

- Status: Accepted
- Date: 2026-08-31
- Deciders: maintainers
- Implements: [#254](https://github.com/gongahkia/yeokcham/issues/254)
- Depends on: ADR-092 exact decision-proposal assistance

## Context

ADR-092 deliberately treats every snapshot entry as opaque bytes. That is the
canonical V4 answer to a decision: it can identify exact source provenance but
cannot claim that two textual edits express compatible intent. Teams may still
want language-aware facts while inspecting a decision—for example, that both
candidates changed a symbol with the same name.

Yeokcham must not become the maintainer of parsers, compiler versions, indexes,
or language-specific trust rules. Such a subsystem would make semantic output
look canonical even when a parser, server version, workspace configuration, or
language interpretation differs between machines.

## Decision

V4 may query one explicitly configured, already-installed Language Server
Protocol (LSP) executable as an **untrusted, session-local advisory tool**.
It imports `lsp = 1.27.0` and `jsonrpc = 1.27.0` for typed request/response
handling and LSP framing; it does not implement an LSP parser or JSON-RPC wire
encoder. The [LSP specification](https://microsoft.github.io/language-server-protocol/)
defines the editor/server protocol boundary used here.

### Local configuration and disclosure

`.yeokcham/semantic-lsp-v1.cbor` is a mode-0600, canonical, versioned,
repository-local configuration file. A server record contains a unique name,
an absolute executable path, literal arguments, enabled state, a matching
scope, and an overlap-sensitivity setting. It is not project state, a signed
record, a package entry, relay input, bootstrap data, authority data, delivery
data, or canonical object.

The `semantic server` CLI adds, lists, configures, enables, disables, and
removes these records. Matching can be explicit extensions (the default),
repository-relative globs, or all changed files. A configured executable is
never downloaded, bundled, guessed, or selected by language detection.

Enabling a matching server is affirmative consent for it to receive the full
named snapshot bytes in a disposable workspace. Yeokcham does not pass the
live worktree path. It cannot sandbox an executable running with the user's
OS permissions: it controls only its own invocation, temporary directory, and
V4 writes. This limitation is displayed in command documentation rather than
being represented as a security guarantee.

### Invocation and lifecycle

`decision propose` preserves ordinary byte-only output when no enabled server
matches. With exactly one enabled match, it appends an advisory automatically.
With several matches it remains byte-only and asks for
`--semantic-server NAME`; that avoids silently disclosing source to multiple
programs. An explicit selected server may also be named with that flag.

For a selected pair, Yeokcham materialises the exact base, left, and right
snapshots independently into mode-0700 disposable directories outside the
live worktree. It starts a fresh configured executable in each directory with
no shell. The directories, descriptors, and child process are removed/reaped
on normal completion, protocol failure, timeout, or interruption.

The allow-list is initialization plus read-only `documentSymbol`,
`workspace/symbol`, definition, and reference requests. The client advertises
neither workspace edits nor configuration support. Any server-initiated
request—including `workspace/applyEdit`, configuration, registration, command,
or unknown request—is answered `MethodNotFound`; notifications are ignored.
No response causes a file, configuration, project, or working-tree write.

Each snapshot session permits a two-second initialization phase, five seconds
after initialization, at most 128 matched regular files, 512 requests/selected
symbol positions, 10,000 locations, 256 KiB per JSON-RPC packet, an 8 KiB
header, and 2 MiB total received protocol bytes. Stderr is discarded rather
than retained as a potentially unbounded side channel. A missing executable,
timeout, malformed packet, oversized output, unsupported capability, unsafe
returned URI, or non-text range is an explicit unavailable result; the exact
proposal still succeeds.

### Advisory output

Every observation displays its base/left/right snapshot ID, configured command,
server-reported name/version, negotiated capability set, request-derived path,
range, and returned definition/reference/workspace-match counts. Nothing is
persisted after the command exits.

The default possible-overlap signal is intentionally narrow: the same path,
symbol name, kind, and nesting identity must appear in all three LSP views, and
the exact UTF-16 bounded source range must have different bytes from the base
on both candidates. Invalid UTF-8, invalid ranges, moved/renamed symbols, and
absent base identities are uncertain, not evidence of safety or conflict.

Per-server settings can broaden the display to nearby returned ranges or shared
definition/reference locations. Those modes are noisier and retain the phrase
`possible overlap`; they never select a candidate or decide a conflict.

There is no semantic merge, no generated code, no accept/reject-proposal event,
and no route from an observation to a resolution. A person still materialises
or constructs bytes outside the live tree and uses the existing explicit
`resolve` action to record a signed resolution.

## Invariants

1. Exact snapshots, modes, symlinks, and byte proposal provenance remain the
   sole canonical decision inputs.
2. LSP observations are local, ephemeral, untrusted, and non-authoritative;
   they never enter state, authority, packages, relay, bootstrap, delivery, or
   object storage.
3. The configured server never receives Yeokcham's live worktree path, and the
   adapter never materialises or writes that worktree.
4. Server-originated edit, configuration, command, and capability-changing
   requests cannot alter local V4 state or files through the adapter.
5. Failure to obtain semantic facts cannot block inspection of the existing
   byte-exact proposal.
6. An overlap display is evidence for human review, never a judgment that two
   changes conflict, compose, or express intent.

## Verification

- canonical local-config fixture; private mode, validation, ordering, duplicate,
  matcher, and invalid-glob tests;
- a disposable compiled fake server proving snapshot URI isolation, reported
  server/version/capabilities, same-symbol evidence, rejected apply-edit,
  rejected command execution, malformed JSON-RPC, oversized packet, and timeout
  behaviour; and
- repository-byte comparison proving a malicious server interaction does not
  modify local V4 metadata.

## References

- [Language Server Protocol specification](https://microsoft.github.io/language-server-protocol/)
- [OCaml `lsp` package 1.27.0](https://opam.ocaml.org/packages/lsp/lsp.1.27.0/)
- [OCaml `jsonrpc` package 1.27.0](https://opam.ocaml.org/packages/jsonrpc/jsonrpc.1.27.0/)
