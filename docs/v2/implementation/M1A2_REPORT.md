# M1a.2 qualification and implementation report

Date: 2026-11-21, Singapore.

**M1a.2 verdict: BLOCKED.**
**Phase A gate: BLOCKED_BY_REFERENCE_CONTRACT.**

No production normalization code or new package tests were written. Phases B–D
were not entered. This is not a partial engine presented as complete. The owner's
conditional instruction permits production work only after Phase A qualifies the
entire intended contract; that condition was not satisfied. No M1b work began.

## 1. Actual source, scope and preservation

Initial and final HEAD: `d4cfc740d6a84625b464c6937bcaea2734d47236`, clean `main`
tracking locally recorded `origin/main` at the start. No fetch was made. The one
commit after the supplied `c9b507f5ff321d391342cf01267b87eb341dd73c` adds the
M1a.1 package/tests/report (11 files); the OCaml implementation is unchanged.
This report path did not exist. No staged or untracked work was present initially.
No commit, push, reset, checkout, cleanup, staging or dependency installation ran.

A SHA-256/mode inventory covers all **543 pre-existing tracked/nonignored
untracked files**, including all Python modules/tests, original source, reference
scripts, vectors, RFCs, reports, README and research. Final comparison reports no
changes or removals. Only this report is added. Ignored cache/build data was not
recursively inventoried; tests and diagnostic outputs use external scratch.

Observed host: Linux 7.2.15-1-omarchy x86_64/glibc 2.44; CPython 3.14.8. Existing
isolated M1a.1 test tools were reused. OCaml/Dune/opam are unavailable on PATH;
no fresh OCaml execution or project CI is claimed. A daemon restart interrupted
the read-only review; HEAD/status were checked again before proceeding and still
matched the initial clean state.

## 2. Evidence and interpretation

References inspected include the M1a.1 report and package/tests, D1/D2, both D3
reviews, D4, all four M0 documents, the four M1a reference documents, machine
observations/evidence, retained content corpus and reference scripts. The relevant
OCaml source is `line_hunks.ml` and composition `tree`, `merge`,
`replace_subtree`, `validate_decision`, `merge_resolved`, scope/basis handling.

The decisive outstanding clauses are:

- [Normalization contract](../m0/m1a-reference/M1A_NORMALIZATION_CONTRACT.md),
  lines 171–182 and 250–274: exact trace-level visit charging and general subtree
  choices/correspondence/saturation remain explicit M1a.2 gates.
- [D4](../D4_BLOCKER_RESOLUTION.md), sections 5.1–5.3: path-origin derivation,
  exhaustive confluence, whole-tree checks and exact subtree choices must coexist;
  a pathwise result is not permission to construct an invalid tree.
- [M0 O02](../m0/M0_SAFETY_AND_TRANCHE_GATES.md), line 283: exact charging,
  structural/resolution and long-history qualification precede full normalization.
- [Reference closure](../m0/m1a-reference/M1A_REFERENCE_CLOSURE.md), lines 86–108:
  content readiness does not qualify full normalization.

This does not reopen Model A, the approved profile pair or the selected persistence
architecture. It identifies the remaining meaning/trace needed to implement those
rules without inventing a second algorithm or claiming unsupported safety.

Existing immutable observations retain all 22 M0 case groups, including S07 and
S21. The symbolic source programs are not delivered as a maintained evaluator;
the historical `normalize_probe.py` and `budget_probe.py` paths do not exist on
this host. Their JSON outputs and hashes are evidence, not an executable oracle
for new structural or budget cases. No historical result is relabelled as a new
production test pass.

## 3. Blocker A: subtree conflict context and resolution lineage

### Exact structural counterexamples

Paths are tuples of raw byte components; `Dir` is an explicit empty-capable
directory, `File(mode,bytes)` a logical file. Root is implicit. All three input
trees below are individually valid.

```text
Base:
  (b'd',)          Dir
  (b'd',b'f')     File(0,b'old')
  (b'u',)          File(0,b'old-u')

A-file (based on Base):
  (b'd',)          File(0,b'A')
  (b'u',)          File(0,b'old-u')

B (also based on Base):
  (b'd',)          Dir
  (b'd',b'f')     File(0,b'old')
  (b'd',b'g')     File(0,b'new')
  (b'u',)          File(0,b'new-u')
```

