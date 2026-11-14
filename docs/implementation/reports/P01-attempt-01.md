# Yeokcham implementation report: P1 — core-workflow record foundation

- Attempt: 01 (continuation of the existing partial P1 implementation)
- Status: complete for P1; full G02 remains partial
- Branch: main; one writer
- Continuation starting commit: `06f526d9f6f09cd06bd3b57a7a348f64ea17817a`
- Original P1 start/pilot assessment: `4577f3456f9fce0246a61e3b1ec4740319d8442e`
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`, amended by D30's pilot priority
- Predecessor report: [G01 attempt 07](G01-attempt-07.md); verified handoff
  `f3bd17705591413078e1504d46d8240eb6c47f2e` and pilot assessment are ancestors
- Platform: native Arch Linux x86_64, kernel `7.2.15-1-omarchy`
- Toolchain: OCaml 5.5.0, Dune 3.25.0, ocamlformat 0.29.0, opam 2.6.1
- Tested implementation: `06b662a8bab5c783117e5fcf45e36b7d942cfc64`
- Report path: `docs/implementation/reports/P01-attempt-01.md`

## Delivered behavior

`Yeokcham_v1_record.Core` now encodes and bounds-decodes shared revisions,
accepted versions and branch events under the existing envelope registry.
Canonical bodies bind repository, causal parents, author certificate, authority
heads and payload. Fixed domains separate Ed25519 messages; complete signed
envelope bytes determine immutable SHA-256 identities. Decoding rejects wrong
scope/type/version/features, malformed references, unsorted/duplicate sets and
oversized/noncanonical input.

`Yeokcham_v1_trust.Core` connects these records to the existing verified
authority/custody machinery and the actual pure core model. Signing checks the
selected current authority heads and provider result. Historical verification
is distinct from current receipt admission: newly arriving records revoked by
a descendant head refuse with `Late_record_requires_adoption`. Core adoption
is explicitly unimplemented; an existing V1 adoption cannot cross domains.
Identical retained historical records remain no-ops.

The existing identity/model implementation is reused. Independent root revisions
can no longer recreate an existing change ID. History namespaces, exhaustion,
collision handling and identical-content/distinct-position behavior are tested.
Atomic sequence allocation belongs to the future locked store/history append,
not the pure reservation function.

These are working library foundations. Existing ordinary CLI workflows are
unchanged. There is no new clone, branch switch, composition executor,
accepted-head publication, durable sequence allocator or integration command.

## Acceptance evidence

All five original P1 criteria are covered by the seven continuation requirements:

| Continuation requirement | Authoritative evidence | Result |
| --- | --- | --- |
| 1. Three canonical record families, signing domains, complete-envelope identities and one registry | `lib/yeokcham_v1_record/core_record.ml`; existing envelope codes 41-43; independent body/message/signature/envelope/ID vectors | passed |
| 2. Bounded decoding and explicit invalid-input rejection | `test/test_core_record.ml`: malformed shapes/references, versions/features, set ordering, byte/item/depth bounds, every truncated envelope prefix and mutation properties | passed |
| 3. Typed random 128-bit IDs and nonnegative int64 history identity, retry/collision/exhaustion and allocation ownership | Existing `Model.Core` API plus change-root collision check; 9 model cases; max-int64 history vector/property; [allocation contract](../INTERFACES.md#identities-and-local-allocation-ownership) | passed |
| 4. Actual model/trust consumption and unsupported-policy refusal | `Trust.Core.sign/verify/receive`; `test/test_core_trust.ml` exercises all families, branch actions, dependencies, valid/rejected signatures, external-provider refusal, revoked/unknown/forked authority and opposite receipt orders | passed |
| 5. Concrete interface names, signatures, registry and invariants | [Interfaces](../INTERFACES.md), actual model/record/trust interfaces | passed |
| 6. Independent vectors and meaningful negative/property cases while retaining existing workflows | 13 fixed vectors independently generated using Python/OpenSSL; 18 core cases with 2,200 property trials; full CI | passed |
| 7. Exact P1 versus full G02 coverage | Interface remainder section, shared progress ledger and this report; G02 remains partial | passed |

[Acceptance receipt](../results/P01-acceptance.json) records tested revisions,
command exits, log/vector/package hashes, environment and scope limitations.

## Verification

Commands use the environment in external
`/home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh`:

```sh
. /home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh
opam exec -- dune exec test/test_core_model.exe
opam exec -- dune exec test/test_core_record.exe
opam exec -- dune exec test/test_core_trust.exe
make build
make lint
make ci
python3 -B test/generate_core_vectors.py
git diff --exit-code -- test/golden/core
```

| Check | Tested source | Actual outcome |
| --- | --- | --- |
| `make setup` | Continuation workspace; no product execution | exit 0; repository-local compiler/dependencies/formatter installed |
| Focused core model / codec / trust executables | Respective final implementation sources, subsequently committed unchanged | exits 0; 9 + 6 + 3 cases, including 2,200 property trials |
| `make build` | `06b662a` | exit 0; uses already-built valid artifacts |
| `make lint` | `06b662a` | exit 0; format/build checks and opam lint passed |
| `make ci` | `06b662a`; only unrelated-to-runtime ledger text pending | exit 0; 50 scheduled OCaml suites / 307 cases and 12 Python harness tests executed; docs and both workflow checks passed |
| Independent vector regeneration and committed-vector diff | `06b662a` | exit 0; all 13 vectors byte-identical |
| Predecessor ancestry and retained G01/P0 evidence digests | Current main | passed; hashes unchanged; no accepted G01 measurement repeated |
| `make docs-check`, `git diff --check` | Final documentation/report/receipt closeout | passed before handoff commit; final documentation has no runtime changes |

No skipped test was reported in the CI log. SoftHSM was configured and its
PKCS#11 case executed. The fresh local switch ran all 50 scheduled OCaml suites
and both Python test files; no cached runtime result is presented as freshly
executed. Subsequent build/lint and documentation checks reuse valid artifacts.
The CI harness tests use tiny disposable fixtures; they do not repeat the
accepted G01 measurement profile.

Initial environment inspection found no opam/compiler and passwordless sudo was
unavailable. Configured package-mirror binaries were extracted under the external
cache; compiler and project dependencies were built in the local switch. No
system package installation or desktop configuration was changed. Dune 3.25.0
satisfies the manifest's `>=3.23`; the historical lockfile was not changed.
SoftHSM initialization initially failed at its compiled-in system module path;
explicit `--module` fixed the test setup. Early focused compilation caught
polymorphism and strict-warning errors; they were corrected before commits.
No security validation or tests were disabled to obtain a pass.

Native macOS/Windows, complete native platform services/custody journeys,
container/RPM/OCI smoke, extended performance and human pilot evaluation were
not run. They remain the later owners' gates in the ledger, not P1 passes.
Historical external G01 and P0 artifact directories are absent on this host;
only their committed evidence/digests were checked here.

## Commits and rollback

| Commit | Atomic purpose | Format/data effect |
| --- | --- | --- |
| `51c374f499372349b235e68b32e7bf3e748d2718` | Complete bounded canonical codec and independent golden/negative/property cases; formatter corrections limited to existing P1 registration paths | Implements new core envelopes using already-allocated codes 41-43; no V1 state/CLI format migration |
| `f900fbc3432e1d7134a547eda4f2ec7366d6c991` | Reject independently recreated change identity, with regression test | Pure validation only |
| `06b662a8bab5c783117e5fcf45e36b7d942cfc64` | Connect core records to verified authority and model consumption; document actual contracts | Pure trust/receipt APIs, no persistent state/head or filesystem mutation |

Inherited P1 work is retained: `0c1f910dcd8a4f4a7d10db81a199d83fa9774043`
(model/identities/tests) and `06f526d9f6f09cd06bd3b57a7a348f64ea17817a`
(registry/interface). The ledger-only P1-start commit is
`8fd4903a997cf0ce694edfe1da00da1dbc2929a2`.

Rollback the three continuation implementation commits newest first with
`git revert 06b662a8bab5c783117e5fcf45e36b7d942cfc64`, then
`git revert f900fbc3432e1d7134a547eda4f2ec7366d6c991`, then
`git revert 51c374f499372349b235e68b32e7bf3e748d2718`.
Reconcile later consumers and the ledger/report first. Removing the codec returns
to the earlier incomplete interface-only development state. Source rollback does
not migrate/delete records or remove external tools, test tokens, logs or the
local switch. No rollback was executed.

The report/ledger/receipt is committed separately. Locate that handoff hash with
`git log -1 --format=%H -- docs/implementation/reports/P01-attempt-01.md`.

## Design and interface notes

No correctness/privacy design amendment. `INTERFACES.md` freezes the actual P1
registry, exact CBOR tuple/map/action layout, raw identifier widths and signing
bytes. It documents record limits, collision/retry behavior, historical versus
current admission and storage ownership. Unsupported policy/review/resolution
references refuse model retention. Planning result types preserve distinct
accepted/workspace snapshots without claiming a planner exists.

## Scope and worktree audit

- Changed product paths: the new core codec, existing core model collision
  validation, trust Core adapter, and formatter-required existing P1 declarations.
  The GC hunk is formatter-only; new core types remain conservatively retained.
- Changed verification paths: `test/dune`, `test/test_core_model.ml`, new codec/
  trust tests, independent generator and `test/golden/core/` vectors.
- Documentation: actual interfaces, current pilot/workflow/design/technical
  status, shared progress, acceptance receipt and this report.
- README changes: none. Existing benchmark files/measurements, dependency
  manifests/lockfiles and CI workflow definitions are unchanged.
- Pre-existing staged/unstaged changes: none at continuation start. At report
  preparation, only owned documentation/evidence remains for the handoff commit;
  final status is checked after committing.
- Tools/logs and disposable SoftHSM tokens remain under the external task cache.
  No user's private custody material was read or committed. The vector seed is
  intentionally public test material. No additional agents, branches/worktrees,
  pushes, releases, deployments or later slices were started.

## Remaining work and next handoff

- P1 acceptance criteria and required checks: none remaining.
- Completed full-design phases: **1 / 20**. Pilot P0/P1 are complete; G02 is partial.
- Remaining G02: review request/version/event and repository-policy records;
  account epochs, personal settings and archive manifests; request/member IDs
  and principal proof; private crypto and full policy/review/archive/journal
  consumer interfaces plus their golden/negative/property coverage.
- P1 does not implement composition/scope/snapshot proofs, persistent new
  history/sequence allocation, branch-head reduction, core adoption, transport
  of these new records or ordinary clone/integration services.
- Every full-design coverage gate after G01 remains open, including the rest of
  G02-G04, storage/sync/archive/review/background work, native product journeys,
  representative performance, packaging and genuine human evaluation.
- Next eligible pilot slice: P2 local work in [Pilot plan](../../PILOT_PLAN.md).
  P2/P3 need a separately scoped handoff respecting their domain dependencies.
  The native pilot OS/project choice remains open for later validation.
- Verify this report, receipt, the three continuation commits and inherited
  P1 contracts before continuing. No next `/goal` prompt is generated here;
  the user will request it separately. Work stops after this P1 handoff.
