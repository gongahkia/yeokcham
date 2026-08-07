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
- [Git interchange](GIT_INTERCHANGE.md) records the intentionally narrow Git
  import/export contract.
- [Local synchronisation](LOCAL_SYNCHRONISATION.md) documents the local object
  exchange and offline-bundle boundary.
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
