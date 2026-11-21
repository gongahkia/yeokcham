# M1a.3: pure public composition qualification and implementation

Date: 2026-11-21, Singapore. **Verdict: PARTIAL.**

Inline PublicBasis.Compose is implemented. The 22 M0 public/conditional projections
now have their normative outcomes using actual inline recipes. Literal replacements,
novel deletion and historical comparison choices are supported within the exact
bounded input path domain. New descendant names/domain expansion and ambiguous
comparison overrides remain explicit refusals. This is not a complete public
protocol, VCS, migration or acceptance implementation. No M1b work began.

## 1. Source and preservation

Initial HEAD: `4a5d284f32b195e5cbe43aff58d649f67d91e14c`; clean
`main...origin/main`, no staged, unstaged or nonignored untracked paths.
Final HEAD: `ba921b67cb633a92cd621ee8e52ae8bcc6ab05f6`. External commits `c7cf8c0` and `ba921b6` incorporated
intermediate work during execution. Their commits and externally staged versions
were left intact. This agent issued no staging, commit, push, reset, cleanup,
branch switch or other Git mutation.

An initial SHA-256/native-mode manifest covers **550** pre-existing tracked and
nonignored untracked files. The only changed pre-existing file is the authorized
`python/src/yeokcham/normalization.py`. Two paths are additional relative to that
inventory: `python/tests/test_public_composition.py` and this report. All original
M1a.1 modules/tests, M1a.2 tests/fixtures, budgets/leaf implementation, OCaml/C,
reference vectors, previous reports, D1–D4/M0, README and unrelated files retain
their initial contents and modes. Ignored data was not recursively inventoried;
builds used an external source copy, and test caches/data stayed external.

Final observed status:

```text
## main...origin/main [ahead 1]
 M python/src/yeokcham/normalization.py
 M python/tests/test_public_composition.py
?? docs/v2/implementation/M1A3_REPORT.md
```

Host: Linux 7.2.15-1-omarchy x86_64/glibc2.44; CPython3.14.8. Existing isolated
pytest9.2.0, Hypothesis6.170.17, Ruff0.17.6, mypy2.4.1 and build1.6.1 were reused.
No runtime dependency, manifest or executable entry point was added. The already
declared setuptools build requirement was installed only in temporary build
environments. No system/global dependency install, live repository IO or service
registration occurred. OCaml/Dune/opam are unavailable; no fresh OCaml suite or
original project CI is claimed. Current linked SQLite is3.54.0; the old M0 host's
3.54.1 observation is not this host's build qualification. No metadata DB was opened.

## 2. Contract gate and amendment review

**Compose: QUALIFIED_FOR_IMPLEMENTATION.**
**Replacement/general profile: QUALIFIED_CONSERVATIVE_SUBSET.**

Sources: [D4 sections5 and10–11](../D4_BLOCKER_RESOLUTION.md),
[M0 semantic reference](../m0/M0_SEMANTIC_REFERENCE.md),
[normalization reference](../m0/m1a-reference/M1A_NORMALIZATION_CONTRACT.md),
[D3 freeze](../D3_CONTRACT_FREEZE.md), D1/D2, all three preceding implementation
reports, actual package/tests and OCaml `replace_subtree`, `validate_decision`,
`merge_resolved` in `lib/yeokcham_v1_composition/yeokcham_v1_composition.ml`.
Those older documents and all normative byte expectations remain unchanged.

| M1a.2 amendment | Original ambiguity resolved / consistency | Recommendation and limitation | Regression evidence |
| --- | --- | --- | --- |
| Exact participating subtree context | A parent entry alone omitted child contributors; D4 requires whole scope | Keep logical binding in eventual profile; future path-domain representation remains open | Original parent/delete/child matrix; new disjoint and nested-scope cases |
| Context-only rejected lineage | Considering a variant falsely implied inclusion | Keep; literal parents are comparisons only; historical choices copy comparisons | S20; rejected-side continuation for all six replacement shapes |
| Minimal structural roots | Pathwise successes could leave orphan children | Keep canonical byte-ordered minimal roots; nonminimal/overlapping choices refuse | Existing six parent/existing-child regressions and new literal scope negatives |
| Distinct nodes plus edges | DFS/BFS physical visits disagreed on acceptance threshold | Keep logical rule as local reference proposal; numeric ceilings need usability review | Old four-path65796/actual65800 tests, diamond14/13, new987000/default1M refusal |
| Per-path/subset once | Cache hits granted different work allowances | Keep canonical query schedule, independent of physical cache | Cache/permutation properties; exact nested `(depth+1)^2` boundaries |
| Entire supplied fact batch bound | Pending inspection otherwise unbounded | Keep prototype guard; do not silently promote over D4's actual-closure limit | Existing fact-bound negatives; large unrelated batches may refuse early |
| Cumulative payload and hunk memo accounting | Repeated allocations hid behind logical alignment charge | Keep local bound; public profile must explicitly specify it | Existing memo/retention negatives; new payload/large-binary checks |
| Typed unsupported outcomes | Missing semantics could escape as a successful proposal | Keep; distinguish unsupported domain expansion from corrupt context | Compose profile/role/cycle failures; new-path/output-claim/domain tests |

