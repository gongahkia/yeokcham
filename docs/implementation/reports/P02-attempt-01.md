# Yeokcham implementation report: P2 — usable local-workflow pilot

- Attempt: 01
- Status: complete for scoped P2; G02/G03/G05/G06/G14 are not marked complete
- Branch: main; session `p2-local-2026-11-14`; no agents/worktrees/branches/push/deployment
- Starting commit: `56eb13d271421720299d7e3f0dcd589d80b4d153` (clean main verified before editing)
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`, amended by D30 pilot priority
- Predecessor: [P1 report](P01-attempt-01.md), [receipt](../results/P01-acceptance.json)
- Verified ancestors: P1 handoff `56eb13d271421720299d7e3f0dcd589d80b4d153`, implementation
  `51c374f499372349b235e68b32e7bf3e748d2718`,
  `f900fbc3432e1d7134a547eda4f2ec7366d6c991`,
  `06b662a8bab5c783117e5fcf45e36b7d942cfc64`; G01 handoff and pilot assessment also verified
- Tested revision: `6826af74810bb4087bb4795781d0176276df2b9e`; final runtime implementation `e181ff9ec863740ceb511fb888b23472056ebd15`
- Platform: native Arch Linux x86_64, kernel `7.2.15-1-omarchy`
- Toolchain: OCaml 5.5.0, Dune 3.25.0, ocamlformat 0.29.0, opam 2.6.1
- Report path: `docs/implementation/reports/P02-attempt-01.md`

## Delivered behavior

A person can initialize existing mixed work privately, inspect actual status and
readable differences, save and navigate exact branching history, create named
shared branches and select their durable private positions. Initialization
creates authenticated empty accepted genesis; it does not accept existing files.
Workspace/branch/draft identities and default names are generated. Local branch
operations produce signed branch/accepted records through P1 trust/model APIs;
unsupported acceptance/policy refuses explicitly. Local workflows require no
shared change/revision creation; ordinary share allocation remains P3.

`status`, `history`, `diff`, `branch list/create`, `switch`, `undo`, `redo` and
`restore STATE` now return domain data and meaningful next actions. History shows
alternate continuations and verified available/not-retained/unavailable contents.
State selectors distinguish workspace:sequence history identity from immutable
snapshot identity. Text hunks preserve newline information; binary/type/mode
changes remain explicit. Inspection does not publish or advance history.

Native root/nested `.yeokchamignore` implements glob/negation/escaping/precedence
and parent re-inclusion, with `ignore explain PATH`. Git ignore configuration is
never read. Descriptor-anchored capture rechecks identities, directory membership
and rules, retries detected instability at most three times, streams large files
and retains the last complete saved state on incomplete capture. Bytes, executable
distinction, empty directories and symlink targets are preserved.

The existing atomic state root owns workspace namespace, monotonic sequence,
history/cursor, signed local branch state and private positions. Pure reservations
or staged objects are not durable allocation. Whole-history encoding is retained;
P2 did not replace it with an unprofiled paging/index system or claim a speedup.

Local selection/copy-out preflight target closure, representability, ignored paths
and untracked obstructions. Verified staged actions use exclusive moves/exchange,
retain displaced originals and journal the exact target. Unexpected external edits
refuse rather than being overwritten by replay/rollback. Equal-content cursor
moves are journaled without rewriting files. `restore STATE --to DIRECTORY`
installs a verified separate copy into a new/empty same-filesystem destination,
without source-history/counter/cursor/branch changes. Recorded operation resume
handles lost acknowledgements without another navigation or partial-tree capture.

Selection supports `--preview`, default cancellation, `--yes` and `--plan ID`.
Changed inputs require a fresh plan; noninteractive application requires explicit
confirmation, and ambiguity remains a choice even with `--yes`. Status identifies
all pending scopes and exact recovery commands. Services/backup are reported
unconfigured/unimplemented/uninspected as applicable. Native custody acceptance,
managed scheduling, private archive and P3 shared exchange/integration are not
inferred from working local commands.

## Acceptance evidence

All seven scoped criteria were audited against the saved [P2 task](../goals/P02-local-workflow.md).
The [compact receipt](../results/P02-acceptance.json) contains exact commands,
log hashes, prerequisite/implementation commits, paths, limitations and ownership.

| Scoped criterion | Evidence | Result |
| --- | --- | --- |
| 1. Actual status/history/text+opaque/type+mode diff; exact IDs/alternatives/availability; saved and working comparisons without history advance; schema-2 domain outcomes. | `test/test_local_inspection.ml`, `test/test_text_diff.ml`, `test/test_local_inspection_cli.py`, `bin/yeokcham_v1.ml` | passed |
| 2. TC07 native exclusions/explanations; bounded descriptor-anchored retries and identity/directory rechecks; incomplete capture preserves last complete state; streamed byte/exec/directory/symlink fidelity. | `test/test_native_ignore.ml`, `test/test_native_ignore_cli.py`, `test/test_capture_consistency.ml`, `test/test_content_verification.ml`, `docs/NATIVE_IGNORE.md` | passed |
| 3. Generated typed workspace/branch IDs/defaults; atomic namespace/counter/history/cursor root; collisions, restart, identical repeats and exhaustion. Local commands create no shared change/revision; ordinary share identity allocation belongs to P3. | `test/test_history_identity.ml`, `test/test_local_core.ml`, `lib/yeokcham_v1_store/local_core.ml`, `lib/yeokcham_v1_store/yeokcham_v1_store.ml` | passed |
| 4. Signed empty accepted genesis/forks, causal branch sets, persistent private selection, duplicate/divergent refusal and private alternative preservation. Local empty/fork-only adapter refuses unsupported acceptance/policy. | `test/test_core_branch_heads.ml`, `test/test_local_core.ml`, `test/test_local_branch_cli.py` | passed |
| 5. Verified bounded staged apply/copy-out, ignored/untracked/representability preflight, retained originals, exact operation journals and recovery at actual mutation/metadata boundaries; preserve external edits; preview/cancel do not move history/files. | `test/test_safe_apply.ml`, `test/test_native_materialize.ml`, `test/test_store_safety.ml`, `test/test_v1_undo.ml`, `test/test_v1_restore_journal.ml`, `test/test_local_selection_cli.py` | passed |
| 6. CLI help/spec, generated identities, preview/default cancellation/yes/plan, noninteractive choice, semantic JSON/exit/action journeys and regression checks; service/backup state reported honestly. | `test/test_v1_cli.ml`, `test/test_cli_domain_data.ml`, `test/test_local_selection_cli.py`, `test/test_local_branch_cli.py`, `test/test_local_inspection_cli.py` | passed |
| 7. Concrete APIs/current guides, criterion-level G03/G05/G06/G14 coverage and remaining G02/P3 dependencies; original full phases remain uncompleted. | `docs/implementation/INTERFACES.md`, `docs/IMPLEMENTATION_PROGRESS.md`, `docs/LOCAL_UNDO.md`, `docs/implementation/reports/P02-attempt-01.md` | passed |

Actual native fault cases stop at file mutation, journal phase and metadata CAS
boundaries, then reopen in another process. Tests also cover writes through
retained file/directory descriptors, changed bytes with preserved inode/size/mtime,
replaced parent/root paths, missing/corrupt staged targets, simultaneous pending
in-place/export scopes, concurrent signed branch names and exact retries.
No production CLI/environment fault-injection mode was added.

## Verification

Use the existing documented environment; packages remain in the repository-local
opam switch, so compiler tools are invoked through `opam exec`:

```sh
. /home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh
```

All final commands below tested `6826af74810bb4087bb4795781d0176276df2b9e`. The final report/status edits are
Markdown/JSON only and do not change these runtime sources. Logs are external in
`/home/gongahkia/.cache/yeokcham-p2-20261114/`; the receipt preserves their SHA-256
hashes so their availability is not assumed on another machine. Closeout
`python3 tools/check_doc_links.py` passed 243 local file references;
`git diff --check` and affected shell syntax checks passed.

| Exact command | Exit | Evidence/outcome |
| --- | --- | --- |
| `opam exec -- dune exec test/test_native_ignore.exe` | 0 | `p02-final-00.log`; 5 OCaml cases |
| `opam exec -- dune exec test/test_capture_consistency.exe` | 0 | `p02-final-01.log`; 7 OCaml cases |
| `opam exec -- dune exec test/test_history_identity.exe` | 0 | `p02-final-02.log`; 7 OCaml cases |
| `opam exec -- dune exec test/test_core_branch_heads.exe` | 0 | `p02-final-03.log`; 3 OCaml cases |
| `opam exec -- dune exec test/test_content_verification.exe` | 0 | `p02-final-04.log`; 5 OCaml cases |
| `opam exec -- dune exec test/test_local_inspection.exe` | 0 | `p02-final-05.log`; 6 OCaml cases |
| `opam exec -- dune exec test/test_text_diff.exe` | 0 | `p02-final-06.log`; 5 OCaml cases |
| `opam exec -- dune exec test/test_native_materialize.exe` | 0 | `p02-final-07.log`; 5 OCaml cases |
| `opam exec -- dune exec test/test_safe_apply.exe` | 0 | `p02-final-08.log`; 22 OCaml cases |
| `opam exec -- dune exec test/test_store_safety.exe` | 0 | `p02-final-09.log`; 7 OCaml cases |
| `opam exec -- dune exec test/test_local_core.exe` | 0 | `p02-final-10.log`; 23 OCaml cases |
| `opam exec -- dune exec test/test_cli_domain_data.exe` | 0 | `p02-final-11.log`; 4 OCaml cases |
| `opam exec -- dune exec test/test_v1_restore_journal.exe` | 0 | `p02-final-12.log`; 9 OCaml cases |
| `opam exec -- dune exec test/test_v1_undo.exe` | 0 | `p02-final-13.log`; 16 OCaml cases |
| `opam exec -- dune exec test/test_v1_local_service.exe` | 0 | `p02-final-14.log`; 45 OCaml cases |
| `opam exec -- dune exec test/test_v1_cli.exe` | 0 | `p02-final-15.log`; 28 OCaml cases |
| `python3 test/test_local_inspection_cli.py _build/default/bin/yeokcham_v1.exe` | 0 | `p02-final-16.log`; 9 Python cases |
| `python3 test/test_local_branch_cli.py _build/default/bin/yeokcham_v1.exe` | 0 | `p02-final-17.log`; 17 Python cases |
| `python3 test/test_local_selection_cli.py _build/default/bin/yeokcham_v1.exe _build/default/test/local_cli_fault.exe` | 0 | `p02-final-18.log`; 16 Python cases |
| `python3 test/test_native_ignore_cli.py _build/default/bin/yeokcham_v1.exe` | 0 | `p02-final-19.log`; 4 Python cases |
| `python3 tools/generate_local_vectors.py` | 0 | `p02-final-20.log`; passed; valid cached build/test artifacts may be reused |
| `make build` | 0 | `p02-final-21.log`; passed; valid cached build/test artifacts may be reused |
| `make lint` | 0 | `p02-final-22.log`; passed; valid cached build/test artifacts may be reused |
| `make ci` | 0 | `p02-final-23.log`; passed; valid cached build/test artifacts may be reused |

Fresh focused verification executed **16 OCaml suites / 197 cases** and **46
Python cases**. Property suites additionally run 150 history/restart sequences,
400 text-hunk reconstruction examples and generated mixed-tree transitions.
These are focused counts, not an invented full-project execution count. Final
`make ci` reused matching successful Dune runtest results; the preceding
`ci-local-cli-complete.log` executed CLI28, native-local23, branch17, inspection9,
ignore4, selection16, watch/runtime/transport and tiny harness8, with other valid
results cached. CI includes documentation links and both workflow checks.

Formatter promotion initially made `make format` exit 2 (Dune exit 1); final
`make format` and lint passed. Intermediate checks exposed missing ignore help,
legacy synthetic partial-tree expectations, stale restore-text assertions and
benchmark verification mutating its measured source metadata. These were fixed;
checkpoint logs/results remain in the ledger. The benchmark verifier now uses a
disposable metadata replica outside timing and asserts measured source storage
and head unchanged. Only tiny harness regressions ran; accepted G01 measurements,
reports/results and P1 core golden bytes are unchanged. No reported skip appears
in the fresh focused checks. Initial direct compiler queries outside `opam exec`
were unavailable on PATH; the documented opam invocations verified the versions.

Unavailable/deferred checks are explicit, not counted as passes:

- Docker tutorial/development container execution: `docker info --format
  '{{.OSType}}'` exited 1 with permission denied on `/var/run/docker.sock`.
  `sh -n test/test_tutorial_container.sh test/test_development_artifacts.sh`
  passed. Container/native packaging evidence remains G20.
- Native macOS/Windows and filesystem-independent power-loss qualification:
  No access. Linux process exits are real evidence for this host, not those gates.
- Native credential-service onboarding, representative project responsiveness and
  human comprehension: P4/G18/G20; explicit disposable test signers are outside
  test workspaces and are not a native custody acceptance claim.
- G06 paging/index rebuild/depth measurements and G19 whole-product performance:
  outside P2; no accepted G01 rerun and no storage replacement or latency claim.

## Commits and rollback

The table is in exact newest-first source rollback order. It includes the scoped
start/documentation commits so all P2 changes are attributable. Reverting source
is an operator decision, not a request executed by this report.

| Commit | Atomic purpose |
| --- | --- |
| `6826af74810bb4087bb4795781d0176276df2b9e` | docs(cli): confirm restore writes in container and source journeys |
| `e181ff9ec863740ceb511fb888b23472056ebd15` | feat(cli): complete confirmed local selection and exact operation recovery |
| `c9c8f2509db2768279287a02724b69367777c9aa` | fix(local): bind selection plans and journal equal-content navigation |
| `822066fbf1f842c42d57a8586c78dfc2e399fd77` | fix(local): journal safe recovery copies without changing source history |
| `5377c3f2a2b34fc405b26fe29117b3572da2b06c` | feat(local): verify applied bytes and stage scoped directory copy-out |
| `440422b7d66dcaa624fef953f5c9666a8d2aeca8` | fix(store): publish recovery metadata atomically and recover dead writers |
| `bf148b817337b13867900f90290681099c65fdeb` | feat(local): select named branches and preserve private alternatives |
| `c1bdcea3c4f9e18e8890c69b13d42fc5e82d179b` | fix(local): resume exact planned navigation without overwriting external edits |
| `90feb3d120f85a9033682dcbaf1b974b2451523a` | feat(local): stage recoverable file actions and preserve external edits |
| `41087171de052c7cbe83ee0732f0ba447ebf0523` | feat(snapshot): add safe staged-application filesystem primitives |
| `37bc7667dc843683591d5605260fa3f204271983` | feat(cli): expose exact local inspection and structured domain outcomes |
| `0e539d8718906713b9fac7514e198ccc7ece1d28` | makingsomeinitialcommits |
| `c51684ffc60b473c7ba8a1a14246cc29791300fd` | feat(local): inspect exact states, capture health and alternate history |
| `0e629dc7c38637fcb9cf99cd8ec168bfe2572700` | makingsomeinitialcommits |
| `2625e2396772b76a57bed332a4c48aa236bbcae4` | feat(snapshot): verify large content without whole-file display buffers |
| `bf7b883c6a990288d8a3959f877ac823da857867` | feat(cli): initialize privately and create authenticated named branches |
| `1d28ab7042f9749b038e41c5ebcbb6c8ed27dc4c` | feat(store): persist authenticated local branches with private retention roots |
| `6033674c69389e486e61f76d0c1e9b6c8c2dac83` | feat(core): expose causal branch head sets without choosing alternatives |
| `93966254c483cc6e657ac7e71ec7017285e33430` | feat(history): persist workspace identities and atomic sequence allocation |
| `986ee9c70260ad2e9704cb7589d59884dbe2ca35` | fix(capture): anchor observations and bound instability retries |
| `6f224e356219febfdad3fe077d67b2d67ead4f05` | updatedzellijconfig |
| `f7d0a25f1bb6b36b0bbbd79a7bdf0d01956700ae` | feat(capture): implement native ignore rules and CLI explanations |
| `2b34dc43218abe7a6a5ab939465a4b06853c6496` | docs: start scoped P2 local-workflow implementation |

Three existing auto-created commits (`6f224e3`, `0e629dc`, `0e539d8`) appeared
around owned work during this session. Their contents were inspected and reused;
no unrelated configuration change was reset or amended despite their generic
subjects. There were no unrelated starting worktree changes.

Data effects and rollback constraints:

- Local history schema 2 stores workspace/counter/cursor/ancestry. Local state
  wrapper 2 additionally stores authenticated branch metadata in the same
  `v1-project-state` root. Existing current wrappers remain readable; older
  clients may not read newly written state. D10 is not permission to discard data.
- P1 canonical signed record codes 41–43 and their vectors stay unchanged. Local
  core mappings bind complete-envelope record IDs to existing store object IDs.
  Current accepted semantics are empty genesis/forks only; P3 must add actual
  integration verification before admitting nonempty results.
- Physical plan schemas 1/2 and restore journals 3/4/5 bind exact file application,
  copy destination, target node/branch and local intent. Old partial operations
  without physical identity plans refuse unexplained replacement. New journals
  must be completed/preserved before using an older executable.
- Recovery publication now uses atomic create-only metadata files and a process
  lock gate; dead known owner markers can be recovered conservatively. GC shares
  the workspace writer boundary and preserves branch/pending/proof roots.
- Preserve repository metadata, live files, recovery proofs/journals and
  `.yeokcham/restore-staging/OPERATION/` before any source rollback. Source reverts
  do not undo materialized files, cursor changes or generated identities. Retained
  displaced native files are not automatically removed by proof forgetting/GC.
  Copy a needed safety/target to a separate location before changing versions.
- New CLI noninteractive writes need `--yes`; callers using earlier unconditional
  undo/redo/restore behavior need the documented flags. Container/source journeys
  and tiny benchmark invocations were updated, without changing measurement rules.

Handoff commit: obtain the separate report/ledger commit with
`git log -1 --format=%H -- docs/implementation/reports/P02-attempt-01.md`.
Its actual hash is returned in the final response; this file is not amended to
insert its own commit identity.

## Design and interface notes

[Interfaces](../INTERFACES.md) records actual modules/signatures, all ordered
fields, registry use, trust/admission boundaries, root ownership, safe-application
limits and structured outcomes. Committed canonical local vectors cover history
v2 and restore v4/v5; an independent Python emitter checks restore v4/v5. P2 reuses snapshot/store/workspace/undo/CLI contracts rather
than introducing another mutable history store. Existing public V1 collaboration
commands retain their older semantics; they are not a renamed P3 integration
loop. Legacy shared workspace activation is a separate conservative adapter;
its replacement belongs with actual verified shared integration.

## Scope and worktree audit

- Owned changes: snapshot native ignore/descriptor/streaming/preflight machinery;
  existing store/model/trust/undo/local-state adapters; local service inspection,
  branch/copy-out/recovery engine; CLI data/spec/rendering; affected GC/journal/
  proof retention; focused tests/vectors; current guides/ledger/scoped goal.
  The receipt lists every changed path through the tested commit. Final closeout
  additionally changes report/receipt and relevant documentation status only.
- README: unchanged. Accepted G01 measurements/reports/results and P1 core
  goldens: verified unchanged by Git diff from the P1 handoff. External G01
  benchmark directories were not recreated or used to rerun measurements.
- Worktree: clean on `main` at tested revision before report/status edits. Only
  explicitly staged owned paths were committed; final clean status is checked
  after the separate handoff commit. No push/release/deployment or agent.
- Fixtures/signers/large files: disposable temporary workspaces or external P1/P2
  cache; no user credential, recovery mnemonic, token or generated large fixture is
  committed. Small deterministic golden bytes are intentional test artifacts.

## Remaining work and next handoff

No scoped P2 acceptance criterion remains. The full design remains **1 / 20
phases complete (G01)**; pilot P0/P1/P2 are complete, P3/P4 unstarted. The full
native/human product pilot has not passed merely because this local slice passed.

| Original phase criterion | Delivered P2 coverage | Still outstanding |
| --- | --- | --- |
| G03 C1 | Existing device trust reused | Stable principal/device proof binding and independent-reviewer identity |
| G03 C2 | Causal branch heads/names, permutations, signed local fork selection/refusal | Full policy heads/fork evaluator, authority reconciliation/adoption semantics |
| G03 C3–C4 | No fabricated approval/policy success | Independent approver default, exact context/preferences/invalidation, reviewer events/withdrawals/blocks/dismissal |
| G03 C5 | Branch receipt permutations/current trust/signature refusal | Complete optional/required review, identity, preference, adoption matrix |
| G05 C1–C3 | Native ignores/explain, bounded stable streaming capture and exact fidelity on Linux | No new full-phase completion claim; maintain implementation with portability qualification |
| G05 C4–C5 | Staged destination preflight, collisions/ignored/untracked refusal; Linux real FS plus boundary/generated tests | Native case/normalization/OS filesystem matrix and full portable qualification remain G05/G20 |
| G06 C1 | Existing whole-history representation deliberately retained | Bounded immutable pages, rebuildable lookup index and append-cost change |
| G06 C2–C3 | Durable namespaces/counters/ancestry/cursor/private branch positions; atomic root, retry/exhaustion/collision | Publication correspondence and full incremental/concurrent received-record/page scenarios |
| G06 C4–C5 | Current/pinned/branch/pending/proof roots, restart/fault/GC tests | Index rebuild, page-publication faults, depth measurements; no G01 rerun here |
| G14 C1–C3 | Init/private genesis, useful local inspection, named branch selection, local recovery | Verified ordinary clone, selected publication/update, shared integration, archived history and remaining vocabulary |
| G14 C4–C5 | Scoped local preview/yes/plan/cancel/JSON/pagination/exits and mixed recovery journeys | Full command/preferences consistency and multi-person shared/remote/archive journeys |
| G14 C6 | Honest watcher/service/backup state, existing feature regressions retained | Managed service delivery remains G15–G17 |

G02 remains partial as recorded by P1: review/request/event/policy,
account/settings/archive families and their consumers/interfaces/vectors remain.
Other original phases and coverage gates are not closed by P2. Next eligible
pilot slice is P3 **only when separately invoked**. Its scope source is
[the pilot plan](../../PILOT_PLAN.md); no next goal file/prompt is generated here.
The next agent must verify this report/receipt, the exact tested implementation
and handoff ancestors, a clean/current branch, and any intervening changes before
editing. Stop after this P2 handoff.
