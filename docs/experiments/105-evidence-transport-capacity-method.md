# Experiment 105 — EVIDENCE-001 TRANSPORT-002 capacity method

This procedure is for an isolated Linux network namespace pair or two isolated
Linux hosts. It measures the V1 and V2 transport adapters with the same
canonical object closure; it does not treat either protocol as a source-tree
materialisation path.

## Preconditions and profile

Record source commit, client/relay executable digest, CPU, memory, kernel,
filesystem, `tc` version, relay configuration, and a redacted scoped credential
description. The required profile names 5,368,709,120 logical bytes, 100,000
fixture paths, five independent runs, a 100 Mbit/s link, and 100 ms delay. The
ticklist does not state whether that 100 ms is one-way delay or round-trip
time; record the chosen interpretation before the run and do not compare rows
using different interpretations. Preserve the raw per-run rows before deriving
a median and nearest-rank p95.

Place the rate/delay qdisc on receiver ingress, rather than only sender egress,
because the `tc-netem(8)` documentation notes that TCP Small Queues can make
sender-side shaping unrepresentative. Use a deterministic netem seed and record
the exact `tc qdisc` commands, including packet overhead/cell parameters if
used. Netem timer granularity can create bursts, so it is a stated experimental
limitation rather than an exact wire-rate guarantee.

```sh
# Run only in an isolated namespace/host arrangement authorized for network admin.
tc qdisc replace dev RECEIVER_INGRESS root netem \
  delay 100ms rate 100Mbit seed 20260905
tc qdisc show dev RECEIVER_INGRESS
```

## Quota boundary

The current relay intentionally limits one project to at most 512 MiB of
immutable objects and V2 temporary session bytes. A single 5 GiB V4 closure
therefore must first demonstrate the bounded quota refusal; do not raise the
limit, split one V4 repository across unrelated project IDs, or call that a
successful 5 GiB repository transfer. Record the exact attempted byte/object
count, returned refusal, relay object/session counts, local state head, and
ordinary-source before/after hashes.

The existing 64 MiB V2 object limit also requires a closure-level measurement,
not one oversized object. A capacity result is valid only if every transferred
object is an existing canonical envelope with its correct identity; compressed
frames and synthetic payloads are not V4 objects.

## Each run

1. Create the deterministic 100,000-path source fixture and signed V4 source
   only through the authorized source initialization path. Retain its profile
   and V4 object closure outside the source repository.
2. Attempt the exact closure with V1 and record wall/user/system CPU, maximum
   RSS, sent/received bytes, relay allocated bytes, object count, quota result,
   and unchanged ordinary-source hashes.
3. Repeat with V2 using its negotiated capability and bounded 1 MiB zstd
   ranges. After one acknowledged segment, interrupt the network path without
   deleting the relay session; resume explicitly and record bytes avoided,
   session identity, final object identity, and retry/refusal result.
4. Explicitly activate only after the receipt verification path has succeeded;
   prove that the receive/sync/verification portion itself did not materialise
   ordinary source. Compare any activated projection against the source only as
   the separately authorized workspace operation.
5. Retain all five V1 and V2 rows, failure rows, command logs with bearer values
   redacted, and environmental data. Derive median/p95 only after validating
   row completeness.

## Interpretation and current status

This method has not yet run under the stated traffic conditions. It may produce
evidence that the current 512 MiB per-project limit refuses the target; that is
a capacity result supporting a development decision, not permission to weaken
the quota or claim the target was met. The 64 MiB local wire-core result in
[Experiment 099](099-v2-transfer-wire-benchmark.md) is supporting adapter
evidence only and does not satisfy this method.

## References

- [Linux `tc-netem(8)`](https://www.man7.org/linux/man-pages/man8/netem.8.html)
- [ADR-099 V2 compressed resumable relay transfer](../adr/099-v2-compressed-resumable-relay-transfer.md)