No amendment weakens preservation, scope or private/public separation. Some
conservatively refuse valid work. These are local in-memory rules, not approval
to advertise a final public normalization profile or allocate wire fields/domains.

Independent Phase A reconstructed all22 M0 projections with the prior report's
separate exhaustive binary-tree oracle and leaf transcription. It checked exact
Compose bytes, comparison-parent lineage, six literal shapes, rejected-side
continuation, equal-result/incomparable comparisons and DFS/BFS cardinalities.
This is finite reference evidence, not fresh OCaml runtime qualification or proof.

## 3. Inline public basis

[normalization.py](../../../python/src/yeokcham/normalization.py): `Compose`,
`Fact.basis`, `_Engine._dependencies`, `prepare`, `compose`.

```text
Compose(accepted: tuple[RecordId,...], selected: tuple[RecordId,...],
        claimed: Tree, resolutions: tuple[Resolution,...], profile=PROFILE)
Fact.basis = exact RecordId | Compose | None
```

A raw basis ID must resolve to a valid required public fact. Inline accepted
inputs must be genesis/accepted; inline selected inputs must be candidates.
The expression is owned by its enclosing candidate. It is not a `Fact(kind=compose)`,
accepted head, workspace or separately selected change. No new wire bytes, signed
record type, signature domain or persistent origin identity was created.

Dependency closure includes every recipe accepted/candidate input and its public
proof/content dependencies, plus any enclosing evolution predecessor. Selected
outputs contain only the outer request's exact selections; recipe dependencies
remain dependencies. Missing facts are Unavailable; cycles/role/shape violations
are InvalidContent. A private-kind dependency is rejected; actual public eligibility,
ID authentication, repository scope and content-closure admission remain caller
preconditions, not simulated signing authority in this library.

Recipes use the same normalizer and shared request counter. The exact result must
equal `claimed`, or IntegrityFailure. Inner conflicts, ambiguous comparisons,
nonconfluence, unsupported profiles and budgets propagate without an outer tree.
Dependencies evaluate iteratively in canonical raw-ID postorder; input IDs and
paths canonicalize. Receipt order is not a winner.

An inherited path keeps its input origin. A multi-frontier inline result uses
`OriginKey(enclosing_record, "basis", path)` with all maximal material parents.
The candidate's own changed path uses the distinct `"result"` slot, parented by
its exact basis origin. Equal bytes never equate two owners or basis/result slots.
Two equal-byte inline joins can still have multiple incomparable recorded
comparisons and require ChoiceRequired(comparison); no equality shortcut hides it.

Nesting is through exact candidate references whose bases contain recipes, as in
D4's accepted/candidate-input grammar. Arbitrary expressions are not record IDs.
Each recipe adds one expression level: an enclosing candidate's depth is
`max(input_depth+2, evolution_predecessor_depth+1)`. An evolution-only predecessor
does not gain a fictitious basis edge. Existing depth256, facts4096, fanout64,
selection64 and all other limits remain; cycles/depth refuse before origins/search.
No recursive AST execution or unbounded new expression store exists.

**S13:** inline `Compose(S0,{A1,Y1},claimed=T11)` in CQ produces exactly
`f.txt=b"x=1\ny=1\n"`, `c.txt=b"composed\n"`. CQ:f inherits CQ's basis-slot
join with parents A1:f/Y1:f. A1/Y1 are not separately selected. Selecting A1 again
does not apply it twice. A2/B2 stay independent pending alternatives when supplied.

## 4. Replacement and comparison contract

`Resolution` now has explicit local `intent` (`variant`, `literal`, `comparison`)
and profile fields. Default variant choices retain their old behavior. Supplying
replacement bytes without explicit literal intent still refuses. All forms bind
the exact context: minimal byte path, accepted/selected IDs, complete scoped source
views/frontiers and uniquely verified per-path recorded comparisons.

- `variant`: copies an exact participating input's whole scoped lineage.
- `literal`: requires a complete immutable replacement subtree. Missing payload is
  Unavailable; `()` is explicit deletion. Root/children/modes/raw bytes/empty dirs
  are exact. Every covered queried path, including absence, gets a new owner-slot
  origin parented **only** by that path's unique comparison origin. Equal bytes
  do not invent ancestry from rejected variants or erase the new decision.
- `comparison`: explicitly copies the verified historical comparison origins and
  their contents. It does not infer that choice from byte equality.

