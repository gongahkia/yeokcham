# Paengi TypeScript adapter

This tool is an optional analysis adapter. It receives one bounded JSON request
on stdin and writes one bounded JSON protocol response on stdout. Diagnostics
and Node failures use stderr; stdout is protocol-only.

It uses TypeScript `7.0.2` through the local package installed from the checked-in
lockfile. Node `>=16.20.0` is required. Install dependencies once with:

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

`analyze` accepts a 64-character immutable Paengi snapshot ID and a virtual
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

The outer Paengi process runner enforces wall-clock timeout and output bounds;
the helper also rejects request/response size excess and reports an elapsed-time
overrun after a completed compiler call.
