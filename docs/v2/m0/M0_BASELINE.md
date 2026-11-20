# M0 reference baseline

Version: `m0-reference-1`. Recorded 2026-11-20, Singapore.
Status: reference preparation only; no production capability certified.

## Authorization and interpretation

The owner's M0 instruction provisionally approves directions A–E **as M0 planning
assumptions**: qualified private automatic capture; Model A and selective acceptance
with path-local material frontiers; SQLite plus immutable objects, initially
DELETE/EXTRA; retained verified content representations with new public controls;
one workspace-based API without persisted lanes; and isolated side-by-side Python
development retaining review, backup, security, recovery and platform obligations.
It does not approve every D1–D4 field, implement these directions, authorize M1a,
or amend any existing V1/Core contract or implementation ledger.

The current instruction replaces D4's proposed `python/reference/` output layout
with exactly four documents in this directory:

- [Baseline](M0_BASELINE.md): provenance, capability classification and departures.
- [Semantic reference](M0_SEMANTIC_REFERENCE.md): exact independently reasoned cases.
- [Vector inventory](M0_VECTOR_INVENTORY.md): existing identities and missing corpus.
- [Safety and tranche gates](M0_SAFETY_AND_TRANCHE_GATES.md): fault tests and handoff.

Precedence for this reference: this M0 authorization; D4's explicit corrections
and restrictions; unaffected D1/D2 proposals; then D3's retained specifications
and open gates. Existing V1/Core contracts still describe their existing formats
and requirements. This ordering is not an assertion that incompatible drafts
already agree. In particular, do not implement D2 section 6.3's global-base rule,
D3's arbitrary proof fields, or D2/D3's empty-destination takeover proposal.
See [D4 section 14](../D4_BLOCKER_RESOLUTION.md#14-exact-amendments-required-in-d1d2d3).

All five design files were read in full, including D4's working-tree additions.
The other contracts, P1–P3 reports/receipts, source/C adapters, tests and generators
listed here and in the companion inventories were inspected. Test existence is
not a fresh pass. No live Yeokcham data was opened or migrated.

## Starting repository and environment

At 2026-11-20 08:17:22 UTC:

```text
HEAD 793bdd036e8f448f876c808376d336e4763601d1
git status --short --branch --untracked-files=all
## main...origin/main
 M docs/v2/D4_BLOCKER_RESOLUTION.md
```

All four target paths were absent. The D4 content SHA-256 is
`d087a235653548584b4e95078af99e72f6cc29a442591b360a16831b307c5f68`;
using `git show HEAD:docs/v2/D4_BLOCKER_RESOLUTION.md` would omit its latest
qualifications. That starting modification is user-owned and must remain exact.
`origin/main` is a local tracking observation; no fetch was performed.

A preservation manifest covers **518** pre-existing tracked/nonignored untracked
files, recording SHA-256 plus native mode, or symlink target. External scratch:
`/var/folders/55/fw1sdntj20v8650vsmkn7s8c0000gn/T/yeokcham-m0-5llmhc2d/`.
`before.json` and `initial.json` hold that initial evidence; absence of this
temporary directory on a later host is not permission to invent its contents.
Ignored build/cache directories were not recursively inventoried or modified by
M0 commands. The reproducible source/vector registers below are the portable
baseline; final preservation and concurrent Git observations are recorded at end.

| Item | Current observation | Requirement / limit |
| --- | --- | --- |
| Host | macOS 26.5.2, arm64 | Host identity, not native filesystem qualification |
| PATH Python | CPython 3.15.0, Clang 21.0.0 | Proposed floor 3.13 and qualification 3.13/3.14 remain unqualified here |
| Linked sqlite3 | SQLite 3.54.1; THREADSAFE=1; backup module available | Exact VFS/build allowlist and fault tests OPEN; a recent version is not an allowlist |
| PATH tools | opam 2.6.1; Dune 3.24.2; ocamlc 5.5.1; Git 2.56.0 | Version commands only; no build or switch setup |
| Formatter | `ocamlformat` absent from PATH | No `opam exec` formatter/toolchain qualification attempted |
| Declared build | OCaml **5.5.0**, Dune >=3.23; formatter 0.29.0 in Makefile | PATH compiler differs from pinned compiler; dependency installation prohibited |
| Crypto comparison | OpenSSL 4.1.0, library 4.1.0 | Used only for copied old public-seed vectors, not production custody qualification |
| Python dependencies | No product manifest/provider lock exists in this tranche | cbor2, PyNaCl/libsodium, zstandard/native binding remain candidates, not selected builds |

Read [dune-project](../../../dune-project), [opam manifest](../../../yeokcham.opam),
[lock](../../../yeokcham.opam.locked), [Makefile](../../../Makefile) and relevant
scripts before choosing commands. Existing commands are `make build`, `make test`,
`make lint`, `make docs-check`, and `make ci`. The first three use `opam exec --
dune`; CI additionally runs workflow checks. `make setup`, `deps`, `format`,
build/test/CI and scripts running real repositories were **not** invoked here.
M0 documentation checks use `python3 -B tools/check_doc_links.py` directly.

## Evidence vocabulary and capability inventory

Classification applies to each claim, not to an entire component. Evidence
describes the inspected source/reports; it does not imply a fresh runtime pass.

| Capability / obligation | Classification | Source/evidence and practical limit |
| --- | --- | --- |
| Manual stable capture, native ignores and supported fidelity | Existing and source/test-backed | [snapshot](../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml), [capture tests](../../../test/test_capture_consistency.ml), [ignore tests](../../../test/test_native_ignore.ml). No M0 filesystem execution |
| Branching private positions, equal snapshots at distinct positions, monotonic namespace | Existing and source/test-backed | [undo](../../../lib/yeokcham_v1_undo/yeokcham_v1_undo.ml), [history tests](../../../test/test_history_identity.ml). Durable owner currently root-CAS, not SQLite |
| Selected live-source sharing and private witnesses | Existing and source/test-backed | [Native_share.prepare](../../../lib/yeokcham_v1_local_service/native_share.ml), [Publication_receipt.proof](../../../lib/yeokcham_v1_store/publication_receipt.ml). Current same-change all-head gate remains in OCaml |
| Verified public receipt without file/cursor movement | Existing and source/test-backed | [native receipt](../../../lib/yeokcham_v1_local_service/native_receipt.ml), [package tests](../../../test/test_core_package.ml), [local-state tests](../../../test/test_local_core.ml) |
| Exact accepted/private D/E outputs and recoverable integration | Existing and source/test-backed | [integration](../../../lib/yeokcham_v1_integration/yeokcham_v1_integration.ml), [preservation](../../../lib/yeokcham_v1_integration/preservation.ml), [native integration](../../../lib/yeokcham_v1_local_service/native_integration.ml), [CLI tests](../../../test/test_native_integration_cli.py) |
| Native HTTPS clone/exchange, scoped resolutions and frozen outbound retry | Historically tested but not freshly verified | P03 report/receipt; enrolled disposable test capabilities, Linux/TLS evidence; no onboarding/parity inference |
| P1/P2/P3 acceptance and passing CI at their exact tested revisions | Historically tested but not freshly verified | Report table below; later failing CI is separate evidence |
| Everyday VCS, automatic private preservation, explicit publication/acceptance, optional/required review, private archive and Windows close second | Existing committed product requirement | [D01–D30](../../PRODUCT_DESIGN.md), [TC01–TC08](../../TECHNICAL_CONTRACTS.md), [pilot](../../PILOT_PLAN.md). Requirement is not delivery |
| Model A independent exact continuation and selective acceptance | Proposed V2 behavior; intentionally changed behavior | D4 sections 3–7, semantic cases here. Existing `selection_root` and `Native_share.prepare` require reconciliation/all heads |
| Path-local normalization, context-only rejected variants, dependency-scoped freshness | Proposed V2 behavior | D4 section 5; small symbolic evidence only. Aggregate budgets/structural qualification OPEN |
| Exact older-source publication without latest substitution | Intentionally changed behavior | D2 section 11.1; current ordinary native share observes current disk. Exclusions/authority still revalidate |
| SQLite private authority and independent workspace writers | Intentionally changed behavior | Replaces nested V1/Core state/root publication. Preserve atomicity/preservation obligations; no SQLite product store exists |
| Absent-only copy-out/new materialization | Intentionally changed behavior | D4 sections 8–9. Existing empty destinations now refuse in proposed Python scope; no OCaml change |
| Managed automatic capture/readiness, complete private backup, full review/principal/adoption | Currently unsupported in complete target-product form | Watch hints/foreground capture and project recovery packages do not deliver these requirements; required unsupported modes refuse |
| Native Windows no-reparse/preservation executor | Currently unsupported | Current C Windows branches fail explicitly; no replacing fallback |
| Current full CI health, old copy-out root cause | Unknown or unqualified | Later retained CI exits 2; mismatch remains unexplained and was not rerun |
| Python runtime preservation, public-control interoperability, power-loss guarantees, performance advantage | Unknown or unqualified | No production implementation, native binding, crash qualification or fair benchmark here |

## Historical acceptance and unresolved evidence

| Evidence | Bound source / recorded result | Retained limitation |
| --- | --- | --- |
| [P01 report](../../implementation/reports/P01-attempt-01.md), [receipt](../../implementation/results/P01-acceptance.json) | Implementation `06b662a8bab5c783117e5fcf45e36b7d942cfc64`; native Arch Linux/OCaml 5.5.0/Dune 3.25.0. CI exit 0, 50 scheduled OCaml suites/307 cases and 12 Python harness tests | P1 codec/model/trust slice, not complete G02 or native onboarding |
| [P02 report](../../implementation/reports/P02-attempt-01.md), [receipt](../../implementation/results/P02-acceptance.json) | Tested `6826af74810bb4087bb4795781d0176276df2b9e`; runtime `e181ff9ec863740ceb511fb888b23472056ebd15`. Focused 197 OCaml/46 Python cases; final CI exit 0 with matching cached results | Linux process-fault/local slice; no macOS/Windows, native onboarding or full performance claim |
| [P03 report](../../implementation/reports/P03-attempt-01.md), [receipt](../../implementation/results/P03-acceptance.json) | Implementation `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`, tree `3106092977d0d75b0602de61968e2245d4d59f03`; final CI exit 0, freshly reported 25 OCaml/353 cases and 81 Python cases | Counts overlap focused checks; other Dune results cached. Test signers, no full native/human qualification |
| [Later CLI receipt](../../implementation/results/cli-graph-20261116.json), ledger follow-up | Implementation `8a0c768fefc3bdb9b62d92250de4b6e180bd3f16`; full serial CI exit 2. Tiny linear/branching copy-out errors also reproduced on start `fba3daa945eb2c670595ab660576be30b8b3d380` | Introduction and cause unknown. Direct TMPDIR contrasts passed historically; no diagnosis follows |
| [G01 report](../../implementation/reports/G01-attempt-07.md), [baseline](../../implementation/results/G01-baseline.md), [lossless summary](../../implementation/results/G01-baseline.json) | Accepted 280 measured records and 24 excluded warmups, as recorded | Preserved by hashes only; not rerun, recreated or reinterpreted as Python evidence |
| [D3 feasibility](../D3_CONTRACT_FREEZE.md#12-d3-verification-record) | 23 SQL checks plus three strengthened negatives | Historical SQL-shape/transaction evidence; not current crash/GC/native qualification |
| [D4 symbolic evidence](../D4_BLOCKER_RESOLUTION.md#7-falsification-results-limits-and-retained-counterexamples) | 26 focused checks, 17 extras, six receipt orders, 1,800 permutation comparisons, 12 namespace abstraction checks | Historical to M0, not rerun or formal proof; scratch is not a production oracle or portable normative artifact |

**BASELINE-COPYOUT-20261116: OPEN, unresolved, root cause unknown.** Exact test:
`test/test_benchmark_runner.py::RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs`.
Both `asset-8192-8` shapes, `--attributes --history-nodes 5 --cold 1 --warmups 1
--warm 2`, reported `installed target bytes changed at "restored" after application`;
child restore exited 8. This is historical observed failure, not a new M0 failure
or a proven regression introduced by the later CLI work. Source error site
`Safe_apply.entry_bytes_match`/`apply_with` does not establish the cause.
The safety companion specifies evidence preservation, M2 discrimination and the
difference between resolving OCaml and isolating a qualified Python path.

## Retained invariants and intentional departures

| Contract | Retain | Proposed departure / gate |
| --- | --- | --- |
| TC01 identity, publication and offline histories | Snapshot/capture/record distinct; exact publication; preserve private ancestry and accepted divergence | Model A single evolution predecessor plus independently evaluated content basis |
| TC02 exact acceptance | Two outputs, default confirmation, scope, current authority/review, relevant staleness, recoverable application | Select exact candidates without all-sibling inclusion; new normalization profile, not old-control reinterpretation |
| TC03 private account/archive | Separate audiences/keys; complete encrypted coverage before eviction; fresh-device recovery | SQLite metadata belongs in complete future backup; public relay and current recovery package are not private-history backup |
| TC04 service | Real readiness; hints plus reconciliation; bounded workers; truthful incomplete/paused states | Per-workspace locks/pending owners and short shared SQL commits replace long repository writer scope |
| TC05 storage | Exact canonical identities/chunker, streamed large assets, reader/GC protection, no sole-copy eviction | SQL instead of authoritative page/root-CAS; raw loose objects first; compression/packs deferred, not retired |
| TC06 canonical/control/merge/application | Unchanged content envelopes, byte leaf profile, no guessed authority or resolution; phases retained | New codes/domains/control schema; path-frontiers normalization above unchanged leaf. Old plans/local wrappers are not SQL schemas |
| TC07 filesystem/ignore | Exact bytes/raw names/exec/empty dirs/symlink targets, native ignores, no `.gitignore`; obstructions refuse | Both old/new metadata excluded; reserved-name collision refuses exact output. Initially absent-only destination; existing-tree attachment OPEN |
| TC08 and roadmap | Evidence before consumer, reports/negative tests/platform/rollback | M-sequence is a staged implementation proposal, not completion of original G phases |

P0–P3 are complete only in their recorded scopes. P4 remains unstarted; G01 is
the sole complete original phase. G02 is partial and G03–G20 retain their ledger
criteria. M0 starts/closes none of those phases. No ledger, RFC, README or old
vector is edited. Directory isolation is not a security sandbox against arbitrary
same-user code. Offline success reports locally verified context, not global freshness.

## Fresh M0 verification and limitations

Inspected each generator's executable control flow first. The following comparisons
passed on the recorded host, with `-B` to suppress bytecode writes:

| Check | Actual M0 result |
| --- | --- |
| `python3 -B tools/generate_composition_vectors.py` | Exit 0; 4 scope/page envelope/object-ID files |
| `python3 -B tools/generate_core_package_vectors.py` | Exit 0; 7 old manifest/hash/courier/clone files |
| `python3 -B tools/generate_integration_vectors.py` | Exit 0; 4 old private-plan files; helper import also inspected |
| `python3 -B tools/generate_local_vectors.py` | Exit 0; 2 old copy-out/selection journal files |
| Core generator copied with its 17 goldens to external scratch | Exit 0; regenerated files byte-identical to all 17 existing files. Never run the writer in the checkout |
| Source/report/vector SHA-256 inventories | Recorded below and in vector inventory; expected golden contents remain unchanged |

These compare **34** existing golden files. They do not execute OCaml consumers,
qualify a new Python decoder, or establish a complete retained-content corpus.
No new V2 signing payload, hash or schema was generated. D4 symbolic checks and
D3 SQL checks remain historical evidence. Full CI, builds, native tests, G01,
service/agent experiments, dependency/provider qualification and power-loss tests
were deliberately not run. One exploratory `rg` used two nonexistent guessed
test paths and returned 2; subsequent inventory uses actual discovered files,
and no evidence is attributed to those missing paths.

## Portable source and report identities

SHA-256 here hashes each existing file's **literal bytes**, not a semantic record
or decoded golden object. These identities bind the inspected working contents.
Recompute with `hashlib.sha256(Path(path).read_bytes()).hexdigest()`; do not infer
the latest D4 contents from HEAD. The vector companion separately inventories
golden-family manifests and expected protocol IDs.

<!-- M0_SOURCE_IDENTITIES -->

## Closeout and next scope

Closeout observations will be filled after the four artifacts pass verification.
No implementation or migration is part of M0. The safety companion gives the
M1a readiness finding and proposed separately authorized Prompt 06 scope.