The supported literal path domain is the union of trees in the exact accepted/
selected **input dependency closure**, including public historical/proof facts.
An output's claimed tree, unrelated supplied facts or the literal itself cannot
bootstrap this domain. Replacement bytes may be new; entirely new descendant
names absent from that input domain refuse `unsupported-new-path-resolution`.
This is an explicit remaining limitation, not a full novel-path merger.

Complete nested subtrees include their scoped root and all descendants, not
ancestors outside the scope. Internal missing/file ancestors refuse; outside
ancestors remain unchanged and are checked in final whole-tree validation. No
implicit parent synthesis or out-of-scope deletion occurs.

A later child can expand the query domain beneath a previously frozen resolution.
The current prototype has no final reusable sparse-absence encoding. If the old
context matches exactly after removing newly queried, universally genesis-absent
paths, return ChoiceRequired(`unsupported-resolution-domain`), not false corruption
or Ready. Other changed context/comparison claims remain IntegrityFailure. This
recognition **only refuses**; it never validates incomplete context as usable.

| Qualified cases | Outcome and lineage |
| --- | --- |
| Regular/executable/symlink literal | Exact raw value/mode; comparison-only new origin |
| Directory with several known children; empty directory | Exact subtree; outside u preserved |
| Explicit deletion with neither variant absent | Exact scoped absence, comparison-only origins |
| Parent replacement versus child edit | Whole minimal subtree decision, no orphan descendants |
| Disjoint literal scopes | Both choices applied; outside work unchanged; permutation/cache equality |
| Nested scope location | Outside ancestor retained; this is distinct from overlapping decisions |
| Historical comparison choice | Exact historical contents/origins, distinct from equal-byte literal |
| Retained rejected variant and later continuation | Original facts remain; all six tested literal shapes conflict with the competing later edit |
| Wrong comparison/stale context | IntegrityFailure, no tree |
| Missing/malformed/outside replacement | Unavailable or InvalidContent, no tree |
| Duplicate/overlapping/nested independent decisions | InvalidContent, no tree |
| Unused scope/profile/budget | Exact typed invalid/unsupported/budget refusal |
| New names, self-supplied output domain, later domain expansion | Explicit ChoiceRequired, no tree |
| Ambiguous/nonconfluent inner result | Cannot be overridden by a guessed literal |

A Ready result is a complete structurally valid **pure proposal**, never
publication/acceptance authority. Failed paths never escape as a partial tree.

## 5. Semantic and TDD evidence

The original279 tests are unchanged. In particular, the old synthetic
`Fact(kind="compose")` negative remains negative; the new M0 adapter translates
fixture label Q into CQ's actual inline recipe instead of admitting Q as a record.
No normative expected bytes were changed. All22 new M0 public/conditional tests
assert their original expected status/tree:15 Ready,5 Conflicted,1 ChoiceRequired,
1 Stale. S01–03 are pure preservation/pending projections, S16 only public/conditional
behavior, and S18 supplied head-fingerprint checking; they are not network/private
history/filesystem transaction tests. Original D3 A2/Z1 and six nonconfluence
permutations remain green.

| Stage | Actual evidence |
| --- | --- |
| Fresh baseline |279 passed,62.74s; old implementation before new code |
| Initial RED |52 failed: missing Compose or explicit resolution-intent fields; harness/import environment worked |
| First GREEN attempt |50 passed,2 failed |
| Independent fixture correction |Equal-byte Compose joins actually have ambiguous comparisons; reference reproduced refusal. Unused-scope fixture was corrected to keep its replacement inside that scope. No normative oracle changed |
| GREEN |52 passed,2.84s |
| Expanded verification |68 passed,2.31s |
| Failed refactor |Variable rename accidentally changed `resolutions`/reason strings:144 failed,8 passed; corrected. Not counted as meaningful TDD RED |
| Refactor verification |152 passed,20.07s (68 new plus84 previous normalization tests) |
| Additional resource tests |349 complete tests passed before later refusal fixes |
| Domain RED/GREEN |1 failed: legitimate new query domain classified as IntegrityFailure; explicit unsupported-domain guard added |
| Output-domain and nested-scope RED/GREEN |2 failed: an output claim bypassed the local new-path restriction; a valid nested subtree was rejected. Fixed input-domain closure and scoped validation;73 targeted tests passed |
| Depth-role RED/GREEN |1 failed: evolution-only dependency got an extra expression edge. Exact role-specific depth fixed;5 focused tests passed |
| Final complete VERIFY |**353 passed,0 failures/errors/skips**, JUnit 75.392s (pytest75.38s);195 original content +84 unchanged normalization +74 new tests |

