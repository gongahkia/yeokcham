# Yeokcham V2 D4: blocker resolution

**DRAFT / OWNER APPROVAL PENDING**

Date: 2026-11-20, Singapore. Starting HEAD:
`3d31a41a58e0f79d02fcfa8dc864760748a29729`.

## 1. Executive outcome

**Design verdict: READY_FOR_OWNER_REVIEW.**
**Implementation preparation verdict: M0_READY_AFTER_OWNER_APPROVAL.**

This recommendation is for a deliberately bounded baseline/reference M0, not
M1a or any filesystem/public-protocol implementation. No implementation is
authorized by this document. All five owner decisions remain pending.

The D3 composition counterexample is resolved in a disposable reference model.
The recommended correction is **path-local material frontiers with a bounded
confluence check**, called `path-frontiers-v1` here. It combines basis-relative
derivation with target-relative composition without a global comparison base,
primitive replay, or a processing-order winner. Existing `line-hunks-v1` remains
the byte-level merge rule inside this explicitly new composition profile.

Model A survives. Neither a new change identity for every continuation nor a
persisted lane solves the demonstrated normalization failure. The correction
adds a derived query over immutable public facts, not another authoritative tree.

Cross-store copy-out and initial materialization are narrowed: stage the complete
tree privately, then publish it with a native **no-replace** directory rename
into a previously nonexistent destination. Pre-existing empty destinations refuse.
A locator marker travels with the staged directory and binds it to the original
SQL operation. There is no host-global ownership database and no incremental
population of an exposed destination. Native qualification remains pending.

Public wire layouts, native ABI/observation encodings and complete SQL enforcement
still have explicit pre-consumer freeze gates. They do not block the revised M0,
which must inventory them instead of claiming to freeze them. The old copy-out
failure remains unresolved. This is closure of specified design rules, not
runtime preservation, interoperability, power-loss or performance qualification.

## 2. D3 inventory, evidence and status

Status vocabulary follows the task: CLOSED_BY_DESIGN, REQUIRES_EXPERIMENT, OPEN,
and BLOCKED. A closed rule is a proposed contract pending owner approval.

| D3 blocker / D4 task | Disposition | Exact scope / remaining gate |
| --- | --- | --- |
| B1 / A: global-base normalization | CLOSED_BY_DESIGN | Sections 3–7 define a bounded deterministic profile and typed refusal. Reference cases pass; full profile/structural/budget qualification precedes M1a |
| B3 / B: cross-store new-destination collision | CLOSED_BY_DESIGN | Sections 8–9 use exclusive whole-tree publication, original operation identity and absent-only destinations. No empty-directory takeover |
| B3: native primitives/flush/identity | REQUIRES_EXPERIMENT | No native binding or filesystem is qualified by symbolic tests. Gate M2; Windows remains unqualified |
| B2 / C: arbitrary comparison-proof fields | CLOSED_BY_DESIGN at logical level | Derive normalizer inputs/results from exact signed facts and a versioned profile. No free-form proof that can override them; byte layouts remain OPEN before M4 |
| Private plan/action/SQL controls | OPEN at byte/constraint level | Section 10 assigns precise consuming tranches. No opaque placeholder may become a valid durable product record |
| D: object/SQL/GC handoff | CLOSED_BY_DESIGN ordering; REQUIRES_EXPERIMENT implementation | Section 11 closes ownership intervals; M1b fault matrix is mandatory. D3 SQL feasibility is insufficient |
| E: interrupted application | CLOSED_BY_DESIGN state/ownership rules; REQUIRES_EXPERIMENT executor | Section 12 retains all five phases, Paused/Recovery and complete-byte checks |
| BASELINE-COPYOUT-20261116 | OPEN, historical root cause unknown | Blocks old-runtime green/parity claims and unqualified Python M2 rollout, not isolated M0 reference work |
| Concurrent attachment to arbitrary existing/nested unmanaged trees | OPEN before supporting that M2 setup mode | Absent-only new workspace creation is covered. Do not infer this broader attachment protocol from pathname uniqueness or an advisory registry |

There is no demonstrated contradiction blocking the restricted M0. There are
explicit prohibitions on dependent implementation where a contract is OPEN.

Observed source state: clean `main`, no nonignored untracked files, target absent.
D3's final working edits have subsequently been committed externally; this task
uses the actual file contents, not the intermediate D3 commit. A SHA-256/mode
manifest inventoried all **517** pre-existing tracked/nonignored untracked files.
No reset, checkout, amend, commit, push, dependency installation or fetch was run.
Final preservation/Git observations are recorded in section 17.

Both D1/D2 and both D3 documents were read in full. Relevant source inspected:

| Source | Evidence and retained boundary |
| --- | --- |
| [Native_share.prepare](../../lib/yeokcham_v1_local_service/native_share.ml), [Integration.selection_root](../../lib/yeokcham_v1_integration/yeokcham_v1_integration.ml) | Existing all-head publication/selection gates really exist; changed only in the new proposal |
| [Composition.Graph](../../lib/yeokcham_v1_composition/yeokcham_v1_composition.ml), `common_base`, `effective_base`, `reconciled_base` | Existing recorded-base/represented-predecessor checks cannot be deleted without replacement |
| [Publication_receipt.proof](../../lib/yeokcham_v1_store/publication_receipt.ml), [Preservation](../../lib/yeokcham_v1_integration/preservation.ml) | Exact scoped source correspondence and known-present public/private distinction remain necessary |
| [Safe_apply](../../lib/yeokcham_v1_local_service/safe_apply.ml), `classify`, `entry_bytes_match`, `apply_with` | Native identities alone are insufficient; original/staged/installed/retained bytes matter |
| [Native_integration](../../lib/yeokcham_v1_local_service/native_integration.ml), `perform` | Materialized/Committed are distinct; resume must not replay files after the verified boundary |
| [C adapter](../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c), [snapshot codec](../../lib/yeokcham_snapshot/yeokcham_snapshot.ml), [registry](../../lib/yeokcham_envelope/yeokcham_envelope.ml) | Actual no-follow/exclusive/exchange operations, content identities and allocated codes |
| [Safety tests](../../test/test_safe_apply.ml), [recovery CLI tests](../../test/test_native_recovery_cli.py), [benchmark fixture](../../test/test_benchmark_runner.py) | Relevant crash/open-descriptor/copy-out and exact historical failure boundaries; no OCaml tests rerun |
| [Technical contracts](../TECHNICAL_CONTRACTS.md), TC01–TC08; [D3 contract](D3_CONTRACT_FREEZE.md) | Existing behavior, privacy, review, archive, capture, native fidelity and validation obligations retain their authority |

Evidence labels: **Observed** means D4 commands/experiments; **Source** means code
or test inspection; **Historical** means retained D3/P03/ledger reports;
**Proposal / [Inference]** means the rules and their predicted consequences below.
No proposed protection is claimed implemented. Examples are not a formal proof.

## 3. Exact reconstruction of D3 case 4b

All modes are regular; bytes below are exact LF bytes. `t00`, etc. are symbolic
snapshot identities, not fabricated verified digests. G is authenticated empty
genesis; R0 introduces `f.txt=b"x=0\ny=0\n"`; **S0 already accepts R0**. It is
not merely published or an unrelated dependency.

| Fact | Evolution edge | Verified public basis | Exact result |
| --- | --- | --- | --- |
| R0 | none | Accepted(G) | t00: `f.txt=b"x=0\ny=0\n"` |
| S0 | accepted parent G; selected R0 | accepted derivation | t00 |
| A1 | R0 | Revision(R0) | t10: `f.txt=b"x=1\ny=0\n"` |
| A2 | A1 | Revision(A1) | t20: `f.txt=b"x=2\ny=0\n"` |
| S_A1 | accepted parent S0; selected A1 | accepted derivation | t10 |
| Z1 | none, different ChangeId | Accepted(S0) | t00 plus `g.txt=b"z\n"` |

A2 needs A1/R0 and their public content closure to reproduce its result. Z1 needs
S0's public closure. Neither needs the other. Neither discloses local private
capture ancestry. Acceptance order is S0 -> S_A1, then exact `{A2,Z1}`.

Under D2's proposed whole-result derivation graph, the common comparison for
`{S_A1,A2}` is A1/t10. Adding Z1 makes it R0/t00. The f.txt variants become
x=1, x=2 and x=0 relative to x=0. `line-hunks-v1` reports two differing replacements
of the x line: **Conflicted**, with no accepted snapshot. This is the incorrect
blocking outcome; it is not an incorrectly written filesystem result.

