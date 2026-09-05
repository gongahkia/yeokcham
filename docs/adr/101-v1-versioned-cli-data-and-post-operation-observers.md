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

The small pure `Yeokcham_v1_cli_data` library is established before Health's
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
   process, or V1 transition dependency.
2. A JSON representation does not change command success, repair eligibility,
   plan bytes, approval digest, object bytes, source materialisation, or any
   receipt boundary.
3. An unknown schema or field refuses decoding rather than silently changing a
   script contract.
4. The health adapter never runs a hook. CLI-001 may only run a hook after a
   separately eligible successful local operation has committed.

## Persistent-format impact

The shared JSON envelope is stdout data, not project state, a package, a repair
plan, a bootstrap artifact, a relay object, or a semantic sidecar. CLI-001 adds
one separately versioned, canonical local `hooks-v1` registry below
`.yeokcham/hooks/`. It stores an explicit hook ID, event, and argv list only;
it is outside V1 canonical history and cannot represent source bytes, a
credential, a private key, an authority decision, or a V1 model object.

## CLI-001 implementation amendment

CLI-001 uses one static, pure command/option specification for help-path
coverage and completion generation. The generated Bash script registers one
function with `complete -F`; the Zsh script is an underscored `#compdef`
function for `compinit`; and the Fish script uses declarative `complete -c`
entries. Scripts offer only static command and option names: they do not invoke
Yeokcham, a relay, a secret provider, or a repository while completing.

`--format text|json` is a dispatcher-level option on every command path in the
static specification. `text` remains the default and preserves established
terminal output. The dispatcher removes the formatter before handing arguments
to the existing command parser, so formatting cannot affect a model transition
or its arguments. Health and `hook list` retain their command-specific JSON
records; commands without a richer public record return the versioned algebraic
`completed` result (`{"outcome":"completed"}`). They do not embed terminal
prose in JSON. This narrow development contract lets scripts distinguish the
command, success, error code, and ordered public warnings without parsing text,
while the established text interface remains available for detailed inspection.

The dispatcher emits `invalid-invocation` for usage failures and
`operation-failed` for ordinary command failures; Health retains its documented
domain-specific codes. The envelope is stdout-only. A concise safe error summary
and any hook warning are also emitted to stderr. Warnings appear in order in the
JSON envelope for generic commands and never change the command's exit status.

Hook configuration is explicit and local:

```text
yeokcham hook add --event EVENT -- PROGRAM [ARGUMENT ...]
yeokcham hook list
yeokcham hook remove --id HOOK_ID
yeokcham hook test --id HOOK_ID
```

`add` records an argv list, never a shell string. Eligible successful commands
first commit their ordinary local V1 state, then receive a redacted
`hook-event-v1` JSON document on stdin. The launcher clears inherited
environment variables except a minimal fixed set, supplies no credential or
private-material value, has no shell interpolation, and terminates after 30
seconds. Missing executables, nonzero exits, malformed stdout, signals, and
timeouts create public warnings only: they neither undo a committed transition
nor alter the primary command's exit status. Explicit `hook test` is an
operator diagnostic and likewise does not change V1 state.

Receipt, relay, daemon, verification, repair-planning, and failed-command paths
are ineligible; HEALTH remains hook-free. Event eligibility is a static part of
the command specification, not a dynamic user choice. The runtime consults that
same eligibility field before dispatching an event.

## Verification

- canonical success and generic-completed JSON fixtures, plus malformed,
  unknown-field, and inconsistent-envelope decoder refusals;
- stdout/stderr and status tests for Health text/JSON output; and
- CLI-001 expands the same fixtures to every migrated command plus hooks and
  shell completion tests.

## References

- [Bash programmable completion](https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html)
- [Zsh Completion System](https://zsh.sourceforge.io/Doc/Release/Completion-System.html)
- [Fish `complete` command](https://fishshell.com/docs/current/cmds/complete.html)