The existing equality/unchanged rule independently applied at each path produces:

```text
(d,)    File(0,b'A')
(d,g)   File(0,b'new')
(u,)    File(0,b'new-u')
```

This is invalid: a file has a descendant. Deleting `d` instead leaves an orphan
`d/g`. Replacing `d` with symlink `File(2,b'target')` produces the same structural
problem. These three cases were reproduced externally, without repository IO.
They demonstrate why neither dropping the child nor synthesizing a directory
is an acceptable automatic correction. They are not evidence that D4 permits
an invalid Ready result: D4 explicitly requires structural validation.

The unresolved part is **general resolution validation/lineage**, not detecting
that these outputs are invalid. At path `d`, B inherits the old directory origin,
which A's replacement dominates. At `d/g`, B supplies a new origin while A's
absence is inherited. Neither path necessarily has an ordinary leaf conflict.
The whole-tree interaction creates the conflict at `d`. The reference does not
supply the executable rule lifting those descendant contributors into the
resolution's complete actual context, especially for missing descendants, nested
replacements and literal replacement origins. Selecting a complete subtree can
produce correct bytes while still assigning incorrect future material ancestry.

Global exact candidate IDs carry the necessary facts; no extra persisted origin
or new public record is needed. What is missing is the precise rule for validating
that context and deriving every chosen/absent descendant origin. Merely copying
an existing tree does not prove those rules. The OCaml `merge_resolved` procedure
supplies useful scope/overlap behavior, but does not implement V2 material origins
or its normalization charging and cannot substitute for that missing rule.

### Proposed minimal closure, not an approved implementation

1. Compute structural conflict roots from **original exact input subtrees**, before
   discarding descendant context through leaf dominance. Include deleted/replaced
   descendants and relevant absent-path effects. Retain original fact/slot/path
   roles; no new hashed origin or authoritative store.
2. Bind the resolution to exact selected/accepted inputs plus complete scope-local
   contributors. An unchanged parent can carry a changed descendant and therefore
   cannot disappear from structural conflict context merely because its own
   directory value was dominated.
3. `choose(A,d)` selects A's entire exact subtree, including covered absences;
   all rejected B descendants remain context-only. It explicitly accounts for
   their rejection. Independently composed work outside `d` remains unchanged.
4. A literal subtree replacement requires a unique recorded comparison and an
   explicit per-path origin rule, including absent descendants. If that comparison
   is ambiguous, return ChoiceRequired(comparison), not a synthetic base.
5. Reject ancestor/descendant overlapping resolutions, even if replacement bytes
   happen to agree. Reject unused, incomplete-context and out-of-scope decisions.
   Proposed classification: InvalidContent for malformed/overlapping/unused input;
   IntegrityFailure for false claimed scope/context; ambiguity remains a choice.
6. Independently qualify later continuation from both chosen and rejected sides,
   checking future dominance, not just the immediate output bytes.

For the example, proposed `choose(A-file,d)` yields exactly `{d: File(0,b'A'),
u: File(0,b'new-u')}`. The descendant disappears by explicit scoped choice,
not silently. Choosing B instead yields its complete directory subtree and
`u=b'new-u'`; A is context-only. Neither action should erase unrelated `u` work.
The scratch diagnostic checks the first output shape and outside preservation;
it does **not** validate the proposed proof/context or future lineage.

### Structural coverage disposition

