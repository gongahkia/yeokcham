# Yeokcham-native HTTP V1

`yeokcham-server` is a read-only, single-user, Yeokcham-native HTTP transport. It is not Git smart HTTP and ordinary Git clients cannot clone from it. Use `git-remote-yeokcham` for the existing Git-compatible local transport.

## Start

```bash
yeokcham-server token create <private-token-file>
yeokcham-server --repository <yeokcham-repo> --auth-token-file <private-token-file>
yeokcham-server --repository <yeokcham-repo> --auth-token-file <private-token-file> --bind 127.0.0.1:9181
```

`token create` creates a new regular mode-0600 file without replacing an existing pathname and prints no secret. The file contains 32 random bytes as 64 lowercase hexadecimal characters plus one newline. Server startup requires this file, opens it without following symlinks, and rejects group-readable, world-readable, or non-regular files. Do not pass the token through a command line or environment variable.

The default bind is the operating system-selected port on `127.0.0.1`. Startup prints the actual address. `--bind` accepts a numeric socket address only and rejects every non-loopback address, including `0.0.0.0`. IPv6 loopback uses `[::1]:<port>`.

## HTTP rules

- HTTP/1.1 only.
- `GET` only; a non-GET request receives `405` and `Allow: GET`.
- One request per connection; responses send `Connection: close` and `Cache-Control: no-store`.
- Request headers are ASCII and limited to 8 KiB.
- `Content-Length` and `Transfer-Encoding` are rejected; V1 accepts no request body.
- Each read or write phase has a five-second deadline.
- Four request workers and eight queued accepted sockets bound local resource use.
- JSON response bodies and raw-object bodies are limited to 64 MiB.
- Every endpoint requires exactly one authorization header: `Authorization: Bearer <64-lowercase-hex>` for native clients, or `Authorization: Basic <base64(yeokcham:<token>)>` for a browser.
- Absent, malformed, duplicate, or wrong credentials receive the same `401` response and both Basic and Bearer `WWW-Authenticate` headers.

Every error response has `application/json` content and this envelope:

```json
{"version":1,"error":"machine_readable_code"}
```

The server deliberately does not expose repository paths, internal error detail, source bodies, or tokens in logs, or a filesystem endpoint.

## Endpoints

### `GET /`

Returns an authenticated static HTML repository page with the repository ID, regular ref names/object IDs, and `HEAD`. Navigate to the printed loopback address; when the browser prompts, use username `yeokcham` and the 64-character token as the password. Basic credentials are Base64-encoded, not encrypted, so do not forward, proxy, or tunnel this endpoint.

Valid UTF-8 ref names are HTML-escaped. Non-UTF-8 names appear as `hex:<lowercase-hex>`. V1 deliberately has no object-body, commit, tree, write, export, recovery, script, form, cookie, or token-bearing-link page.

### `GET /v1/health`

Returns `200` when the process accepts V1 requests:

```json
{"version":1,"status":"ok"}
```

### `GET /v1/refs`

Resolves the current checked Yeokcham ref state. A repository with no published ref state returns `404` with `ref_state_unavailable`; invalid or unavailable stored state returns `500` without storage detail.

```json
{
  "version": 1,
  "repository_id": "550e8400-e29b-41d4-a716-446655440000",
  "refs": [
    {
      "name_hex": "726566732f68656164732f6d61696e",
      "object_id": "0123456789012345678901234567890123456789"
    }
  ],
  "head": {
    "kind": "symbolic",
    "ref_name_hex": "726566732f68656164732f6d61696e"
  }
}
```

`name_hex` and `ref_name_hex` are lowercase hexadecimal encodings of exact Git refname bytes. A detached `head` instead contains `{"kind":"detached","object_id":"<sha1>"}`. Clients must not decode a ref name as UTF-8 unless they explicitly require UTF-8.

### `GET /v1/objects/<sha1>`

`<sha1>` is exactly 40 lowercase hexadecimal SHA-1 digits. The server reconstructs a published object through bounded manifests, verifies its Git identity, then returns `200` with:

```text
Content-Type: application/vnd.yeokcham.git-object
X-Yeokcham-Native-Version: 1
X-Yeokcham-Git-Object-Id: <sha1>
X-Yeokcham-Git-Object-Kind: blob|tree|commit|tag
Content-Length: <body-bytes>
```

The body is the exact decompressed Git object body without the canonical loose-object `"<type> <size>\\0"` header. A client reconstructs that header from `X-Yeokcham-Git-Object-Kind` and the received byte length, then recomputes SHA-1 before trust. Unknown IDs return `404` with `not_found`.

## Security boundary

V1 requires one generated token and is deliberately loopback-only. Native clients use Bearer; normal browsers may use Basic with username `yeokcham` and that token as password. Basic is Base64 encoding, not encryption. Loopback prevents network peers from connecting, while authentication rejects a local process that lacks the token; neither protects a compromised account, process memory, or operating system. Treat the token file as a full read credential. Do not use a generic port forward or reverse proxy to expose V1. Non-loopback deployment, TLS termination, write operations, token reload/rotation without restart, and browser sessions are separate milestones.

The service is read-only. Its loss or termination cannot change a Yeokcham repository; recovery remains the existing local export and encrypted recovery path. To rotate a token, create a new file, restart the server with it, and update clients; a lost token does not affect repository recovery.
