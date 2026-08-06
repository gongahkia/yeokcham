# Paengi architecture walkthrough

## M11-12 scope

This walkthrough describes the implemented local-first prototype. It is a map
of contracts and boundaries, not a second backlog or a production-readiness
claim. The authoritative work queue remains [GitHub issue tracking](ISSUE_TRACKING.md).

Verification host: macOS 26.5.2 arm64, OCaml 5.5.0, Dune 3.24.1, and Git
2.55.0. These versions identify this documentation run; they are not a
compatibility matrix or performance result.

## One model, three histories

```text
working directory --scan--> scratch checkpoint --curate--> capsule revision
       ^                       |                              |
       |                       v                              v
   guarded restore          recovery                      workspace attempt
                                                              |
                                                              v
                                                        immutable release
                                                              |
                                                              v
                                                        local Git export
```

The arrows do not collapse the identities:

| History | Purpose | Implemented boundary |
| --- | --- | --- |
| Scratch | frequent local recovery | `paengi_snapshot`, `paengi_chunking`, `paengi_scratch`, and `paengi_compaction` record exact snapshots, checkpoints, retention, and compacted generations. A checkpoint is not a capsule. |
| Intent | human-curated change selection and composition | `paengi_capsule`/`paengi_capsule_store` and `paengi_workspace`/`paengi_workspace_store` retain immutable revisions, selected physical links, ordered attempts, conflicts, and explicit resolutions. A capsule or workspace is not a release. |
| Release | immutable reproducible final state | `paengi_validation` and `paengi_release` bind evidence to a verified final snapshot. Export creates a mapping to Git; it does not make Git canonical Paengi history. |

The M11 demonstrations exercise the same sequence: [repository](DEMO_REPOSITORY.md),
[recovery](DEMO_RECOVERY.md), [compaction](DEMO_COMPACTION.md),
[capsules](DEMO_CAPSULE.md), [workspace](DEMO_WORKSPACE.md),
[conflicts](DEMO_CONFLICT.md), [release](DEMO_RELEASE.md), and
[Git export](DEMO_GIT_EXPORT.md).

## Storage contract

`paengi_encoding`, `paengi_envelope`, `paengi_id`, `paengi_hash`, and
`paengi_store` form the persistent boundary. Canonical, versioned Envelope-1
objects receive typed content identities. A visible ref names exact logical and
physical objects only after validation; writers do not mutate an immutable
object in place. Rebuildable indexes are not required to recover canonical
history.

This is why a process, parser, or storage failure is not converted into an
invented checkpoint, capsule, workspace, release, or mapping. Unsupported
mandatory features, malformed canonical bytes, wrong object types, collisions,
and bounded-resource violations return structured errors before the relevant
visibility point. The format and publication detail lives in
[ARCHITECTURE.md](../ARCHITECTURE.md) and the ADRs it links.

## Functional core and effect boundaries

```text
pure transition and validation
  snapshot / scratch / capsule / workspace / release
                  |
                  v
typed persistence and guarded adapters
  store / filesystem / validation process / Git / local exchange
```

The pure cores derive snapshots, replay operations, order selections, create
conflict values, and verify release inputs. The adapters perform scanning,
object/ref publication, guarded materialisation, direct-argv validation, Git
plumbing, and local exchange. Tests exercise generated transitions separately
from persistent and failure-injection adapters.

Two deliberate limits matter:

- Guarded restore/materialisation protects divergent working bytes with a
  safety checkpoint and reports a possible partial filesystem application; it
  is not crash-atomic.
- Scratch-head and workspace-attempt ref publication are separate visibility
  points. Recovery re-resolves immutable inputs and retries exact work rather
  than hiding a partial boundary.

## Optional analysis and external protocols

`paengi_textual_patch` remains the byte-only fallback. The TypeScript and Rust
sidecars (`paengi_semantic*`, `paengi_typescript_adapter`, and
`paengi_rust_adapter`) receive verified snapshot bytes and return bounded
evidence, ambiguity, or unavailable/incomplete results. They do not persist
semantic facts, read a live source tree, or authorise ambiguous rewrites.

`paengi_git` is an explicit import/export adapter: it invokes local Git through
bounded direct argv and preserves only the documented interchange subset.
`paengi_exchange*`, `paengi_ref_event*`, `paengi_device*`,
`paengi_divergence*`, `paengi_bundle*`, and `paengi_http_exchange` exchange or
inspect immutable objects. They do not choose a divergent ref head, reconcile
it, or establish identity/trust policy. [Git interchange](GIT_INTERCHANGE.md)
and [the comparative report](COMPARATIVE_WORKFLOW_ANALYSIS.md) describe the
external boundary without claiming equivalence.

## How to read the roadmap

The core prototype and its demonstrations are complete enough to inspect the
boundaries above. Deferred retention/compaction policy work, benchmark/report
work, and any future naming or collaboration decisions remain separate from
those contracts. They must preserve the three-history split and add model,
invariant, persistence, and test evidence before changing canonical behaviour.
See [issue tracking](ISSUE_TRACKING.md) for the current, non-duplicated queue.

## Verification

```text
opam exec -- dune runtest test/test_demo_git_export.exe
opam exec -- dune runtest test/test_architecture_walkthrough.exe
make check
```

`test_demo_git_export` reruns the final scripted fixture. The focused
walkthrough test checks the three-history labels, module map, structured-failure
boundary, and roadmap link. These tests verify the stated architecture map; they
do not establish a performance result, a full Git implementation, semantic
correctness, network security, or production readiness.
