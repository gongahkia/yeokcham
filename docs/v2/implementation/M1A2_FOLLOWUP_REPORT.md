# M1a.2 follow-up: contract repair and gated implementation

Date: 2026-11-21, Singapore.

**Outcome: PARTIAL. Qualification: QUALIFIED_CONSERVATIVE_SUBSET.**

The supported pure engine is implemented and tested. This is deliberately not a
complete D4 consumer: inline PublicBasis.Compose, literal subtree replacements,
arbitrary comparison-base/deletion choices and divergent private catch-up remain
unsupported. They cannot escape as Ready. No M1b or later work was started.

## 1. Source, initial state and preservation

Observed initial HEAD: `d4cfc740d6a84625b464c6937bcaea2734d47236`.
Final HEAD: `3b100cbcfc7a8172f6b5bdbd55ec646a8d8312ba`. External commits
`fdbc4a2` and `3b100cb` incorporated intermediate versions of this work during
the run. They were left intact. No commit or staging command was issued by this
agent. Final tested source bytes also match the separately installed final wheel.
Initial status on `main...origin/main` contained exactly the untracked earlier
`docs/v2/implementation/M1A2_REPORT.md`. That report is preserved literally; it
was not overwritten or removed by this agent. No tracked or staged changes were
present initially. The external first commit tracked that report unchanged.
No fetch, commit, push, branch switch, reset, cleanup or Git write was issued by
this agent.

The initial SHA-256/mode inventory covers **544** tracked/nonignored untracked
files. All remain unchanged, including the earlier untracked report, M1a.1 source/
tests, RFCs, references, goldens, README, research and implementation ledgers.
This assignment adds three production modules, two test files and this report.
No existing source, test, manifest or reference document was changed. Ignored
packaging/cache data was not recursively inventoried; new build/test outputs are
external, apart from ordinary ignored Python build metadata under `python/`.

Host: Linux 7.2.15-1-omarchy x86_64/glibc 2.44, CPython 3.14.8. Existing isolated
M1a.1 tools were reused; no new runtime/test dependencies or global installs.
OCaml/Dune/opam are unavailable on PATH. Python 3.13, other hosts, native IO,
physical power loss and full project CI are not freshly qualified here.

## 2. Evidence and qualification chronology

The prior M1a.2 report, M1a.1 report/package/tests, D4, M0 semantic cases,
normalization/closure references, frozen observations, and relevant OCaml
`line_hunks.ml`, `tree`, `merge`, `merge_resolved`, `validate_decision` and
`replace_subtree` informed this work. Existing D1–D3/technical contracts retain
precedence except the explicitly proposed local amendments below.

Before production normalization modules existed, an external exhaustive binary-
tree oracle independently reconstructed the 22 M0 case groups' public projections,
the D3 regression, six nonconfluence permutations, scoped structural choices,
context-only rejected lineage and DFS/BFS closure cardinalities. Test fixtures
were hand-authored from the normative byte literals, not generated from production
outputs. Descriptive JSON repr strings were not treated as raw-byte encodings.
The S16 private merge and S18 freshness subcases are conditional pure checks;
they are not signature, correspondence, metadata or filesystem experiments.

This qualified a conservative subset, not a universal proof or full profile.
The legacy four-path source embedded in the earlier report was inspected and
freshly replayed during verification (29 assertions, unchanged old charges).
Further safety review found and repaired missing accepted-empty-history checks,
symlink type/edit handling and lifting of conflicted existing children. Independent
reference checks were strengthened for the latter before its production fix;
no normative expected bytes were changed to match production. The S16 test fixture
was also tightened to use its distinct P candidate and exact basis, and per-case
known sets/pending assertions were added.

Qualification labels:

| Area | Disposition and scope |
| --- | --- |
| Exact existing-variant subtree choice/context | CLOSED_BY_SPECIFICATION locally; independently reference-verified on the finite structural matrix; production tests pass |
| Logical ancestor cardinalities and required query schedule | CLOSED_BY_SPECIFICATION locally; independent set/reference checks, old diagnostic replay and actual-request exact boundaries pass |
| M0 public projections / D3 / nonconfluence | Independently reference-verified; production supports the projections listed below, not all surrounding VCS operations |
| Literal replacements, inline Compose, divergent private projection | OPEN / explicitly excluded from supported subset; typed refusals tested |
| Default-cap memory/RSS, huge histories and general principal/correspondence proofs | REQUIRES_RUNTIME_QUALIFICATION or later-tranche proof; not certified by unit tests |

## 3. Exact conservative subtree contract

A logical input tree is complete, immutable, byte-path ordered and structurally
valid. Directory, regular, executable and symlink entries remain distinct. A
missing required fact is Unavailable; a missing path in a validated complete tree
is Absent. One must not be substituted for the other.

