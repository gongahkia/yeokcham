# Path-frontier normalization reference

Version: `m1a-normalization-reference-1`, 2026-11-20.
**DRAFT / OWNER APPROVAL PENDING**. Logical profiles remain the ordered pair
`(path-frontiers-v1, line-hunks-v1)` from [D4 sections5–7](../../D4_BLOCKER_RESOLUTION.md).
No public profile bytes, OriginRef encoding or new production engine is defined.

## Qualification verdict

The 22 [M0 cases](../M0_SEMANTIC_REFERENCE.md) have their original expected
outcomes under a new finite symbolic check. Model A survives. Independent
whole-tree enumeration and subset dynamic programming agree on100 applicable
path results. This is falsification evidence, **not a proof of the full model**.
General subtree-resolution/correspondence and physical/default resource
qualification remain outside this check; full normalization is not M1a-ready.
Implement the isolated content subset first, then a separately scoped M1a.2.

The corrections here make charging and preflight explicit; they do not replace
D4 with a new global comparison base or second authoritative representation.

## Facts, contribution identity and derivation

A candidate is an immutable exact **public basis plus result plus declared
scope**. Its own edit is diff(basis,result). Its complete proposed state includes
verified basis content; dependency does not mean a second separately selected
patch. Evolution predecessor relates revisions of the same change. It supplies
material lineage only if also an actual content-basis input. No timestamp,
receipt order, change label or mere snapshot equality supplies an edge.

The material contribution identity is a **derived tuple**
`(exact public record identity, basis/result slot, raw component path)` and a
verified before/after state and material-parent set. Slots distinguish an inline
Compose basis from its enclosing result. This is not a new hashed public ID or
persisted table. Records referenced by the tuple must already have validated
identities; symbolic labels in observations are fixture names only.

States are Absent, Directory, File(mode, exact content). Missing/corrupt input
cannot establish Absent. Genesis supplies a distinguished absence origin for
each queried path. For unchanged paths inherit the exact basis origin. For a
changed path derive a result origin with its exact basis origin as parent.
Ancestor directory replacement/deletion includes actual descendant effects;
scope validation cannot ignore them. Compose evaluates its exact accepted inputs,
candidate inputs and resolutions recursively, verifies the claimed result, and
derives enclosing basis-slot origins. It does not create an accepted version.

A join inherits one surviving origin, or derives an accepted result origin with
**all original maximal material inputs** as parents, even when their values are
equal. Equal values can share payload storage, not causal identity. Explicit
choice copies the chosen path/subtree lineage; discarded variants are context
dependencies only. A literal replacement needs a unique verified recorded
comparison origin and a new material origin based on that comparison, as in D4.
Do not invent a replacement origin when that comparison is ambiguous.

Keep three separate sets: exact selected candidate revisions; required
causal/content/proof dependencies; resolution context. Only the first is the
selection. Dependencies may supply content without separately selecting their
records. Context-only rejected variants must not acquire material edges.
Nothing here authorizes publication, acceptance or disclosure of private inputs.

“Already represented” means this path's input origin is identical to or a
verified material ancestor of a current surviving input. Dominance removes it
from **composition**, not history/provenance/selection. It does not mean its old
bytes occur verbatim or that every ancestor patch must be applied again. There
is no global `applied` flag. A candidate previously considered and discarded is
not already represented through a context-only edge. Pending siblings remain
retained independent alternatives, including after a different tip is accepted.

## Deterministic algorithm

`recorded_ancestors(S)` is the union of reflexive material ancestor sets of the
original origins in subset S; temporary results have exactly S as parents but
are never recorded comparisons. Thus common candidates for two partial results
are the intersection of these two unions, reduced to material maxima. One
recorded maximum is required; zero or multiple yields ChoiceRequired(comparison).
No synthetic merge base is created to make the calculation convenient.

