# ADR-101 — versioned CLI data and post-operation observers

- Status: Accepted
- Date: 2026-09-04
- Implements: CLI-001; provides the shared output foundation required by
  HEALTH-001

## Context

HEALTH-001 exposes inspection and repair commands to both people and scripts.
Its roadmap contract requires `--format text|json`; CLI-001 correctly forbids
a health-specific JSON dialect and requires one stable envelope for every
roadmap command. The roadmap order would otherwise make the health command
contract depend on an output format that cannot be introduced until after
Health completes.

## Decision

The small pure `Yeokcham_v4_cli_data` library is established before Health's
command adapter. It owns only the common result envelope and its exact JSON
rendering; it does not add a command, hook, completion script, process, or
repository write.

Every JSON result has exactly these top-level fields in this order:

```json
{
  "schema_version": 1,
  "command": "verify",
  "ok": true,
  "result": {},
  "warnings": [],
  "error": null
}
```

`schema_version` is an integer. `command` is a stable lowercase command path.
`ok` determines command success. `result` is an object or `null`; it carries
only command-specific public data. `warnings` is an ordered array of public
strings. `error` is `null` on success or an object with stable `code` and
non-contractual human `message`. JSON goes to stdout; diagnostics remain on
stderr, and the existing process exit status remains authoritative.

The common encoder uses fixed top-level key order and a real JSON encoder for
all strings. It never serialises bearer credentials, secret-service values,
private keys, passphrases, raw source contents, or relay payloads. Its decoder
rejects unknown top-level mandatory fields, wrong schema versions, wrong
types, duplicate semantic fields, and non-object result/error values.

HEALTH-001 uses this library for `verify` and `repair` only. That is an output
adapter required to make its accepted public interface inspectable, not the
start of broad CLI migration. CLI-001 subsequently migrates the remaining
roadmap commands, generates completions from its central command specification,
and adds observer hooks. Hook execution remains post-success only and is never
used by Health verification or repair planning.

## Invariants

1. Formatting is pure: it has no filesystem, clock, network, secret lookup,
   process, or V4 transition dependency.
2. A JSON representation does not change command success, repair eligibility,
   plan bytes, approval digest, object bytes, source materialisation, or any
   receipt boundary.
3. An unknown schema or field refuses decoding rather than silently changing a
   script contract.
4. The health adapter never runs a hook. CLI-001 may only run a hook after a
   separately eligible successful local operation has committed.

## Persistent-format impact

None. JSON is stdout data, not project state, a package, a repair plan, a
bootstrap artifact, a relay object, or a semantic sidecar.

## Verification

- canonical success/error JSON fixtures and malformed/unknown-field decoder
  refusals;
- stdout/stderr and status tests for Health text/JSON output; and
- CLI-001 expands the same fixtures to every migrated command plus hooks and
  shell completion tests.