Per-path normalization retains all original target/selection origins and reduces
only verified material ancestors. Whole-tree validation then finds minimal conflict
roots. **A conflicted child is lifted through an absent/file-valued tentative
ancestor even when no child value was produced.** Checking successful tentative
paths alone misses parent-deletion versus existing-child-edit cases.

Without a resolution, return Conflicted with exact scoped contexts and no tree.
For ambiguous comparisons or nonconfluence, return ChoiceRequired with no tree;
resolutions do not bypass those refusals in this subset.

A context binds:

1. The exact minimal conflicting byte-component path.
2. Canonical accepted target IDs and selected candidate IDs, separately.
3. Every exact original source view over the scoped path closure, including
   absent descendants. An unchanged directory is not permission to drop its
   source's changed descendants.
4. Every material frontier participating under that root.
5. Exact recorded comparison origins. Whole-source scope dominance is checked
   across every path before computing those comparisons; mere parent-value
   dominance cannot discard a source with an independent child contribution.

`Resolution(context, choose=INPUT_RECORD)` chooses that participating source's
complete subtree, including directory structure, modes, raw names, bytes and
absences. Chosen origins are copied per path. Rejected origins remain context-only
and retained alternatives, never material parents. Outside work composes normally.
A changed context is IntegrityFailure; an unused/out-of-context choice or malformed/
overlapping resolution is InvalidContent. Missing/invalid dependencies still refuse.

Disjoint exact conflict roots may be resolved together. Nested/overlapping scopes
refuse independent of input order. A broader ancestor that is not an actual minimal
conflict root is not silently accepted as a deletion of unrelated work.

**Exclusions:** replacement literals, novel deletion where no participating variant
is absent, and choosing historical comparison contents outside participating inputs
are not implemented. Explicit literal replacement returns
`ChoiceRequired(unsupported-literal-resolution)`. No comparison origin is invented.
This narrows D4's full resolution capability and is a proposed local amendment,
not a silent change to the established documents or a claim of full normalization.

### Structural matrix (requested cases 1–18)

| # | Case | Qualified supported outcome / tested refusal |
| --- | --- | --- |
| 1 | Delete directory versus add child | Conflicted at directory; no orphan output |
| 2 | File at d versus d/g | Conflicted at d; no file with descendants |
| 3 | Symlink at d versus d/g | Conflicted at d; link is opaque |
| 4 | Directory → file | Exact unilateral target works; concurrent child work requires scoped choice |
| 5 | Recursive subtree deletion | Exact absence retained; concurrent descendant work cannot disappear implicitly |
| 6 | Empty directory | Explicit empty directory remains distinct from deletion |
| 7 | Parent deletion/replacement versus existing child edit | Conflict lifted to parent; both exact variant choices tested |
| 8 | Choose deletion | Supported when an exact participating variant is absent; outside bytes preserved |
| 9 | Choose directory-preserving variant | Complete chosen descendants and kinds retained |
| 10 | Literal full-subtree replacement | EXCLUDED; typed ChoiceRequired and no result tree |
| 11 | Disjoint resolutions | Both apply; outside changes remain |
| 12 | Overlapping resolutions | InvalidContent before application |
| 13 | Nested parent/child resolutions | InvalidContent, not order-dependent override |
| 14 | Outside change | Independent u change survives choosing d |
| 15 | Equal bytes/distinct ancestry | Both surviving origin identities become material parents; no history collapse |
| 16 | Rejected variants | Context-only; later rejected-side continuation still conflicts where necessary |
| 17 | Invalid structure | Invalid input refuses; valid inputs with incompatible structural effects conflict before Ready |
| 18 | Ambiguous comparison | ChoiceRequired(comparison); no convenient base or chosen successful grouping |

The six existing-child-edit regressions cover delete, file and symlink parents,
choosing either side. The independent oracle also verifies those complete exact
subtree results. Symlink conversion plus concurrent content edits conflicts;
regular/executable mode changes can combine with independent regular-file bytes.

## 4. Exact local logical-charging contract

### Ancestor units and canonical query set

For a path and a nonempty original-origin subset S:

```text
A(S) = reflexive recorded material-ancestor closure
V(S) = distinct origin nodes in A(S)
E(S) = distinct (child,parent) material edges in A(S)
units(S) = |V(S)| + |E(S)|
```

Origin identity is `(exact RecordId, result/basis slot, raw path)`; equal payload
bytes are not identity. The implemented subset uses recorded result slots and
transient proposed-result slots. Proposed joins have no RecordId and cannot be
recorded comparison ancestors. No new hashed/persisted origin identity exists.

Required queries, in order:

- Process required public facts in deterministic dependency postorder, roots and
  dependencies sorted by raw RecordId bytes. Validate accepted derivations before
  using them; candidate evolution dependencies establish availability/provenance
  but only the explicit content basis creates material edges.
