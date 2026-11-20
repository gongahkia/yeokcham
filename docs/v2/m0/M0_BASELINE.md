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

Starting Git tree: `7cec31df17ed4301af00cbae62511ecafaaecf6d`. The 518-entry
preservation map's canonical JSON digest is
`6bbc01e93995523173b19e8409aa979ccac20f546186e2cdc857cf6bb0d18209`:
SHA256 of `json.dumps(map,sort_keys=True,separators=(',',':'),ensure_ascii=True)`
encoded ASCII, without a trailing newline. Entries contain `mode` and `sha256`
for ordinary files, or `mode` and `target` for symlinks. The starting tree plus
the explicitly recorded D4 working-content identity describes the initial source;
M0 references added later are excluded from this map.

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
| Oversized-inline reader admission | Unknown or unqualified for the Python consumer | Source writer uses manifest above 64 KiB; inspected reader Content branch lacks the cutoff. O13 requires explicit inspection/admission policy, not an invented existing rejection |
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
| Disposable sqlite3 transaction/backup probe | Exit 0; 11 assertions on this host. Explicit SQL boundaries/pragmas/reopen/backup only, not VCS constraints or crash safety; detailed scope in safety companion |
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

| Existing path | SHA-256 of literal file bytes |
| --- | --- |
| [docs/v2/D1_PRODUCT_RFC.md](../../../docs/v2/D1_PRODUCT_RFC.md) | `c86c9d446b2280c5346313a2c9d5bf07bddee99101bd24a8de442fe7d80000b4` |
| [docs/v2/D2_PYTHON_ARCHITECTURE_RFC.md](../../../docs/v2/D2_PYTHON_ARCHITECTURE_RFC.md) | `84e80eb78c3bfe3aa04ad7cc7961d7a475dc0ee03c39abaa3a4ff0bbbd425907` |
| [docs/v2/D3_ARCHITECTURE_GATE.md](../../../docs/v2/D3_ARCHITECTURE_GATE.md) | `087701bc583c332f92acf27675416766a11385f2b17055f7e47a4f16898c4280` |
| [docs/v2/D3_CONTRACT_FREEZE.md](../../../docs/v2/D3_CONTRACT_FREEZE.md) | `9948b35b0e3abcfdd875aafb4ba1c1f47325862987772d938a2dbcb6eee32c33` |
| [docs/v2/D4_BLOCKER_RESOLUTION.md](../../../docs/v2/D4_BLOCKER_RESOLUTION.md) | `d087a235653548584b4e95078af99e72f6cc29a442591b360a16831b307c5f68` |
| [docs/PRODUCT_DESIGN.md](../../../docs/PRODUCT_DESIGN.md) | `ac322302da3d8fbe888f7f0aacc5b51615bc3b7c167722454db10832f63550b4` |
| [docs/TECHNICAL_CONTRACTS.md](../../../docs/TECHNICAL_CONTRACTS.md) | `1e8b9bc62fc3663d3d26b43c6cc0291467be434ad0d45859c7d92b0d2084eb59` |
| [docs/PILOT_PLAN.md](../../../docs/PILOT_PLAN.md) | `ed32505b932698acd4aad507dc5b81d9ff40162bdecee5a704cebdd8f64d5f83` |
| [docs/IMPLEMENTATION_PROGRESS.md](../../../docs/IMPLEMENTATION_PROGRESS.md) | `88f83f7e44e029985944787d22ce9cb9a1f9a8017cb2d2e0b778a2396e8efff5` |
| [docs/implementation/INTERFACES.md](../../../docs/implementation/INTERFACES.md) | `1ff1531cb0b198f87901aaba1fea73d82724b0457872e09d7ac142a4e344fe3c` |
| [docs/implementation/reports/P01-attempt-01.md](../../../docs/implementation/reports/P01-attempt-01.md) | `3bbeba9456af5bea068b3d834fa1d3cb52e517afbfc3cba1decf4b93796bdd09` |
| [docs/implementation/reports/P02-attempt-01.md](../../../docs/implementation/reports/P02-attempt-01.md) | `b44eedb856ce8b1c0a88d84a5332d1efd51a1303420912bc38feb76615563641` |
| [docs/implementation/reports/P03-attempt-01.md](../../../docs/implementation/reports/P03-attempt-01.md) | `d28ecbe65c2553aa19c1917b5b6f902ce0f8e0a97d405282866460d06b92c4a7` |
| [docs/implementation/results/P01-acceptance.json](../../../docs/implementation/results/P01-acceptance.json) | `0ce36f78e031c6bd4884224958e9eaa7013b2a89cd0770d372ebd5979c737da5` |
| [docs/implementation/results/P02-acceptance.json](../../../docs/implementation/results/P02-acceptance.json) | `2d90e4eb923010aa10e659c663f1fd3b7bf00e21301e90bba4ceaaa20a2aba6a` |
| [docs/implementation/results/P03-acceptance.json](../../../docs/implementation/results/P03-acceptance.json) | `ddfa87d8e886bcaf49f48ccba0aeec5d6c876cfc606bfa331b0cb343595943b1` |
| [docs/implementation/reports/G01-attempt-07.md](../../../docs/implementation/reports/G01-attempt-07.md) | `84a94493488fd9e37cff196c70d3aea60fc4939788e70da0b8951b72dc3dad6a` |
| [docs/implementation/results/G01-baseline.md](../../../docs/implementation/results/G01-baseline.md) | `402ce4e7941e2883a9f8d4874ff19b6d411abf660334ed112f8bbfaa2831a805` |
| [docs/implementation/results/G01-baseline.json](../../../docs/implementation/results/G01-baseline.json) | `03e105c1c9ad56178f20b67bc1132c1a5795015d4346dce6d3c9b5f4115ed88b` |
| [docs/implementation/results/cli-graph-20261116.json](../../../docs/implementation/results/cli-graph-20261116.json) | `c5589b9ebf25ad9c82e0b58ed777f1d84eb5a65f24447266e213f1c0d0adb8af` |
| [lib/yeokcham_encoding/yeokcham_encoding.ml](../../../lib/yeokcham_encoding/yeokcham_encoding.ml) | `06404ab8817041517aa0d1e8a9843154daa320bce21271db9def707aacb9f852` |
| [lib/yeokcham_envelope/yeokcham_envelope.ml](../../../lib/yeokcham_envelope/yeokcham_envelope.ml) | `ce4c28f79e098ee12f4550eaf894a9a68a07651289c5ee9909e964bea09f7374` |
| [lib/yeokcham_store/yeokcham_store.ml](../../../lib/yeokcham_store/yeokcham_store.ml) | `4fc750773cfede78c084a5dd38db6a7a76141921d38600c34f6fdc9e87c4e81d` |
| [lib/yeokcham_snapshot/yeokcham_snapshot.ml](../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml) | `88dcb8e6b20b331156dfca593e58ef2814df10a719da36cf810b0b9bc1d21ad7` |
| [lib/yeokcham_chunking/yeokcham_chunking.ml](../../../lib/yeokcham_chunking/yeokcham_chunking.ml) | `ec8bec612fdfaa756663a93e0c5119ca3c5419b0537b9ff2ae56e7583397fea2` |
| [lib/yeokcham_snapshot/native.ml](../../../lib/yeokcham_snapshot/native.ml) | `17d9ec3a51df227800297153d3717e05bc2c8396874a6d7702fe71610d5ff710` |
| [lib/yeokcham_snapshot/yeokcham_scan_stubs.c](../../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c) | `2546a187a5a7491d9d910aeac277a2c83f06f74b9b60208996c4cce5d21224fa` |
| [lib/yeokcham_v1_record/core_record.ml](../../../lib/yeokcham_v1_record/core_record.ml) | `6fc4181e6d09097e6fcb0b7030802b94eff3541f711d152423999e54d07e3d6d` |
| [lib/yeokcham_v1_composition/line_hunks.ml](../../../lib/yeokcham_v1_composition/line_hunks.ml) | `dc08b9c7f2e8765779d0a936e2ec604ec73d60f85d733ba66717319f472dbb91` |
| [lib/yeokcham_v1_composition/yeokcham_v1_composition.ml](../../../lib/yeokcham_v1_composition/yeokcham_v1_composition.ml) | `80ecd976a5c958cc8da036e2613440aafe2396a90ea2991f7c638daf5e73da96` |
| [lib/yeokcham_v1_local_service/native_share.ml](../../../lib/yeokcham_v1_local_service/native_share.ml) | `f4f9a38bc6f2c8ec282a0dc9b2bc42d66fb050a2082196a1a194478db5924ad5` |
| [lib/yeokcham_v1_integration/yeokcham_v1_integration.ml](../../../lib/yeokcham_v1_integration/yeokcham_v1_integration.ml) | `a205587a3b94f6e8705d257fce553e582b0780edc6f499e635220494e8b7738b` |
| [lib/yeokcham_v1_integration/preservation.ml](../../../lib/yeokcham_v1_integration/preservation.ml) | `61c7476c518c28db5c86667b94491ae44de76c6cc6c329bbea7f004604e8a544` |
| [lib/yeokcham_v1_store/publication_receipt.ml](../../../lib/yeokcham_v1_store/publication_receipt.ml) | `e33c04d39ce90ef2a9e509bcdc8fbdebfde3fdb6d71b84d5ee603341307cfc25` |
| [lib/yeokcham_v1_local_service/safe_apply.ml](../../../lib/yeokcham_v1_local_service/safe_apply.ml) | `9f9615e8effc2a9d254475bd6b94cfbc1c375e52dee4cfa7ef7862b4aa638ca9` |
| [lib/yeokcham_v1_local_service/native_integration.ml](../../../lib/yeokcham_v1_local_service/native_integration.ml) | `b68451be23f1a1cd26b6cb5c6e5e064dc6253bf47e50d287285cadd18cdbed25` |
| [test/test_safe_apply.ml](../../../test/test_safe_apply.ml) | `97bea43d454822e8e690d0d27a35813873440f1200892570cb371d81e321f001` |
| [test/test_benchmark_runner.py](../../../test/test_benchmark_runner.py) | `3380f22bc2cca1a3c8f1366cc5d3069c3d8e3278e867bd52229dc0547886d599` |
| [tools/benchmark_runner.py](../../../tools/benchmark_runner.py) | `7931d593f9dd8de17b19a093e8e3b8f4a027437248609a6469043658efd69764` |
| [test/generate_core_vectors.py](../../../test/generate_core_vectors.py) | `31525027b9802844f5a6381decb87d736774db871d14cfcd2970934f45dfedab` |
| [tools/generate_composition_vectors.py](../../../tools/generate_composition_vectors.py) | `1ad5fed130c88d0959765619e986a433e670e36b499907448686822f464dbe94` |
| [tools/generate_core_package_vectors.py](../../../tools/generate_core_package_vectors.py) | `4f8c9a6083a4ee4fd18c9cce47cd73b556bd0c3f1f71992e6819f12088db0a27` |
| [tools/generate_integration_vectors.py](../../../tools/generate_integration_vectors.py) | `aacbd374f311532ada662f20e660e3a1627cbe50bccc106a2826c2594f92a6de` |
| [tools/generate_local_vectors.py](../../../tools/generate_local_vectors.py) | `d1b3425c605d7afeb33cfc60c5f6b73a7478db13d7a69398455ef82186a0e25d` |