| Required case | Exact outcome/condition | Current qualification |
| --- | --- | --- |
| File → directory | One valid selected target can contain `d:Dir,d/g:new`; no file ancestor remains | Structural validity diagnostic only; concurrent context/lineage not qualified |
| Directory → file | Target `d:File` contains no descendants | Replacement/child-add trap reproduced; general resolution gate remains |
| Symlink → directory | Treat link as opaque File(mode2), not as a host directory | Complete target shape checked; no host symlink IO or general resolution proof |
| Recursive deletion | Unchanged peer permits complete deletion; changed descendant requires Conflicted(d), not an orphan | Delete/add trap reproduced |
| Parent deletion + descendant modification | Whole subtree must participate; no silent pruning | Context-lifting/lineage gate remains |
| New child + independently replaced parent | File/symlink plus descendant is invalid | Both traps reproduced |
| Empty directories | `{d:Dir}` differs from deletion `{}` | Diagnostic assertion passed; retained bytes already covered by M1a.1 |
| Structurally impossible output | Never Ready; invalid input differs from conflicting valid inputs | Diagnostic detects invalid combinations; no normalization API exists |
| Scoped subtree resolution | Exact chosen subtree; preserve outside changes; rejected context not material | Proposed rule above needs independent context/continuation fixtures |
| Overlapping parent/child resolutions | Reject instead of ordering them | Prefix overlap demonstrated; no engine-level refusal classification implemented |

## 4. Blocker B: no authoritative origin-visit trace

The numeric limits are not changed. The reference defines
`recorded_ancestors(S)` as a union and asks implementations to match a specified
cache-independent traversal, but does not provide a complete labelled trace for
all its callers (dominance, comparison reduction, subset queries and derivation).
A union can be evaluated by one shared-seen walk or by separate root walks followed
by set union. Both give the same ancestor set, but their logical charges differ.
Caching either one must not silently choose a different public refusal outcome.

Bounded diagnostic graph, per path:

- Nodes 0..127 form a chain: node0 has no parent; node i has parent i−1.
- Six distinct tips 128..133 each have parent127; frontier size is exactly six.
- For four distinct file paths, use path-specific origins over this same 134-fact
  shape: 134 origins/path and 536 total, below the stated origin/dependency caps.
- Enumerate the documented 63 nonempty subsets and 301 unordered proper
  bipartitions. Each pair asks for both sides' ancestors: 602 queries/path.
- Count one visit per first-entered node and traversed parent edge, with canonical
  root/edge order. Compare sharing `seen` within each union query versus resetting
  it for every original root in that query. Neither kernel is presented as the
  missing normative trace; they expose the observable choice left by the abstract
  union operation.

| Ancestor-query kernel | One path | Four paths |
| --- | ---: | ---: |
| Shared-seen union walk per query | 156042 | 624168 |
| Separate root walks per query, then union | 325362 | 1301448 |
| Existing request visit limit | — | 1000000 |

The second kernel's ancestor queries alone exceed the limit; the first's do not.
These are **not** full-engine total-work measurements or proof the first complete
request would return Ready. Other required operations also need charges. They show
why a cached implementation cannot be checked against a unique budget oracle until
all those logical query/visit events are defined. Both diagnostic query orders
are canonical and the reversed input order produces the same query sequence.
No frontier beyond six or uncontrolled exponential run was attempted.

Recommended closure: use a unique-node/edge union walk for each labelled logical
ancestor query, with explicit canonical query scheduling and charging even on
cache hits. Freeze the complete event trace, including derivation, dominance,
common-maxima reduction, repeated subset requests, shared subtrees and early
refusals. Specify which repeated events deduplicate and which charge again.
Independently compare traces at limit−1/limit/limit+1. The kernel recommendation
alone is not a complete specification; accepting it does not close the gate until
all call sites and their exact oracles are supplied.

### Other resource requirements

| Area | Observed diagnostic | Not established |
| --- | --- | --- |
| Frontier six/seven | Six gives 63 subsets/301 partitions; seven refused before enumeration | No full DP/value-state engine or saturation test |
| Cycles/missing facts | Iterative test-only graph checks distinguish cycle/missing | Not production validated-fact closure handling |
| Depth | 256 edges accepted, 257 refused by the diagnostic's stated edge-depth convention, without recursion | Canonical production depth convention/trace still needs freezing |
| Fanout | 65 refused before expanding children | Full recursive Compose/profile charging |
| Alignment | Exact arithmetic: 2000×2000=4000000; 2001×2001 exceeds leaf cap | No default-size matrix allocation/RSS or aggregate 16M/64M engine run |
| Distinct states/bytes | Existing reference caps retained: 32/subset, 8MiB/path, 64MiB/request, transient reservations | Default-cap saturation and cache-independent retained-state traces not run |
| Origin visits | Concrete bounded ambiguity above | Authoritative full trace and million-visit boundary qualification |

