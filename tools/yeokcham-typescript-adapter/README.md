# Yeokcham TypeScript adapter

This tool is an optional analysis adapter. It receives one bounded JSON request
on stdin and writes one bounded JSON protocol response on stdout. Diagnostics
and Node failures use stderr; stdout is protocol-only.

It uses TypeScript `5.9.3` through the local package installed from the checked-in
lockfile. Node `>=14.17.0` is required. Install dependencies once with:

```sh
npm ci --ignore-scripts --no-audit --no-fund
```

`node_modules/` is intentionally untracked. The adapter never invokes npm,
reads a global TypeScript installation, accesses the network, executes project
code, runs tsconfig plugins, reads host `node_modules`, or runs build scripts.

## Protocol v1

`handshake`:

```json
{"protocolVersion":1,"operation":"handshake"}
```

`analyze` accepts a 64-character immutable Yeokcham snapshot ID and a virtual
project file map. All paths are safe project-relative POSIX paths; contents are
hex-encoded exact UTF-8 bytes. The tool accepts `.ts`, `.tsx`, and `.d.ts`.

```json
{
  "protocolVersion": 1,
  "operation": "analyze",
  "snapshotId": "<64 lowercase hex chars>",
  "rootFiles": ["src/main.ts"],
  "files": [{"path":"src/main.ts","language":"ts","contentsHex":"..."}],
  "compilerOptions": {"strict":true,"jsx":"preserve","moduleResolution":"bundler"},
  "timeoutMs": 5000
}
```

The virtual CompilerHost resolves only explicit supplied files. Relative imports
and bounded `baseUrl`/`paths` mapping can resolve inside that map; bare imports,
external config inheritance, plugins, and host dependency reads remain
unavailable. TypeScript source positions are converted to UTF-8 byte offsets
before output. Parse or resolution incompleteness is explicit in the response.

`replace-node` requires one exact declaration byte span, expected preimage bytes
and SHA-256, declaration kind, and declaration-shape digest. It splices only
that range; reparses the candidate bytes; verifies one matching structural
context; and returns a structured conflict if any check fails. It never prints a
complete file or claims behavioural equivalence.

The OCaml boundary materialises its bounded request into a private temporary
stdin descriptor, uses direct argv for Node, and enforces wall-clock timeout and
stdout/stderr bounds. The helper also rejects request/response size excess and
reports an elapsed-time overrun after a completed compiler call. Protocol v1
also rejects analysis exceeding 4096 declaration records before type checking;
the handshake exposes this `declarationLimit` as a capability bound.

Adapter declarations, paths, aliases, types, and source positions are transient
evidence only. Neither TypeScript `Symbol` objects nor internal IDs are Yeokcham
identities. Adapter absence, failed startup, malformed protocol, timeout,
compiler failure, unresolved imports, incomplete resolution, or configured
limits return a structured unavailable or incomplete result; callers retain the
independent exact byte-based textual operation.