The intended result is exactly:

```text
f.txt: b"x=2\ny=0\n"
g.txt: b"z\n"
```

D4 reconstructed both maximal-base sets and the conflict independently in scratch.
The exact Z1/g.txt=`b"z\n"` expectation above passes in both selection orders.
An additional analogous fixture, C0/g.txt=`b"c\n"`, also passes; it is not used
as a substitute for the original counterexample.

The problem is that an accepted wrapper is not a whole-result ancestor of A2,
although its f.txt value comes exactly from A1. A per-path projection can establish
that fact without inventing whole-snapshot ancestry or replaying A1.

## 4. Strategy comparison and recommendation

| Strategy | Merits | Falsification / complexity / decision |
| --- | --- | --- |
| 1: replay exact basis-relative primitive contributions in causal layers | Explicit dependencies and narrow signed scope; useful validation primitive | A1/B1 intermediate overlap can block before A2/B2 converge to equal endpoints. Ordinary evolution is not always a content dependency. A general patch-rebase/coverage algebra would be substantial. Do not adopt primitive replay as acceptance semantics |
| 2: normalize each whole candidate endpoint independently against the target, then merge | Directly accounts for accepted A1; simple two-input behavior | A2 and cross-change C1 based on A1 can count A1 twice: A2 carries x=2, C1's whole endpoint carries x=1. Processing order or extra accepted state must not decide which wins. Reject this unqualified whole-snapshot rule |
| 3: path-local material frontiers, then confluence-checked target composition | Preserves exact basis lineage, dependency contents and target context; removes dominated versions before merging; no global base | Requires a small derived path-lineage evaluator and bounded multi-input check. This is the recommended minimum reference contract; qualify cost before production |

Path scope **alone** is insufficient: target W may contain A1's x=1 plus a later
y=1; A2 changes x to 2; unrelated C changes z to 1 in that same file. A single
per-file common base can still move backwards. Likewise, cross-change dependency
prefixes cannot just be treated as extra selected patches. The reference tests
these stronger cases, not only D3's two-file example.

Recommendation: retain Model A and Strategy 3, with explicit deterministic bounds
and refusals. Model B would change naming/grouping but retains the same basis,
dependency, conflict and accepted-target problems. It is not a simplification
unless those responsibilities are removed, which would violate the task.

The new profile does not promise every mathematically conceivable combination.
Unsupported graph/work bounds, incomparable recorded comparisons and nonconfluent
valid results return ChoiceRequired. It never chooses a successful tree by ID,
arrival order, wall clock or implementation traversal order. These limits must
be visible in preview; they do not block preservation or independent publication.

## 5. Normative reference contribution semantics and algorithm

“Normative” in this section means the proposed **D4 reference contract**, pending
owner approval. It is not a claim that a wire schema or production codec is frozen.

### 5.1 Candidate, basis and path derivation

A candidate revision is an immutable authenticated public basis plus an exact
result and exact declared scope. Its own contribution is `diff(basis,result)`.
Its complete proposed state includes verified public dependency contents as well
as that new contribution. An evolution predecessor groups a same-change
continuation and fixes provenance; it supplies content lineage **only when** it
is also an actual public basis input. Equality of snapshots supplies no edge.

For each requested raw byte path, derive an in-memory *origin token* naming the
existing public record and result/basis slot that established its state. There
is no origin record/type code, persisted origin ID, SQL cursor or new authority.
Tokens are rebuildable from verified signed inputs, scope, profile and resolutions.

Path states are Absent, Directory, or File(mode, content), with regular,
executable and symlink modes distinct. Missing/corrupt objects are not Absent.

1. Empty genesis supplies a distinguished Absent origin for any queried path.
2. Accepted(R), Revision(R) inherit R's verified path origins. Compose evaluates
   its exact public inputs by this same contract; its result origins are derived
   basis-slot tokens of the enclosing already identified public record.
3. An unchanged candidate path inherits its basis origin. A changed path creates
   a result-slot origin whose material parent is its exact basis origin, with
   the actual before/after path state verified. Ancestor replacements include
   their actual descendant/absence effects even if the minimal signed scope
   names only the ancestor.
4. An accepted path with one surviving origin inherits it. A successful automatic
   merge creates a result origin with the entire surviving frontier as material
   parents. Equal-value alternatives retain every distinct input origin.
5. A shared explicit choice copies the chosen variant's path/subtree lineage;
   a literal replacement creates a new origin based on the uniquely identified
   comparison origin. Unchosen variants are proof/context edges **only**. They
   are not material ancestors of the chosen result. Private choices never create
   a public origin or shared resolution.

Material ancestry here proves a verified derivation/continuation, not that every
ancestor byte still occurs verbatim. Ordinary explicit edits can overwrite or
revert earlier edits. A resolution that discards a variant does not gain material
ancestry from the fact it considered that variant. This distinction makes an
already accepted predecessor removable without resurrecting a rejected sibling.

No-op requires path-specific derivation, not a global accepted flag. If all
requested path origins are dominated by the target's proven current origins,
there is no new content effect; the exact selection/provenance remains inspectable.
If a needed origin was discarded, is incomparable, or cannot be established,
normalization can conflict or require a choice. Receipt alone never establishes it.

### 5.2 Frontier and bounded confluence

For each path, start with target accepted origin(s) and exact selected candidate
result origins. Remove duplicates and material ancestors of another input:
those effects are already represented by a verified successor on this path.
Keep every distinct record in provenance/selection roles; this reduction affects
composition only. An unrelated candidate's unchanged path inherits its old
origin and cannot move this path's comparison backwards merely by arriving.

For two surviving origins, use their unique maximal **recorded** common material
ancestor, then the existing whole-path/`line-hunks-v1` rules. Incomparable bases
return ChoiceRequired. Temporary results do not become invented comparison bases.

For three to six surviving origins, enumerate all unordered binary partitions
of the frontier, recursively checking admissible combinations. Each successful
partial result keeps exactly its subset's original material parents; a temporary
node is not eligible as an invented recorded comparison. Deduplicate equal
partial states, but keep the complete frontier provenance.

- No complete compatible derivation: Conflicted, unless an ambiguous required
  comparison made the attempt unsupported, then ChoiceRequired.
- Multiple distinct complete result values: ChoiceRequired(nonconfluent).
- A comparison ambiguity encountered by the specified exhaustive check:
  ChoiceRequired; do not select a convenient tree instead.
- One complete value and no comparison ambiguity: that value is the result.
  A failed intermediate merge does not veto a verified complete compatible
  combination, and no single successful order is accepted without the full check.

The canonical result origin has all original maximal frontier parents; it does
not depend on which successful binary tree happened to be visited first. This
defines future lineage independently of diagnostic proof-tree layout.

Bounds proposed for the initial reference profile: at most six surviving origins
per path, 4,096 reachable origin nodes per path and 1,000,000 aggregate origin
visits per request. The two-origin text operation retains 2 MiB/input and
4,000,000 alignment cells including boundary cells, exact LF/CRLF/final newline,
deletion-first ties and conservative overlapping insertion/replacement rules.
Add a deterministic aggregate budget of 16,000,000 alignment cells per path over
distinct canonical base/result pairs. Cache strategy cannot change the charged
work. Overflow gives ChoiceRequired(normalization-budget), never partial success.

The scratch model exercises the six-frontier refusal and small byte fixtures;
it does **not** qualify the large-DAG/aggregate-budget implementation or running
time. Exact charging/iteration encoding and resource-bound negative fixtures are
a mandatory pre-M1a reference-freeze item, not an opportunity to invent wire bytes.
Six-frontier enumeration is a small bounded reference oracle, not permission to
search unbounded merge orders in a service. Future optimized paths need equivalent
results/refusals against this oracle, or a newly reviewed profile version.

Long-lived single-file histories must be part of budget qualification: repeatedly
requiring user choices merely because ordinary history has grown would fail the
quiet-operation objective. The proposed numerical bounds are not evidence that
such histories meet that objective; ancestor-proof reuse and its validation need
measurement before the profile is promoted.

### 5.3 Deterministic pseudocode

