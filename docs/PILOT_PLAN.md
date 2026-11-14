# First usable Yeokcham: core workflow pilot

Updated November 14, 2026.

## Priority and status

The user wants the complete everyday workflow of using a VCS, with a small
set of essential operations and optional capabilities around it. Local recovery
is one part of that workflow. The broader direction in
[Product design](PRODUCT_DESIGN.md) remains in place.

P0 evaluation and P1 core foundation are complete. The
[P1 report](implementation/reports/P01-attempt-01.md) records implementation
`06b662a8bab5c783117e5fcf45e36b7d942cfc64`, actual checks and
[interfaces](implementation/INTERFACES.md). P2 local work is in progress;
P3/P4 are pending. G01 remains complete; G02 has partial P1 coverage and is not
complete. G01-G20 remain the full-design backlog.
This pilot changes delivery order and the first milestone; it does not mark
original criteria complete or relax privacy, authority, fidelity or recovery.

The first native pilot OS and representative real project remain to be selected.
The automated evaluation used WSL2, which is not a supported native product
platform. P1 subsequently passed module/CI checks on native Arch Linux, but no
complete native-host pilot or human-usability gate has passed.

## Essential operations

The assessment column below records P0's observed V1 behavior on its WSL host.
P1 adds pure library interfaces; it does not implement these missing CLI journeys.

These are user intentions; names may evolve toward [CLI design](CLI_DESIGN.md).
Git terms provide orientation, without adding a Git interoperability commitment.
Automatic checkpoints, explicit sharing and accepted versions remain distinct.

| User need | Minimum first-product behavior | Current assessment |
| --- | --- | --- |
| Start or obtain a project: init/clone | Start privately offline; obtain a verified selected shared version in a usable working directory, with actionable identity/trust setup. | Init works with the disposable signer. Native onboarding failed on this host. No ordinary clone; received packages cannot activate a workspace. A separate relay/bootstrap path exists. |
| Understand work: status/diff | Changed paths, readable text differences, opaque-file changes, saved/shared/accepted state and next actions. | Status and changes run. Changes show paths/modes/content IDs; generic version diff is absent. Status JSON is only a completion envelope. |
| Record and inspect history | Durable capture, named explicit sharing, readable history and tool-generated stable IDs. | Save/timeline/log/graph/undo-tree exist. No-op saves and alternate continuations were verified. Share requires supplied change/revision IDs. |
| Work on alternatives: branch/switch | Named shared branches and selection, preserving private work or explaining a conflict before replacement. | Local undo continuations work. Draft creation does not switch files; branch/switch commands are absent. |
| Recover work | Preview undo/redo/restore, preserve unsaved disk edits, separate-copy restoration and retained alternatives. | Verified on the tiny mixed fixture, including executable distinction, symlinks and an empty directory. Ignored live paths cause safe in-place refusal. |
| Exchange work: push/fetch | One documented native-remote path for explicit publication and verified receipt/retry. Receipt does not apply files or accept work. | Offline package receipt and history inspection worked without file changes. HTTPS/relay/bootstrap was not exercised here. |
| Accept shared work: integration | Preview an exact result, confirm explicitly, preserve later private edits and record accepted result/parents. | Integrate is absent. Existing delivery records do not establish the stronger composition guarantee required by TC01/TC02. |
| Handle conflicts | Identify files/versions; inspect, choose a version or supply combined contents, defer and finish recoverably. | Advanced decision show/inspect/diff work on a received stale-base decision. The complete two-person integration/resolution loop is incomplete. |
| Continue offline and after interruption | Use verified local data, report missing data, retain competing heads and resume without duplicate acceptance or lost work. | Fresh-process local history worked. Full collaborative offline/retry/interruption journeys need implementation and fault evidence. |
| Use it routinely | A small understandable command surface, documented native installation, truthful capture state and acceptable pilot latency. | Foreground watch captured an edit. Default help exposes the large advanced surface. Native installation, representative latency and participant comprehension remain open. |

Keep the existing filesystem scope: bytes, empty directories, symlink targets
and regular/executable distinction. No new promise covers arbitrary permissions,
ownership, timestamps, ACLs or unsaved editor buffers.

