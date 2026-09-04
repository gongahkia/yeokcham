# Experiment 104 — EVIDENCE-001 controlled Linux field exercise

## Scope and admission criteria

Run this only with two to ten consenting participants on isolated Linux test
machines and disposable V4 repositories/relay volumes. Record the exact source
commit, client binary digest, Linux distribution/kernel, container runtime,
network topology, participant count, and role assignments. Do not use
production repositories, real work, long-lived credentials, personal key
material, payload bytes, or names in the observation record.

The facilitator assigns one relay operator, one repository administrator, and
at least one collaborator. A participant may hold more than one role only when
the total is two; record that overlap. Stop the exercise if an unexpected
ordinary-source write occurs on a receipt path, a credential appears in output
or logs, an authority action cannot be understood, or a disposable environment
cannot be restored safely. Preserve diagnostic metadata and the failed step,
but do not overwrite the original volume or infer a resolution.

## Controlled journey

1. The administrator creates a disposable source repository and scoped relay
   access; the collaborator bootstraps into a fresh empty directory. Before
   activation, record that bootstrap created only `.yeokcham` metadata and did
   not create ordinary source paths.
2. The collaborator explicitly runs `workspace activate`; compare the exact
   projection with the administrator's saved checkpoint. Ask whether the
   distinction between receipt and materialisation was clear from the command
   output.
3. Two collaborators make intentionally overlapping changes, save, exchange
   work, inspect the conflict/decision state, and create an explicit signed
   resolution. No participant may accept an automatically chosen result.
4. Interrupt one explicit `sync` by stopping the disposable relay or severing
   its test-network path. Record the reported failure, retry/resume outcome,
   receipt/state outcome, and a before/after hash of ordinary source paths.
5. Introduce a documented disposable metadata/object fault, run `verify`,
   create a repair plan from one explicit test backup, and choose `defer` for
   at least one candidate. If a repair is applied, record the plan and
   candidate IDs and prove the backup/source ordinary files were unchanged.
6. The operator follows the relay backup runbook: quiesce or snapshot, create
   a checksum, reject one corrupted copy, restore a checked copy to a separate
   disposable volume, and perform a read-only receive/bootstrap smoke journey.
7. Rotate one disposable relay credential and revoke another. Confirm that an
   old credential is rejected, the replacement works only for its stated
   repository/scopes, and no secret is retained in the observation record.
8. Simulate operator recovery by restarting the restored relay and repeating a
   scoped fetch plus `verify`. Record any recovery ambiguity or manual action.

## Observation record

Write one redacted row per step in an external plain-text or JSONL file:

```text
exercise_version=1
source_commit=<40-hex>
participant_count=<2..10>
step=<bootstrap|activate|resolution|sync-interrupt|repair|backup|credential|operator-recovery>
result=<pass|fail|stopped|incomplete>
ordinary_source_unchanged=<yes|no|not-applicable>
observation=<redacted usability or defect note>
```

Add elapsed time and host role only when they do not identify a person. Never
record bearer values, private keys, token PINs, raw object/source bytes, full
paths outside the disposable environment, or unredacted command output.

## Interpretation

A completed exercise is usability and operational evidence for this exact
development revision only. It does not establish compatibility, production
support, security certification, hosted-service readiness, or a public release.
If fewer than two participants, a Linux test environment, or an authorized
facilitator is unavailable, record the exercise as `[Unverified]`; do not
substitute simulated participants or CI for this observation.