```text
normalize(targets, selected, resolutions, verified_public_resolver, limits):
    canonicalize exact ID sets; reject duplicate selection references
    validate typed IDs, closure shape, cycles, supported profiles and declared scope
    charge/validate public closure BEFORE expanding dependencies or path effects
    absent dependency => Unavailable; false scope/claimed result => IntegrityFailure
    topologically evaluate public bases; evolution-only edges are not content inputs
    derive bounded structural path closure in raw-byte component order
    for each path:
        I = target origins at path UNION exact selected result origins at path
        F = unique material maxima(I), ordered by exact origin tuple
        reject unsupported frontier size BEFORE generating subsets/trees
        values, ambiguous = solve(F)
        if ambiguous: return ChoiceRequired(comparison)
        if no complete value: mark Conflicted(path)
        if more than one complete value: return ChoiceRequired(nonconfluent)
        otherwise retain exact value and canonical lineage parents F
    check ancestor/type/delete-edit interactions and complete output tree
    validate exact supported resolutions; never silently drop/recreate subtrees
    unsupported structural decision => ChoiceRequired(structural-resolution)
    no accepted result when any conflict, ambiguity or work refusal remains
    return pure proposed snapshot + derived lineage + exact role-separated inputs

solve(S):
    singleton => {exact state}, no ambiguity
    charge one subset state, memoize by its original origins, NOT temporary tree ID
    enumerate EVERY unordered proper partition A|B, including min(S) in A
    increasing subset cardinality, then lexicographic origin tuple
    solve BOTH children; propagate ambiguity even if another partition succeeds
    for every pair of their distinct states, in canonical state order:
        charge pair BEFORE comparison/merge
        comparison = unique maximal RECORDED common material ancestor(A,B)
        if unsupported/ambiguous: remember ambiguity; continue bounded check
        validate base bytes; apply exact whole-entry/mode/line-hunks rules
        an incompatible merge contributes no value for this pair
        successful state keeps original subset parents S, not one chosen tree
        precharge retained state bytes/count before insertion; deduplicate values
    return ALL complete values and accumulated ambiguity
```

Bound failure aborts the whole attempt with no partial accepted snapshot; it
cannot turn an incomplete search into a unique answer. One successful derivation
does not prove confluence. A failed grouping alone does not veto a unique complete
value established by the exhaustive check. No complete value means Conflicted
unless a necessary comparison was unsupported, when ChoiceRequired takes priority.
Canonical state order is Absent, Directory, then File(mode,length,raw bytes);
origin order uses raw typed IDs/slot/component tuples, never display names.

Leaf semantics retain [actual OCaml line hunks](../../../../lib/yeokcham_v1_composition/line_hunks.ml):
whole-state equality/unchanged cases first; regular/executable mode and content
changes selected separately; incompatible type/deletion or differing opaque
values conflict. Text is strict UTF-8 without NUL; split only on LF, preserve
CRLF and final newline exactly. Trim identical line prefix/suffix, compute LCS,
break equal-score ties by deletion, deduplicate identical hunks, reject differing
overlapping hunks including insertion at replacement boundaries. Do not replace
this with Python `splitlines()` or an arbitrary diff library. Source limits are
2MiB/input and4,000,000 alignment cells including boundary cells. Equality and
unchanged identity paths can work for large/opaque files without text parsing.

Acceptance/head/authority/known-present validation remains a separate pure
application check before any later transaction. A late irrelevant sibling cannot
invalidate an exact plan; a new relevant accepted head does. Private projection
must have verified local correspondence and ancestry; it is not a public origin.

## Proposed deterministic work profile

These are **local reference limits**, CLOSED_BY_SPECIFICATION as proposed tests,
not an allocated public wire profile or measured performance budget. D4 limits
are retained and additional caps make the preflight finite. Physical memory,
default-limit saturation and long-history usability still require qualification.
An implementation must not silently increase a limit or produce a different
partial result when exhausted. Public reuse needs a separately frozen M4 profile.