## Evidence from the evaluation

Assessed revision: f3bd17705591413078e1504d46d8240eb6c47f2e.

- make build exited 0.
- Executed 60 CLI invocations plus one bounded foreground watcher.
- Passed 17 explicit walkthrough checks on five regular text/binary files,
  one symlink and one empty directory.
- Exercised A-B-C, return to B, then D; selected both continuations across fresh
  CLI processes, recovered unsaved E and restored exact C into a separate folder.
- Verified preview, ambiguous redo and ignored-path refusal preserve the relevant
  files/history. These checks do not substitute for crash fault tests.
- Used separate disposable Alice/Bob signing directories, enrolled Bob, explicitly
  shared work, exported a package, joined, received and inspected its revision
  and stale-base decision.
- Both Bob workspace activation/update attempts refused with "workspace has no
  verified imported projection basis"; his worktree stayed empty. This establishes
  a limitation of the package path, not failure of the separate relay/bootstrap path.
- Clone, branch list, switch, integrate, history, generic diff and conflicts entry
  points returned usage errors. Existing older inspection/recovery and advanced
  decision commands remain available.
- Native init returned "Linux Secret Service is unavailable or rejected the
  request". Subsequent mutations used the explicit test-only signer; that is not
  an installation workaround for pilot users.

The [compact receipt](implementation/results/PILOT-workflow-assessment.json)
contains the revision, executable hash, argument templates, exits, checks, single
timings and external artifact hashes. Redacted full outputs and the driver remain
at /home/gongahkia/.cache/yeokcham-pilot-20261114-jef0er2n. Recovery mnemonics
were omitted from captured output; disposable custody files stay outside Git.

This is diagnostic evidence from a tiny fixture. It does not establish
representative performance, native support, private backup or product completion.
Accepted G01 measurements were preserved and were not repeated.

Read the receipt and its hashed external assessment.json to reuse the findings.
After relevant runtime changes, copy external evaluate.py to a fresh external
directory and run that copy with python3 -B; it creates its fixture beside itself
and refuses existing directories. The driver runs the first 57 invocations.
The final three decision probes are listed separately in the receipt. Preserve
the current evidence instead of overwriting it.

## Capabilities that can follow

- PR-style review requests/comments/approval policy administration. Unsupported
  required policies must fail explicitly, never be silently bypassed.
- Private account backup, all-device-loss recovery, automatic archival/eviction
  and account-wide settings. The pilot must not claim private backup.
- Managed per-user scheduling and service installation across all operating
  systems. An explicitly running foreground watcher can support the pilot;
  capture must not be described as automatic when the watcher is stopped.
- Advanced pack/compression tuning and automatic maintenance, unless a measured
  pilot blocker calls for a bounded storage change. Storage integrity and
  protection of recovery roots always remain required.
- Additional native platforms after the first selected pilot host.
- Extended source/monorepo/asset comparisons and broad performance claims.
  Focused correctness and representative usability checks remain necessary.
- Git carryover, GUI, semantic/AI assistance and managed hosting.

Basic member authentication, protected key custody, exact selected sharing,
deterministic integration, conflict preservation, safe writes and useful errors
are essential, alongside the ordinary commands.

## Implementation sequence

Each slice must connect actual CLI behavior to domain implementation, include
meaningful tests/docs and stay buildable. Freeze the shared registry and APIs
before assigning concurrent consumers. Estimates are low-confidence focused
development ranges including tests/integration; host/participant waits add time.