```text
prepare(target_parents, exact_selected, exact_resolutions, workspace_observation):
    validate scope, IDs, closure, signatures, authority/policy and required review
    reject missing inputs as Unavailable, false scope/proof as IntegrityFailure
    if branch has several admitted accepted heads:
        require explicit reconciliation naming the complete known parent set
        require a unique recorded accepted comparison; otherwise ChoiceRequired
    evaluate every named public basis; reject cycles and unsupported profiles
    for each canonical path in the bounded verified input/structural closure:
        inputs = target origins + exact selected-result origins at this path
        frontier = maximal material origins(inputs)       # no evolution shortcut
        if budget exceeded: return ChoiceRequired
        values, ambiguity = ALL_COMPLETE_DERIVATIONS(frontier)
        if ambiguity: return ChoiceRequired
        if no values: require an exact actual-conflict resolution or Conflicted
        if several distinct values: return ChoiceRequired(nonconfluent)
        derive output state and canonical lineage from the original frontier
    verify whole-tree structure and ancestor/type/delete-edit interactions
    reject overlapping, unused, stale or out-of-context resolutions
    accepted = exact canonical public snapshot
    known_present = only proven publication contributions on selected local ancestry
    working = existing exact merge(known_present, accepted, observed_private_tree)
    unknown/discarded correspondence => private ChoiceRequired; overlap => Conflicted
    retain plan and all roots; no acceptance, publication or ordinary-file writes

ALL_COMPLETE_DERIVATIONS(F):
    singleton => its exact state and origin
    otherwise evaluate EVERY unordered proper partition A | B:
        recursively obtain all supported partial results of A and B
        for every pair:
            require unique maximal recorded material comparison
            apply exact whole-path / mode / line-hunks-v1 rules
            retain a successful temporary state with original subset parents
    collect all complete values, comparison ambiguity and deterministic work charge
```

Paths are a presentation/verification decomposition, not permission to produce an
invalid tree. File/directory conflicts and directory-delete/descendant-edit cases
must be identified before output; do not silently drop descendants or resurrect
an ancestor. Regular mode and contents follow the existing separate checks;
symlink/opaque contents use exact equality/unchanged rules. Structural resolution
selects one exact subtree and preserves nonconflicting work outside that scope.

Required ordering is supplied by verified basis evaluation: A2's basis A1 is
evaluated before A2, and C1's Compose recipe before C1. Dependencies are not
replayed as extra selected changes. Independent compatible contributions are
combined as a set. No execution schedule, labels or receipt order determines
accepted contents. Old V1/Core controls retain their old composition semantics.

## 6. Worked semantic validation

Unless stated, each row starts from S0/t00 in section 3, has no private files,
and retains all unselected public variants. A1/B1/A2/B2 mean x=1/3/2/4, y=0.
C_ind means base Accepted(S0), new g.txt=`b"c\n"`; C_dep means base Revision(A1),
new c.txt=`b"requires x=1\n"`; C_y means base R0 and y=1; C_overlap means base
R0 and x=3. Different names are exact symbolic record IDs, not floating labels.

| Required case | Initial accepted state / selection | Dependencies and effective contribution | Exact result / pending work / decision |
| --- | --- | --- | --- |
| 1. R0 -> A1 -> A2 | S0; no acceptance during publication | A1 basis R0, A2 basis A1; f origins form a real material chain because these are also actual bases | Public A1 is `b"x=1\ny=0\n"`, A2 `b"x=2\ny=0\n"`; S0 unchanged; exact predecessor when ambiguous |
| 2. R0 forks A1/B1 | S0; neither selected | Both need R0; separate immutable material/evolution continuations | Both retained, neither accepted; publishing one does not reconcile the other |
| 3. A2/B2 independent | S0; neither selected | A2 needs A1/R0, B2 needs B1/R0; no cross-sibling dependency | Exact x=2 and x=4 endpoints coexist; valid receipt orders do not select a winner |
| 4. Accept A2 directly | S0; `{A2}` | f frontier prunes R0 in favor of A2; A1/R0 are reproduction dependencies, not extra applications | `b"x=2\ny=0\n"`; B2 pending, A1 superseded on A continuation; confirm exact plan |
| 5. A1 then A2 | S_A1/t10; `{A2}` | S_A1's f origin is A1, a verified material ancestor of A2; remove it on f only | t20 once, not x applied twice; B2 pending |
| 6. D3 failure | S_A1; `{A2,C_ind}` | f removes target A1 and C_ind's inherited R0; g keeps C_ind's new origin | t20 plus g=`b"c\n"`; both selection orders identical; original Z1 spelling instead yields g=`b"z\n"` |
| 7. Cross-change dependency | S0; `{C_dep}` | f inherits A1, c is C_dep's own contribution; A1 was not separately selected | x=1/y=0 plus c=`b"requires x=1\n"`; preview dependency-provided f explicitly; B2 pending |
| 8. Compatible different files | S0; `{A2,C_dep}` | f's A1 dependency is dominated by A2; c supplied by C_dep | x=2/y=0 plus c; no second application of A1; both permutations pass |
| 9. Overlapping lines | S0; `{A2,C_overlap}` | Incomparable x=2/x=3 f origins, comparison R0 | Conflicted(f.txt), variants retained; exact selection/replacement/defer needed. C_y instead yields `b"x=2\ny=1\n"` |
| 10. Opaque binary | SO includes `bin=b"\x00zero"`; select BA/BB based on O0 | Proposed bin values `b"\x00alice"`/`b"\x00bob"`; same exact base, no text merge | Conflicted(bin); explicit variant/replacement; other files preserved |
| 11. PublicBasis.Compose | Q composes S0 + A1 + C_y to t11; CQ based on Q adds c | Independently verify Q=t11, inherit its f origin, add CQ's c origin | Accepting CQ at S0 yields x=1/y=1 plus c=`b"composed\n"`; no prior acceptance of Q required |
| 12. Criss-cross | U=t10 and V=t01; two distinct valid accepted joins Q1/Q2 both t11, parents U/V; L/R continue separately | Maximal comparison histories are incomparable U/V even though joins have equal bytes | ChoiceRequired; no synthesized virtual base or equal-snapshot history collapse. Missing U/V instead Unavailable |
| 13. A2 accepted, B2 pending | S_A/t20; publish B3 from B2 | Publication has B2 as exact public basis; S_A does not gate it | B3 x=5 retained/publishable; S_A unchanged; B2 superseded only on pending B continuation |
| 14. Offline acceptance | Alice S_A/t20 and Bob S_B/t40 both parent S0 | Receipt retains both accepted heads. Reconcile parents `{S_A,S_B}`, f context R0/A2/B2; choose A2 explicitly | Common successor t20. For equal-content S_B', still name both accepted parents; no content change is needed merely to preserve both histories |
| 15. Public D/private E | Basis S0; source h1 has t20 plus private secret; P selects f. h2 has `f=b"x=2\ny=1\n"` plus private secret later | Receipt proves P/f at h1 on current ancestry. K=t20 without secret. Merge K -> accepted t20 with K -> E | Accepted t20; workspace E, secret private. Incomparable/discarded correspondence requires a private decision |
| 16. B3 during plan | Pinned exact-A2 plan at S0, workspace v/h/basis unchanged | B3 is outside actual input closure; no all-candidate-head/global-generation binding | Same plan/result. A new accepted head or authority/workspace change instead stales it; retain partial materialization if already started |

Every row separates immutable public records from authoritative local admission,
cursor/basis, requests/outbox and operation roots. Candidate status is derived
per accepted branch/head context. Only confirmed successful acceptance changes
the latter facts; publication and receipt do not apply files. Failed preparation
leaves accepted state and live files unchanged. Partial application follows
section 12 and may leave explicit partial files, never a false saved/accepted claim.

The public disclosure is the selected records and required public basis/proof
closure, including dependency versions; it excludes private source ancestry,
witnesses, plans, keys and E. C_dep cannot claim it excluded A1's f contents in
case 7. Dependencies do not constitute independent selection or approval. Source
privacy/authority/closure verification remains a separate admission prerequisite;
the toy reference does not implement those security boundaries.

In case 8, `requires x=1` is literal file content, not a machine-enforced runtime
constraint. Content dependency means reproducibility from A1, not a promise that
later compatible selection can never supersede A1. A semantic requirement on
program behavior needs observed evidence or an explicit acceptance decision.

## 7. Falsification results, limits and retained counterexamples

Observed external scratch directory:
`/var/folders/55/fw1sdntj20v8650vsmkn7s8c0000gn/T/yeokcham-d4-vl3wg3_3/`.
It contains `reference.py`, `falsification.py`, `extra_checks.py` and JSON results
with exact inputs, expected outputs, actual outputs and selected permutations.
No repository module/fixture is imported or modified by those models.