All additional reference limits (64 selections/dependencies, 4096 facts/paths,
depth256/fanout64, 1MiB path bytes, 4096/65536 origins, 32768/131072 pairs,
32MiB fetched text, 131072 line descriptors, byte/state/transient caps) remain
unchanged and unimplemented in normalization. No partial accepted result was
created during diagnostics.

## 5. Publication correspondence and public/private boundary

This is **not** blocked on signatures, private Merkle witnesses, public wire
encoding or storage: those are intentionally later. The eventual pure API can
consume externally validated immutable public facts, explicitly typed roles,
exact basis/result snapshots and verified declared scope. It must distinguish
selected facts, content dependencies, evolution/proof dependencies and rejected
resolution context. Given only a valid public input closure, private source files
must not be consulted to fill a base or omitted path.

S16's private continuation is a conditional preservation example, not permission
to include private paths in the public normalizer. The report does not claim a
normalizer can authenticate input IDs, validate membership, prove source
correspondence or establish availability merely because a caller says validated.
A later adapter must provide those proofs. The pure result should retain exact
selected/dependency/context/material-lineage roles so that the proofs remain
possible without changing normalization meaning. That boundary is coherent;
the remaining structural context/origin rule must be closed within it.

## 6. Reference regressions and actual verification

External diagnostics: **29 assertions passed**, exit 0. These are bounded Phase A
checks, not 29 production normalization tests. They cover the three structural
traps and proposed output shapes, prefix overlap, empty directory/target shape,
query counts/charging difference, frontier preflight, iterative graph negatives,
leaf threshold arithmetic and small leaf comparisons.

The D3 diagnostic reconstructs the old artificial conflict:
`leaf(x0, x1, x2, x0)` refuses. Given the required reduced singleton frontier,
the leaf produces exactly `f.txt=b"x=2\ny=0\n"`; the independent addition is
`g.txt=b"z\n"`. This is a leaf/frontier illustration of S07, **not** a fresh full
normalizer S07 pass. All 22 full-engine M0 case groups remain unimplemented.

The preserved nonconfluence witness was checked with a small external byte-level
transcription of the inspected OCaml leaf rule:

```text
base = b'a\nc\nb\n'
A = b'c\nb\nc\n'
B = b'a\na\nb\nc\n'
C = b'c\nc\nc\nb\n'
(A+B)+C -> b'c\nc\nb\nc\n'
(A+C)   -> conflict
(B+C)+A -> b'c\nc\na\nb\nc\n'
```

The two complete outputs match the unchanged observations exactly. Hence the
full profile's required result remains ChoiceRequired(nonconfluent), not the
first successful output. No full subset normalizer or all-six-permutation
production check was run. No OCaml runtime pass is inferred from the transcription.

### Fresh M1a.1 regression/static results

- Full existing suite: **195 passed, 0 failed/errors/skips**, 48.79s; exit 0.
- Existing Hypothesis: 100 codec +30 feed +150 arbitrary-byte +30 corruption =
  **310 passing generated examples**, no failing examples. The codec strategy
  retried 14 invalid generation candidates; these are not skipped pytest cases.
- Ruff lint: exit 0; format check: exit 0, seven files already formatted.
- Strict mypy with the package config: exit 0, five source modules checked.
- The unchanged content suite verifies retained bytes/109 rejection cases; it
  does not establish candidate normalization.
- No Phase B RED, production GREEN or normalization REFACTOR occurred: the gate
  is intentionally earlier. Reporting the existing green suite as M1a.2 TDD
  would be incorrect.

Existing package build/import evidence remains the M1a.1 report, not freshly
rerun here. Phase D package/normalizer/differential/property/structural suites were
not entered. No native, SQLite, cryptographic, network, power-loss or original
copy-out runtime test ran. BASELINE-COPYOUT-20261116 remains unresolved, root
cause unknown.

