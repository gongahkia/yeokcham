# M0 semantic reference: exact candidates and selective acceptance

Version: `m0-reference-1`. Recorded 2026-11-20.
Status: independently reasoned reference expectations under the owner's M0
planning assumptions, **not implemented behavior or a formal proof**.

This document specifies 22 cases: the 18 required M0 cases and four regression
extensions. Expected bytes/refusals follow [D4 sections 3–7](../D4_BLOCKER_RESOLUTION.md#3-exact-reconstruction-of-d3-case-4b),
not whichever implementation runs. No domain implementation was created for M0.
D4's symbolic results are historical evidence with their documented limitations.

## Reading the cases

Paths and contents use Python **byte literal notation**, without executing Python.
`\n`, `\r`, `\x00` denote exact bytes. All listed files are Regular unless stated;
root directory is implicit. Every unlisted ordinary path is **Absent**, not an
unavailable object. Missing/corrupt dependencies instead give Unavailable or
IntegrityFailure before composition. Empty directories and other modes require
the structural/fidelity tests in the vector inventory.

`Txy` is a symbolic exact SnapshotId for this complete tree:

```text
T00 = {b"f.txt": b"x=0\ny=0\n"}
T10 = {b"f.txt": b"x=1\ny=0\n"}
T20 = {b"f.txt": b"x=2\ny=0\n"}
T30 = {b"f.txt": b"x=3\ny=0\n"}
T40 = {b"f.txt": b"x=4\ny=0\n"}
T01 = {b"f.txt": b"x=0\ny=1\n"}
T11 = {b"f.txt": b"x=1\ny=1\n"}
T21 = {b"f.txt": b"x=2\ny=1\n"}
```

`T20 + {g: bytes}` means that complete tree plus exactly the listed new file;
`g`, `c`, `bin`, `secret` abbreviate byte paths `g.txt`, `c.txt`, `bin`,
`secret.txt`. These are symbolic identities, **not expected cryptographic digests**.
G, R0, A1, etc. are distinct symbolic complete signed RecordIds; changing a record
does not mutate an old name. Actual ID bytes/signatures require frozen schemas
and independent vectors. No timestamp, label or receipt order is causal authority.

The common public facts are:

| Fact | Evolution predecessor | Exact verified public basis | Complete result / own scope |
| --- | --- | --- | --- |
| G | none | authenticated accepted genesis, no parent/selection | empty tree |
| R0, change X | null | Accepted(G) | T00; `{f.txt}` |
| S0 | accepted parent G; selects R0 | exact accepted derivation | T00; **R0 is already accepted** |
| A1, change X | R0 | Revision(R0) | T10; `{f.txt}` |
| B1, change X | R0 | Revision(R0) | T30; `{f.txt}` |
| A2, change X | A1 | Revision(A1) | T20; `{f.txt}` |
| B2, change X | B1 | Revision(B1) | T40; `{f.txt}` |
| S_A1 | accepted parent S0; selects A1 | exact accepted derivation | T10 |
| S_A | accepted parent S0; selects A2 | exact accepted derivation | T20 |
| S_B | accepted parent S0; selects B2 | exact accepted derivation | T40 |
| C_ind, different change Y | null | Accepted(S0) | T00 + `{g: b"c\n"}`; `{g}` |
| Z1, different change Z | null | Accepted(S0) | T00 + `{g: b"z\n"}`; `{g}` |
| C_dep, different change C | null | Revision(A1) | T10 + `{c: b"requires x=1\n"}`; `{c}` |
| Y1, different change Y_text | null | Revision(R0) | T01; `{f.txt}` |

Only facts named in a case's known set participate. Default known set K is
`{G,R0,S0,A1,B1,A2,B2}`; add the case's named facts. K does not mean selected.
`cl(R)` denotes exact recursive **availability/proof closure** including R,
its public basis inputs, scope/result content objects, evolution predecessor,
accepted parents/selected facts/resolution context where applicable, and trust
references. It never means replay all those facts as selected changes.
Content-only basis inputs are stated separately when an evolution edge differs.
All referred contents must be verified from an eligible public source; knowing
a hash or possessing private-only cached bytes does not establish public eligibility.

Origin notation `A2:f` means the derived result-slot origin for f, not a new
persisted identity. `0:g` is G's Absent origin at g. `J(S;A,B):f` is the derived
accepted join result with material parents A:f/B:f. An unchanged path inherits
its basis origin. Changed-path origin's parent is its exact basis origin.
An evolution edge supplies material ancestry only if it also supplies that basis.
Rejected resolution variants are context-only, not material ancestors.

For every case, unless overridden:

- Private contents are empty. Sources contain only listed public bytes. Any
  unselected private source/ancestry/witness is excluded from public records.
- Signatures, repository scope, current author authority, exact scope/closure
  and optional-policy configuration are **fixture preconditions**, not M0-verified
  cryptographic facts. Unsupported required review/adoption refuses; confirmation
  never grants authority. The actual public wire schemas remain OPEN.
- Preparing a result does not accept, publish, transfer, move a cursor or write
  files. Committing acceptance is separately authorized and uses a confirmed
  plan, native application and atomic metadata/outbound publication.
- Immutable facts remain unchanged. SQL would own admission, workspace cursor/
  basis/version, request results, pending operations and roots; heads/status are
  derived. Every unselected tip remains pending in this branch context unless
  already selected, resolved, or superseded on its own continuation.
- A failed preparation leaves accepted state and ordinary files unchanged.
  After physical mutation, explicit partial state/roots survive under Paused;
  no automatic rollback or lost-response replay is permitted.

## Contract algorithm and open bounds

For each path: derive exact target and selected-result origins, remove only
duplicates/material ancestors of another input, then evaluate the surviving
frontier. The selected RecordId set and all provenance roles remain inspectable
after this reduction. Dependency contents can participate without becoming a
second selection or a second application.

One survivor supplies its state. Two survivors require a unique maximal recorded
common material comparison, then exact whole-path/mode/`line-hunks-v1` rules.
For a bounded larger frontier, check **all unordered binary partitions** and
all supported partial results. Temporary joins retain their original subset
parents but are not invented recorded comparison bases. One complete value with
no encountered comparison ambiguity is Ready; no complete value is Conflicted;
multiple values, incomparable comparisons or work overflow require ChoiceRequired.
An ambiguous comparison in the exhaustive check cannot be bypassed by selecting
a convenient successful tree. Canonical result lineage contains all original
maximal frontier parents, independently of traversal order.

Whole-tree ancestor/type/delete-edit validity is checked before output. Exact
actual-conflict resolutions must match full context and preserve unrelated paths.
Choice copies the chosen variant lineage; literal replacement uses the unique
comparison as material parent. Rejected variants remain proof/context only.
Accepted-head reconciliation additionally names all locally known accepted heads
and requires an unambiguous recorded accepted comparison. Private output is
separate: merge known-present public projection K with accepted output and the
observed private continuation. Unknown correspondence gives a private decision.

| Bound / profile | M0 status |
| --- | --- |
| Leaf `line-hunks-v1`: <=2 MiB/input, <=4,000,000 alignment cells including boundaries after trimming; LF-byte splitting, deletion-first ties | Existing source-defined leaf contract retained; large/opaque uses equality/unchanged or conflict, not storage exclusion |
| Normalization `path-frontiers-v1` | M0 planning profile name and logical algorithm; no wire advertisement or production qualification |
| <=6 surviving origins/path; <=4,096 reachable origins/path; <=1,000,000 aggregate visits/request | **OPEN proposed D4 upper bounds**; not a frozen executable profile or a measured cost result |
| <=16,000,000 aggregate alignment cells/path over distinct canonical base/result pairs | **OPEN** exact charging, iteration, unique-pair accounting and boundary negatives before full M1a normalization |
| Long histories, modes/subtrees, nonconfluence/refusal encoding | Reference qualification and exact supported subset OPEN before consumer. No arbitrary tie-break or unbounded search |

Resource refusal must be deterministic for a finalized profile and independent
of cache hits/traversal schedule. M0 does not decide the missing charging rule.
These OPEN items block the **full normalization consumer**, not isolated ID/content
work or reference preparation. No consumer may serialize OPEN as null/empty proof.

## Core case matrix

### S01 — linear candidate continuation

Start: accepted S0/T00, known `{G,R0,S0,A1,A2}`, private empty; selection `{}`.
Bases/evolution: R0 -> A1 -> A2 with the Revision bases in the common table.
Dependencies: A1 uses cl(R0); A2 uses cl(A1), not another selected patch.
Represented: S0:f=R0:f. Current acceptance frontier is `{R0:f}`.
Normalized effect on accepted state: none. Expected accepted snapshot T00;
published A1=T10 and A2=T20 coexist immutably. A2 pending; A1 superseded only
on its continuation. Publishing A2 needs exact predecessor and public scope,
not acceptance. Each public closure contains its historical f versions only.

### S02 — two independent siblings

Start S0/T00; known `{G,R0,S0,A1,B1}`; selection `{}`; private empty.
A1/B1 both evolve/use R0 independently; dependencies cl(R0) each.
Represented R0:f; acceptance frontier `{R0:f}`, normalized effect none, result
T00. Pending `{A1,B1}`. Either publication/receipt order retains both; neither
selects a winner. A combined request would instead have frontier `{A1:f,B1:f}`
and conflict at f; independent publication does not require that combination.

### S03 — A1/B1 followed by independent A2/B2

Start S0/T00, known K, selection `{}`, private empty. Bases/evolution as common
table; A2 needs cl(A1), B2 cl(B1), neither needs its sibling.
Represented R0:f; frontier `{R0:f}` for unchanged accepted state; normalized
effect none/result T00. Pending exact tips `{A2,B2}`; A1/B1 retained ancestors.
All six orders satisfying A1<A2 and B1<B2 preserve the same facts/tips:
`A1 A2 B1 B2`, `A1 B1 A2 B2`, `A1 B1 B2 A2`, `B1 B2 A1 A2`,
`B1 A1 B2 A2`, `B1 A1 A2 B2`. This is a causal order constraint, not a winner.

### S04 — select A2, leave B2 pending

Start S0/T00, known K; select `{A2}`. Dependencies cl(A1), including R0/G;
evolution A2<-A1. Represented R0:f is dominated by A2:f; f frontier `{A2:f}`.
Effective target change is f from `b"x=0\ny=0\n"` to `b"x=2\ny=0\n"`.
Ready accepted T20; with no private work, proposed workspace T20. A1/R0 are
dependency/history roles, not additional selections; B2 pending, B1 its ancestor.
The public closure does not need B1/B2 merely because locally known. Exact
confirmation/current authority remain required for a later commit.

### S05 — accept A1, then A2 once

Start S_A1/T10, known K plus S_A1; select `{A2}`. Bases/evolution unchanged;
required closure cl(S_A1) plus cl(A2). Target f origin **is A1:f**, not a new
competing edit. Frontier `{A2:f}` after pruning A1:f. Effective change x=1 ->2;
Ready T20, B2 pending. Do not reapply R0->A1 or treat A1 dependency as another
selected change. This is distinct from reusing an old request to accept A1 again.

### S06 — A1 accepted, then A2 and unrelated C_ind

Start S_A1/T10, known K plus S_A1/C_ind; select `{A2,C_ind}`.
C_ind basis Accepted(S0), evolution null/different change, own scope g only;
required cl(A2), cl(C_ind), cl(S_A1). On f, target A1:f and C_ind's inherited
R0:f are dominated by A2:f: frontier `{A2:f}`. On g, target `0:g` is dominated
by C_ind:g: frontier `{C_ind:g}`. Normalized effects x=1->2 and g addition;
Ready `T20 + {g: b"c\n"}`. Both selected orders give exactly this result.
B2 pending. C_ind's inherited f is not a fresh x=0 proposal against A2.

### S07 — exact D3 A2/Z1 counterexample

Start S_A1/T10, known K plus S_A1/Z1; select `{A2,Z1}`. Z1 has null evolution,
basis Accepted(S0), own scope g, exact bytes `b"z\n"`; dependencies cl(S0).
A2 basis A1/evolves A1, closure cl(A1). Represented target A1:f.
Old whole-result comparisons: `{S_A1,A2}` -> A1/T10; adding Z1 moves comparison
to R0/T00. Endpoints x=1,2,0 relative to x=0 produce the spurious Conflicted(f).

Correct D4 frontiers: f `{A2:f}` after pruning A1:f/R0:f; g `{Z1:g}` after
pruning Absent. Normalized changes x=1->2, add g. **Ready exact result**:

```text
{b"f.txt": b"x=2\ny=0\n", b"g.txt": b"z\n"}
```

Both `{A2,Z1}` input permutations must agree; B2 pending. Selection does not
disclose private contents or accept B2. The expectation follows inherited-path
origins and dominance, independently of D4's passing scratch implementation.

### S08 — cross-change public dependency without selecting A1

Start S0/T00, known K plus C_dep; select `{C_dep}` only. C_dep has different
change/null evolution, basis Revision(A1), result T10+c, own contribution c.
Required cl(A1) and C_dep; A1 is a content dependency, not separately selected.
Target R0:f is dominated by inherited A1:f; frontier f `{A1:f}`, c `{C_dep:c}`.
Effective output includes dependency-provided x=1 and added c. Ready
`T10 + {c: b"requires x=1\n"}`; pending A2/B2. Preview must expose that f
effect. Accepting only c without x=1 requires a different valid candidate/choice.
Literal text in c is not an enforced runtime compatibility constraint.

### S09 — compatible candidates on separate contribution paths

Start S0/T00, known K plus C_dep; select `{A2,C_dep}`. Required cl(A2)/cl(C_dep);
bases/evolution as S08/common. Target R0:f and C_dep's A1:f are dominated by
A2:f. Frontiers f `{A2:f}`, c `{C_dep:c}`. Effective result
`T20 + {c: b"requires x=1\n"}`, Ready in both selection orders, B2 pending.
No extra A1 patch; its public bytes remain disclosed in required closure.
Independent contributions need no incidental processing order, although basis
validation must evaluate A1 before A2/C_dep. Program compatibility still needs evidence.

### S10 — overlapping text lines

Start S0/T00, known K; select `{A2,B2}`; private empty. Required cl(A2)/cl(B2),
independent basis chains via A1/B1. R0:f is represented but dominated by both;
frontier `{A2:f,B2:f}`, unique maximal comparison R0:f/T00.
Effective variants replace x=0 with x=2 and x=4 at the same line.
**Conflicted(f.txt)**, no accepted output in either permutation. Both tips stay
pending. Require exact scoped shared choice/replacement or narrower selection;
confirmation does not choose a side. Private resolution must not become public.

### S11 — identical final bytes, distinct histories

Add B2_equal, evolution B1/basis Revision(B1), result **T20**, distinct from A2.
Start S0/T00; known `{G,R0,S0,A1,B1,A2,B2_equal}`; select both exact endpoints.
Closures cl(A2)/cl(B2_equal), common material comparison R0:f. Frontier retains
`{A2:f,B2_equal:f}` even though values equal. Ready T20; normalized result origin
has **both** material parents. Both permutations agree; no pending tip from this
known selected pair. Signed IDs/evolution/provenance remain distinct; equal bytes
do not prove correspondence, history equality or permission to drop a parent.

### S12 — incompatible opaque binary variants

Add O0, basis Accepted(S0), null evolution, result `T00 + {bin: b"\x00zero"}`;
SO accepts O0 from S0. OA/OB independently evolve/use O0, with results
`T00 + {bin: b"\x00alice"}` / `T00 + {bin: b"\x00bob"}`.
Start SO; select `{OA,OB}`; required cl(SO)/cl(OA)/cl(OB).
Represented bin=O0:bin; frontier bin `{OA:bin,OB:bin}`, comparison O0:bin.
f stays R0:f. Both binary replacements differ: **Conflicted(bin)** in either
permutation, no output snapshot. OA/OB and default K's A2/B2 remain pending.
Explicit whole-path choice/replacement required; never use a guessed text merger.

### S13 — explicit PublicBasis.Compose

Start S0/T00; known K plus Y1/CQ. CQ's evolution is null/different change;
its **inline basis recipe Q**, not another accepted head, is
`Compose(accepted={S0}, candidates={A1,Y1}, resolutions={},
profile=(path-frontiers-v1,line-hunks-v1), claimed_result=T11)`.
CQ result is `T11 + {c: b"composed\n"}`, own scope c. Required recipe inputs
cl(S0)/cl(A1)/cl(Y1) plus CQ/scope/content. Recompute Q, do not trust its claim.
Q's f frontier `{A1:f,Y1:f}`, comparison R0:f; x/y line replacements combine
to T11 in both recipe orders. CQ inherits derived basis-slot f origin with those
parents; c frontier `{CQ:c}`. Selecting `{CQ}` at S0 gives Ready
`T11 + {c: b"composed\n"}`. A2/B2 pending; A1/Y1 are dependencies, not selected
by this acceptance. No hidden evolution edge or prior Q acceptance is created.
Wrong claimed result is IntegrityFailure; missing input Unavailable; unsupported
or ambiguous recipe requires a typed refusal, not a convenient base.

### S14 — ambiguous criss-cross ancestry

Use U accepted from S0 selecting A1 ->T10, and V from S0 selecting Y1 ->T01.
Distinct accepted Q1/Q2 each reconcile exact parents `{U,V}` with no resolution,
valid result T11 and f origins `J(Q1;A1,Y1):f` / `J(Q2;A1,Y1):f`.
L basis Accepted(Q1), null evolution, result T21; R basis Accepted(Q2), null
evolution, result `{f.txt: b"x=3\ny=1\n"}`. SL accepts L on Q1, SR accepts R on Q2.
Start known accepted heads `{SL,SR}`, respective exact trees above; private empty.
Request reconciliation of **both**, selected new candidates `{}`.
Required cl(SL)/cl(SR) includes U/V/Q1/Q2/L/R/A1/Y1/S0/R0/G.
Frontier f `{L:f,R:f}`; maximal material comparisons `{A1:f,Y1:f}` incomparable.
Accepted comparison histories `{U,V}` are also incomparable.
**ChoiceRequired(comparison)**; no output or new accepted fact. Default K's B2
and any unselected candidates remain retained/pending. Missing U/Y1 instead gives
Unavailable; invalid join claim IntegrityFailure. Do not collapse Q1/Q2 because
T11 matches or synthesize a virtual common base. An unsupported choice mechanism
cannot be invented during implementation; compare/defer remains available.

### S15 — independent offline accepted heads

Alice initially knows S0 and accepts `{A2}` ->S_A/T20. Bob knows only S0 and
accepts `{B2}` ->S_B/T40. Their local closures are cl(A2) and cl(B2), not the
unknown peer's accepted fact. On exchange the exact head set is `{S_A,S_B}` in
either receipt order; **no filesystem, cursor or chosen basis moves**.

A common successor explicitly reconciles parents `{S_A,S_B}`, selects no new
candidate, with dependency/proof closure cl(S_A)/cl(S_B). Frontier f
`{A2:f,B2:f}`, comparison R0:f; default result Conflicted(f). A scoped choice of
A2 against that complete context yields T20, with only A2:f as material lineage
and B2 context-only; both accepted histories remain causal parents. B2 is now an
accounted/replaced variant in this successor, not a global rejected record.
No unselected tip other than any separately known future continuation is deleted.

Equal-content subcase replaces Bob's B2 by B2_equal from S11, S_B_equal/T20.
Two accepted heads still survive. Explicit parent-complete reconciliation can
produce T20 without content conflict; f lineage retains both equal origins.
Knowing candidates alone never causes either acceptance. Relevant authority/
policy still gates admission; a foreign invalid fact is not promoted to a head.

### S16 — public D accepted, later private E preserved

Start accepted S0/T00, workspace w cursor h2 parent h1 parent h0. h1 is exactly
`T20 + {secret: b"private\n"}`; h2/current observed E is
`T21 + {secret: b"private later\n"}`. P is different change/null evolution,
basis Accepted(S0), public result T20, scope f only. Private correspondence
proves P's f value at exact h1 using scope/Merkle witnesses and h1 ancestor of h2.
Select `{P}`; dependencies cl(S0)/P and its public contents. h1/h2/secret/witness
remain private. Public f frontier `{P:f}` dominates R0:f, result D_public=T20.
Known-present projection K_present is exactly **T20**, not h1 or h2 including secret.
Private merge `merge(K_present,T20,E)` yields exact E because accepted side is unchanged.
Expected accepted T20; expected workspace T21+private-later secret. A2/B2, if
known from default K's public graph, remain unselected/pending. No secret bytes
or private ancestry enter public closure. Missing/nonancestor/discarded source
correspondence instead requires a **private** ChoiceRequired, never live-tree acceptance.

### S17 — unrelated late sibling during exact plan

Start S0/T00, known K; ready exact-A2 plan binds accepted/event heads S0/e0,
workspace `(w,v,h,basis=S0)`, observation T00, relevant authority/policy/review
and cl(A2), resolutions empty; select `{A2}`. Already represented R0:f;
frontier `{A2:f}`, effective result T20 as S04.
Receive B3, evolution B2/basis Revision(B2), result `{f.txt: b"x=5\ny=0\n"}`.
B3/cl(B2) changes no actual plan input. **Same exact plan remains valid**;
result T20, B3 pending and B2 superseded on B continuation. The metadata commit
must retain B3's admission. Never bind a global generation or all candidate tips.
All valid receipt orders for the unrelated closure leave this result invariant.
An explicit completeness claim about that sibling set would be a different plan.

### S18 — new accepted head invalidates exact plan

Start with the same S17 plan/selection/dependencies/frontier/result proposal.
Receive valid S_B/T40 with parent S0, chosen B2. Now accepted heads
`{S_B}` replace S0 as the known target head. If S_A was independently already
committed, the head set instead contains `{S_A,S_B}`. For the uncommitted S17 plan the exact
bound set `{S0}` is no longer current, even if a new head's bytes matched T00.
**Stale**, requiring a new parent-complete plan/decision. No fresh accepted output
is authorized; proposed T20 is retained, not committed. A2 remains pending in
the current branch context unless separately accepted; B2 is selected by S_B.

Before physical writes: accepted state is received S_B, workspace unchanged T00.
After Applying/Materialized but before COMMIT: keep target T20 (and any later
external edits), safety T00, stage/displaced copies, exact operation and pins;
pause, do not publish stale S_A or replay/rollback. If S_A already committed
before S_B receipt, return that historical success and retain both heads instead.
This distinction follows the local COMMIT boundary, not network time.

## Additional regression cases

### S19 — evolution rebase does not retain old contents implicitly

Start S0/T00, known K plus A3_rebased; select `{A3_rebased}`. Evolution
predecessor A2 (same X), **basis Accepted(S0)**, result T01, scope f.
Content inputs cl(S0); causal/proof closure also requires A2/cl(A2). Target R0:f
is material parent of A3_rebased:f; A2:f is not. Frontier `{A3_rebased:f}`;
effective x stays 0, y becomes 1; Ready T01, B2 pending. A2 is superseded in
evolution but never reintroduced as x=2. The disclosed causal closure may include
A2's historical public bytes without those bytes being material inputs again.

### S20 — accounted-for discarded ancestor is not already applied

S_chooseB has accepted parent S0, exact selection `{A1,B1}`, actual conflicting
f context, scoped resolution choosing B1 ->T30. Material f origin is **B1:f**;
A1 is resolution context-only. Start S_chooseB/T30, known K plus that resolution
and accepted fact; now select `{A2}`, whose basis/evolution is A1.
Dependencies cl(S_chooseB)/cl(A2). Frontier `{B1:f,A2:f}`, comparison R0:f;
effective x=3 versus x=2 overlap. **Conflicted(f)**, no output, A2/B2 pending
as appropriate to these exact older selections. Do not prune A2 through a graph
edge that merely proves A1 was considered/rejected. An explicit new choice is needed.

### S21 — stronger same-file mixed-basis normalization

Use a fresh isolated family: R3 basis empty genesis ->
`F000={f.txt: b"x=0\ny=0\nz=0\n"}`; S3 accepts R3. AX1 uses/evolves R3 ->F100;
AX2 uses/evolves AX1 ->F200; AY1 uses R3/null evolution ->F010; CZ1 uses
Accepted(S3)/null evolution ->F001. Fxyz changes only the three literal ASCII
digit values in the exact three-line template. W accepts `{AX1,AY1}` on S3 ->F110.
Start W/F110, private empty, select `{AX2,CZ1}`; required cl(W)/cl(AX2)/cl(CZ1).
Target f origin is join `{AX1:f,AY1:f}`, not either single ancestor. Frontier
`{W:f,AX2:f,CZ1:f}`; none dominates another. A single global/per-file comparison
R3 exposes false x conflicts in some intermediate grouping. All supported
complete derivations must yield the one compatible value
`{f.txt: b"x=2\ny=1\nz=1\n"}`; Ready in both selection orders.
The effective changes to W are x=1->2 and z=0->1, preserving y=1.
No unselected tip in this isolated family is deleted; AX1/AY1 historical roles
remain. The algorithm must check all bounded derivations, not pick the first
successful grouping. This is D4's stronger retained regression, not an invented base.

### S22 — deletion versus continued file edit, not missing data

Start S0/T00, known K plus DEL; DEL null evolution/different change, basis
Revision(R0), result empty tree and exact scope `{f.txt}`. Select `{DEL,A2}`;
required cl(DEL)/cl(A2). Target R0:f is dominated; frontier `{DEL:f,A2:f}` with
unique comparison R0:f. DEL:f is a recorded Absent state with material parent
R0:f; A2:f is the changed file. **Conflicted(f.txt)** in both permutations,
no output, DEL/A2/B2 remain available/pending absent a later explicit decision.
Missing DEL content/proof would instead be Unavailable, not proof of deletion.
Whole-tree directory/delete-descendant cases need separate structural qualification.

## Reference acceptance and remaining gaps

All 22 cases have exact contract expectations; none is a newly passed production
test. Ready, Conflicted, ChoiceRequired and Stale are different results. For S01–03
the expected result is preservation/publication of alternatives with no acceptance.
S15/S18 include phase-specific subcases; they are not extra counted test passes.
Compatible selection permutations, valid dependency order and nonapplying receipt
properties are stated with their exact cases. No requirement asks an invalid
causal order to produce an admitted result before its dependencies are available.

Future independent tests must cover all these rows plus scope lifting, overlapping
subtree decisions, mode/content combinations, symlink opacity, repeated-line and
nonassociative hunks, deliberately nonconfluent graphs, deterministic budget
charging/exhaustion, corrupt/private-only closures, false scope, cycles, wrong
repository/kind/version and discarded/nonancestor correspondence. Such missing
qualification is not a license to return Ready or choose a convenient order.

The present reference supplies no concrete independently checked graph with two
different successful normalized outputs; that negative **corpus gap is OPEN**.
The contract for one is ChoiceRequired(nonconfluent). Find a real witness or
prove the relevant restricted subset cannot exhibit it; do not fabricate a fixture
to claim coverage. Full M1a normalization readiness remains gated by this work
and the OPEN resource/structural specification in the safety companion.