| Slice | Deliverable | Existing work to use | State / rough effort |
| --- | --- | --- | --- |
| P0: evaluate | This walkthrough, evidence and essential-operation inventory. | Current V1, G01 and existing designs/guides. | complete |
| P1: core foundation | Canonical revision/accepted-version/branch records, workspace/history identities, bounded signed decoding, duplicate/collision handling and actual state/plan/error interfaces; golden/negative cases. | Relevant G02 contracts and encoding/envelope/record/model/trust modules. | complete; [report](implementation/reports/P01-attempt-01.md) |
| P2: local work | Readable status/history/diff, native file/directory exclusions, tool-generated IDs/names, branch selection/private-work preservation and exact recovery. Reuse working capture/undo; profile before replacing storage. | Core parts of G03/G05/G06/G14; snapshot, undo, store, workspace and CLI. | in_progress; original rough estimate 3-5 days |
| P3: shared loop | One native clone/materialization path, explicit selected sharing, verified exchange/retry, composition, preview/confirmation, journaled integration, conflict actions and accepted-history publication. Wire CLI alongside services. | Basic authority/heads G03, composition G04, transfer G08, integration G13 and CLI G14. | pending; 5-10 days |
| P4: harden/handoff | Two-person/source/document/binary journeys, branches/offline cases, fault/retry/private-work tests, native onboarding, pilot responsiveness, concise instructions and actual user feedback; fix blockers. | Focused G18/G20 checks and affected domain tests. | pending; 3-7 days |

P2/P3 share P1 and have real domain dependencies. Branch switching consumes
verified materialization/recovery; P3 uses durable writes from its first
implementation. P4 adds adversarial verification, rather than postponing safety.

The complete core-workflow pilot is provisionally **3-6 weeks**, to be
re-estimated after P1 and the first shared loop. The earlier 1-3 week local-only
range does not cover the clarified complete VCS workflow. Parallel workers can
help independently owned modules after interfaces freeze; worker count is not
a schedule multiplier.

Original G02 also covers review/account/archive record families beyond P1.
Implementing part of its scope does not complete G02. Track the exact remaining
criteria against the original phases. The pilot can wire basic collaboration
before unrelated archive/account/review capabilities while preserving genuine
schema, authority, storage and journal dependencies.

## Definition of a usable pilot

All these must work through ordinary supported commands on the selected native
host, with real native custody and a documented remote setup:

1. Initialize mixed text/binary work, understand status/diff, record and inspect
   history, and recover earlier alternatives with unsaved disk edits preserved.
2. Alice shares selected work without unrelated private content or undo ancestry.
   Bob obtains a usable verified worktree, edits/publishes, and Alice receives
   without an unsolicited working-tree change.
3. Preview and integrate exact shared work. Accepted contents exclude later
   private edits while those edits remain safe. No further delivery ceremony.
4. Create/select named branches, preserve private work or explain conflicts,
   work offline with verified downloaded versions, and refuse unavailable
   versions before changing files.
5. Handle concurrent text and opaque-file conflicts with preserved candidates:
   defer, select a version or supply combined contents, then integrate explicitly.
6. Resume interrupted application and lost-response/repeated transfers without
   duplicate acceptance. Preserve concurrent offline heads in either receipt
   order. Tests cover actual mutation and commit boundaries.
7. Complete fresh native setup and an observed participant journey. Record
   actual timing/confusion on a representative project and set explicit
   responsiveness budgets for that host/workload before closing the gate.
   The tiny automated walkthrough cannot satisfy native or human evidence.

The native OS/project choice remains an open input. Required privacy/recovery
guarantees do not depend on that choice.

## P0 assessment verification (historical)

The current checkout built successfully. Documentation link checking passed
with 186 local references, and the compact receipt was independently compared
against all 60 raw command records, 17 checks and external artifact hashes.
The current executable and retained G01 result/acceptance hashes match their
recorded values. Only documentation/evidence changed; no product source or
format was modified and no benchmark was rerun. Full runtime CI was not rerun
for these documentation-only changes.

## Next handoff

P1 is complete under the [scoped task](implementation/goals/P01-core-workflow-foundation.md).
Verify its [report](implementation/reports/P01-attempt-01.md),
[acceptance receipt](implementation/results/P01-acceptance.json) and actual
interfaces before starting P2 local work. Preserve the original G02 remainder.
P2 was separately invoked through the [scoped local-workflow task](implementation/goals/P02-local-workflow.md); P3/P4 remain unstarted.
The user requires one writer on main for this handoff. Future orchestration
preferences must be reconciled separately before changing that workflow.

Maintain [Implementation progress](IMPLEMENTATION_PROGRESS.md), original-phase
coverage, evidence and coherent commits. Full-design native/resource/backup
gates stay open. This assessment does not claim a release or authorize deployment.