Final Hypothesis: **469 passing examples,0 failing examples**;18 generation retries (15 codec,3 generated DAG) are not pytest skips. These are generated examples within collected
tests, not additional test cases or a proof. New properties use fixed seeds
20261121–20261124: receipt/cache permutations20, literal binary-value/selection
permutations20, bounded nested histories15, exact budget boundaries15. Previous
399 examples retain their existing profiles. Generated invalid candidates/retries
are reported by Hypothesis, not silently counted as skipped tests.

Ruff lint/format pass over13 Python files; strict mypy passes8 source modules.
Source/wheel build, local no-dependency wheel installation and outside-checkout
`python -I` Compose/literal smoke pass, with no executable entry point. An initial
`--no-isolation` build failed because the reused test environment has no setuptools;
the declared backend was then built in isolated temporary environments. One
packaging-driver syntax error was corrected; neither is semantic RED evidence.

No fresh OCaml, original full CI, native IO, process-kill storage, signing or
power-loss test ran. The copy-out issue remains unresolved and undiagnosed.

## 6. Resource and memory qualification

Logical charge remains `|distinct recorded ancestor nodes| + |distinct material
edges|` once per `(raw path, canonical original-origin subset)` request query.
Recipe validations share the counter/query set with accepted validation and final
composition. Repeated facts/ancestors within one closure deduplicate; different
paths/subsets still charge. Temp outputs are not recorded comparison ancestors.
All numeric limits and budget-failure ordering are unchanged. Literal origin and
payload allocation use the existing counters, and recipe count/depth/fanout checks
precede dependency expansion/search. Input path-domain inspection is bounded by
the already validated graph/path limits and does not create material edges/charges.

Independent diamonds have6 nodes/8 edges: exact14 succeeds,13 refuses under both
DFS/BFS set semantics. Nested linear recipes have costs1,3,...,2d+1, totaling
`(d+1)^2`; exact and one-below tests agree for cache on/off. Existing four-path
65796/actual65800 boundaries remain green.

Representative measurements below are separate fresh Linux processes, process
peak RSS in KiB including interpreter/import/input memory. Deterministic fixtures
use no random generator; property seeds are above. Elapsed times are observations, not comparative benchmarks. The first table was
rerun against the final tested source, SHA-256 `9c55b2a95a969abe3cba105dff281ab51e2f62771b691bd91984b8d81b6e6243`.

| Workload | Outcome / budget | Elapsed seconds | Peak RSS KiB |
| --- | --- | ---: | ---: |
| linear256 | Ready  | 0.023084 | 21160 |
| linear257 | ChoiceRequired depth | 0.010121 | 20740 |
| compose128 | Ready  | 0.234369 | 20944 |
| compose129 | ChoiceRequired depth | 0.008273 | 20620 |
| wide6 | Ready  | 0.03898 | 20908 |
| wide7 | ChoiceRequired frontier | 0.0021 | 20884 |
| binary6MiB | Ready  | 0.007628 | 26996 |
| binary9MiB | ChoiceRequired retained_path | 0.011701 | 30156 |
| alignment1999 | Conflicted  | 2.474413 | 34864 |
| alignment2000 | ChoiceRequired cells_alignment | 0.000845 | 20640 |

At frontier6, all63 subsets/301 partitions are checked; frontier7 refuses before
subset/pair work. A 127-edit prefix plus6 equal-result tips costs16450 units/path,
including the target singleton.60 paths =>987000;61 would require1003450 and
refuses early at999752 accumulated units. Cache on/off report the same charges,
status and no partial tree on refusal. These longer runs preceded the final
context/domain/depth-role corrections (source digest `2dee88110aa37aa9b78ae9f125bde1bbf4475342bc0b2e1fb082357fa4fb5b94`). Their inputs contain no resolution or Compose evolution-only predecessor,
so semantic paths are unchanged, but final-process RSS was not remeasured for
these long runs; dependency-map lifetime can affect memory:

| Paths / ancestry cache | Outcome / units charged | Elapsed seconds | Peak RSS KiB |
| --- | --- | ---: | ---: |
| 60 / on | Ready / 987000 | 12.60442 | 55548 |
| 60 / off | Ready / 987000 | 65.697134 | 25000 |
| 61 / on | ChoiceRequired / 999752 | 7.941822 | 54488 |
| 61 / off | ChoiceRequired / 999752 | 71.97361 | 23872 |


The full alignment case allocates at most4M cells at a time and charges8M across
two distinct pairs;2000 lines requests4004001 cells and refuses before allocation.
No full16M/path/64M/request alignment saturation,32-state worst-case,65k-origin
peak, physical power-loss or cross-platform RSS qualification is claimed. Existing
small-limit pair/alignment/memo/state/payload/fanout/cycle tests remain relevant.