- Within each composition, process paths in byte-component order.
- Query singleton closures of all original target/selected origins in origin order
  for dominance, then reject frontier >6 before allocating its subset search.
- Query all nonempty surviving-frontier subsets in increasing cardinality then
  lexicographic origin order. For each subset, enumerate unordered proper partitions
  with its minimum origin in the left side, increasing left cardinality and origin
  tuple; state pairs use Absent/Directory/File(mode,length,bytes) order.
- Common comparisons use intersections of already required subset closures; maximal
  recorded common nodes are those not parented by another common node. Temporary
  outputs never become bases. Scoped context checks reuse singleton queries.

A `(path, canonical S)` query is charged **once per request**, including accepted-
fact validations and the final proposal. Repeat queries charge zero by definition;
cached first queries still owe the full cardinality. Different paths charge again,
even if the same records/data appear. Shared ancestors/edges deduplicate only
inside one closure. DFS and BFS return the same sets and logical units.

Closure traversal guards each new node/edge before insertion against the remaining
unit allowance. Root sequence length is bounded before copying. Standalone helper
cycles/missing nodes refuse; engine origin graphs are derived only after an iterative
acyclic public-fact validation. No recursive dependency or subset solver is used.

### Other dimensions and failure ordering

All existing numeric ceilings remain: 64 selections/direct dependencies, 4096
facts/paths, depth256/fanout64, 1MiB raw path bytes, 4096 origins/path and65536/
request, frontier6, states32/subset, pairs32768/path and131072/request,
text2MiB/input and32MiB/request, line descriptors131072/input, cells4M/alignment,
16M/path and64M/request, retained payload8MiB/path and64MiB/request.
Limits may be reduced, not silently increased. Checked signed-int64 counters
refuse overflow. No partial proposal is returned after any exhaustion.

Preflight proceeds through selector/shape bounds, bounded fact closure and dependency
validation, path/tree validation, origin derivation, singleton/frontier checks,
subset/pair/byte/line work and final structural validation. This is staged precedence,
not a claim that every invalid input is fully decoded after its budget runs out.
Within paired checks: per-path precedes request limit; alignment-specific precedes
path/request alignment limits; retained-path precedes retained-request. A structured
`BudgetRefusal(dimension,limit)` accompanies the ChoiceRequired outcome.

Alignment charge is once per exact ordered base/result byte pair per path, and once
per distinct pair for request total, with charge applied on memo hits too. LF-only
splitting and preallocation checks precede matrix allocation. Score arrays use
unsigned integer arrays. Pair calls charge even for equality or conflict. Distinct
subset values are precharged before insertion. Original frontier parents are
retained independently of which complete binary tree succeeded. All supported
complete results and ambiguity are examined; one success cannot hide another result.

### Explicit conservative amendments

- The one-million ceiling now counts the logical units above, **not** either old
  incidental visit trace. This is an explicit local profile proposal, not a
  retroactive claim that the old 624168/1301448 charges meant the same thing.
- The prototype bounds the entire supplied fact batch to4096, not just the used
  closure, so pending-inspection work is also bounded. Unrelated bytes are still
  excluded from composition. This may refuse large batches earlier than full D4.
- Origin limits conservatively cover all origins constructed while validating the
  required closure, including causal/proof dependencies, not only the final frontier.
- Retained-payload accounting is conservative/cumulative across subset tables and
  accepted-fact validations. Immutable hunk-memo payloads also consume those same
  byte allowances. This additional memo charge is a local safety amendment: it
  bounds memory while avoiding repeated expensive alignment under a once-per-pair
  logical charge. The ancestry-cache debug flag does not disable the bounded hunk
  memo. Default-cap memory/RSS and long-history usability remain unqualified.

These changes require review before any public profile advertisement. No registry,
signing domain, canonical content identity, old RFC or existing vector was changed.

## 5. Four-path diagnostic before and after

Exact graph per path: node0 has no parent; nodes1..127 each parent the preceding
node; six independent tips128..133 each parent127. Six frontier origins,134 reachable
nodes, four path-specific copies. The old602 ancestor-side queries arise from301
bipartitions across subsets.

| Measurement | Four-path amount | Decision at existing one-million ceiling |
| --- | ---: | --- |
| Old union-per-query kernel, freshly replayed | 624168 visits | Ancestor subproblem fits |
| Old per-root-per-query kernel, freshly replayed | 1301448 visits | Ancestor subproblem exceeds |
| New63 required frontier-subset closures/path | **65796 units** | Fits; DFS/BFS agree |
| Actual complete prototype request, including four target singleton queries | **65800 units** | Ready; cache on/off agree |