| Check | Observed result and limit |
| --- | --- |
| Focused reference | 26 checks across 17 case groups; exact expected small regular-byte/absence results, conflicts, criss-cross refusal, discarded ancestry, rebase, frontier-limit refusal and private E |
| Required graph facts and extra byte/status checks | 17 further checks: exact bases/evolution, independent endpoints, CRLF/no-final-newline, insertion conflict, private selection, accepted-head order/equal-snapshot identity and relevant staleness |
| Receipt order | All six valid topological receipt permutations of A1/B1/A2/B2 retain the same exact-A2 result, with B2 unselected |
| Original D3 spelling | Both permutations of exact A2/Z1 produce t20 plus `g.txt=b"z\n"`; the old global-base rule reports Conflicted |
| Seeded DAG permutation falsification | Seed 20261120, 300 one-path material DAGs, all six permutations of three chosen inputs: 1,800 comparisons agree. Graph outcomes: 238 Ready, 62 Conflicted |
| Namespace abstraction | 12 checks over both repository-winner orders, case-fold aliases, lost-progress identification and rename/substitution; no actual native syscall/flush qualification |
| Existing independent vectors | `python3 -B tools/generate_composition_vectors.py` verified four existing scope/page envelope/ID vectors without `--write`; no new public vectors or expected digests fabricated |

Random permutation checking is a falsification check against one computed oracle
result, not an independent proof of each result's correctness. Manual exact
expected cases supply the separate expected-value checks. The toy line splitter
is exercised on LF/CRLF fixtures and is not a qualified replacement for the
source profile on arbitrary byte/control-character inputs. Modes, directory
structure, resource exhaustion, signatures, Merkle witnesses, SQL crashes and
native application are outside the toy implementation.

Rejected-rule counterexamples remain in the evidence:

1. D3 global-base merging conflicts on x after adding an independent g edit.
2. Primitive causal-prefix replay conflicts at A1/B1 even when independently
   published A2/B2 have equal final x=2 endpoints. The revised profile retains
   both selected endpoint origins and coalesces their equal value.
3. Whole-snapshot target projection duplicates A1 through C_dep, giving x=2
   versus x=1. Path-frontier dominance removes only the redundant dependency.
4. Path scope with a single common base still fails the W/A2/C same-file case.
   The bounded all-derivations check produces the unique x=2/y=1/z=1 result for
   both selection orders, rather than choosing one convenient merge schedule.

No remaining incorrect Ready result was found in these checks. This is not a
claim of general confluence or absence of counterexamples. Multiple valid outputs,
ambiguous comparisons and bound overflow have a specified ChoiceRequired outcome;
comprehensive generated DAGs, structural cases, repeated-line/nonassociativity
fixtures and aggregate-work negatives are required before M1a promotion. A new
counterexample that produces a false Ready result reopens this design gate.

## 8. Cross-store destination ownership contract

### 8.1 Designs compared and selected scope

| Design | Assessment |
| --- | --- |
| Create an empty destination with mkdir, then fill it | Kernel creation chooses a winner, but the exposed directory is partial. Crash before recording its identity creates an adoption gap. Filling/cleanup needs more ownership and external-edit handling; reject for initial copy-out |
| Durable destination-local marker plus native identity | Useful for recognizing *our* already-published directory after lost progress. It is a locator/binding, not independent execution authority. Select as part of complete-tree publication |
| Host registry/global reservation database | Adds cross-user/version/bootstrap/recovery coordination and does not stop external writers. Reject as initial destination authority; scheduling registry remains advisory |
| Complete private tree, then exclusive native rename into absent destination | Select. One kernel operation claims the name and exposes the already-staged tree. Competing stores cannot exchange with, adopt or overwrite an existing directory |

The initial copy-out/clone/new-workspace materialization contract is **absent-only**:
the destination entry must not exist, its direct parent must already exist, and
the operation creates no missing parent hierarchy. Refuse a pre-existing empty
directory as DestinationExists; do not remove it for the user. Offer a different
unused path. This narrows D1/D2/D3's new-or-empty allowance and needs owner approval.
It does not retire eventual empty-directory support, authorize altering OCaml,
or prohibit metadata-only inspection of an unsupported destination.

Stable already attached **nonoverlapping** workspaces use their existing native
workspace lock, persistent store/WorkspaceId marker, SQL pending owner and
identity checks. Their unrelated operations remain independent. Exact same-root
aliases must resolve to that same marker/identity, not create a second cursor.
An unknown/foreign/incomplete marker refuses application.

Concurrent adoption of arbitrary existing/nested unmanaged directory trees is
not solved by absent-only export. It remains an explicit OPEN setup capability
before M2 may support it. No namespace UNIQUE index, scanner pass or advisory
registration list proves race-free attachment. The first qualified new-workspace
mode uses absent-only installation with a permanent attachment marker; existing-
tree adoption needs its own frozen exclusion/locking protocol. It cannot be
advertised as working merely because new-destination copy-out is qualified.

### 8.2 Exact durable facts and native order

SQL remains the sole operation authority. Before exposing destination bytes:

1. Bind request arguments, exact PlanId/OperationId, source workspace, target and
   safety CAS roots, intended native parent identity/raw leaf name, staging slot
   and source/attachment identities. Pin all required objects under the shared
   publication/GC gate. Signing/human waits have already released all locks.
   For copy-out, the destination pre-state is Absent and there are no displaced
   originals. A source capture pin describes that capture, not a fresh observation
   of all current source bytes; copy-out never mutates the source tree.
2. Construct the *entire* target in a private exclusive staging directory on the
   same filesystem. No user originals are moved during new-destination staging.
   Pre-Prepared partial staging is owned temporary work, never a completed
   materialization. The request/plan keeps its CAS inputs protected after a crash.
3. Put an immutable locator in the already-reserved `.yeokcham-v2` metadata area
   of that staged directory. Proposed `DestinationClaim-v1` is canonical CBOR:

   ```text
   ["yeokcham-destination-claim", 1, repository_b32, operation_b16,
    plan_b32, target_snapshot_b32, random_claim_token_b16, role]
   role = 0 (copy-out) or 1 (new managed workspace)
   ```

   The file `.yeokcham-v2/claim.cbor` is create-only, <=512 bytes, parser depth <=8,
   <=64 items, exact field count/types, no unknown version/role/extra fields.
   It contains no phase, cursor, secret or history. SQL stores its exact bytes/
   digest and stage native identity. A marker alone never authorizes recovery.
4. Verify target bytes/modes/names/structure and the marker separately; sync all
   staged files/directories. Commit Prepared plus immutable physical intent,
   expected stage identity, request association and protected roots in one short
   SQL transaction. No destination entry has been created yet.
5. Commit Applying before mutation. Reopen/revalidate parent/ancestor identities
   without following symlinks; reject managed/staging/source ancestors and native
   aliases. Invoke directory-relative Linux `renameat2(..., RENAME_NOREPLACE)` or
   macOS `renameatx_np(..., RENAME_EXCL)` to install the staged directory. **Never
   exchange, ordinary replacing rename, or populate the destination recursively.**
6. Sync source staging-parent and destination-parent directories; verify the
   installed owned directory, marker and complete target bytes again. Rewalk the
   requested parent/ancestor chain and check that it still names the bound native
   objects. A renamed parent or substituted pathname pauses with the installed
   tree retained; it is not success at the requested spelling. Only then record
   Materialized. The native name claim and exposure are one atomic
   operation; byte durability still depends on flush/filesystem qualification.
7. Commit the permitted metadata/result, then Completed/root transfer. Copy-out
   changes no source cursor, counter, accepted basis or ordinary source files.
   A managed workspace keeps its persistent attachment marker. Copy-out removes
   only its own locator metadata after durable commit, through verified owned
   handles and only if there are no unexpected metadata children; otherwise
   preserve it and report deferred cleanup.