**Product risk:** linear depth257,129 nested recipe levels, a9MiB scalar payload,
or six long frontiers over61 paths can refuse despite valid data. The reference
profile is not yet qualified as an everyday product default. The raw-object
streaming support in M1a.1 is unchanged; this flattened pure normalization model
is not general large-asset acceptance. Recommend a separately reviewed profile/
proof-reuse and lazy-content investigation with retained-history benchmarks;
do not silently raise ceilings, discard history or let cache choices decide
acceptance. No Git/jj performance comparison or superiority claim is made.

## 7. Private catch-up: design only

No general divergent private catch-up was implemented. Existing `preserve_private`
remains the conditional K==D helper. Minimal future contract:

1. Keep exact accepted public target D, known-present public projection K, private
   capture identity/ancestry and later observed E separate. Snapshot equality is
   not correspondence. K contains only proven selected public path values/absences,
   never an entire private snapshot or secret paths.
2. Publication correspondence binds the exact revision, source capture, public
   basis/result/scope and per-path/absence/Merkle witnesses. Prove that source is
   an ancestor of the private occurrence being preserved. Rejected/context-only
   contributions do not establish that K is represented.
3. If K==D, preserve exact E (the S16 case) after those proofs. Otherwise compute
   a separate private proposal from K,D,E. Public normalization never consults E.
   Overlap needs explicit private decisions bound to all three exact snapshots,
   correspondence, occurrence and observation; ambiguous ancestry/witnesses refuse.
4. Acceptance of public D does not publish or discard E. A new private history
   position preserves E or the explicitly resolved private continuation, its
   provenance and alternate positions. Later publication requires fresh scoped
   correspondence from that preserved occurrence; an old receipt is insufficient.
5. Interrupted preservation needs durable intent, safety/target/displaced roots,
   native observations, byte checks and recovery ownership. Later external edits
   must remain distinguishable; no blind replay/rollback or stale acceptance.

| Proof/state owner | Required future responsibility |
| --- | --- |
| M1b | Typed capture/workspace identity, immutable parent/snapshot binding, transactional cursor/request/root ownership; does not manufacture publication correspondence |
| M2 | Real capture ancestry/observations, filesystem safety, durable recovery and preservation of later external edits |
| M4 | Public admission plus private publication correspondence/path witnesses; exact public closure and authority/privacy checks |
| M5 | Exact accepted-head/policy/review plan binding, separate private proposal/decisions, safe materialization and atomic acceptance/private-history/root transfer |

This workflow is not an artificial prerequisite for isolated private M1b storage.

## 8. Complexity, limitations and M1b handoff

Only one production file changed. Added one immutable inline expression, explicit
resolution intent/profile and derived dependency/path queries; no new hierarchy,
persistent origin store, parallel domain, storage/wire codec, runtime dependency
or orchestration layer. Existing byte leaf/budget implementations are reused.
Recipe and accepted validation use the same composition engine/counter. Local
facts are not authenticated public schemas or API permission capabilities.

Remaining unsupported: new descendant-name/domain expansion, overlapping/nested
independent resolutions, guessed/ambiguous comparison overrides, general private
catch-up and all storage/publication/transport/application/services. Large-history
and payload limits remain substantial. Missing or corrupt prerequisites never
mean absence; no typed refusal is treated as Ready or committed acceptance.

**M1b readiness: BLOCKED for production start by its own unclosed gates.**
Content compatibility and this qualified public subset allow an independent
private-store contract/readiness task now. Neither full public composition nor
divergent private catch-up needs to be finished before private storage. However,
[D4 sections10–11](../D4_BLOCKER_RESOLUTION.md) and
[M0 O04/O05/O07/O08](../m0/M0_SAFETY_AND_TRANCHE_GATES.md) still require:

- Exact restricted production DDL/schema/application/version ownership, complete
  immutable-field/root-kind/release/cursor/capture-sequence/exhaustion constraints.
  D3 feasibility DDL is not that freeze. Define which controls are supported;
  no opaque plan/public/action placeholders may become valid durable rows.
- Exact private request/idempotency arguments/results and pending/uncertain COMMIT
  recovery. Same key/different intent refuses; original identities remain authoritative.
- Concrete object publication/file+directory sync/root-COMMIT ordering, shared/exclusive
  publication/reader/collector gates and lock order; no SQL FK/Boolean substitutes
  for durable verified external bytes. Even with GC disabled, ownership intervals
  and concurrent readers/publishers need explicit protection.
- CPython/SQLite/VFS/build/locking/flush allowlist and disposable multiprocess
  IOERR/FULL/BUSY/kill/uncertain-response/root-transfer fault fixtures and independent
  inspectors. Host version presence alone does not close these gates.
- Initially keep GC/eviction off until quarantine/purge/reachability controls and
  their tests qualify. Defer canonical public controls, signing, native action/
  plan bytes and filesystem application; close O05 only for controls actually used.