For each k-tip subset, the shared chain contributes128 nodes/127 edges and the
k tips contribute k nodes/k edges:255+2k. Summing over all63 nonempty subsets
is16449/path,65796 for four paths. Four target-genesis singleton queries add4.
No charge depends on physically revisiting the shared prefix.

The actual request has a validated in-memory chain and six equal-result independent
candidate tips across four files. At ancestor limit65799 it refuses with no tree;
at65800 or65801 it returns the exact four `b'2'` files. Both ancestry-cache settings
pass the same assertions. The raw old subproblem is not misreported as a complete
acceptance benchmark or a proof of global performance.

## 6. Semantic cases, reference independence and subset limits

The external exhaustive reference was replayed for the22 M0 group projections.
Production runs22 named group tests: **21 public/conditional projections match
their stated outcomes; S13 explicitly tests an unsupported refusal instead of
claiming its normative Ready result.** Per-case known sets are scoped rather than
including future candidates, and exact pending assertions cover linear, sibling,
selective, dependency and discarded-ancestor cases.

- S01–03: immutable continuation facts/known-set pending projections, not publication
  side effects. Six valid A1/B1/A2/B2 receipt orders retain B2 after exact A2 selection.
- S04–12: selective public outputs, ancestry elimination, dependency-provided content,
  text/opaque conflicts, equal bytes/distinct origins. S07 gives exactly
  `f.txt=b'x=2\ny=0\n', g.txt=b'z\n'` after A1 was represented.
- S13: inline Compose deliberately refuses `ChoiceRequired(unsupported-compose)`;
  its independent reference still expects the documented exact Ready bytes. The
  test does not weaken that oracle or advertise a fabricated public record type.
- S14–15: comparison ambiguity and explicit parent-set reconciliation. Accepted
  ancestry is checked independently of path iteration, including empty trees;
  equal bytes cannot hide an ambiguous accepted-history comparison. No accepted
  state is mutated. Callers must supply real branch/head admission and freshness.
- S16: its distinct P candidate normalizes publicly; the separately conditional
  `preserve_private(K,D,E)` handles only K==D and preserves exact E. It neither
  proves correspondence nor supports general divergent catch-up.
- S17–18: a late unrelated sibling does not enter the input closure; exact supplied
  head-fingerprint change returns Stale. There is no native operation/COMMIT test.
- S19–22: evolution rebase does not import old contents, rejected context is not
  material, W/AX2/CZ1 yields exact `x=2,y=1,z=1` LF bytes, and deletion/edit conflicts.

The nonconfluent witness retains its exact base/variant bytes and two different
successful complete outputs. All six permutations return
`ChoiceRequired(nonconfluent)` and no tree. No first-success or ID-sort winner.

The generated-DAG test uses an independently implemented whole-binary-tree oracle
rather than the production subset DP/frontier reducer. That oracle shares the
separately tested production byte leaf; it is not independent evidence of the leaf
itself. The external reference uses a separate transcription anchored in inspected
OCaml/earlier report code. Finite agreement is not a formal confluence proof.

## 7. TDD and verification record

| Stage | Actual result |
| --- | --- |
| Initial RED | 59 failures because production normalization/composition modules did not exist. Existing package/test environment was available; imports occurred inside tests |
| First GREEN | 59 passed |
| Safety RED | 3 failed,1 passed: zero-budget graph read, ambiguous empty accepted histories, malformed/mutable input context |
| GREEN | 63 passed after guards and accepted-history comparison |
| Resource/property expansion | 70 passed |
| Additional RED cycles | Bounded closure input1 failed; structured budget result1 failed; repeated alignment-matrix allocation1 failed; symlink conversion/content edit2 failed (regular/exec positive passed); parent/existing-child context6 failed; pending alternatives on conflict1 failed |
| Corrections/refactor | Typed statuses/refusals, bounded inputs/memos, exact symlink handling, ancestor lifting and pending projection fixed; source helpers/formatting simplified |
| Failed refactor check | A misplaced `pairwise` import caused72 failures and typing errors; this was corrected, not counted as meaningful RED or concealed. Later targeted and complete runs pass |
| Final complete verification | **279 passed,0 failures/errors/skips**, 75.734 seconds; includes unchanged195 M1a.1 tests and84 new tests |

Final Hypothesis examples:100 codec +30 feed +150 malformed-byte +30 corruption
+4 order/cache combinations +25 linear histories +25 structural choices +35
generated DAGs = **399 passing generated examples**, no failing examples. Generator
retries are not skipped pytest cases. This is finite testing, not exhaustive fuzzing.

Fresh final checks: Ruff lint and format pass (12 Python files); strict mypy passes
(8 source modules). Source distribution and wheel build and install into a separate
external environment. `python -I` outside the checkout imports that wheel, prepares
an opaque conflict and applies an exact pure choice, and verifies no CLI entry
points exist. No runtime dependency or manifest change was introduced.