| Dimension | Initial limit / charging point |
| --- | --- |
| Selected tips / direct dependencies per fact | 64 each; validate count before resolving/enqueuing |
| Public facts in actual closure | 4096 distinct; includes accepted, basis, selected and proof/context dependencies; not all known candidates |
| Dependency depth / fanout | 256 /64; tri-color graph validation before evaluation; cycles InvalidContent, missing Unavailable |
| Paths | 4096 affected plus structural-closure paths; 1MiB cumulative raw component bytes; depth256; charge before path expansion/output allocation |
| Material origins | 4096 reachable/path,65536/request; at most1,000,000 aggregate origin node/edge visits; precharge each explicit traversal step |
| Incomparable frontier | 6/path; reject7 before subset allocation. At6:63 nonempty subsets,301 total unordered proper bipartitions across all subsets,945 whole labelled binary trees |
| Distinct values | 32/subset; all subset entries and states charged before retaining, even if another partition already succeeded |
| Pair applications | 32768/path,131072/request; one for every enumerated pair including conflict/ambiguity/equality; no hidden retry loops |
| Text inputs | 2MiB each; request at most32MiB distinct fetched text bytes; charge before reading/copying. Streaming content validation is separately bounded; large equality paths need no flattened bytes |
| Line descriptors | 131072/input for automatic text; count LF plus final fragment before building arrays. Exceeding this local work cap is a refusal, not proof of a content conflict |
| Alignment cells | (n+1)*(m+1) after common-prefix/suffix trimming, at most4,000,000 per actual base/result alignment; check by division before multiply/allocation |
| Aggregate alignments | 16,000,000 cells/path and64,000,000/request over distinct ordered exact (base bytes,result bytes) pairs; equality requires no alignment. Cache hits do not change logical charge. First charge before allocating the corresponding score matrix |
| Retained payload state | Sum byte lengths of ALL subset-state entries, deduplicated within a subset, <=8MiB/path,64MiB/request; same bytes in different subsets charge again. Charge before insertion, irrespective of implementation interning |
| Transient output | Before constructing a merge output reserve conservative len(left)+len(right) under the same per-path/request byte caps; release transient reservation after insertion/discard. A conservative refusal is explicit, never a truncated result |

Integer counters use checked arithmetic. Canonical traversal and exact pair keys
make results/refusals independent of arrival order and cache strategy. Ancestor
closure memoization does not grant free unbounded graph work: count canonical
node/edge visits in the specified reference traversal, not physical cache misses.
An optimized evaluator must match the reference charges or undergo a new review.
Resource refusal is `ChoiceRequired(normalization-budget, dimension, limit)`;
the pure content parser uses ResourceLimit, not this semantic choice result.
No exponential enumeration takes place before the frontier/counter checks.

The finite guard experiment exercises zero-cap pair/state/cell/state-byte
refusals **before** the guarded action; graph cycle/missing/depth/fanout/count
negatives; frontier7 refusal before pair work. It does not test default caps at
physical saturation, all path closure expansions or a million-visit graph.
Exact trace-level cache-independent visit charging and complete executable
default-limit fixtures remain a **M1a.2 gate**; do not advertise this as a fully
qualified production cost model.

## Original cases and observed results

Exact input facts/bytes remain in M0 and are copied as symbolic fixture facts in
[normalization-observations.json](normalization-observations.json). No generated
signed IDs stand in for unallocated V2 records. “Verified” here means small
symbolic outcome only; source authorization, cryptography, operations and SQL
are assumed inputs, not newly tested implementations.

| M0 | Expected and observed finite result |
| --- | --- |
| S01–03 | Publishing linear/sibling continuations leaves T00 accepted; pending tips A2, A1/B1, A2/B2 respectively |
| S04 | Select A2 at S0 ->T20 (`x=2\ny=0\n`); B2 pending |
| S05 | A1 already accepted; A2 ->T20 once; A1 path origin dominated |
| S06 | A1 accepted, select A2+C_ind ->T20 plus g=`c\n`; both selection orders agree |
| S07 | Exact D3 A2/Z1 regression ->T20 plus g=`z\n`, both orders; no false f conflict |
| S08 | C_dep alone ->T10 plus c=`requires x=1\n`; A1 is basis dependency, not separately selected |
| S09 | A2+C_dep ->T20 plus same c; A1:f dominated, both orders |
| S10 | A2+B2 ->Conflicted(f), no output |
| S11 | A2+B2_equal ->T20, both origins retained; histories not collapsed |
| S12 | NUL-containing OA/OB alternatives ->Conflicted(bin) |
| S13 | Compose(S0,A1,Y1) verified T11; CQ alone ->T11+c=`composed\n`; recipe order invariant |
| S14 | Incomparable material comparisons A1/Y1, accepted comparisons U/V ->ChoiceRequired(comparison) |
| S15 | Offline SA/SB both heads; default reconcile conflicts; exact choose-A2 ->T20 with B2 context-only. Equal-result SA/SB_equal still two heads |
| S16 | Conditional known-present T20; merge(T20,T20,E)=exact E, secret unchanged/private; no public secret input |
| S17 | B3 receipt does not change actual plan dependencies; exact-A2 plan stays valid, B3 pending |
| S18 | New SB changes bound accepted heads ->Stale; symbolic check does not exercise materialization or COMMIT |
| S19 | Evolution A2 but basis S0 ->T01; no ghost x=2 contribution |
| S20 | Previously discarded A1 not material parent of choose-B1; A2 now conflicts with B1 |
| S21 | Joined W(AX1,AY1)+AX2+CZ1 ->`x=2\ny=1\nz=1\n`, preserving AY1 |
| S22 | Recorded deletion versus continued file edit ->Conflicted(f), not Unavailable |