Recommended next action: a **M1b private-store contract freeze/readiness gate**,
plus separately scoped M1a public-profile follow-up for stable absence domains
and realistic history/large-asset bounds. Do not begin implementation merely
because pure tests pass. The old copy-out failure is still an M2/parity concern,
not a newly invented dependency on private SQL storage.

## 9. Reproduction and evidence

```sh
task_tmp=$(mktemp -d)
python3 -m venv "$task_tmp/env"
"$task_tmp/env/bin/python" -m pip install -e './python[test,dev]'
PYTHONDONTWRITEBYTECODE=1 HYPOTHESIS_STORAGE_DIRECTORY="$task_tmp/hypothesis" \
  "$task_tmp/env/bin/python" -m pytest python/tests -p no:cacheprovider \
  --basetemp="$task_tmp/tests" --hypothesis-show-statistics \
  --junitxml="$task_tmp/results.xml"
"$task_tmp/env/bin/ruff" check --no-cache python
"$task_tmp/env/bin/ruff" format --no-cache --check python
"$task_tmp/env/bin/mypy" --config-file python/pyproject.toml \
  --cache-dir "$task_tmp/mypy" python/src
cp -R python "$task_tmp/package"
"$task_tmp/env/bin/python" -m build "$task_tmp/package" --outdir "$task_tmp/dist"
python3 -B tools/check_doc_links.py
git diff --check
```

The actual full command used the existing `/tmp/yeokcham-m1a1-env/bin/python`;
`complete.log` and `complete.xml` record the final run. Build used an external
filtered copy and temporary build/wheel environments; installed source bytes
match the final source. No runtime dependency was installed into system Python.


All final listed verification commands exited0. Test-failure stages above remain
part of the record. External logs/scripts/JUnit/distributions are supplemental:
`/tmp/yeokcham-m1a3-4876seid/`. They need not survive for ordinary package tests.
The independent qualification and memory scripts are reproduced below so future
reviewers can recreate the finite experiments without this chat. Extract the
prior report's `reference.py` Python block into the same external directory, copy
`python/tests/normalization_cases.py` there as `fixtures.py`, then run the new
qualification script from repository root. It imports no production normalizer.
Resource scripts use the real Python package via `PYTHONPATH=python/src`, one new
process per listed workload. No reference expected value is generated by the
function under test. No symbolic result is a universal correctness proof.


### Independent finite qualifier