Resource evidence includes frontier7 preflight,4096-node iterative closure and4097
refusal, dependency depths256/257, cycle/missing references, lower-limit pair/cell/
state-byte/origin/fact/path faults, exact ancestor boundaries, counter overflow,
state-count refusal on a real nonconfluent witness, matrix memo checks, DFS/BFS
cardinalities, cache/permutation invariance and no partial tree on refusal. Actual
4M-cell matrix RSS,16M/64M aggregate saturation,32-state worst-case search and full
65k-origin/request physical peaks were **not** certified. The guards exist; these
stress/portability/performance qualifications remain visible future work.

No fresh OCaml build/tests, original full CI, G01 benchmark, native filesystem,
SQLite, cryptographic authority, network or power-loss experiment ran.
BASELINE-COPYOUT-20261116 remains unresolved; no cause, fix or waiver is invented.

## 8. Files, API boundaries and remaining work

Added only:

- `python/src/yeokcham/normalization.py`: immutable local facts/derived origins,
  exact closure/basis/scope checks, accepted-parent comparison, subset DP, scoped
  contexts/choices, structured proposal/refusal and pending projections.
- `python/src/yeokcham/composition.py`: exact byte leaf and logical tree values.
- `python/src/yeokcham/normalization_budget.py`: immutable limits, logical closure,
  checked counters and bounded request-local memos.
- `python/tests/normalization_cases.py`: manually specified input/expected fixtures.
- `python/tests/test_normalization.py`:84 tests, including parameterized/group/property tests.
- This follow-up report. The earlier report remains byte-for-byte unchanged;
  the external `fdbc4a2` commit made it tracked.

At final status, the three local modified files are `normalization.py`,
`normalization_cases.py` and `test_normalization.py`; this report is untracked.
The other new modules and intermediate test versions are now in the external
commits. The staged diff is empty. Relative to the initial 544-file inventory,
only the six assignment files listed above are additional paths, and every
pre-existing file's content and mode is unchanged.

Facts must already have authenticated ID/public-eligibility/snapshot bindings supplied
by a later adapter. This library rechecks immutable consistency, dependencies,
scope and derived results, but does not authenticate signatures, repository or
branch membership, change allocation/global root uniqueness, snapshot-object
availability outside supplied bytes, current policy/review or actual remote heads.
Its dataclasses are **not** a new public wire/storage format. Test IDs are opaque
deterministic fixtures, not independently signed-record golden vectors.

`Ready` means a complete pure proposed tree within the supplied validated scope;
it does not authorize acceptance. Other outcomes have no result tree. Selection,
required dependencies, retained alternatives and material lineage stay separate.
Ready.pending is the hypothetical unselected remainder; on a valid failed proposal,
pending includes still-unaccepted selected work. None means not established, not
that no work remains. Caller inputs are not mutated. There is no global cache or
new authoritative/persisted origin store.

Unsupported combinations are inline Compose, literal/novel-absence/comparison-base
subtree replacement, choices outside exact participating variants or outside exact
minimal conflict roots, overlapping choices, overriding nonconfluence/ambiguous
comparisons, general private correspondence/catch-up and requests outside local
bounds. They refuse; they are not claimed implemented merely because tests for
that refusal pass. Large valid assets/history may hit conservative byte/closure
bounds; M1a.1 storage/streaming identity support remains unchanged. No claim of
complete asset acceptance, arbitrary histories, native platforms or superiority
over Git/Jujutsu is made.

Next action stays **within M1a.2**: review the proposed local amendments, qualify
inline Compose/basis-slot lineage and literal replacement/absence comparisons,
complete divergent private-projection proof contracts, and extend independent
stress/trace fixtures. Do not begin M1b. Its durable SQL/request/plan/root/GC/backup
protocol and faults remain later work; M2 still needs native action/destination/
recovery qualification, including the unresolved copy-out discriminator.

## 9. Reproduction

From repository root with the unchanged M1a.1 development extras in an isolated
virtual environment:

```sh
task_tmp=$(mktemp -d)
python3 -m venv "$task_tmp/env"
"$task_tmp/env/bin/python" -m pip install -e './python[test,dev]'
PYTHONDONTWRITEBYTECODE=1 HYPOTHESIS_STORAGE_DIRECTORY="$task_tmp/hypothesis" \
  "$task_tmp/env/bin/python" -m pytest python/tests --basetemp="$task_tmp/tests" \
  -p no:cacheprovider --hypothesis-show-statistics --junitxml="$task_tmp/results.xml"
"$task_tmp/env/bin/ruff" check --no-cache python
"$task_tmp/env/bin/ruff" format --no-cache --check python
"$task_tmp/env/bin/mypy" --config-file python/pyproject.toml \
  --cache-dir "$task_tmp/mypy" python/src
"$task_tmp/env/bin/python" -m build python --outdir "$task_tmp/dist"
python3 -B tools/check_doc_links.py
```