The native APIs/flags are source-backed; their filesystem support/flush behavior
still needs qualification ([Linux rename](https://man7.org/linux/man-pages/man2/rename.2.html),
[Apple declarations](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/stdio.h)).
Unsupported flags, EXDEV, unsafe parent identity, permissions or flush failures
refuse/pause. There is no replacing fallback.

The metadata name is already reserved by the V2 isolation proposal. If an imported
target requires ordinary user data at that reserved path or a native case alias,
refuse before staging/installing it; do not omit those target bytes and call the
copy exact. Internal metadata is validated separately from the exact included
user tree. This is a scoped metadata exclusion, not weakening full-byte checks.

### 8.3 Processes, aliases, interference and release

| Situation | Required behavior |
| --- | --- |
| Two workspaces in one repository | Each has its own writer/pending owner. New-destination claims use the same kernel no-replace rule, not per-source serialization as a collision proof |
| Two stores/processes/users/compatible installations | Different SQL databases are immaterial to the name race. One native claim wins; the other returns DestinationExists and retains its own staging/roots. No global DB required |
| Same operation concurrently retried | Source workspace/process lock serializes it; the unique SQL plan-to-operation association identifies it. Recovery classifies that same stage/destination; it does not regenerate another operation |
| Relative/absolute/case aliases | Compare opened parent and native entry identities. Kernel no-replace resolves the actual namespace, including case-insensitive collisions; lexical path equality is insufficient |
| Symlink/reparse/bind/root substitution | No-follow traversal and parent/root revalidation. Unsupported aliases/mount arrangements refuse; no case folding or Unicode normalization of canonical names |
| Nested destination | Direct parent must pre-exist. A child claim cannot precede an absent parent's claim; afterward the parent's pending marker blocks a cooperative child operation. Existing parent destination itself refuses. No recursive parent creation |
| Destination/parent renamed while pending | Keep original identity and intent. If the requested path no longer names the owned directory, return LocationChanged/RecoveryRequired. Never adopt a replacement, replay into the old spelling or scan the host for a guessed owner |
| Another repository sees an existing claim | Foreign repo/op/token/native identity does not match its own pending SQL record: refuse, even if target bytes happen to match. Unknown marker version also refuses |
| Ordinary external writer / old noncooperating client | Advisory locks/markers do not stop it. Native no-replace avoids overwriting its pre-existing entry; post-install edits cause complete-byte/identity checks to pause. No universal prevention claim against arbitrary same-user writes |
| Completion and cleanup | Return durable historical result on the same key; do not freshly write or reverify today's output by replay. Release pins only after retention transfer. Never recursively delete an uncertain, foreign or relocated directory |

Only installations implementing this ownership contract are cooperative for
pending-prefix exclusion. Older tools and external writers are treated as
uncooperative, not assumed to honor a new marker. No user command may “take over”
a foreign claim implicitly. A byte-identical tree or copied marker is insufficient:
local SQL identity/intent, claim token, expected native identity and contents
must match. If native identity is insufficient to distinguish replacement, pause.

During a process's lifetime a parent handle can name a directory that an external
writer relocated. Descriptor-relative operations do not promise the original
absolute spelling still resolves there. Pre/post identity checks report that
uncertainty; they do not follow a newly substituted path to overwrite its contents.
After losing the handle, recovery requires an explicit exact relocation choice
and a newly checked private recovery plan, not automatic search/adoption.

## 9. Fully worked ownership/recovery timelines

### 9.1 Two repositories race for absent `/p/out`

`/p` is an existing qualified parent. Store A has Prepared OA, staged directory
inode IA with marker `(A,OA,tokenA)`, exact target TA and active CAS pins. Store B
has independently Prepared OB/IB/`(B,OB,tokenB)`/TB/pins. Both source trees are
unchanged. No destination entry exists.

A's no-replace rename publishes IA at `/p/out`. B's rename returns EEXIST; IB
remains B's private staging. Reversing process order reverses the winner, not
the safety rule. B does not read TA as its successful TB, even if TA=TB. It reports
DestinationExists with its own operation/staging state. A verifies IA/token/TA,
records Materialized and commits its original result. Only after its durable
completion may it remove its own copy-out marker; B still cannot overwrite the
now-ordinary existing output. No original destination was displaced.

The same rule covers relative/case aliases resolved to the same native entry.
The symbolic model exercised both winner orders and alias keys. No native race
was executed, so the kernel/filesystem implementation remains REQUIRES_EXPERIMENT.

### 9.2 Crash after ownership, before Materialized

OA is durably Applying, IA/TA/claim bytes and roots are in its intent. Native
rename succeeds and moves the entire prepared IA tree into `/p/out`; the process
dies before recording post-action progress or the Materialized observation.
SQL still says Applying. Stage slot is absent; destination exists.

Retry OA checks the original request/plan association and native pair. Matching
IA + exact own claim + TA permits **verification and directory sync only**, then
Materialized/commit/completion. It must not run rename again, fill files again,
or create a second export identity. If an external writer changed TA to U,
preserve U, keep TA and safety roots, and pause. If the stage is missing and the
destination is absent or foreign, location is unknown; do not reconstruct TA
at the old path as if the first installation never happened.

There is intentionally no state where this contract owns an exposed *partially
populated* destination. A crash during partial staging happens before claim:
the destination is absent, incomplete private staging is not accepted output,
and the pinned target can be rebuilt only through the recorded request/intent.
An external destination created meanwhile causes EEXIST, not adoption.

### 9.3 Destination replaced or renamed before recovery

After the previous crash, an external process renames IA from `/p/out` to
`/p/kept`, then creates foreign directory IX at `/p/out` containing `b"external"`.
The only SQL owner is still OA, with expected IA/tokenA and original parent/name.
No row states IX is owned. OA recovery finds IX or a mismatched marker/identity,
returns RecoveryRequired and leaves both directories untouched. It never deletes
IX, copies TA into it, or clears OA's roots to let normal application continue.

The user can provide `/p/kept` explicitly for a relocation/recovery preview.
Matching marker alone is insufficient; verify IA, exact intent, contents and
current ancestor scope. A new exact recovery plan preserves observed external
changes and retains original identity/provenance. If IA cannot be found, CAS
TA/safety remain recoverable but physical placement is unknown. No success claim
about the old pathname and no automatic host scan. After an already Committed
operation, return historical completion and report unknown current placement;
do not reapply because the response was lost.

## 10. Protocol/schema closure and exact consumer gates

“Frozen for reference” below is a review proposal usable by the restricted M0.
It is not permission to emit public controls or accept untrusted bytes. Existing
codes 1–47, old signing domains and old golden vectors remain unchanged. The
actual registry was re-inspected: 48–51 remain unallocated in source.

| Element / why D3 left it OPEN | Minimal D4 choice | State, consuming tranche and obligations |
| --- | --- | --- |
| Candidate meaning and evolution/content edges | Keep D3's candidate fields: ChangeId, predecessor/null, exact PublicBasis, result SnapshotId, exact scope. Evolution alone never provides material edges | CLOSED_BY_DESIGN semantics. M1a reference model; byte/schema vectors before M4. Unknown kinds/profiles refuse |
| PublicBasis | Accepted(id), Revision(id), or Compose(exact accepted inputs, exact candidate tips, resolutions, profile, claimed result). Evaluate the same path-frontier function; verify claimed bytes | CLOSED_BY_DESIGN logical roles. Exact CBOR field ordering/graph work charging remains OPEN before M1a reference promotion/M4 codec; never serialize an OPEN placeholder |
| Accepted dependencies/proof | Store exact parents, selected IDs, resolutions, result, policy/review context and a profile pair. Required content/proof closure is derived. Remove D3's independent direct-input set and arbitrary proof override | CLOSED_BY_DESIGN representation correction. Revised consecutive payload map/order must be frozen before M4; existing code 42 is not reinterpreted |
| Profile/version | Proposed normalization ID `path-frontiers-v1`, leaf ID `line-hunks-v1`; profile represented logically as this ordered pair | Frozen for reference. Resource charging/structural negatives and independent equivalence tests before M1a. Do not advertise only old line-hunks-v1 as if old composition semantics changed |
| Shared resolution | Bind exact accepted/chosen context, full actual path frontier, unique comparison origin, single path/subtree and chosen source or explicit public replacement. Context-only rejected variants are not material parents | CLOSED_BY_DESIGN rule; exact OriginRef/choice CBOR and nonconfluence-choice coverage OPEN before M4. Unsupported ambiguous comparison remains ChoiceRequired |
| Branch event | Preserve exact create/rename/advance/reconcile roles, causal event parents and accepted targets; acceptance + authored advance atomic | Frozen logical semantics; M4 codec vectors still required. Equal result snapshots do not discard accepted/event histories |
| Registry/framing/IDs | Proposed codes 48 candidate, 49 accepted, 50 branch, 51 resolution; Envelope-1 framing/object-format 1, public body 2, fresh per-kind `/v2` domains with the D3 NUL separator | Proposed reservations only, no registry mutation. Re-audit immediately before allocation; bounded canonical/signature/hash/domain negatives before M4 |
| Snapshot/content compatibility | Retain current Content/Chunk/Tree/Manifest/Snapshot bytes, object/full-content domains, modes and Buzhash defaults | Frozen inherited meanings. Complete independent content corpus before M1a; this does not grant repository or control-protocol interoperability |
| Private plan | Exact repository/workspace/kind/version/cursor/basis, accepted/event/authority/policy/review inputs, selected/resolutions, observed snapshot/ignore/native read set, public/private outputs and decisions. PlanId keeps `yeokcham/plan/v2` + NUL + canonical control hash | Logical contract closed; canonical private field order/version and platform observation bytes OPEN before M1b durable plans/M2 executor. A list of hashes is not a verified plan |
| Operation actions | Immutable ordinal/raw path/root+parent identities, pre/post state, stage/retained slots and native action/expected identities; mutable serial/progress separate. Whole-directory new-destination action uses no-replace only | Logical contract closed; exact native identity/ABI/action encoding and relocation recovery control OPEN before M2. No second JSON execution journal |
| Metadata constraints | D3 SQL fact ownership retained. Add complete immutable-field/phase/root-release validation and sequence-reservation checks; represent root ownership independently of object existence proof | OPEN production DDL/transition enforcement before M1b. D3 feasibility does not approve a schema migration |
| Cross-store claim | DestinationClaim-v1 in section 8; local SQL + stage identity + exact marker; absent-only native install | CLOSED_BY_DESIGN. Independent marker byte vectors and native race/flush qualification before M2; arbitrary existing-tree attachment remains OPEN |
| Authority/custody carriage | Preserve historical/current verification distinction and explicit authority forks. No new-public adoption by borrowing old domains | Exact unchanged trust bundle reuse/carriage and principal/policy controls OPEN before M4; required unsupported modes refuse. No M0 dependency |
| Capability negotiation | Require exact public-control version 2, normalization/leaf profile pair and supported envelope/type/mandatory features in a new repository scope | Logical rule closed; exact bounded handshake/media/route encoding OPEN before M5. No V1 fallback for changed control semantics, auth or integrity failures |

Retain D3 identity sizes: repository/record/object/digests 32 bytes, workspace/
branch/change/operation 16 bytes, capture `(workspace, nonnegative int64)`,
signature 64 bytes. Public control bound 8 MiB, reference sets <=16,384, parser
depth <=16/items <=131,200, sorted raw-byte sets, consecutive integer map keys,
explicit nulls, strict UTF-8 text and raw byte paths. Unknown versions/features
refuse. These scalar requirements do not freeze the OPEN payloads or qualify a
generic canonical-CBOR provider. No new expected vector digest was generated.

Proposed new signature domains remain D3's exact per-kind `yeokcham/record/.../v2`
ASCII bytes followed by NUL and canonical body; logical RecordId hashes the full
signed canonical envelope, StoredObjectId uses its separate old object domain.
The four new codes are **draft reservations**, not an implementation registry.
Removing redundant draft fields is incompatible with an independently built
unapproved D3 sketch; no such interoperability is promised. Do not reuse an old
registered code/signature domain to accommodate the correction.

No full protocol/SQL freeze is claimed. M0 can inventory every OPEN item and its
gate. M1a can be authorized only with its bounded pure/content scope and required
reference/resource fixtures settled. M1b/M2/M4/M5 must not fill gaps while coding.
Private-account/review/archive/migration protocols remain separate retained
obligations, not omitted for aesthetic simplicity.

## 11. SQLite, object, GC and backup obligations

Keep SQLite plus immutable objects, DELETE/EXTRA, explicit SQL transactions and
one metadata owner. The new normalizer changes no persistence ordering. Official
transaction/backup documentation was rechecked; it does not transact external
objects or worktrees ([SQLite transactions](https://www.sqlite.org/lang_transaction.html),
[Python transaction control](https://docs.python.org/3.14/library/sqlite3.html#transaction-control),
[backup API](https://www.sqlite.org/c3ref/backup_finish.html)).

### 11.1 Design closures and newly explicit intervals

| Boundary | Required rule; prohibited inference |
| --- | --- |
| Object before SQL | Shared publication/GC gate covers validated create-only object publication, file and shard/ancestor-directory sync through authoritative root COMMIT. No success from an orphan |
| Reader before root lookup | Acquire shared gate before reading SQL roots, or atomically establish durable reader pins while still holding it. Release SQL read transactions before streaming. Timeout/PID reuse cannot release a live pin |
| Uncertain COMMIT | Under autocommit=True use SQL BEGIN/COMMIT/ROLLBACK, not connection.commit(). Reopen/recover and look up original request and plan-operation association; never blindly reallocate/resign/reapply |
| Same-key concurrency | Serialize the local request claim and freeze argument/unsigned intent. Same key/different digest refuses. A pending key retains its own pins through provider/process interruption; a live duplicate returns/joins that identity |
| Root-pin transfer | New owner and complete surviving pins become authoritative in the same short transaction that releases the old owner. An FK or verification Boolean is not proof of durable valid external bytes |
| Operation staging | Object GC never traverses/unlinks physical operation staging/displacement as generic temp data. Only workspace-owned cleanup after durable phase/retention checks can reclaim it. Pre-Prepared temporary staging contains no displaced original |
| Quarantine/publish race | Exclusive gate fixes collector roots; no root writer bypasses it. A later publisher needing quarantined bytes verifies/restores or republishes them before COMMIT. Purge rechecks current reachability, not an old counter |
| Consistent backup | Shared gate covers completed SQLite backup destination inspection and live backup-intent/pin COMMIT. Pins come from the completed destination DB, not a guessed start timestamp or mutable live-root enumeration |
| Pending-operation backup | DB/object history backup is not resumable execution backup. Exact native staging/displaced coverage and quiescence/identity verification are required for the stronger class; missing physical data refuses replay |
| DB loss | CAS alone cannot reconstruct admission, cursors, requests, ownership or successful acknowledgement. Restore consistent metadata explicitly; orphan signed files are not automatically accepted/published |

Lock order remains workspace/process ownership -> shared object/GC gate -> short
SQL transaction. Collector uses exclusive gate then short SQL and never waits for
a workspace. Absent-destination installation needs no host namespace lock/registry.
Native operations happen outside SQL. No network, full scan, renderer, signer or
human wait holds a SQL transaction. No root-changing writer may take a SQL lock
first and wait for the gate. Multi-workspace locks, when needed, sort by raw ID;
normal independent workspaces hold only their own locks.

A's long capture may share the gate with C's receive/capture; B's confirmation
wait holds only persisted plan pins. B Paused blocks B's ordinary partial-tree
capture, not A/C. SQLite write commits still serialize briefly. Fairness, BUSY
latency and collector starvation require measurements; a shared gate is not a
promise of unlimited progress on saturated storage.

D3's illustrative sequence trigger permits shapes that only the adapter can
authorize, especially `next_seq=NULL`. The production rule is explicit: ordinary
capture refuses exhaustion; only the exact pending operation can insert its
already burned reserved sequence. Capture append/cursor/counter and request
result commit atomically; Prepared burns its reservation once; cancelled gaps
are never reused. Complete immutable-field and valid phase transitions, root-owner
kind/cardinality and release guards are pre-M1b schema work. D4 does not pretend
the illustrative DDL already enforces them.

### 11.2 Mandatory M1b fault-injection matrix

Each point needs before/after process termination and an independent metadata,
object, identity and root inventory check. All fixtures are disposable, separate
from old stores/G01 measurements; record exact build/host/filesystem provenance.

| Inject at / concurrency | Expected invariant and retry |
| --- | --- |
| Temp create/write/file fsync | No authoritative capture/result; incomplete owned staging can remain. Same request never mistakes it for saved history |
| Canonical link/rename and every directory sync | Either a fully published verifiable object or no eligible new root. Flush error never returns completed capture |
| Durable objects before BEGIN/SQL insertion | Orphans may exist, old metadata authoritative; no auto-admission or capture from orphan bytes |
| Sequence allocation/capture/cursor before COMMIT | All rollback together; no published cursor to absent node. Exhaustion/reservation/duplicate collisions exercised |
| COMMIT before/after response, IOERR/FULL/BUSY | Recover DB, query same key/op; same committed IDs/result or explicit pending/unknown. Lost response creates no second capture/acceptance |
| Pending unsigned intent/provider wait | Source/plan pins survive, no SQL/gate lock retained while waiting. Same request resumes frozen inputs, not latest disk |
| Reader root lookup/open/stream vs GC | Reader gate or committed pins covers entire use; no read transaction held over stream; failed liveness check leaks protection rather than deleting bytes |
| Two publishers + collector | Exclusive collector cannot interleave publication/root handoff. Re-reachable quarantine restored/verified before new root; no stale purge |
| Old-owner release/new-owner root transfer | Every recovered committed state contains a complete owner; no intermediate unprotected root or pending physical stage deletion |
| Quarantine move/progress/purge marker/unlink | Restartable original intent; current roots rechecked before purge. Missing files after interruption are classified, not blindly declared safe |
| Incremental SQLite backup with concurrent writers/root release | Completed destination DB is internally consistent; its exact pinned closure remains available, including roots no longer in the live DB |
| Crash before/after backup-intent commit | Uncommitted artifact is not acknowledged coverage; committed frozen backup intent is retryable. Stream objects only after pin handoff |
| Backup DB with pending operation but missing physical stage | History-only classification; no source replay or Completed fabrication. Matching recovery bundle needed for resumption |
| Corrupt/missing object or DB | Typed integrity/unavailability, stop relevant mutation; keep diagnostics/data. No rollback-by-overwrite, derived-index rebuild masquerading as authoritative recovery |
| A/B/C workspaces, one Paused/human wait | Other two make bounded independent progress; no global repository generation stales their valid plans |

Ordering/pin ownership is CLOSED_BY_DESIGN; the matrix is REQUIRES_EXPERIMENT.
Automatic history eviction stays off. Quarantine receipt bytes and full production
enforcement remain OPEN before enabling collection. Process kills cover process
failure, not controller flush lies, torn sectors or physical power loss; separate
native/storage qualification is mandatory. No hardware-independent guarantee.

## 12. Recovery and BASELINE-COPYOUT disposition

Preserve `Prepared -> Applying -> Materialized -> Committed -> Completed` and
recorded Paused origins plus explicit Recovery. New-destination publication is
one physical action inside that state machine, not a replacement for it.

Pending operations retain safety/target CAS closure, exact plan/op/request,
proposed public result, physical stage/displaced locations and complete SQL pins.
Cancellation before mutation may close intent while retaining safety. After
mutation, cancellation pauses; it does not erase ownership or unlink the tree.
Recovery uses an immutable linked private recovery intent under the original
pending owner, with its own monotonically numbered recovery generation. Original
plan/intent is never edited. No second active workspace owner is created. Exact
recovery control bytes remain a pre-M2 freeze item.

In-place restore/integration still use preservation-aware exchange or exclusive
moves and retain displaced originals. Old descriptors may change those nodes;
complete bytes as well as native identity must be checked. Safe target install
does not authorize deleting an unexpected original. A Materialized operation
never replays file writes. A newly received accepted head/authority change before
COMMIT pauses with target/safety/displaced roots retained. Later private edits
remain live, including after a historical Materialized boundary. Commit uses
fresh unrelated metadata while revalidating only actual dependencies.

For new-destination copy-out there was no displaced original because the target
entry was absent. An occupied or even empty destination is never exchanged.
This removes one source of complexity, but does not diagnose the old checker.

**BASELINE-COPYOUT-20261116 remains OPEN and unresolved.** Exact historical test:
`test/test_benchmark_runner.py::RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs`,
linear/branching 8,192-byte/eight-file attribute fixtures. Reported error:
`installed target bytes changed at "restored" after application`.
Preserve the ledger/receipt, original source and binary hashes, full logs,
compiler/runtime, Dune action/TMPDIR, direct-run contrast, shapes and complete-byte
assertions. D4 inspected the source/checker; it neither debugged nor modified OCaml.

| Tranche / claim | Impact |
| --- | --- |
| Restricted M0 | May record immutable evidence, semantic cases, inventories and gaps. No reproduction/bug fix, native application or green-CI claim required |
| M1a pure/content reference and M1b isolated metadata faults | Can be separately scoped without relying on the failing copy-out implementation. They do not establish filesystem safety |
| M2 source-writing/copy-out qualification | Cannot close its safety gate without discriminating independent tests and an explicit resolved-or-isolated disposition. Absent-only design alone is insufficient evidence |
| M3 managed restore and M5 clone/acceptance rollout | Inherit M2's qualified executor requirements; cannot advertise parity or use the old failure as a waived guard |
| OCaml full CI/parity claim | Remains blocked until separate investigation establishes cause/correction and passes relevant checks/full CI on the exact source |

Before M2 promotion, implement tests distinguishing true bytes changed versus
false classification: new/empty (empty must now refuse), direct versus Dune-like
temp placement, both tiny history shapes, original/staged/installed/retained
bytes and modes, raw names/directories/symlinks, chunked/large files, parent/root
substitution, preserved-mtime edits, old open file/directory descriptors, every
intent/native rename/sync/progress/Materialized/COMMIT boundary, lost response,
same-token retries and concurrent destinations. Deliberately changed installed
bytes must fail; unchanged exact bytes with benign metadata differences must
not be rejected solely by a faulty fingerprint assumption.

Resolved means the OCaml cause is established and the corrected old path passes
its discriminating regression and required verification under separately
authorized work. Isolated means the Python implementation has a demonstrably
different qualified path, independently detects true mismatches, reproduces the
relevant environmental/fidelity/fault conditions, and records an approved explicit
limitation. Isolation never labels the OCaml issue fixed. If neither is supported
by evidence, M2's gate remains blocked. No assertion/check may be weakened.

## 13. Simplicity and architecture impact

Keep one domain/application API, SQL authority, immutable CAS, small native
adapter, transport/custody boundaries and existing workspace identities. The
correction introduces no published origin object, latest pointer, writable
frontier map, conflict registry, lane, review waiver or event-sourced authority.
An origin map and partial-derivation cache are disposable query results; their
inputs/results must be verified against signed immutable facts, not trusted after
a corrupted cache read. Losing them requires recomputation, not recovery of
private cursors from object files.

The additional domain responsibility is narrow: evaluate exact basis path
lineage, remove proven material ancestors and check bounded compatible joins.
Fast cases have one or two surviving origins. A reference implementation can
enumerate the small remaining cases; production optimization is evidence-gated.
This is less state machinery than per-change applied-event logs, patch rebasing
records or independent coverage databases. It is still real algorithmic
complexity, and its limits/cost must be explicit rather than marketed as a trivial
Python translation. Reject an optimization that hides a different answer/refusal.

The ownership correction removes initial support for empty-destination takeover
and partially populated exposed exports. Stage bytes remain rebuildable before
Prepared; after Prepared, SQL owns exact intent and the locator only binds native
placement. Existing in-place preservation remains necessary. No new mandatory
user command exposes these internal concepts: choose an unused output path,
inspect/confirm an exact plan, and use the existing operation recovery surface.

An agent uses the same workspace, capture, exact-source publication, comparison,
test-evidence and acceptance APIs as a human. Quiet capture, source privacy,
receipt without application and deliberate acceptance remain the intended daily
workflow. No orchestrator or persisted lane is added. Git/Jujutsu remain fair
baselines with reasonable automation; D4 provides no value/performance result.

## 14. Exact amendments required in D1/D2/D3

None of these files is edited by D4. The following is the explicit reconciliation
list for owner review and any separately authorized documentation update; do not
silently claim old text already agrees. Approved V1/Core contracts are not
changed by a new draft.

| Existing text | Required amendment / retained boundary |
| --- | --- |
| D1 section 4.2 independent continuation | Retain Model A; explain that evolution grouping alone is not material ancestry. Selective acceptance uses a new bounded normalization profile with explicit unresolved outcomes |
| D1 sections 4.3/5 J2,J7/6 restore and clone | Initial Python copy-out/new materialization accepts only nonexistent destinations with pre-existing direct parents. Empty existing destinations refuse. Keep safe restoration and eventual broader workflow commitments |
| D1 sections 7/9 departures and owner decisions | Record the new profile, absent-only staging qualification and revised reference-only M0. Do not grant approval or delete review/archive/platform obligations |
| D2 sections 5.2/6.1–6.3 | Replace global common-base endpoint algorithm with sections 5–7 here. Preserve basis/scope validation, exact content IDs and old leaf hunk semantics. Do not replay dependencies as selected edits |
| D2 sections 6.4–6.6 | Specify S0 already accepts R0, add exact D3/stronger cases and independent input/receipt permutations. Retain accepted-head reconciliation and dependency-scoped plan freshness |
| D2 sections 8/9.2/11.1/13 clone/restore | Add immutable destination locator, whole-directory exclusive publication and absent-only scope. Remove initial empty-directory exchange promise; qualify arbitrary existing-tree attachment separately |
| D2 sections 4/14 | Add pending-key pin ownership, physical-staging exclusion from object GC, exact reservation/exhaustion guards and the M1b fault matrix. Retain DELETE/EXTRA and short transactions |
| D2 sections 16/19.3 | M0 inventories/reference-freezes existing facts and D4 semantic cases; it does not freeze OPEN public/native/SQL consumers by implication. Consumer gates remain explicit |
| D3 architecture sections 1/6/8/9 | Replace blanket M0 blockage with the two D4 verdicts and bounded scope. B1's reference semantics and absent-destination collision rule are closed by design; native qualification and existing-tree setup remain distinct |
| D3 contract sections 2–5 | Define material versus context-only edges per path. Remove arbitrary proof override/direct-dependency duplication from proposed accepted controls; revised exact payload map is a pre-M4 gate, not an old-protocol reinterpretation |
| D3 contract sections 6–9/11 | Keep SQL skeleton as illustrative; no claim of full enforcement. Replace initial global destination-prefix registry requirement with absent-only exclusive installation, and retain explicit unsupported attachment scope |
| TC02/TC06 expectations | Preserve exact public/private outputs, current authority/review and default confirmation. New profile is an intentional versioned departure from old global composition behavior; no V1 source/fixture changes |
| TC04/TC05/TC07/TC08 | Preserve capture/service/fidelity/ignore/storage/validation goals. SQL representation, isolated experimental formats and phased qualifiers remain owner decisions. New internal metadata names must be explicit mandatory exclusions with collision refusal |

These named departures are proposals, not blanket permission to change an
approved contract or silently use a different reader. If the owner rejects a
departure, the dependent scope must be revised before implementation. Existing
research notes remain background discussion and are not amended or promoted to
a competing product RFC.

## 15. Owner decisions: maximum five, all pending

| Decision | Recommended disposition / qualification |
| --- | --- |
| A: product/Model A | Approve qualified quiet history, independent continuation and selective acceptance using the bounded `path-frontiers-v1` reference contract. Approve the initial absent-only copy-out/materialization restriction; retain typed decisions and later product obligations |
| B: persistence | Approve SQLite plus immutable objects, DELETE/EXTRA and the stated root/reader/backup/fault obligations; no automatic history eviction before archive proof |
| C: compatibility/protocol | Approve retained content identities with new public controls/profile and isolated stores. Accept staged wire/native/SQL freeze gates instead of a false complete freeze; no old-control interoperability or implicit upgrade |
| D: human/agent API | Approve existing workspace identities and ordinary directories through one typed API, exact evidence, safe retirement and evidence-gated lanes; no new authority primitive |
| E: execution order | Approve the bounded reference-only M0 below, side-by-side development and explicit later tranche gates, preserving P4/G01–G20 and review/archive/platform commitments. Actual M0 execution still needs a separate instruction |

No disposition is recorded as approved. D4 authorization covered reading,
verification and this document only. Approval of direction or a document is
not authorization to execute a tranche or publish data.

## 16. Revised M0 readiness and proposed scope

**M0_READY_AFTER_OWNER_APPROVAL** for this revised scope; no readiness finding for
M1a/M1b/M2/M4/M5 follows. This is narrower than D3's all-protocol contract-freeze
assignment and makes its remaining OPEN dependencies explicit.

Proposed future permitted additions, after separate instruction and checking
their absence:

```text
python/reference/README.md
python/reference/baseline.json
python/reference/semantic-cases.json
python/reference/vector-inventory.json
python/reference/qualification.json
python/reference/open-contracts.json
```

M0 would record actual HEAD/status and preservation hashes; source/registry/
old-reader/old-vector identities; exact D4 cases with selected/dependency/pending
roles and expected bytes/refusals; retained invariants/departures; independent
vector inventory and plan; current host/build facts and qualification gaps;
proposed budgets/fixtures; and every pre-consumer freeze item from section 10.
It may verify existing read-only vectors or disposable copies after checking
their command behavior. It must not execute a writing generator in the checkout.

M0 does **not** add a product package, dependency lock, executable, public-control
codec, native binding, service, SQLite store/migration, new public byte vectors,
protocol-v2 schema declaring OPEN fields final, or metadata DDL claiming complete
enforcement. The earlier proposed `protocol-v2.schema.json` and `metadata-v2.sql`
are excluded from this M0. Reference-case JSON is documentation evidence, not a
production persistence/wire format. Keep symbolic IDs explicit; do not fabricate
cryptographic vector expectations.

Acceptance for that one assignment:

1. Only the permitted reference additions; old files/fixtures/reports and active
   data untouched, preserved by a before/after manifest.
2. Exact case inputs, manual expected bytes/refusals, valid receipt/selection
   permutations and evidence limits recorded without claiming a formal proof.
3. Old content identity/encoding/chunking requirements and independent vector
   sources inventoried; missing corpus and provider work remain plainly pending.
4. BASELINE-COPYOUT recorded unresolved, with its preserved evidence and M2 tests;
   no OCaml investigation, accepted G01 rerun or green-CI claim.
5. Each OPEN field/qualification has its precise consuming tranche and prohibition.
   No dependency installation, physical application or public/private migration.
6. Reference structure/links/whitespace and preservation checks pass. The handoff
   proposes one next separately authorized scope; it starts none.

Rollback is to stop that reference assignment and retain its artifacts for review;
any later removal concerns only inspected new reference files. No reset, old
reader disposal or active-data rollback. Existing P4 and G01–G20 status stays
unchanged; M-sequence coverage must be reconciled when future authorized execution
permits ledger updates. Windows qualification begins with native/service seams,
not silently postponed indefinitely.

There is no unresolved issue that requires the restricted M0 to guess a public
schema, touch live data, install dependencies or run a native writer. If future
M0 instructions reintroduce those dependencies, this readiness verdict does not
apply; rescope or return M0_BLOCKED before executing them.

## 17. Verification, preservation and handoff

Observed D4 checks: external symbolic reference/expected-value/falsification and
namespace models described in section 7 pass; four existing independent scope/
page vectors pass read-only. Official native rename and SQLite/Python documentation
was consulted. No dependency was installed. D3's 23 SQL checks plus strengthened
negatives remain **historical feasibility evidence**, not a fresh D4 crash test.

An initial criss-cross scratch fixture used values inconsistent with an automatic
join. Before final validation it was corrected to compatible U=x=1/y=0 and
V=x=0/y=1, two distinct verified-rule joins x=1/y=1, and separate descendants.
The retained final model verifies that join's bytes and returns ChoiceRequired
for its two incomparable comparison origins. This correction affected only
disposable scratch, not source, fixtures or RFCs.

Observed closeout at 2026-11-20 08:08 UTC: the documentation link checker passes
390 local file references; the new document has no local fragment links. Its 17
numbered sections, balanced fences and whitespace checks pass. `git diff --check`
passes. The 517-file starting hash/mode manifest reports no changes or removals;
only this D4 path was added relative to the start.

Initial Git state was clean at `3d31a41a58e0f79d02fcfa8dc864760748a29729`.
An external process committed an intermediate D4 snapshot as
`793bdd036e8f448f876c808376d336e4763601d1` during this review. Observed final HEAD
is that commit; status is ` M docs/v2/D4_BLOCKER_RESOLUTION.md` on
`main...origin/main`, with no additional untracked files. The working changes
retain the later qualifications and this closeout. This task ran no commit
command and did not discard or rewrite the external snapshot. Preservation is
measured against the initial files, independently of the changing Git baseline.

Not run: OCaml builds/tests/full CI, native rename/locking/flush experiments,
real SQL/GC process-kill faults, provider installation, public-control byte
generation, power-loss tests, service registration, benchmarks, lane experiment,
M0, P4 or any G-phase. No native implementation, cryptographic protocol or full
VCS is reported complete. Existing-tree attachment, consumer-specific byte
contracts and native/platform qualification remain visibly gated.

Proposed next tranche: the restricted M0 in section 16, **after owner decisions
and a separate M0 instruction**. Do not begin it while awaiting review. If later
falsification finds an incorrect Ready result or an ownership gap within the
qualified absent-only contract, reopen that design item before its consumer.

**No implementation was authorized or started.**
