# Experiment 094 — external LSP sidecar boundary

- Date: 2026-08-31
- Host: Fedora Linux 43 development environment
- Server: compiled disposable fake LSP server in `test/fake_lsp_server.ml`
- Protocol libraries: `lsp` 1.27.0 and `jsonrpc` 1.27.0

## Purpose

Exercise the Yeokcham adapter boundary, not language intelligence. The fake
server returns one stable document symbol and the required read-only capability
set, then separately attempts an edit or command request, or sends malformed,
oversized, and timed-out protocol output.

## Observations

- The adapter reported the fake server's declared name, version, capability
  set, and all three named base/left/right snapshot identities.
- A same-symbol change produced only a `possible overlap` observation. No test
  created a resolution, selected a candidate, or modified source.
- The fake server received a temporary `file:` workspace URI, not the test's
  live repository URI.
- `workspace/applyEdit` and `workspace/executeCommand` each received
  `MethodNotFound`; malformed JSON, an oversized declared packet, and an
  initialization timeout each produced unavailable advice.
- Repository metadata bytes were equal before and after the hostile server
  interaction.

## Limits and future runs

This is not evidence that any real language server is sound, stable, private,
or useful for a language. Before recording a real-server run, add its language,
server command and version, host, decision shape, useful observations,
unavailable cases, false/stale observations, and whether the disclosure of the
complete staged snapshot was appropriate. Do not turn those observations into
claims about V4 authority, resolution quality, or delivery.