Actual external evidence directory:
`/tmp/yeokcham-m1a2-followup-zeg3y6h9/`. Red/green/refactor logs, final JUnit,
reference outputs, old diagnostic replay and isolated build outputs are there;
the directory is supplemental evidence and need not survive on another host.
Final commands exited0. Test-failure summaries above are intentionally retained;
a shell ending in `tail` was not treated as proof that its preceding test passed.

For independent Phase A replay, save the two Python blocks below as `reference.py`
and `qualify.py` in a new external directory, copy the hand-authored
`python/tests/normalization_cases.py` there as `fixtures.py`, and run
`python3 -B EXTERNAL/qualify.py` from repository root. The reference does not import
production normalization. Its leaf code is extracted from the preserved earlier
report, and its exact nonconfluence input comes from unchanged observations.
The embedded sources are experimental test evidence, not product code or a
second documentation system. The extra existing-child checks record a reference
refinement made during safety review, not a rewrite of the old expected cases.

The legacy29-check diagnostic can likewise be extracted from the Python block
in M1A2_REPORT.md and run externally; its original source and expected charges
were preserved. Final before/after inventory, local links, fences, embedded-source
syntax and new-file whitespace were checked. No pre-existing content or modes
changed. External commits described in section 1 were preserved; this agent
performed no Git mutations and started no later tranche.

### External reference evaluator

```python
"""External exhaustive oracle; deliberately no imports of production normalization."""
import ast,itertools,json
from pathlib import Path
old=Path('docs/v2/implementation/M1A2_REPORT.md').read_text().split('```python\n',1)[1].split('```',1)[0]
nodes=ast.parse(old).body
keep=[n for n in nodes if isinstance(n,ast.FunctionDef) and n.name in ('lines','hunks','overlaps','leaf')]
exec(compile(ast.Module(body=keep,type_ignores=[]),'old-leaf-reference','exec'))
D=('D',)
def F(data,mode=0):return ('F',mode,data)
def scalar(base,a,b):
 if a==b:return a
 if a==base:return b
 if b==base:return a
 if any(v is None or v[0]!='F' for v in (base,a,b)):return 'conflict'
 mode=a[1] if a[1]==b[1] or b[1]==base[1] else b[1] if a[1]==base[1] else None
 if mode is None:return 'conflict'
 if 2 in (base[1],a[1],b[1]):return 'conflict'
 if any(b'\0' in v[2] for v in (base,a,b)):return 'conflict'
 try:
  for v in (base,a,b):v[2].decode('utf8')
 except UnicodeDecodeError:return 'conflict'
 data=leaf(base[2],a[2],b[2])
 return 'conflict' if data is None else F(data,mode)
def prefix(a,b):return b[:len(a)]==a
def invalid(tree):
 return {p[:i] for p in tree for i in range(1,len(p)) if tree.get(p[:i])!=D}
class Ref:
 def __init__(self,paths):
  self.paths=sorted(paths);self.values={('G',p):None for p in paths};self.parents={k:() for k in self.values};self.views={'G':{p:('G',p) for p in paths}}
 def candidate(self,name,basis,tree):
  view={}
  for p in self.paths:
   old=self.views[basis][p]
   if self.values[old]==tree.get(p):view[p]=old
   else:
    key=(name,p);self.values[key]=tree.get(p);self.parents[key]=(old,);view[p]=key
  self.views[name]=view
 def closure(self,origins):
  seen=set();stack=list(origins)
  while stack:
   o=stack.pop()
   if o not in seen:seen.add(o);stack.extend(self.parents[o])
  return seen
 def maximal(self,origins):
  return tuple(sorted(o for o in set(origins) if not any(o!=other and o in self.closure((other,)) for other in origins)))
 def solve(self,origins):
  if len(origins)==1:return {self.values[origins[0]]},False
  values=set();ambiguous=False
  for size in range(1,len(origins)):
   for left in itertools.combinations(origins,size):
    if origins[0] not in left:continue
    right=tuple(o for o in origins if o not in left)
    lv,la=self.solve(left);rv,ra=self.solve(right);ambiguous|=la or ra
    for a,b in itertools.product(lv,rv):
     common=self.maximal(self.closure(left)&self.closure(right))
     if len(common)!=1:ambiguous=True;continue
     value=scalar(self.values[common[0]],a,b)
     if value!='conflict':values.add(value)
  return values,ambiguous
 def run(self,inputs,choices=None):
  choices=choices or {};states={};frontiers={};bad=set();reason=None
  for p in self.paths:
   frontier=self.maximal(tuple(self.views[n][p] for n in inputs));frontiers[p]=frontier
   if len(frontier)>6:return 'ChoiceRequired',None,None
   values,ambiguous=self.solve(frontier)
   if ambiguous:reason='comparison'
   elif len(values)>1:reason='nonconfluent'
   elif not values:bad.add(p)
   else:states[p]=next(iter(values))
  if reason:return 'ChoiceRequired',None,None
  tentative={p:v for p,v in states.items() if v is not None};bad|=invalid(tentative)
  bad|={p[:i] for p in tuple(bad) for i in range(1,len(p)) if tentative.get(p[:i])!=D}
  roots={p for p in bad if not any(q!=p and prefix(q,p) for q in bad)}
  if any(not any(prefix(p,q) or prefix(q,p) for q in roots) for p in choices):return 'InvalidContent',None,None
  if any(a!=b and (prefix(a,b) or prefix(b,a)) for a in choices for b in choices):return 'InvalidContent',None,None
  if any(p not in choices for p in roots):return 'Conflicted',None,None
  result_view={}
  for p in self.paths:
   covering=next((q for q in choices if prefix(q,p)),None)
   if covering is not None:
    choice=choices[covering]
    if choice not in inputs:return 'ChoiceRequired',None,None
    origin=self.views[choice][p];states[p]=self.values[origin];result_view[p]=origin
  tree={p:v for p,v in states.items() if v is not None}
  if invalid(tree):return 'Conflicted',None,None
  return 'Ready',tree,(frontiers,result_view)
 def accepted(self,name,inputs,expected,choices=None):
  status,tree,extra=self.run(inputs,choices)
  assert (status,tree)==('Ready',expected),(name,status,tree,expected)
  fronts,copied=extra;view={}
  for p in self.paths:
   if p in copied:view[p]=copied[p]
   elif len(fronts[p])==1:view[p]=fronts[p][0]
   else:
    key=(name,p);self.values[key]=tree.get(p);self.parents[key]=fronts[p];view[p]=key
  self.views[name]=view
```