## 7. Required closure decisions and next assignment

No repeat approval of Model A, Python, existing workspace identities, SQLite or
the retained content codec is requested. The outstanding contract decisions are:

1. Freeze the subtree-resolution context/lifting, absence and chosen-versus-
   rejected material-origin rules described in section 3. Include literal
   replacement comparison and exact refusal categories. Recommended default is
   complete original scoped subtree context and full exact subtree choice, with
   rejected variants context-only and all outside work preserved.
2. Freeze a complete canonical logical charging trace. Recommended kernel is
   unique union traversal per labelled query, with virtual charge on cache hits;
   do not approve a kernel while leaving its callers/deduplication implicit.
3. Independently qualify those decisions with exact immediate and subsequent-
   continuation outputs, complete charging traces, bounded near-limit fixtures,
   the 22 M0 groups and all required compatible permutations. Numeric limits stay
   those in the existing contract; changing them requires an explicit profile
   decision rather than a silent implementation adjustment.

These are proposed clarifications, not edits to frozen reference documents or a
claim of owner approval. The next assignment should **close the M1a.2 reference
contract and repeat Phase A**, then enter RED under an unambiguous contract.
A restricted engine that refuses every structural choice could be another product
scope, but is not silently substituted for the full engine requested here.
Do not advance to M1b. Its SQL/plan/request/root schemas and fault verification,
and M2's native action/DestinationClaim/recovery qualification remain outstanding.

## 8. Reproduction and preservation checks

The diagnostic source is embedded below so the report does not depend on temporary
macOS programs or this chat. Save the fenced Python source into a new external
temporary directory and run it from repository root using `python3 -B FILE`.
It imports no production normalizer and emits JSON to stdout. Its source SHA-256
is recorded after the listing. It must not be mistaken for product code.

Actual external directory: `/tmp/yeokcham-m1a2-qualification-0artiu83/`.
Commands executed (all completed with exit 0):

```sh
python3 -B /tmp/yeokcham-m1a2-qualification-0artiu83/phase_a.py
PYTHONDONTWRITEBYTECODE=1 \
HYPOTHESIS_STORAGE_DIRECTORY=/tmp/yeokcham-m1a2-qualification-0artiu83/hypothesis \
/tmp/yeokcham-m1a1-env/bin/python -m pytest python/tests \
  --basetemp=/tmp/yeokcham-m1a2-qualification-0artiu83/regression \
  -p no:cacheprovider --hypothesis-show-statistics -q
/tmp/yeokcham-m1a1-env/bin/ruff check --no-cache python
/tmp/yeokcham-m1a1-env/bin/ruff format --no-cache --check python
/tmp/yeokcham-m1a1-env/bin/mypy --config-file python/pyproject.toml \
  --cache-dir /tmp/yeokcham-m1a2-qualification-0artiu83/mypy python/src
python3 -B tools/check_doc_links.py
git diff --check
```

The temporary environment paths are execution evidence, not installation
requirements. A fresh environment can use the unchanged M1a.1 report's setup
commands and declared `python[test,dev]` extras. Final documentation target/fence/
reproduction checks and the before/after inventory passed; exactly this report
is added, all 543 initial files unchanged, HEAD unchanged. No code/test/module or
reference was modified. There are no new production APIs or acceptance results.

### Self-contained external diagnostic

