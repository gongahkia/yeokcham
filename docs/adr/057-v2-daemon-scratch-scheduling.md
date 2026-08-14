# ADR-057 — V2 daemon-owned scratch scheduling

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#136](https://github.com/gongahkia/yeokcham/issues/136)
- Related issues: [#134](https://github.com/gongahkia/yeokcham/issues/134), [#135](https://github.com/gongahkia/yeokcham/issues/135), [#147](https://github.com/gongahkia/yeokcham/issues/147)

## Context and problem statement

ADR-050 provides one local runtime socket, ADR-051 supplies advisory Linux
inotify requests, and ADR-055 provides exact scan-and-publish. Until this
decision, they were independent components: no daemon-owned operation could
turn a due normalized request into a V2 scratch checkpoint.

The integration must not make inotify authoritative, persist scheduler state,
reuse one encryption nonce for the two envelopes in a publication, or make the
Linux process boundary part of the client-agnostic V2 model. It must also avoid
watching its own `.yeokcham` writes: otherwise publication would feed back into
new advisory scans.

## Decision drivers

- Preserve exact scanning as the sole source of scratch bytes.
- Bound continuous watcher bursts with the existing scheduler configuration.
- Resume after daemon restart without assuming stale watcher coverage survived.
- Use a monotonic rather than wall-clock source for scheduler deadlines.
- Keep capability custody outside the daemon runtime protocol.

## Considered options

### Let the watcher call scratch publication directly

This would make unverified event paths look authoritative, bypass debounce, and
couple a platform adapter to canonical state. It is rejected.

### Persist the scheduler queue or a mutable daemon checkpoint ref

The queue describes only advisory runtime work. Persisting it would add a
second recovery source and an authority boundary not needed for exact scans. It
is rejected.

### Use wall-clock timestamps for deadlines

Wall-clock adjustments can move backwards or forwards discontinuously, breaking
the scheduler's monotonic-time contract. It is rejected.

### Use a client-agnostic runner with a Linux runtime edge

The runner accepts normalized requests, injected bootstrap capability, and an
injected nonce source. A Linux adapter owns inotify, the ADR-050 socket loop,
and a POSIX monotonic clock. It is selected.

## Decision outcome

`yeokcham_v2_scratch_daemon` owns only runtime scheduler state. For a due
emission it obtains two distinct nonce values, calls the exact scanner through
the ADR-055 scratch service, and reports either `No_checkpoint` or the exact
published checkpoint. A non-due request does no scan. A late request first
processes the old emission, then becomes the new pending request.

The Linux edge starts the local socket and inotify watcher, schedules an
`Initial_scan` whole-root request on every start, and calls the runner before
each bounded socket wait. It uses `clock_gettime(CLOCK_MONOTONIC)` converted to
milliseconds. It closes and returns an explicit error for watcher loss,
scanner/store failure, nonce failure, divergence, or malformed/corrupt V2
state. A restart obtains a new watcher and schedules another whole-root scan;
it does not rely on in-memory work from the former process.

The Linux watcher excludes the root `.yeokcham` subtree. Repository metadata
remains observable through explicit inspection and verification, but it cannot
produce an automatic scratch scan or publication feedback loop.

## Consequences

- An unchanged exact scan produces no checkpoint and no V2 object publication.
- A crash before a due scan leaves the old causal scratch state valid. A later
  daemon start scans the complete root rather than replaying an advisory path.
- A crash during publication retains ADR-055's snapshot-first safety boundary:
  the prior visible checkpoint remains valid and any new snapshot without a
  ledger event is unreachable.
- The runtime socket capability remains session-local. The Linux edge receives
  an already-authenticated bootstrap repository and never reads Secret Service
  itself.
- macOS needs a separate FSEvents edge and platform validation; this decision
  does not treat Linux inotify behavior as a cross-platform event format.

## Model and invariant impact

```text
Daemon_state = Scheduler_state (runtime only)

due(request) -> exact_scan(root) ->
  Unchanged                         => No_checkpoint
  Changed and one/no scratch head   => Publish_checkpoint
  Divergent/corrupt/watcher failure => explicit error and stop
```

1. Only the exact scan result reaches ADR-055 publication.
2. Every automatic publication supplies two byte-distinct CSPRNG nonces.
3. A start always schedules one whole-root scan before relying on watcher
   observations.
4. Runtime queue, socket, watcher, and clock values are never canonical bytes.
5. `.yeokcham` events cannot schedule automatic work.
6. Failure does not choose a divergent head, repair data, or silently continue
   with incomplete watcher coverage.

## Persistent-format and migration impact

No persistent format changes. The runner only invokes ADR-055's existing typed
snapshot and ledger publication. Scheduler state and socket discovery disappear
with the process. There are no pre-user repositories to migrate and no prior
format reader is added.

## Verification

- Runner unit traces cover due publication, explicit unchanged results,
  late-emission ordering, restart whole-root recovery, and duplicate-nonce
  failure before publication.
- A seeded generated test verifies that arbitrary unchanged advisory requests
  never create a second checkpoint.
- Linux watcher coverage proves `.yeokcham` metadata writes are excluded.
- The Linux runtime test proves monotonic reads and authenticated controlled
  shutdown of the worker loop.
- No golden fixture applies because no canonical persistent bytes are added.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

`yeokchamd` opens the Linux Secret Service capability, then starts this worker
with explicit positive quiet-period and maximum-latency milliseconds. Its
runtime socket protocol remains liveness/shutdown-only. No V1 command behavior
changes.

## Sources

The [Linux clock_gettime manual](https://man7.org/linux/man-pages/man3/clock_gettime.3.html)
documents that `CLOCK_MONOTONIC` does not move backwards across discontinuous
system-time changes. The [inotify manual](https://man7.org/linux/man-pages/man7/inotify.7.html)
documents event loss/overflow as incomplete observation, supporting the
whole-root restart rule.