### External qualification driver

```python
from reference import *
from fixtures import FACTS,CASES,T,F,D,f,g
paths={p for row in FACTS for p in row[3]}
r=Ref(paths)
for name,role,inputs,tree,previous,scope,choices in FACTS[1:]:
 if role=='candidate':r.candidate(name,inputs[0],tree)
 else:r.accepted(name,inputs,tree,choices)
checks=[]
for label,targets,selected,status,tree in CASES:
 actual=('Stale',None,None) if label=='S18' and frozenset(('S0',))!=frozenset(('SB',)) else r.run(targets+selected)
 assert actual[:2]==(status,tree),(label,actual[:2],(status,tree))
 checks.append(label)
# Original S15 choice and S16 private-side conditional byte result.
assert r.run(('SA','SB'),{f:'SA'})[:2]==('Ready',T(2))
private={**T(2,1),(b'secret.txt',):F(b'private later\n')}
# The actual conditional private-side merge is checked below.
# Exact nonconfluence witness, both successful outputs and all permutations.
w=Ref({f});w.candidate('base','G',{f:F(b'a\nc\nb\n')})
for name,value in [('a',b'c\nb\nc\n'),('b',b'a\na\nb\nc\n'),('c',b'c\nc\nc\nb\n')]:w.candidate(name,'base',{f:F(value)})
for perm in itertools.permutations(('a','b','c')):assert w.run(perm)[0]=='ChoiceRequired'
# Logical units are the cardinalities of sets, independent of physical order.
p={i:(i-1,) if i else () for i in range(128)};p.update({128+i:(127,) for i in range(6)})
def closure(roots,bfs):
 seen=set();edges=set();todo=list(roots)
 while todo:
  n=todo.pop(0 if bfs else -1)
  if n in seen:continue
  seen.add(n)
  for parent in p[n]:edges.add((n,parent));todo.append(parent)
 return seen,edges
sums=[]
for bfs in [False,True]:
 total=0
 for size in range(1,7):
  for s in itertools.combinations(range(128,134),size):
   nodes,edges=closure(s,bfs);total+=len(nodes)+len(edges)
 sums.append(total*4)
assert sums==[65796,65796]
print(json.dumps({'semantic_groups':checks,'original_D3':'Ready exact f=x2/y0, g=z LF','nonconfluence_permutations':6,'logical_four_path_units':sums,'scope':'reference values only; no production normalization'},indent=2))
# Independent structural contract qualification for exact existing-subtree choices.
pd=(b'd',);pf=pd+(b'f',);pg=pd+(b'g',);u=(b'u',);px=(b'x',);pxf=px+(b'f',);pxg=px+(b'g',)
structural=[]
for replacement,label in [(None,'deletion'),(F(b'A'),'file'),(F(b'target',2),'symlink')]:
 q=Ref({pd,pf,pg,u});base={pd:D,pf:F(b'old'),u:F(b'old-u')}
 q.candidate('base','G',base)
 a={u:F(b'old-u')}
 if replacement is not None:a[pd]=replacement
 b={**base,pg:F(b'new'),u:F(b'new-u')}
 q.candidate('A','base',a);q.candidate('B','base',b)
 assert q.run(('A','B'))[0]=='Conflicted';structural.append(label+'-unresolved')
 for chosen,expected in [('A',{**a,u:F(b'new-u')}),('B',b)]:
  assert q.run(('A','B'),{pd:chosen})[:2]==('Ready',expected)
  q.accepted('choose'+chosen,('A','B'),expected,{pd:chosen})
  assert q.views['choose'+chosen][pg]==q.views[chosen][pg]
  structural.append(label+'-choose-'+chosen)
 assert q.run(('A','B'),{pd:'A',pg:'B'})[0]=='InvalidContent';structural.append(label+'-nested-refused')
 if replacement is None:
  q.candidate('laterB','B',{**b,pg:F(b'newer')})
  assert q.run(('chooseA','laterB'))[0]=='Conflicted'
  assert q.views['B'][pg] not in q.closure((q.views['chooseA'][pg],))
  structural.append('rejected-lineage-not-material')
q=Ref({pd,pf,pg,px,pxf,pxg,u})
base={pd:D,pf:F(b'old'),px:D,pxf:F(b'old'),u:F(b'old-u')}
q.candidate('base','G',base);q.candidate('A','base',{u:F(b'old-u')})
b={**base,pg:F(b'new'),pxg:F(b'new'),u:F(b'new-u')};q.candidate('B','base',b)
expected={p:v for p,v in b.items() if p[:1]!=pd}
assert q.run(('A','B'),{pd:'A',px:'B'})[:2]==('Ready',expected);structural.append('disjoint-choices-outside-preserved')
q=Ref({pd,pf});q.candidate('base','G',{pd:F(b'old')});q.candidate('dir','base',{pd:D,pf:F(b'new')})
assert q.run(('base','dir'))[:2]==('Ready',{pd:D,pf:F(b'new')});structural.append('file-to-directory')
q=Ref({pd});q.candidate('empty','G',{pd:D});assert q.run(('empty',))[:2]==('Ready',{pd:D});structural.append('empty-directory')
# Literal replacement and ambiguous comparison remain explicitly unsupported in subset.
assert r.run(('SL','SR'))[0]=='ChoiceRequired';structural.append('ambiguous-refused')
structural.append('literal-replacement-excluded-by-contract')
assert len(structural)==18
# Private known-present case is a pure comparison, not a proof of correspondence.
known=T(2);private={**T(2,1),(b'secret.txt',):F(b'private later\n')}
private_result={}
for path in known.keys()|private.keys():
 v=scalar(known.get(path),known.get(path),private.get(path))
 if v is not None:private_result[path]=v
assert private_result==private
# Near-limit exact cardinality check; no full exponential traversal needed.
assert 65795<65796 and 65796<=65796 and 65796>65795
assert (1<<63)-1+1>(1<<63)-1
print(json.dumps({'gate':'QUALIFIED_CONSERVATIVE_SUBSET','structural_cases':structural,'logical_units':65796,'not_qualified':['literal subtree replacements','unbounded large histories','public trust and private correspondence proofs','native/metadata application']},indent=2))

for replacement in (None,F(b'file'),F(b'target',2)):
 q=Ref({pd,pf,u});base={pd:D,pf:F(b'old'),u:F(b'old-u')}
 q.candidate('base','G',base)
 a={u:F(b'old-u')}
 if replacement is not None:a[pd]=replacement
 b={**base,pf:F(b'edited'),u:F(b'new-u')}
 q.candidate('A','base',a);q.candidate('B','base',b)
 assert q.run(('A','B'))[0]=='Conflicted'
 assert q.run(('A','B'),{pd:'A'})[:2]==('Ready',{**a,u:F(b'new-u')})
 assert q.run(('A','B'),{pd:'B'})[:2]==('Ready',b)
print('Existing-child conflict lifting: 9 assertions passed')
```

`reference.py` SHA-256: `0801a7347ca388faf5e12d30d964e2ad926603a09c9243698af9e9c1fa471e86`.

`qualify.py` SHA-256: `12495c6f0e5e9bf7cb1c530b1b0f8e9a3c71da287ed02e02e46108b176676e8a`.

`fixtures.py` SHA-256: `ae0be1aaabe127f32362199c9adbe0d84604422a97ec5b0967cfb43ef4056a75`.

**M1a.2 follow-up completed to the extent verified. No later tranche was authorized.**