S01–03 are tip/status assertions, not merge runs. S15/S18 and privacy have
phase/context subcases, not extra counted semantic cases. Six valid receipt
orders of A1/B1/A2/B2 retain B2 and yield T20 for exact A2. A1-before-A2 content
evaluation order follows the recorded basis, not arrival order. No general
permutation invariance is claimed for semantically ordered edits.

### Corrected exact D3 counterexample

R0/S0:T00=`{f.txt:b"x=0\ny=0\n"}`; A1 basisR0 ->T10=`x=1,y=0`;
A2 basis/evolutionA1 ->T20=`x=2,y=0`. Accepted SA1 selectsA1 ->T10.
Z1 has no evolution predecessor, basisAccepted(S0), adds g=`b"z\n"` and
inherits R0's f. Select exactlyA2/Z1 atSA1. Both require public R0/S0/A1 closure;
B2 is unselected. Old global-base selection moves A1 back toR0 after Z1 joins,
compares x=1/2/0 against0 and incorrectly conflicts. New f frontier prunes
A1/R0 underA2; g keepsZ1. Both permutations give
`{f.txt:b"x=2\ny=0\n",g.txt:b"z\n"}`. No private bytes, receipt winner or
extra A1 application. This is the original M0/D3 expected result, not an output
chosen to match the new checker.

### Real nonconfluence witness

Independent recorded variants all use base `b"a\nc\nb\n"`:
A=`b"c\nb\nc\n"`, B=`b"a\na\nb\nc\n"`, C=`b"c\nc\nc\nb\n"`.
No material dominance between these three origins.

* (A+B)+C succeeds with `b"c\nc\nb\nc\n"`.
* (A+C)+B conflicts at the first merge.
* (B+C)+A succeeds with `b"c\nc\na\nb\nc\n"`.

Every pair/partial comparison uses the original recorded base. Actual OCaml
leaf results confirm all three trees. All six input permutations must return
**ChoiceRequired(nonconfluent)**, never whichever successful tree was visited
first. Seed20261120 found this at trial1392 (search ceiling20000). This fills
the missing concrete negative witness; it does not invalidate D4's exhaustive rule.

### Structural adversary and remaining gate

Base `{d:Directory,d/f:b"old"}`; A deletes subtree d; B retains d/f and adds
d/g=`b"new"`. Independent path equality rules could emit `{d/g:b"new"}` with
no parent. The independent checker detects this invalid tentative tree. Expected
**Conflicted(d)**; never silently add d, drop g or declare Ready. This is a real
counterexample to a path-only implementation, not to D4's mandatory whole-tree
validation. General resolution of subtree/type conflicts and preservation of
work outside chosen subtrees still needs exact executable fixtures.

Adversaries covered: duplicate ancestor application (S05), false conflict
(S07/S21), discarded ancestry (S20), omitted basis contribution (S08/S13),
pending alternatives and receipt winner (S03/S17), private path contamination
(S16 conditional witness), genuine text/binary/delete conflict (S10/S12/S22),
equal bytes/distinct ancestry (S11/S15), ambiguity (S14), nonconfluence above,
and finite pre-work guards. No test claims complete authority/correspondence
proof or physical memory qualification.

Before M1a.2: qualify general subtree choices/literal replacements with context
coverage, exact publication-scope/correspondence witnesses, long-lived DAG
charging and saturation/default refusal fixtures. The broad rule “derive and
check” is insufficient for coding these cases without another explicit scope.
M1a.1 must neither import this symbolic model nor expose partial candidate
normalization as a complete acceptance API. M4/M5 public encoding/signature and
acceptance transaction gates remain separate.