```python
"""Independent finite reference; no production engine imports."""
import itertools,json
from reference import Ref,F,D,prefix,invalid
from fixtures import FACTS,CASES,T,f,g
paths={p for row in FACTS for p in row[3]}
r=Ref(paths)
roles={row[0]:row[1] for row in FACTS}
for name,role,inputs,expected,previous,scope,choices in FACTS:
 if role=='genesis':continue
 if role=='candidate':r.candidate(name,inputs[0],expected)
 else:r.accepted(name,inputs,expected,choices)
for case,targets,selected,status,expected in CASES:
 actual=('Stale',None,None) if case=='S18' else r.run(targets+selected)
 assert actual[:2]==(status,expected),(case,actual)
# Inline Q has basis-slot ownership in CQ; it is not an accepted identity.
old=r.views['Q'][f]
assert r.parents[old]==r.maximal((r.views['A1'][f],r.views['Y1'][f]))
assert r.values[old]==F(b'x=1\ny=1\n')
# Independent literal rule: unique recorded comparison, one new origin per path.
def literal(q,owner,inputs,root,replacement):
 assert not invalid(replacement)
 assert all(prefix(root,p) and p in q.paths for p in replacement)
 view={}
 for p in q.paths:
  if not prefix(root,p):continue
  common=set.intersection(*(q.closure((q.views[v][p],)) for v in inputs))
  maxima=q.maximal(common)
  assert len(maxima)==1
  key=(owner,p);q.parents[key]=maxima;q.values[key]=replacement.get(p);view[p]=key
 return view
pd=(b'd',);pf=pd+(b'f',);pg=pd+(b'g',);u=(b'u',)
q=Ref({pd,pf,pg,u})
base={pd:D,pf:F(b'old'),pg:F(b'g-old'),u:F(b'old-u')}
q.candidate('base','G',base)
q.candidate('A','base',{pd:F(b'file'),u:F(b'old-u')})
q.candidate('B','base',{**base,pf:F(b'edit'),u:F(b'new-u')})
assert q.run(('A','B'))[0]=='Conflicted'
replacements=[{pd:F(b'literal')},{pd:F(b'run',1)},{pd:F(b'../raw\xff',2)},
 {pd:D,pf:F(b'new'),pg:F(b'other')},{pd:D},{}]
for i,rep in enumerate(replacements):
 view=literal(q,'literal'+str(i),('A','B'),pd,rep)
 assert {p:q.values[o] for p,o in view.items() if q.values[o] is not None}==rep
 for p,o in view.items():
  assert q.parents[o]==(q.views['base'][p],)
  assert q.views['A'][p] not in q.closure((o,)) or q.views['A'][p]==q.views['base'][p]
  assert q.views['B'][p] not in q.closure((o,)) or q.views['B'][p]==q.views['base'][p]
# Equal bytes do not infer ancestry; two owners have distinct literal origins.
a=literal(q,'L1',('A','B'),pd,replacements[0]);b=literal(q,'L2',('B','A'),pd,replacements[0])
assert a[pd]!=b[pd] and q.values[a[pd]]==q.values[b[pd]]
# Set cardinalities define charge independently of traversal/caching.
parents={0:(),**{i:(i-1,) for i in range(1,128)},**{i:(127,) for i in range(128,134)}}
def closure(roots,bfs):
 todo=list(roots);nodes=set();edges=set()
 while todo:
  n=todo.pop(0 if bfs else -1)
  if n in nodes:continue
  nodes.add(n)
  for p in parents[n]:edges.add((n,p));todo.append(p)
 return len(nodes)+len(edges)
charges=[sum(closure(s,bfs) for k in range(1,7) for s in itertools.combinations(range(128,134),k))*4 for bfs in (False,True)]
assert charges==[65796,65796]
print(json.dumps({'gate':'QUALIFIED_CONSERVATIVE_SUBSET','m0_groups':22,'literal_shapes':len(replacements),'logical_units':charges,'exclusions':['new descendant path absent from required fact trees','overlapping choices','ambiguous comparison override'],'scope':'finite symbolic values and lineage, not trust/storage/IO'},indent=2))
r.accepted('Q-other',('S0','A1','Y1'),T(1,1))
r.candidate('CQ-other','Q-other',{**T(1,1),(b'c.txt',):F(b'composed\n')})
assert r.run(('S0','CQ','CQ-other'))[0]=='ChoiceRequired'
print('Equal Compose payloads with incomparable recorded comparisons: ChoiceRequired')
for i,rep in enumerate(replacements):
 name='literal'+str(i)
 scoped={p:o for p,o in q.views['B'].items() if not prefix(pd,p)}
 scoped.update({p:(name,p) for p in q.paths if prefix(pd,p)})
 q.views[name]=scoped
 q.candidate('later-B','B',{**base,pf:F(b'later'),u:F(b'new-u')})
 assert q.run((name,'later-B'))[0]=='Conflicted'
print('All six literal shapes versus rejected-side continuation: Conflicted')
# A complete subtree includes its root and descendants, not ancestors outside scope.
nested_root=(b'parent',b'leaf')
rep={nested_root:F(b'literal')}
assert not {p for p in invalid(rep) if len(p)>=len(nested_root)}
assert invalid(rep)=={(b'parent',)}
print('Nested scope: ancestor outside replacement remains an outside-tree obligation')
```

SHA-256: `42a11e2b04f3895c4538c002c41debd96953bc9eb667f77edf3a43f65814d5ff`.

### Bounded memory workloads

