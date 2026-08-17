# Yeokcham documentation

This directory contains the operational, demonstration, research, and decision
records for the Yeokcham prototype. The root [README](../README.md) is the
short project entry point; this page maps readers to the detailed material.

## Start with the model

1. [Project context](../PROJECT_CONTEXT.md) explains the problem, thesis, and
   intended user.
2. [PRD](../PRD.md) states the product requirements and delivery boundaries.
3. [Formal model](../FORMAL_MODEL.md) defines the model and invariants.
4. [Architecture](../ARCHITECTURE.md) describes storage, transitions, and
   adapters.
5. [Decisions](../DECISIONS.md) indexes the accepted architecture decisions;
   file-backed records live in [adr](adr/README.md).

## Use and inspect the prototype

- [CLI reference](CLI.md) describes the local command groups and their safety
  boundaries.
- [Architecture walkthrough](ARCHITECTURE_WALKTHROUGH.md) maps the implemented
  model to modules, operational boundaries, and verification.
- [Git interchange](GIT_INTERCHANGE.md) records the implemented narrow bridge
  and its preservation/adoption/exit contract.
- [Peer exchange](PEER_EXCHANGE.md) records the implemented direct publication,
  transfer, and explicit-integration boundary.
- [SSH peer-sync v1](SSH_PEER_SYNC_V1.md) records the experimental pinned SSH
  transport, noncanonical capability placement, and verification boundary.
- [Relay peer-sync v1](RELAY_PEER_SYNC_V1.md) records the signed filesystem
  mailbox, untrusted discovery, and staging-before-import boundary.
- [Peer sync daemon v1](PEER_SYNC_DAEMON_V1.md) records the Unix runtime
  scheduler, private control status, and bounded retry boundary.
- [1.0 stability contract and release gate](STABILITY_1_0.md) distinguishes the
  proposed compatibility/release promises from the evidence still required to
  make them.
- [Field-trial evidence v1](FIELD_TRIAL_V1.md) defines reproducible host
  evidence without treating CI as a platform trial.
- [Release signing v1](RELEASE_SIGNING_V1.md) defines the external-key and
  signed-tag verification boundary without claiming a released key.
- [opam source release v1](OPAM_RELEASE_V1.md) records the source-package
  preflight and upstream-review boundary without claiming publication.
- [Local synchronisation](LOCAL_SYNCHRONISATION.md) documents the local object
  exchange substrate and its historical V3 predecessor.
- [ADR-073](adr/073-unix-first-vcs-git-migration-and-peer-exchange.md) records
  the active Unix-first VCS direction and retired V2 scope.
- [Validation retention](VALIDATION_RETENTION.md),
  [compaction budget](COMPACTION_BUDGET.md), and
  [compaction inverses](COMPACTION_INVERSES.md) specify retention and compaction
  behaviour.

## Follow demonstrated workflows

The demos exercise representative paths without extending the product contract:
[repository setup](DEMO_REPOSITORY.md), [recovery](DEMO_RECOVERY.md),
[compaction](DEMO_COMPACTION.md), [capsules](DEMO_CAPSULE.md),
[workspaces](DEMO_WORKSPACE.md), [conflicts](DEMO_CONFLICT.md),
[release](DEMO_RELEASE.md), and [Git export](DEMO_GIT_EXPORT.md).

Each stateful demonstration requires its own freshly created fixture root. Do
not chain the demonstration scripts against one root: later demonstrations
make assumptions about the setup fixture's scratch and workspace state. In
particular, the release demonstration creates its own workspace composition;
after the capsule demonstration advances scratch history, materialisation is
expected to report a partial result rather than silently applying a mismatched
composition.

## Read research and evidence carefully

- [Research and benchmark report](RESEARCH_AND_BENCHMARK_REPORT.md) is the
  evidence index, including negative outcomes and scope limits.
- [Compaction retention benchmark](COMPACTION_RETENTION_BENCHMARK.md) and
  [results](COMPACTION_RETENTION_RESULTS.md) publish host-specific measurements
  without a general performance claim.
- [Comparative workflow analysis](COMPARATIVE_WORKFLOW_ANALYSIS.md) separates
  source-backed comparison from inference.
- [Experiments](experiments) contain the versioned semantic and retention
  experiment methods, schemas, and results.

## Track work and contribute

- [Issue tracking](ISSUE_TRACKING.md) explains the historical migration record
  and points to the live GitHub backlog.
- [Contributing](../CONTRIBUTING.md) and the [agent guide](../AGENTS.md) define
  the repository’s implementation, verification, and issue-linking rules.