## Closeout and next scope

**M0 COMPLETE as reference preparation, with explicit consumer gates.** At
2026-11-20 08:35 UTC, all 518 starting files retained their literal contents and
modes; only the four named M0 paths were added relative to the starting inventory.
The independent preservation audit also checked 44 source/report identities,
all 74 golden files/family checksums, 12 existing expected-ID/CBOR rows, 22 numbered
semantic cases, five local heading fragments, balanced fences and whitespace.
The repository link check passed 515 local file references; `git diff --check`
passed. New-file whitespace was checked separately, not inferred from tracked diff.

External processes created snapshots during M0:

| Observed commit | Contents / attribution |
| --- | --- |
| `ffdce9e6bf50f223363733cdcf04f2726466e45e` | Committed the pre-existing final D4 working edits unchanged, plus intermediate baseline/semantic drafts |
| `f5c4f00ef366e873f81c909caadd8f6555e2337b` | Committed the intermediate vector inventory |

This task issued no commit, push, checkout, branch switch, reset, amend, cleanup,
dependency installation or Git worktree command. These external snapshots were
inspected/preserved; commit presence does not grant architecture approval or
attribute those Git actions to M0. Starting D4 becoming clean in Git is not a
content change by M0. Observed closeout HEAD is
`f5c4f00ef366e873f81c909caadd8f6555e2337b`, with the following full status:

```text
## main...origin/main
 M docs/v2/m0/M0_BASELINE.md
 M docs/v2/m0/M0_SEMANTIC_REFERENCE.md
 M docs/v2/m0/M0_VECTOR_INVENTORY.md
?? docs/v2/m0/M0_SAFETY_AND_TRANCHE_GATES.md
```

Working differences retain subsequent qualifications and this closeout. Any later
external snapshot is reported separately at final handoff; a changing HEAD never
justifies overwriting current user work. The external audit files are supplemental
evidence, not a fifth repository deliverable.

No implementation or migration is part of M0. **Full M1a is NOT READY** while its
independent content corpus, oversized-inline reader-admission choice and normalization qualification/specification gates
remain open. The safety companion defines a proposed separately authorized
Prompt 06 for closing those reference prerequisites; it starts no production code.