```python
"""One fresh process per bounded workload; no repository or filesystem VCS IO."""
import hashlib,json,resource,sys,time
from dataclasses import asdict
from yeokcham import normalization as n
from yeokcham.composition import merge_bytes
from yeokcham.normalization_budget import Counter,Limits,BudgetExceeded
from yeokcham.identities import RecordId

def rid(s):return RecordId(hashlib.sha256(s.encode()).digest())
f=(b'f',)
def tree(data):return n.tree({f:n.Node(n.Mode.REGULAR,data)})
mode=sys.argv[1];start=time.perf_counter();g=n.Fact(rid('G'),'genesis',());facts=[g];extra={}
if mode in ('linear256','linear257','compose128','compose129'):
 count=int(''.join(c for c in mode if c.isdigit()))
 for i in range(count):
  prior=facts[-1]
  basis=n.Compose((g.identity,),() if i==0 else (prior.identity,),prior.tree) if mode.startswith('compose') else prior.identity
  facts.append(n.Fact(rid(str(i)),'candidate',tree(str(i).encode()),basis=basis,scope=(f,)))
 a=n.normalize(facts,(g.identity,),(facts[-1].identity,),cache=False)
 b=n.normalize(list(reversed(facts)),(g.identity,),(facts[-1].identity,),cache=True)
 assert a==b
 expected='ChoiceRequired' if mode in ('linear257','compose129') else 'Ready'
 assert a.status==expected
 result={'status':a.status,'charge':asdict(a.charge),'budget':None if a.budget is None else asdict(a.budget)}
elif mode.startswith('wide'):
 count=int(mode[4:]);base=n.Fact(rid('base'),'candidate',tree(b'0'),basis=g.identity,scope=(f,));facts.append(base)
 tips=[]
 for i in range(count):
  v=n.Fact(rid('tip'+str(i)),'candidate',tree(b'1'),basis=base.identity,scope=(f,));facts.append(v);tips.append(v.identity)
 expr=n.Compose((g.identity,),tuple(tips),tree(b'1'))
 v=n.Fact(rid('outer'),'candidate',tree(b'1'),basis=expr);facts.append(v)
 a=n.normalize(facts,(g.identity,),(v.identity,),cache=False);b=n.normalize(facts,(g.identity,),(v.identity,),cache=True)
 assert a==b and a.status==('Ready' if count==6 else 'ChoiceRequired')
 result={'status':a.status,'charge':asdict(a.charge),'budget':None if a.budget is None else asdict(a.budget)}
elif mode in ('binary6MiB','binary9MiB'):
 size=(6 if mode=='binary6MiB' else 9)*1024*1024
 data=bytes(range(256))*(size//256)
 v=n.Fact(rid('binary'),'candidate',tree(data),basis=g.identity,scope=(f,))
 a=n.normalize([g,v],(g.identity,),(v.identity,))
 assert a.status==('Ready' if size==6*1024*1024 else 'ChoiceRequired')
 if a.tree is not None:assert dict(a.tree)[f].data==data
 result={'status':a.status,'charge':asdict(a.charge),'budget':None if a.budget is None else asdict(a.budget)}
elif mode in ('alignment1999','alignment2000'):
 size=int(mode[9:]);base=b'base\n'*size;left=b'left\n'*size;right=b'right\n'*size
 c=Counter(Limits())
 try:
  assert merge_bytes(base,left,right,counter=c,path=f) is None
  result={'status':'Conflicted','charge':asdict(c.snapshot())}
  assert size==1999 and c.cells==8_000_000
 except BudgetExceeded as e:
  assert size==2000 and e.dimension=='cells_alignment'
  result={'status':'ChoiceRequired','dimension':e.dimension,'charge':asdict(c.snapshot())}
else:raise ValueError(mode)
result.update(workload=mode,seconds=round(time.perf_counter()-start,6),peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
print(json.dumps(result,sort_keys=True))
```

SHA-256: `ccc04c27735ab2b1a4c11166a3352b57b97457f580453c515be4df72ff541a55`.

### Near-limit long-frontier workload

```python
import hashlib,json,resource,sys,time
from dataclasses import asdict
from yeokcham import normalization as n
from yeokcham.identities import RecordId

def rid(s):return RecordId(hashlib.sha256(s.encode()).digest())
count=int(sys.argv[1]);cache=sys.argv[2]=='on';start=time.perf_counter()
paths=[(str(i).encode(),) for i in range(count)]
def tree(data):return n.tree({p:n.Node(n.Mode.REGULAR,data) for p in paths})
g=n.Fact(rid('G'),'genesis',());facts=[g]
for i in range(127):facts.append(n.Fact(rid('prefix'+str(i)),'candidate',tree(str(i%2).encode()),basis=facts[-1].identity,scope=tuple(paths)))
base=facts[-1];tips=[]
for i in range(6):
 v=n.Fact(rid('tip'+str(i)),'candidate',tree(b'2'),basis=base.identity,scope=tuple(paths));facts.append(v);tips.append(v.identity)
r=n.normalize(facts,(g.identity,),tuple(tips),cache=cache)
assert r.status==('Ready' if count==60 else 'ChoiceRequired')
if count==60:assert r.charge.ancestor_units==987000
else:assert r.budget.dimension=='ancestor_units' and r.tree is None
print(json.dumps({'paths':count,'cache':cache,'status':r.status,'charge':asdict(r.charge),'budget':None if r.budget is None else asdict(r.budget),'seconds':round(time.perf_counter()-start,6),'peak_rss_kib':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss},sort_keys=True))
```

SHA-256: `fe8f7c518498756382e92d3258d9aee98f16e2269dea9fd9204cffbc1c983018`.

Run the resource driver in separate processes, for example:

```sh
PYTHONPATH=python/src python3 -B EXTERNAL/resources.py compose128
PYTHONPATH=python/src python3 -B EXTERNAL/resources.py alignment1999
PYTHONPATH=python/src python3 -B EXTERNAL/long_frontiers.py 60 on
PYTHONPATH=python/src python3 -B EXTERNAL/long_frontiers.py 61 off
```

Other resource arguments are the workload names in the table. Each script asserts
its exact expected outcome; an exception/nonzero exit is not a successful result.
The full final suite and checks are the primary package verification, not these
supplemental traces. No M1b or later tranche was implemented.

**M1a.3 completed to the extent verified. No later tranche was authorized.**