```python
"""Bounded Phase A diagnostics, NOT a candidate-normalization implementation."""
from itertools import combinations
import json
from pathlib import Path

D = ('directory',)
def file(data, mode=0): return ('file', mode, data)
def valid(tree):
    return all(all(tree.get(path[:i]) == D for i in range(1,len(path))) for path in tree)
def simple_paths(base,a,b):
    out={}
    for p in sorted(base.keys()|a.keys()|b.keys()):
        old,x,y=base.get(p),a.get(p),b.get(p)
        if x==y: v=x
        elif x==old: v=y
        elif y==old: v=x
        else: return None
        if v is not None: out[p]=v
    return out

def partitions(frontier):
    f=tuple(sorted(frontier))
    for size in range(2,len(f)+1):
        for subset in combinations(f,size):
            for n in range(1,size):
                for left in combinations(subset,n):
                    if subset[0] in left:
                        yield left,tuple(v for v in subset if v not in left)

def visits(parents,roots):
    stack=list(reversed(sorted(roots)));seen=set();count=0
    while stack:
        n=stack.pop()
        if n in seen: continue
        seen.add(n);count+=1
        for p in reversed(parents[n]):count+=1;stack.append(p)
    return count

def graph_check(parents,roots,max_depth=256,max_fanout=64):
    # Test-only validation; depth is explicitly measured as edges from each root.
    active=set();stack=[(r,0,False) for r in reversed(sorted(roots))]
    while stack:
        n,depth,leaving=stack.pop()
        if leaving:active.remove(n);continue
        if n in active:return 'InvalidContent'
        if n not in parents:return 'Unavailable'
        if depth>max_depth or len(parents[n])>max_fanout:return 'budget'
        active.add(n);stack.append((n,depth,True))
        stack.extend((p,depth+1,False) for p in reversed(parents[n]))
    return 'valid'

# Independent small byte-level transcription of the inspected OCaml leaf rule.
def lines(raw):
    parts=raw.split(b'\n')
    return [p+b'\n' for p in parts[:-1]]+([parts[-1]] if parts[-1] else [])
def hunks(base,value):
    a,b=lines(base),lines(value);prefix=suffix=0
    while prefix<min(len(a),len(b)) and a[prefix]==b[prefix]:prefix+=1
    while suffix<min(len(a)-prefix,len(b)-prefix) and a[-1-suffix]==b[-1-suffix]:suffix+=1
    n,m=len(a)-prefix-suffix,len(b)-prefix-suffix
    assert (n+1)*(m+1)<=4000000
    score=[[0]*(m+1) for _ in range(n+1)]
    for i in reversed(range(n)):
        for j in reversed(range(m)):
            score[i][j]=1+score[i+1][j+1] if a[prefix+i]==b[prefix+j] else max(score[i+1][j],score[i][j+1])
    i=j=0;pending=None;replace=[];out=[]
    def flush(end):
        nonlocal pending,replace
        if pending is not None:out.append((pending,prefix+end,tuple(replace)));pending=None;replace=[]
    while i<n or j<m:
        if i<n and j<m and a[prefix+i]==b[prefix+j]:flush(i);i+=1;j+=1
        elif i<n and (j==m or score[i+1][j]>=score[i][j+1]):
            if pending is None:pending=prefix+i
            i+=1
        else:
            if pending is None:pending=prefix+i
            replace.append(b[prefix+j]);j+=1
    flush(i);return out

def overlaps(a,b):
    x,y,_=a;u,v,_=b
    if a==b:return False
    if x==y and u==v:return x==u
    if x==y:return u<=x<=v
    if u==v:return x<=u<=y
    return max(x,u)<min(y,v)

def leaf(base,*variants):
    changed=sorted(set(v for v in variants if v!=base))
    if not changed:return base
    if len(changed)==1:return changed[0]
    all_hunks=sorted(set(h for v in changed for h in hunks(base,v)))
    if any(overlaps(a,b) for a,b in zip(all_hunks,all_hunks[1:])):return None
    raw=lines(base);out=[];cursor=0
    for first,last,replacement in all_hunks:out.extend(raw[cursor:first]);out.extend(replacement);cursor=last
    out.extend(raw[cursor:]);return b''.join(out)

checks=[]
def check(name,condition):
    assert condition,name
    checks.append(name)

p=(b'd',);f=p+(b'f',);g=p+(b'g',);outside=(b'u',)
base={p:D,f:file(b'old'),outside:file(b'old-u')}
b={**base,g:file(b'new'),outside:file(b'new-u')}
structural={}
for label,replacement in [('delete',None),('file',file(b'A')),('symlink',file(b'target',2))]:
    a={outside:file(b'old-u')}
    if replacement is not None:a[p]=replacement
    tentative=simple_paths(base,a,b)
    check(label+' valid inputs',valid(a) and valid(b) and valid(base))
    check(label+' exposes invalid independent-path result',tentative is not None and not valid(tentative) and tentative[g]==file(b'new'))
    # Proposed subtree-choice effect only: not a resolution-context validator.
    chosen={q:v for q,v in tentative.items() if q[:1]!=p}
    chosen.update({q:v for q,v in a.items() if q[:1]==p})
    check(label+' explicit choice shape/outside preservation',valid(chosen) and chosen[outside]==file(b'new-u') and g not in chosen)
    structural[label]={'tentative':repr(tentative),'proposed_choose_A':repr(chosen)}
check('parent and child decisions overlap',g[:len(p)]==p)
empty={p:D}
check('empty directory is distinct from deletion',valid(empty) and empty!={})
check('file to directory complete target is structurally valid',valid({p:D,g:file(b'new')}))
check('symlink to directory complete target is structurally valid',valid({p:D,g:file(b'new')}))

parents={i:(i-1,) if i else () for i in range(128)}
parents.update({128+i:(127,) for i in range(6)})
fro=tuple(range(128,134));queries=[q for pair in partitions(fro) for q in pair]
union=sum(visits(parents,q) for q in queries)
per_root=sum(sum(visits(parents,(r,)) for r in q) for q in queries)
check('six frontier DP counts',len(queries)==602 and 2**6-1==63)
check('four paths straddle default visit limit',4*union==624168 and 4*per_root==1301448 and 4*union<1000000<4*per_root)
check('permutation-independent diagnostic queries',list(partitions(fro))==list(partitions(reversed(fro))))
allocated=False
if len(fro+(134,))>6:outcome='budget'
else:allocated=True;outcome=list(partitions(fro+(134,)))
check('seven-frontier guard before enumeration',outcome=='budget' and not allocated)
check('small valid graph',graph_check(parents,fro)=='valid')
check('cycle',graph_check({0:(1,),1:(0,)},(0,))=='InvalidContent')
check('missing dependency',graph_check({0:(1,)},(0,))=='Unavailable')
check('fanout 65 refusal',graph_check({0:tuple(range(1,66))},(0,))=='budget')
for edges,expected in [(256,'valid'),(257,'budget')]:
    chain={i:((i-1,) if i else ()) for i in range(edges+1)}
    check('iterative depth '+str(edges),graph_check(chain,(edges,))==expected)
check('alignment exact threshold arithmetic',2000*2000==4000000 and 2001*2001>4000000)

x0=b'x=0\ny=0\n';x1=b'x=1\ny=0\n';x2=b'x=2\ny=0\n'
check('D3 old global-base artificial conflict',leaf(x0,x1,x2,x0) is None)
check('D3 singleton frontier required exact bytes',leaf(x1,x2)==x2)
check('D3 independent added file exact bytes',leaf(b'',b'z\n')==b'z\n')
witness=json.loads(Path('docs/v2/m0/m1a-reference/normalization-observations.json').read_text())['independent_budget_and_structure']['nonconfluence_witness']
wb=bytes.fromhex(witness['base_hex']);a,b,c=map(bytes.fromhex,witness['variants_hex'])
ab=leaf(wb,a,b);bc=leaf(wb,b,c)
check('witness A+C conflicts',leaf(wb,a,c) is None)
check('witness exact distinct successful trees',ab is not None and bc is not None and sorted([leaf(wb,ab,c).hex(),leaf(wb,bc,a).hex()])==sorted(witness['outputs_hex']))
result={'checks_passed':len(checks),'checks':checks,'structural':structural,'charging':{'subsets':63,'partitions':301,'ancestor_queries':602,'origins_per_path':134,'paths':4,'union_visits':4*union,'per_root_visits':4*per_root,'default_limit':1000000},'not_qualified':['subtree resolution context and lineage validation','authoritative charging trace','full normalization','all 22 production case groups','resource saturation']}
print(json.dumps(result,indent=2))
```

Diagnostic source SHA-256: `a6591a2fd817093cdd93cb8bdabc30585b4f482b01c8b24f3d7f245cd628765d`.

**M1a.2 completed to the extent verified. No later tranche was authorized.**
