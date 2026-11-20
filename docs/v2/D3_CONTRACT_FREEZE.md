# Yeokcham V2 D3: contract review and partial freeze

**DRAFT / OWNER APPROVAL PENDING**

Review date: 2026-11-20, Singapore. Observed HEAD:
`ecd6accd0cc496c3566c60f81b2785476116b6ca`.
Overall verdict: **BLOCKED**, for the reasons in
[architecture gate](D3_ARCHITECTURE_GATE.md). This is a partial freeze for review,
not a complete wire protocol, production schema or implementation authorization.

## 1. Contract status and identity model

`FROZEN_FOR_REVIEW` means a concrete D3 recommendation; it remains subject to
owner approval, independent vectors and the stated qualification gates. `OPEN`
means consumers must not choose a meaning or encoding during implementation.
Approved V1/Core contracts retain their existing authority and bytes. D1/D2/D3
are proposals and do not amend those documents or their implementation ledger.

| Contract | D3 status | Earliest consumer / gate |
| --- | --- | --- |
| Supported fidelity, privacy, four transition boundaries, no inferred authority | Retained existing requirements | All tranches |
| Typed identity sizes and occurrence allocation | FROZEN_FOR_REVIEW | M0 reference fixtures; M1b real transactions |
| Exact old content/chunk/tree/manifest/snapshot encodings | Retain source-defined meanings; independent corpus incomplete | M1a after M0 vector review |
| Independent same-change continuation and exact candidate selectors | FROZEN_FOR_REVIEW product semantics | M1a/M4 after owner A |
| General represented-contribution composition | OPEN B1, case 4b | Blocks M1a public-composition consumer, M4/M5 |
| Codes 48–51, framing and explicit ordered record fields | Proposed reservations / review-frozen portions | No emitted bytes until B2/vector gate |
| Compose/acceptance comparison proof, authority carriage, private plan/action bytes | OPEN B2/B3 | Blocks their codecs/admission/executor |
| SQL fact ownership, constraints and explicit transaction discipline | FROZEN_FOR_REVIEW skeleton | M1b after fault tests; not an approved migration |
| Destination-prefix exclusion across stores | OPEN B3 | Blocks general M2 copy-out/application support |
| Native API/flush requirements | FROZEN_FOR_REVIEW behavior; binding/ABI unqualified | M2 native capability gate |
| Provider versions, build allowlist and platform qualification | OPEN dependency selection | Before each dependent tranche; no installation in D3 |

Identity definitions:

| Type | Representation / rule |
| --- | --- |
| RepositoryId | 32 opaque bytes, allocated once from OS CSPRNG and bound by authenticated genesis; not a path hash |
| WorkspaceId, BranchId, ChangeId, OperationId | Distinct 16-byte random typed IDs; never reused; source-copy workspaces receive a new namespace |
| CaptureId | Canonical pair `[WorkspaceId, sequence]`, sequence in `0..2^63-1`; committed identity never recycled |
| RecordId | SHA-256 of complete canonical signed control envelope; 32 bytes; separate Python type from object IDs |
| StoredObjectId | SHA-256 of `ASCII("yeokcham:object:v1") || NUL || envelope`; 32 bytes |
| FullContentId | SHA-256 of `ASCII("yeokcham:content:v1") || NUL || exact_file_bytes`; not the stored content/manifest reference |
| PlanId | SHA-256 of `ASCII("yeokcham/plan/v2") || NUL || canonical_private_control`; exact control remains OPEN |
| ObservationDigest | Separate purpose/type over native read-set observations; not proof that a snapshot is current |
| RequestKey | Caller opaque bytes, 1–128 bytes, scoped by action and authenticated caller within one repository; not an object ID or authorization |
| PrincipalId | Stable verified member identity, not a device label; exact proof/carriage remains OPEN before required review |

Snapshot references are StoredObjectIds naming verified Snapshot objects. Equal
bytes do not equate full-content, inline/manifest, tree, snapshot, capture or
signed-record identities. Equal result snapshots do not collapse causal histories.
Display time is nullable nonnegative int64 and never selects a winner.

Python boundary validators require exact integer type rather than accepting bool,
bounded sizes before allocation, byte paths with no implicit Unicode normalization,
and distinct ID wrappers. SQL STRICT is an additional boundary, not a replacement
for typed API validation. Typed ID lengths alone do not validate scope or bytes.

## 2. Graph meanings and invariant vocabulary

Keep the following relationships separate:

| Relationship | Meaning | Does not prove |
| --- | --- | --- |
| `evolves(A2,A1)` | A2 continues the same named change; one exact predecessor | A1's contents survived A2's possibly changed public basis |
| `basis(A2,Revision(A1))` | A2's scope is computed relative to A1's public result | A1 is separately selected at acceptance |
| Content dependency | Exact input needed to reproduce a basis/result | Independent endorsement or an extra patch application |
| Selected endpoint | Exact public proposal explicitly participating in an acceptance | Every dependency is separately selected, or every conflicted variant's bytes survive |
| Accepted parent | Exact same-branch accepted history extended/reconciled | All included historic contents remain unchanged forever |
| Resolution context/accounted variant | Exact conflict input considered and replaced/selected | That variant was included in the result |
| Private correspondence | Selected values/absence match an exact local occurrence | Whole private snapshot can be published, or equal remote bytes establish correspondence |

Two graph projections are necessary: proof/availability dependencies and material
comparison/representation. A record used to prove a rejected variant existed is
still a proof dependency. It cannot be treated as a represented material parent
solely because a signed resolution references it. D2's phrase “content ancestry”
is not an adequate definition of the latter projection. B1 must specify it.

`PublicBasis` proposal:

```text
Accepted(id) -> verified accepted result
Revision(id) -> verified candidate result
Compose(accepted_inputs, revision_inputs, resolutions,
        profile, comparison_proof, claimed_result) -> verified exact composition
```

The first two are precise. Compose is bounded inline data, not a mutable head.
Its proof is OPEN; claimed snapshots, evolution edges or ID sorting cannot
substitute for it. Input role sets, comparison origin and actual scoped choices
must reproduce the result without a hidden base or a circular dependency.

All following “preservation” statements are proposed obligations under the stated
filesystem/hardware limits, not verified runtime guarantees. A failed plan changes
no accepted state; a failed physical operation can leave explicit partial files,
with intent/safety/target/displaced roots retained. No automatic rollback over
external edits is permitted. “Pending” is derived per accepted branch/head context,
not a mutable global accepted boolean.

## 3. Candidate and acceptance cases

### Case 1: define R0 and S0 first

Use exact LF bytes and Regular modes. Define the snapshot function `T(x,y,extra)`:

```text
f.txt = b"x=" + ASCII(x) + b"\ny=" + ASCII(y) + b"\n"
extra = additional exact path/value pairs, absent unless listed
```

Each `t00`, `t10`, etc. below denotes `SnapshotId(T(...))` using retained canonical
encoding, not a fabricated measured hash. Record names G, R0, S0, A1, etc. are
symbolic distinct RecordIds of their complete signed envelopes. No expected hash
or signature is claimed verified. Namespace IDs and author/authority are fixed
per fixture; all records are same-repository and authorized unless stated.

G is authenticated empty genesis on branch `main`, result empty, no selected
candidate. R0 is the root of change X, basis Accepted(G), predecessor null,
result t00, exact scope `{f.txt}`. **S0 already accepts R0**: accepted parent G,
selected `{R0}`, result t00. R0 is therefore represented at S0, not merely known.

If S0 instead remained G and R0 were merely published, accepting a continuation
would also introduce R0's material dependency contents. That is a different
fixture and must be previewed accordingly; do not silently reuse this one.

Public disclosure is G/R0/S0 and f.txt's t00 bytes. Private workspace files and
capture ancestry are undisclosed. Immutable facts are the records/snapshots;
mutable authority is their local admission plus workspace cursor/basis, not their
payloads. Status at S0: R0 directly selected historically. No remaining decision.
Failed receipt leaves prior admission/cursor; orphan objects are not acceptance.

### Case 2: A1/B1/A2/B2 continue independently

| Revision | Evolution predecessor | Public content basis | Result | Exact scope |
| --- | --- | --- | --- | --- |
| A1 | R0 | Revision(R0) | t10 = T(1,0,{}) | `{f.txt}` |
| B1 | R0 | Revision(R0) | t30 = T(3,0,{}) | `{f.txt}` |
| A2 | A1 | Revision(A1) | t20 = T(2,0,{}) | `{f.txt}` |
| B2 | B1 | Revision(B1) | t40 = T(4,0,{}) | `{f.txt}` |

All four use ChangeId X. Each can be published with a distinct request key and
source correspondence without accepting a sibling. A2 proof/content closure
includes A1/R0/G; it does not include B1/B2. Evolution tips `{A2,B2}` are derived
in every valid topological receipt order. S0 remains the accepted basis.

Public disclosure includes only each chosen endpoint's complete public closure,
including historical public f.txt versions. Unselected private `secret.txt` and
later captures never enter it. Immutable revisions coexist; admission/outbox/
request/correspondence are private authoritative facts. A1/B1 are superseded only
on their own continuations; no global rejection. Exact predecessor selection is
required when a human label is ambiguous. Invalid scope, authority, storage or
signer failure refuses that publication without blocking valid other workspaces.

### Case 3: accept A2 while B2 remains pending

Prepare exact selection `{A2}`, accepted parent `{S0}`. In this simple graph the
unique material comparison is R0 (t00); S0 contributes t00, A2 contributes t20.
The proposed S_A result is exactly `b"x=2\ny=0\n"`, no extra files. Selected is
`{A2}`; A1/R0 are reproduction dependencies, not additional patches. B2 is absent
from selection and material inputs, and remains available/pending.

| Record | Status relative to S_A |
| --- | --- |
| R0 | Historically selected by S0; dependency of A2; x=0 superseded in result |
| A1 | Dependency of selected A2 and superseded on that continuation; x=1 not final |
| A2 | Selected directly by S_A; its endpoint supplies x=2 |
| B1 | Older revision on still-pending B continuation; retained |
| B2 | Pending tip; neither rejected nor implicitly included |

No dependency status may imply all its bytes are present verbatim. The decision
is exact A2 acceptance, with default confirmation and current authority/policy.
Public disclosure adds S_A and its public provenance, never the private workspace.
Only the committed SQL acceptance/admission, workspace basis/capture and outbox
change; the plan/signature alone changes none of them. Sibling B3 may still be
published. Partial application obeys section 9; no stale success claim.

### Case 4: accept A1 first, then A2

S_A1 has parent S0, selected `{A1}`, result t10. Then plan parent S_A1, selection
`{A2}`. A1 is the unique recorded common material input for these two endpoints.
Compare t10 -> t10 (target unchanged) and t10 -> t20 (A2), producing t20 once.
Never replay R0 -> A1 after installing A2. A1 remains historically selected and
a dependency; current A2 is direct selection. B2 stays pending.

Only public t00/t10/t20 and signed control facts are disclosed; private E stays
private under case 9. Immutable records remain intact; admission/basis/cursor/
outbox commit atomically after physical application. Confirmation selects A2's
exact result. Missing A1 proof is Unavailable, not permission to guess a diff.

### Case 4b: blocking extension of case 4

Add an independent change Z with Z1 basis Accepted(S0), result
`T(0,0,{g.txt: b"z\n"})`, scope `{g.txt}`. Target S_A1, selected `{A2,Z1}`.
The intuitive compatible result is `T(2,0,{g.txt: b"z\n"})`.

D2's single-common-base procedure, even granting its proposed material graph,
now finds R0/t00 as the common comparison for S_A1, A2 and Z1. Its input f.txt
endpoints are x=1, x=2 and x=0. `line-hunks-v1` reports competing replacements
of the x line. With A2 alone the comparison was A1/t10 and succeeded. Adding a
change only to g.txt has introduced an unnecessary conflict on f.txt.

No endpoint is an ancestor of another here: S_A1 and A2 both derive from A1 but
neither derives from the other; Z1 derives from S0. Generic ancestor elimination
does not repair this. Merging A2 first and Z1 second can succeed; another order
can expose the conflict. Order-dependent acceptance is prohibited.

**B1 is OPEN.** A correction needs role-specific, path-scoped representation/
normalization proof that accounts for the exact A1 already present before
combining independent contributions. It must also distinguish A1 accounted for
by a resolution that *discarded* its bytes. A whole-tree “represented” flag or
reachability through a resolution is insufficient. D3 does not claim that proof
has been supplied. The safe reference refusal is ChoiceRequired for unsupported
mixed-basis normalization, not a falsely Ready plan or a claim that the desired
low-friction semantics have passed.

All bytes remain retained and nothing is accepted on refusal. Public disclosure
is unchanged until an explicit corrected proposal; no private contents are used
to paper over it. Test all selection/receipt permutations and resolution variants
before promoting the correction. Model B must pass the same test if proposed.

### Case 5: C1 uses A1's public contents

C1 is a different ChangeId Y, predecessor null, basis Revision(A1), result
`T(1,0,{c.txt: b"requires x=1\n"})`, scope `{c.txt}`. The direct dependency is
A1; its recursive closure includes R0/G. Selection `{C1}` against S0 is valid
in the simple case and produces x=1 plus c.txt. It can be accepted without
**separately selecting** A1, but cannot pretend it excluded A1's material effect.
Preview lists selected C1, dependency-provided f.txt, and the full public closure.

Accepting only c.txt while excluding x=1 needs a newly authored candidate with
basis Accepted(S0), or an explicit exact composition choice. It is not the same
C1. No automatic inference of semantic necessity is made from the text of c.txt.
A1 is dependency-provided, not directly selected by this acceptance; B2 remains
pending. Public C1 discloses its entire basis closure, not just the c.txt delta.
Private files/correspondence stay private. SQL admission/basis/outbox own the
transition; a missing dependency refuses before physical writes. Cases involving
already resolved/partially represented A1 depend on B1 and are not frozen.

### Case 6: reproducible Compose basis

For this case only, use A1 = T(1,0,{}) and independent Y1 based on R0 with result
T(0,1,{}). Recipe Q = Compose(`{S0}`, `{A1,Y1}`, `{}`, `line-hunks-v1`,
comparison R0, claimed t11). Verify each basis/scope and unique recorded comparison;
merge exact base-indexed, nonoverlapping x/y line replacements to T(1,1,{}).
A new C2 basis Q can add `c.txt=b"combined\n"` without accepting Q first.

The proof must commit exact input roles/IDs, comparison origin, deterministic
profile, applicable resolutions and t11. No evolution edge is fabricated between
A1 and Y1. Unresolved overlaps produce Conflicted, missing proof bytes Unavailable,
multiple incomparable bases ChoiceRequired. A claimed t11 alone is not proof.
General proof encoding/normalization is OPEN B1/B2; this simple recipe is an
obligation for its future reference implementation, not a frozen general codec.

Public closure includes A1/Y1 and both versions of f.txt; private observed files
are excluded. Immutable recipe is embedded in C2; admission/outbox/correspondence
are local facts. Only explicit selection accepts C2; constructing Q accepts none.
No private tree scan may supply the unresolved comparison or silently fix a hash.

### Case 7: criss-cross, and distinguish the refusal

Let U1 and V1 be incomparable public results based on R0. Q and Q' are distinct
explicit public compositions with both U1 and V1 as inputs, neither deriving
from the other. L derives from Q; R derives from Q'. Their maximal common
material bases can be `{U1,V1}`. Even if Q/Q' result bytes are equal, there is
no unique recorded comparison record for L/R.

- Complete valid closure but incomparable comparisons: ChoiceRequired. Do not
  synthesize a virtual base, choose an ID or use a timestamp.
- A required Q/U1 record or object is missing: Unavailable; do not classify this
  as a content conflict or fabricate an absence.
- An explicit supported exact comparison/context exists and overlapping endpoints
  disagree: Conflicted, with exact byte/path alternatives.
- A claimed proof or scope is false: IntegrityFailure/invalid record, not a choice.

A new public comparison/reconciliation with a verifiable derivation could make
future composition possible. Its proof semantics are OPEN, so initial consumers
must refuse the ambiguous case. Private material remains undisclosed; public
L/R and their full proof closures remain retained. No accepted-head mutation on
refusal. The need for an explicit decision is independent of capture/publication.

### Case 8: offline accepted heads survive, including equal snapshots

Alice accepts A2 from S0 -> S_A/t20. Bob, knowing only S0, accepts B2 -> S_B/t40.
On exchange the admitted accepted heads are `{S_A,S_B}` in either arrival order.
Neither workspace cursor/basis moves. Common successor S_AB must name both
accepted parents and exact reconciliation choices; ordinary single-parent
acceptance refuses while both heads are locally known. Here choosing x=2 on
f.txt is an explicit shared resolution against the exact conflicting context.
Publication of that resolution is not acceptance by itself.

Equal-content subcase: Bob's B2' has distinct evolution/signature/provenance but
result t20. S_B' and S_A are still distinct heads. A parent-complete S_AB' may
need no content replacement; its signed reconciliation preserves both histories.
It is not coalesced merely because snapshot IDs match. Unknown offline heads
cannot be anticipated; success reports locally known parents only.

Only public facts/results are disclosed. Private E and each local history remain
private. Admission is authoritative locally, head sets derived; reconciliation
and cursor/outbox effects require a committed explicit operation. Invalid late
authority/policy is withheld rather than promoted to a trusted head. Both valid
heads remain identifiable; no last-upload-wins or fabricated global freshness.

### Case 9: public D and later private E

Workspace w has accepted basis S0/t00, capture h1 parent h0 with
`D=T(2,0,{secret.txt:b"private\n"})`. Publish P with basis Accepted(S0), selected
path f.txt, public result t20. A private receipt binds P, source h1, exact selected
f.txt value and required Merkle metadata witnesses. It neither discloses nor
needs permanent reachability of secret.txt's old blob solely for correspondence.
Then h2/higher disk observation is
`E=T(2,1,{secret.txt:b"private later\n"})`, parent h1.

Known-present K is S0 plus the **proven** newly represented f.txt contribution
from P: exactly t20, without secret.txt. Accepted D_public is t20. Private merge
K -> accepted t20 (unchanged) with K -> E yields E. Commit accepts x=2/y=0,
retains private x=2/y=1 plus secret.txt, and appends the integration occurrence
with parent h2. P is applied once, not replayed as another private change.

Proof requirements: h1 is a verified ancestor of the selected cursor; receipt
scope/value/absence matches P's actual basis/result delta; source witnesses
authenticate those values; the accepted result has a valid representation of
that contribution. Same bytes from another workspace/occurrence are insufficient.
Unknown, incomparable or resolution-discarded correspondence requires a private
decision. General representation after arbitrary resolutions is part of B1.

Public disclosure is P/t20/S_A and their public closure only. h1/h2, K recipe,
receipt, ignore/native observations, secret.txt and E are private. Immutable
captures/receipts survive; SQL owns the current cursor/basis/operation and pins.
Conflicts pause before default writes; after interruption retain safety E,
target E and displaced contents. Do not publish a private resolution implicitly.

### Cases 10 and 11: relevant staleness, before and after application

Plan p selects exact A2, target branch parent S0/event heads e0, workspace
w/version v/cursor h/basis S0, observed E, current authority/policy and outputs.
Those exact dependencies are pinned before human/provider waits.

| Event | Required behavior |
| --- | --- |
| B3 arrives, predecessor B2, no actual plan dependency changed | p remains valid. Admission/outbox facts merge into fresh SQL state. Do not bind global repository generation or all candidate tips |
| Another workspace captures, or unrelated comment arrives | Same; preserve that independent committed fact |
| A3 arrives | p still selects immutable A2; no latest-label substitution. Complete-fork claims, if any, bind a separate explicit variant set |
| New accepted head S_B arrives before Prepared/apply | Stale/ChoiceRequired. Fresh plan must show the complete known accepted-parent set; no ordinary-file writes |
| S_B arrives after Applying or Materialized but before acceptance COMMIT | Revalidation fails; keep physical output/safety/staging, pause the original operation and publish no stale acceptance. Recovery/reconciliation needs an explicit new plan |
| S_B arrives after acceptance COMMIT, before response | Return the committed original operation; retain both heads on receipt. Do not retroactively claim that local acceptance failed |
| Authority/policy/required-review or workspace read set changes | Revalidate the exact relevant context, refuse stale/unauthorized work, and preserve partial output if any |

Public candidate/acceptance facts remain immutable. Private E/read set/operation
are undisclosed. Mutable facts are admission, workspace version and operation
progress; accepted heads are derived under the transaction's snapshot. Decisions
are replan/reconcile/recover as applicable. COMMIT and receipt serialize, so the
before/after distinction has a local linearization point, not a network clock.
An unknown COMMIT uses request/operation lookup, never an inferred new attempt.

## 4. Deterministic reference procedure and unresolved normalization

This is bounded specification pseudocode, not production Python or a complete
proof. It deliberately refuses the unsupported branch instead of treating D2's
algorithm as already correct.

```text
verify_record(r, stack):
    reject unknown kind/version, malformed/noncanonical bytes, wrong scope
    bound bytes/depth/items/refs before constructing values
    reject a cycle or same identity with different bytes
    verify historical signature and every typed causal/proof reference
    basis = evaluate_public_basis(r.basis, stack + r)   # candidate only
    require complete verified object closure from an eligible public source
    require actual_diff(basis, r.result) == canonical_scope(r.scope)
    validate exact selected-path/deletion/required-directory semantics
    do not infer public eligibility from private cache hits

publish(source_capture, paths, basis, predecessor, request):
    require exact retained source and validated current exclusion profile
    require predecessor has same ChangeId; null allocates a fresh ChangeId
    evaluate basis independently of predecessor's evolution edge
    result = overlay_only_selected_values_and_absences(basis, source_capture)
    scope = actual_diff(basis, result), minimal at ancestor replacements
    prove source correspondence for scope; disclose entire public closure
    stage frozen unsigned intent, sign outside locks, revalidate and commit once

prepare_acceptance(target, exact_selected, resolutions, observed_workspace):
    require exact admitted records, applicable current authority/policy
    require one known accepted head, or explicit all-known-head reconciliation
    preserve roles: selected; reproduction dependencies; accounted variants
    verify every candidate basis, scope, resolution and dependency closure
    comparisons = maximal common MATERIAL comparisons for this exact request
    if closure missing: Unavailable
    if comparison ambiguous: ChoiceRequired
    if mixed represented bases lack the B1 normalization proof:
        ChoiceRequired("unsupported represented-contribution normalization")
    normalize contributions using the reviewed B1 algorithm   # OPEN; no stub
    derive base-relative byte hunks as an unordered set
    equal/unchanged coalesce; incompatible text/path/type/mode => Conflicted
    apply only exact actual-conflict resolutions; reject unused/stale overlaps
    accepted = deterministic_result(public_inputs)
    known_present = proven_source_contributions_once_on_current_capture_ancestry
    workspace = merge_private(known_present, accepted, observed_workspace)
    if private correspondence ambiguous: ChoiceRequired; private conflicts => Conflicted
    retain canonical private plan and all required pins; no acceptance/file writes

apply_acceptance(plan, confirmation, request):
    require approved exact PlanId and fresh dependency-scoped validation
    prepare durable native operation; execute section 9; verify Materialized
    revalidate accepted parents/events, authority/policy and workspace versions
    if invalid: pause, retain outputs, no acceptance
    else SQL-COMMIT exact public fact + cursor/basis/capture + outbox + result
```

Whole-path rules and `line-hunks-v1` remain TC06: UTF-8 without NUL, <=2 MiB/input,
<=4,000,000 alignment cells **including boundary row/column** after trimming;
preserve line endings/final newline, consume equality first and deletion on ties.
Opaque/over-bound inputs use equality/unchanged only, otherwise explicit choice.
Never sort IDs to select a winner or replay every dependency as a selected edit.

For B1, D4 must specify role-specific material ancestry, represented contribution
normalization and scope lifting, prove permutation independence, and run case 4b
with explicit resolution-discarded/rebased ancestors. A no-op needs proof that
the requested effect is already represented, not a boolean reachability test.
No implementation of the OPEN pseudocode line is authorized by this document.

## 5. Minimum public protocol: concrete proposal and OPEN proof fields

### 5.1 Registry and common encoding

Observed [registry](../../lib/yeokcham_envelope/yeokcham_envelope.ml): codes 1–47
are allocated. In particular 41/42/43/47 are existing Core signed controls;
44/45/46 are scope/page/private plan. There is no allocation at 48–51 in this
HEAD. The following are **D3 proposed reservations only**, to re-audit and enter
the one registry in a separately authorized tranche. Do not modify it now.

| Proposed code | Body kind | Schema | Ed25519 domain bytes before body |
| --- | --- | --- | --- |
| 48 | `candidate-revision` | 2 | ASCII(`yeokcham/record/candidate-revision/v2`) + NUL |
| 49 | `accepted-version` | 2 | ASCII(`yeokcham/record/accepted-version/v2`) + NUL |
| 50 | `branch-event` | 2 | ASCII(`yeokcham/record/branch-event/v2`) + NUL |
| 51 | `shared-resolution` | 2 | ASCII(`yeokcham/record/shared-resolution/v2`) + NUL |

Retain Envelope-1 framing with *new type codes*, object-format version 1,
mandatory features 0 and checksum algorithm 1. The public body schema is 2;
these are different version axes. No need to renumber every unchanged content
envelope. The future decoder must explicitly permit these new combinations;
the existing OCaml decoder correctly rejects unknown types.

```text
prefix = "YEOK" || u8(1) || u8(type_code) || u16be(1) || u64be(0)
         || u8(1) || u64be(payload_byte_length)             # 25 bytes
checksum = SHA256(prefix || payload)                      # 32 bytes
envelope = prefix || checksum || payload                  # header 57 bytes
body = [kind_text, 2, repository_b32, causal_parents,
        author_certificate_b32, authority_heads, payload_map, time_or_null]
payload = CBOR([body, signature_b64])                      # body embedded, not bytes
signature = Ed25519(domain_with_NUL || CBOR(body))
RecordId = SHA256(envelope)
StoredObjectId = SHA256("yeokcham:object:v1" || NUL || envelope)
```

The deliberate NUL in these new signing domains is part of the proposal. Old
Core domains have **no** separator; their messages and codes remain unchanged.
Never substitute the old signing input or treat a storage ID as a RecordId.

Restricted canonical CBOR: minimal signed-int64 integers, exact byte strings,
strict UTF-8 text, arrays, bool/null and maps with strictly increasing consecutive
nonnegative integer keys. No tags, floats, indefinite forms, shared references,
duplicate keys, trailing bytes or permissive decode-and-reserialize admission.
Unknown fields, mandatory features, schema/profile/type mismatches and unknown
versions refuse admission. Diagnostic inspection may report unsupported bytes
without treating them as verified mutation inputs.

New controls are <=8 MiB including envelope. Proposed parser depth <=16 and
aggregate item count <=131,200, across body and wrapper; reference sets <=16,384
and strictly sorted by raw ID with no duplicates. Empty sets are `[]`; nullable
singles are explicit CBOR null. Set sorting is semantic, not CBOR encoder magic.
Names are 1–1,024 UTF-8 bytes, no NUL; display time is null or `0..2^63-1`.
Every nested basis consumes the same aggregate budget. Inline Compose nesting is
disallowed: composition uses exact record references, with iterative cycle/depth/
work checks over their graph. Overflow returns a bounded Unsupported/size error;
limits on a control are not total history/file-size limits.

The accepted-proof resource/graph budget is still OPEN with B1; no general
untrusted public-control parser is frozen solely by the scalar limits above.

### 5.2 Ordered payloads

Keys below are **exact proposed consecutive integer keys**. `R` means RecordId,
`O` StoredObjectId, `I` a 16-byte typed ID, `Set(T)` sorted unique array. Snapshot
fields must name Snapshot objects, not arbitrary hashes. All references are
same-repository and checked for exact kind; dependencies must be available and
acyclic. Raw path components are bytes; scope objects use unchanged code 44
only if its exact existing schema/meaning is retained and independently checked.

| Kind | Key : type and meaning |
| --- | --- |
| Candidate 48 | 0: ChangeId I; 1: predecessor R/null; 2: PublicBasis; 3: result O; 4: exact edit-scope O |
| Accepted 49 | 0: BranchId I; 1: mode integer; 2: accepted parents Set(R); 3: fork origin R/null; 4: selected candidates Set(R); 5: direct content-input records Set(R); 6: shared resolutions Set(R); 7: result O; 8: profile text; 9: comparison/normalization proof **OPEN**; 10: policy heads Set(b32); 11: review evidence Set(b32) |
| Branch event 50 | 0: BranchId I; 1: previous events Set(R); 2: action integer; 3: accepted targets Set(R); 4: display name text/null |
| Shared resolution 51 | 0: BranchId I/null for unaccepted public composition; 1: accepted context Set(R); 2: selected candidate context Set(R); 3: complete actual path-variant records Set(R); 4: one path scope O; 5: comparison/normalization proof **OPEN**; 6: replacement subtree snapshot O; 7: profile text |

Candidate `causal_parents` equals `[predecessor]` or `[]`. A null predecessor
creates one new ChangeId; independent root collisions refuse. A nonnull
predecessor must be a candidate with that same ChangeId. A rebase onto a different
basis is explicit and does not assert predecessor contents survived. Direct
content dependencies are derived from the role-labelled PublicBasis, not a
second arbitrary dependency set that could disagree with it.

PublicBasis proposed logical shapes:

```text
[0, accepted_record_b32]
[1, candidate_record_b32]
[2, accepted_inputs, candidate_inputs, resolutions, profile,
    comparison_normalization_proof_OPEN, result_snapshot_b32]
```

For accepted records, mode 0 = initial empty genesis, 1 = branch fork,
2 = ordinary acceptance, 3 = accepted-head reconciliation. Genesis has no parents,
origin null, empty selections/resolutions and exact empty result; unique branch
creation binds it. Fork has no same-branch parents, one explicit accepted origin,
no new selected work and a result equal to that origin. Ordinary mode requires
one same-branch parent, origin null; reconciliation requires >=2 incomparable
same-branch parents, origin null. Local committing ordinary/reconcile mode also
checks the complete currently admitted branch/event heads. Remote verification
checks recorded ancestry/proof rather than requiring a remote record to have
anticipated our unknown offline head. Receipt retains valid concurrent heads.

Accepted `causal_parents` equals its same-branch parent set; fork's content origin
is a separate typed edge. Key 5 is exactly the direct material input reference
set derived by the comparison proof, excluding separately selected IDs and
accepted parents already named in their roles. Its recursive reproduction closure
is calculated, never independently selected/replayed. **The derivation of key 5
and key 9 is OPEN B1**, so the Accepted 49 payload is not wire-frozen.

Branch actions: create=0, rename=1, advance=2, reconcile=3. Causal parents equal
previous events. Create has no previous event, a fresh BranchId/name and exactly
one valid genesis/fork target. Rename preserves inherited target sets, and changes
only the name. Advance/reconcile target exact same-branch accepted records whose
parents prove the claimed progression; event predecessors are incomparable
same-branch events. No event can hide a competing accepted head without a new
accepted reconciliation. Concurrent names stay a set; a name is not branch ID.
An acceptance and its authored advance event are admitted in the same local
transaction; a packet requiring the pair cannot expose a half-authenticated branch.

Resolution causal parents equal the union of accepted, selected and actual
variant context IDs, sorted/unique. Proof evaluation must exclude the resolution
itself when deriving that context: no hash cycle through a plan or future accepted
ID. It must prove an actual conflict, the complete named variant set for that
path, exact comparison and replacement at only that path/subtree, preserving
other automatic changes. Unused, overlapping, incomplete, stale or out-of-scope
choices refuse. A workspace-only choice is private plan data, never code 51.
General proof field 5 remains OPEN; no “choose any snapshot” escape hatch.

In initial no-review mode policy/evidence sets must be empty under a verified
optional-policy configuration. Unknown policy is not optional. Any mandatory
unimplemented review/adoption/principal capability refuses. The context must bind
an exact certificate and verified incomparable authority heads; signers must be
active at the required current heads, while historical verification remains
separate from admission. Existing V1 certificate/epoch codecs have their own
identity/signing domains in [trust](../../lib/yeokcham_v1_trust/yeokcham_v1_trust.ml).
Exact V2 authority bundle carriage/reuse vectors are **OPEN B2**; these references
do not allocate new principal/policy codes or authorize accepting old-domain
adoption records for new controls.

Representative **logical**, unverified payloads (symbolic b32/b16 names):

```text
candidate A2:
["candidate-revision",2,repo,[A1],alice_cert,[epoch],
 {0:X,1:A1,2:[1,A1],3:t20,4:scope_f},null]
accepted S_A:
["accepted-version",2,repo,[S0],alice_cert,[epoch],
 {0:main,1:2,2:[S0],3:null,4:[A2],5:direct_inputs_from_proof,
  6:[],7:t20,8:"line-hunks-v1",9:OPEN,10:[],11:[]},null]
branch advance:
["branch-event",2,repo,[e0],alice_cert,[epoch],
 {0:main,1:[e0],2:2,3:[S_A],4:null},null]
resolution:
["shared-resolution",2,repo,exact_context_union,alice_cert,[epoch],
 {0:main,1:[S_A,S_B],2:[],3:exact_conflicting_variants,
  4:scope_f,5:OPEN,6:replacement_t20,7:"line-hunks-v1"},null]
```

These are not encodable verified test vectors. `OPEN` cannot be serialized as a
placeholder, null, empty array or guessed proof during implementation.

### 5.3 Compatibility and vector boundaries

Normative retained bytes are those defined by current source for Content(1),
Tree(2), Snapshot(3), Chunk(13), File_manifest(14), restricted CBOR, full-content
hash and Buzhash-v1 (64-byte window, 16/64/128 KiB min/target/max; inline <=64 KiB).
Retain exact tree byte-name ordering, regular/executable/symlink modes, empty
directories, content manifests and envelope checksum behavior. A generic Python
chunker or canonical-CBOR option is not evidence of identity compatibility.

Existing `test/golden/core`, `composition`, `core-package`, `integration`, `local`
and `v1` controls stay unchanged as **old-protocol** vectors. In particular old
41/42/43/47 signatures and type-46 private plans are not normative schemas for
new Model A controls/SQL plans. Scope/page bytes may be reused only for unchanged
semantics. There is not yet a complete independently reviewed retained-content
corpus for the proposed Python consumer; M0 inventories the existing tests and
constructs the missing plan, M1a cannot infer that gap away.

| Claim | D3 disposition |
| --- | --- |
| Exact content byte compatibility | Proposed and testable with independent retained vectors; not yet demonstrated in Python |
| Semantic compatibility | Preserve named invariants; intentionally change fork/selection/private persistence behavior |
| Read-only old inspection | Retain matching OCaml reader; a limited Python decoder is not a complete old-repository recovery tool |
| Full repository migration | Not designed/authorized; needs explicit export/import including private facts and interrupted operations |
| Native protocol interoperability | Not promised. New repository scope/control negotiation; never mix old/new couriers silently |

## 6. Minimum SQLite authority and illustrative DDL

### 6.1 Configuration and ownership

Retain DELETE/EXTRA. SQLite has one concurrent writer; bounded short transactions
fit the proposed workload but contention remains to measure
([transactions](https://www.sqlite.org/lang_transaction.html)). EXTRA adds the
rollback-DELETE directory sync; WAL has a different file/checkpoint lifecycle
([synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous),
[WAL](https://www.sqlite.org/wal.html)). No evidence here justifies changing the
default. Never silently fall back to NORMAL/OFF, or set/check pragmas in an
already-open transaction.

Startup must verify application ID, independent schema version, RepositoryId,
format marker, `journal_mode=delete`, `synchronous=3`, `foreign_keys=1`, functioning
native locks/flush, and the reviewed SQLite build. On macOS require/check the
qualified stronger flush setting; unsupported durability must be explicit.
Require STRICT support, feature floor SQLite 3.37.0; qualify exact builds rather
than treating that minimum as an allowlist
([STRICT](https://www.sqlite.org/stricttables.html)). Local native stores only;
no NFS/SMB/cloud-sync live database. Disable extension loading/unneeded unsafe SQL
interfaces. User text is bound data, never SQL interpolation.

Python uses `sqlite3.connect(..., autocommit=True)` and explicit SQL
`BEGIN IMMEDIATE`, `COMMIT`, `ROLLBACK`. In this mode `Connection.commit()`,
`rollback()` and the connection context manager are not the intended boundary
([Python sqlite3](https://docs.python.org/3.14/library/sqlite3.html#transaction-control)).
Check `in_transaction`; close cursors/read transactions promptly. Each worker
owns its connection; do not fork with a live connection or share one arbitrarily
between threads. Do not toggle `autocommit` to perform commits implicitly.

### 6.2 DDL skeleton

The following is executable **illustrative DDL in documentation**, schema number
1 for an isolated experiment only. It is not an approved production migration.
Foreign keys are enabled on every connection; STRICT alone does not prove graph
semantics. Roots refer to external CAS IDs; they cannot prove those files exist,
are valid, are fsynced, or have the claimed closure.

`root_set` is retention ownership bookkeeping, not a second project head. All
captures/admitted public facts remain retained initially. Releasing a plan is
explicit; completed operations transfer pins to retention before release.
The SQL adapter is the only writer. Byte controls below remain private and
bounded; their canonical schemas are OPEN before consuming tranches.

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = EXTRA;

CREATE TABLE repository (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  repository_id BLOB NOT NULL UNIQUE CHECK (length(repository_id) = 32),
  format TEXT NOT NULL CHECK (format = 'yeokcham-python-v2-experimental'),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1)
) STRICT;

CREATE TABLE root_set (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN
    ('capture','public','authority','correspondence','plan','operation',
     'outbound','reader','restore-proof','backup')),
  state TEXT NOT NULL CHECK (state IN ('active','released'))
) STRICT;
CREATE TABLE object_root (
  root_set_id INTEGER NOT NULL REFERENCES root_set(id),
  object_id BLOB NOT NULL CHECK (length(object_id) = 32),
  traversal TEXT NOT NULL CHECK (traversal IN ('closure','exact-object')),
  PRIMARY KEY (root_set_id, object_id, traversal)
) STRICT;

CREATE TABLE authority_fact (
  id BLOB PRIMARY KEY CHECK (length(id) = 32),
  kind TEXT NOT NULL CHECK (kind IN ('certificate','epoch','policy')),
  canonical BLOB NOT NULL CHECK (length(canonical) BETWEEN 1 AND 8388608),
  roots INTEGER NOT NULL REFERENCES root_set(id)
) STRICT;
CREATE TABLE public_record (
  id BLOB PRIMARY KEY CHECK (length(id) = 32),
  object_id BLOB NOT NULL UNIQUE CHECK (length(object_id) = 32),
  repository_id BLOB NOT NULL REFERENCES repository(repository_id),
  kind TEXT NOT NULL CHECK (kind IN
    ('candidate','accepted','branch-event','resolution')),
  admission_context BLOB NOT NULL
    CHECK (length(admission_context) BETWEEN 1 AND 8388608),
  roots INTEGER NOT NULL REFERENCES root_set(id)
) STRICT;

CREATE TABLE workspace (
  id BLOB PRIMARY KEY CHECK (length(id) = 16),
  lifecycle TEXT NOT NULL CHECK (lifecycle IN ('new','attached','retired')),
  attachment BLOB UNIQUE,
  native_root_identity BLOB,
  cursor_seq INTEGER CHECK (cursor_seq >= 0),
  next_seq INTEGER CHECK (next_seq >= 0),
  basis BLOB REFERENCES public_record(id),
  content_version INTEGER NOT NULL CHECK (content_version >= 0),
  pause TEXT NOT NULL CHECK (pause IN ('none','network','all')),
  CHECK ((attachment IS NULL) = (native_root_identity IS NULL)),
  CHECK (attachment IS NULL OR length(attachment) BETWEEN 1 AND 65536),
  CHECK (native_root_identity IS NULL OR length(native_root_identity) > 0),
  CHECK (lifecycle != 'attached' OR
    (attachment IS NOT NULL AND cursor_seq IS NOT NULL)),
  FOREIGN KEY (id, cursor_seq) REFERENCES capture(workspace_id, sequence)
    DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE capture (
  workspace_id BLOB NOT NULL REFERENCES workspace(id),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  parent_workspace BLOB,
  parent_sequence INTEGER,
  snapshot BLOB NOT NULL CHECK (length(snapshot) = 32),
  accepted_basis BLOB REFERENCES public_record(id),
  provenance BLOB CHECK (provenance IS NULL OR length(provenance) <= 65536),
  roots INTEGER NOT NULL REFERENCES root_set(id),
  PRIMARY KEY (workspace_id, sequence),
  CHECK ((parent_workspace IS NULL) = (parent_sequence IS NULL)),
  CHECK (parent_sequence IS NULL OR parent_sequence >= 0),
  CHECK (parent_workspace IS NULL OR
    (parent_workspace = workspace_id AND parent_sequence < sequence) OR
    (parent_workspace != workspace_id AND sequence = 0)),
  FOREIGN KEY (parent_workspace, parent_sequence)
    REFERENCES capture(workspace_id, sequence) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE publication_correspondence (
  revision BLOB PRIMARY KEY REFERENCES public_record(id),
  source_workspace BLOB NOT NULL,
  source_sequence INTEGER NOT NULL,
  selected_proof BLOB NOT NULL
    CHECK (length(selected_proof) BETWEEN 1 AND 8388608),
  roots INTEGER NOT NULL REFERENCES root_set(id),
  FOREIGN KEY (source_workspace, source_sequence)
    REFERENCES capture(workspace_id, sequence)
) STRICT;
CREATE TABLE plan (
  id BLOB PRIMARY KEY CHECK (length(id) = 32),
  workspace_id BLOB NOT NULL REFERENCES workspace(id),
  kind TEXT NOT NULL CHECK (kind IN
    ('accept','reconcile','restore','switch','copy-out','activate','recover')),
  canonical BLOB NOT NULL CHECK (length(canonical) BETWEEN 1 AND 8388608),
  released INTEGER NOT NULL CHECK (released IN (0,1)),
  roots INTEGER NOT NULL REFERENCES root_set(id),
  UNIQUE (id, workspace_id)
) STRICT;
CREATE TABLE operation (
  id BLOB PRIMARY KEY CHECK (length(id) = 16),
  plan_id BLOB NOT NULL UNIQUE,
  workspace_id BLOB NOT NULL,
  intent BLOB NOT NULL CHECK (length(intent) BETWEEN 1 AND 8388608),
  expected_version INTEGER NOT NULL CHECK (expected_version >= 0),
  reserved_sequence INTEGER CHECK (reserved_sequence >= 0),
  phase TEXT NOT NULL CHECK (phase IN
    ('Prepared','Applying','Materialized','Committed','Completed',
     'Paused','Recovery','Cancelled')),
  resume_phase TEXT CHECK (resume_phase IN ('Prepared','Applying','Materialized')),
  serial INTEGER NOT NULL CHECK (serial >= 0),
  materialized_observation BLOB
    CHECK (materialized_observation IS NULL OR length(materialized_observation) = 32),
  result BLOB CHECK (result IS NULL OR length(result) <= 8388608),
  roots INTEGER NOT NULL REFERENCES root_set(id),
  CHECK ((phase = 'Paused') = (resume_phase IS NOT NULL)),
  CHECK (phase NOT IN ('Materialized','Committed','Completed') OR
    materialized_observation IS NOT NULL),
  FOREIGN KEY (plan_id, workspace_id) REFERENCES plan(id, workspace_id)
) STRICT;
CREATE UNIQUE INDEX one_pending_operation ON operation(workspace_id)
  WHERE phase NOT IN ('Completed','Cancelled');
CREATE UNIQUE INDEX one_reserved_sequence ON operation(workspace_id,reserved_sequence)
  WHERE reserved_sequence IS NOT NULL;

CREATE TABLE operation_action (
  operation_id BLOB NOT NULL REFERENCES operation(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  byte_path BLOB NOT NULL CHECK (length(byte_path) BETWEEN 1 AND 65536),
  intent BLOB NOT NULL CHECK (length(intent) BETWEEN 1 AND 8388608),
  progress TEXT NOT NULL CHECK (progress IN ('intent','verified-post','paused')),
  serial INTEGER NOT NULL CHECK (serial >= 0),
  PRIMARY KEY (operation_id, ordinal),
  UNIQUE (operation_id, byte_path)
) STRICT;
CREATE TABLE destination_reservation (
  operation_id BLOB NOT NULL REFERENCES operation(id),
  scope_key BLOB NOT NULL CHECK (length(scope_key) = 32),
  scope_control BLOB NOT NULL CHECK (length(scope_control) BETWEEN 1 AND 65536),
  active INTEGER NOT NULL CHECK (active IN (0,1)),
  PRIMARY KEY (operation_id, scope_key)
) STRICT;
CREATE UNIQUE INDEX one_exact_destination ON destination_reservation(scope_key)
  WHERE active = 1;

CREATE TABLE request_result (
  action TEXT NOT NULL CHECK (length(action) BETWEEN 1 AND 64),
  caller BLOB NOT NULL CHECK (length(caller) BETWEEN 1 AND 256),
  request_key BLOB NOT NULL CHECK (length(request_key) BETWEEN 1 AND 128),
  arguments BLOB NOT NULL CHECK (length(arguments) = 32),
  frozen_intent BLOB CHECK (frozen_intent IS NULL OR length(frozen_intent) <= 8388608),
  operation_id BLOB REFERENCES operation(id),
  state TEXT NOT NULL CHECK (state IN ('pending','committed','completed','cancelled')),
  result BLOB CHECK (result IS NULL OR length(result) <= 8388608),
  CHECK (state = 'pending' OR result IS NOT NULL),
  PRIMARY KEY (action, caller, request_key)
) STRICT;
CREATE TABLE outbound (
  id BLOB PRIMARY KEY CHECK (length(id) = 16),
  kind TEXT NOT NULL CHECK (kind IN ('obligation','batch')),
  endpoint BLOB CHECK (endpoint IS NULL OR length(endpoint) = 32),
  canonical BLOB NOT NULL CHECK (length(canonical) BETWEEN 1 AND 8388608),
  roots INTEGER NOT NULL REFERENCES root_set(id),
  CHECK ((kind = 'batch') = (endpoint IS NOT NULL)),
  UNIQUE (id, endpoint)
) STRICT;
CREATE TABLE outbound_member (
  batch BLOB NOT NULL REFERENCES outbound(id),
  obligation BLOB NOT NULL REFERENCES outbound(id),
  PRIMARY KEY (batch, obligation),
  CHECK (batch != obligation)
) STRICT;
CREATE TABLE acknowledgement (
  batch BLOB PRIMARY KEY,
  endpoint BLOB NOT NULL CHECK (length(endpoint) = 32),
  canonical BLOB NOT NULL CHECK (length(canonical) BETWEEN 1 AND 8388608),
  FOREIGN KEY (batch, endpoint) REFERENCES outbound(id, endpoint)
) STRICT;
CREATE TABLE retention (
  id BLOB PRIMARY KEY CHECK (length(id) = 16),
  kind TEXT NOT NULL CHECK (kind IN ('reader','restore-proof','backup')),
  canonical BLOB NOT NULL CHECK (length(canonical) BETWEEN 1 AND 8388608),
  active INTEGER NOT NULL CHECK (active IN (0,1)),
  roots INTEGER NOT NULL REFERENCES root_set(id)
) STRICT;

CREATE TRIGGER capture_immutable_update BEFORE UPDATE ON capture
BEGIN SELECT RAISE(ABORT,'immutable capture'); END;
CREATE TRIGGER capture_immutable_delete BEFORE DELETE ON capture
BEGIN SELECT RAISE(ABORT,'retained capture identity'); END;
CREATE TRIGGER public_immutable_update BEFORE UPDATE ON public_record
BEGIN SELECT RAISE(ABORT,'immutable public admission'); END;
CREATE TRIGGER public_immutable_delete BEFORE DELETE ON public_record
BEGIN SELECT RAISE(ABORT,'retained public admission'); END;
CREATE TRIGGER sequence_monotonic BEFORE UPDATE OF next_seq ON workspace
WHEN (OLD.next_seq IS NULL AND NEW.next_seq IS NOT NULL)
  OR (NEW.next_seq IS NOT NULL AND NEW.next_seq < OLD.next_seq)
BEGIN SELECT RAISE(ABORT,'sequence reuse'); END;
CREATE TRIGGER capture_allocation BEFORE INSERT ON capture
WHEN NOT EXISTS (SELECT 1 FROM workspace w WHERE w.id = NEW.workspace_id
  AND (w.next_seq IS NULL OR NEW.sequence < w.next_seq))
BEGIN SELECT RAISE(ABORT,'sequence not reserved'); END;
CREATE TRIGGER version_monotonic BEFORE UPDATE OF content_version ON workspace
WHEN NEW.content_version != OLD.content_version + 1
BEGIN SELECT RAISE(ABORT,'invalid workspace version'); END;
CREATE TRIGGER cursor_requires_version
BEFORE UPDATE OF cursor_seq,basis,attachment,native_root_identity ON workspace
WHEN NEW.content_version != OLD.content_version + 1
BEGIN SELECT RAISE(ABORT,'cursor requires version advance'); END;
CREATE TRIGGER active_root_delete BEFORE DELETE ON object_root
WHEN (SELECT state FROM root_set WHERE id = OLD.root_set_id) = 'active'
BEGIN SELECT RAISE(ABORT,'release owner only after root transfer'); END;
CREATE TRIGGER operation_progress_serial BEFORE UPDATE ON operation
WHEN NEW.serial != OLD.serial + 1
BEGIN SELECT RAISE(ABORT,'operation serial'); END;
CREATE TRIGGER action_progress_serial BEFORE UPDATE ON operation_action
WHEN NEW.serial != OLD.serial + 1
BEGIN SELECT RAISE(ABORT,'action serial'); END;
```

This skeleton has no writable accepted-head table, duplicate cursor file, global
repository version, event log or lane. `public_record` is admission membership;
current branch/evolution heads are derived from its verified signed contents.
Secondary indexes and cached decoded edges have a rebuildable owner and cannot
authorize admission. `authority_fact` retains exact public trust facts; effective
authority is computed, not independently set by a relay/Boolean.

### 6.3 Constraints the adapter must additionally validate

The DDL is deliberately not claimed to enforce an entire VCS inside SQL triggers.
These are explicit requirements of the single metadata writer; canonical controls
and comprehensive transition triggers remain OPEN before M1b/M2 consumers:

- Reject non-BLOB/wrong-size typed arguments before SQL; STRICT may coerce inputs.
  Check repository/application/schema version before any write; no initialization
  over an unknown database. Use one repository per DB.
- `next_seq=NULL` means exhausted. Prepared burns one sequence in the same
  transaction as its operation reservation; regular capture burns/inserts/moves
  cursor in one transaction. Allow gaps from abandoned operations; never reuse.
  A reservation does not constitute a completed capture. Guard int64 overflow
  for sequence, version and progress counters before arithmetic/coercion.
- A new root occurrence has no parent, or sequence zero explicitly forks an
  existing source workspace. Subsequent occurrences have a valid parent; no
  arbitrary extra root at sequence >0. After navigation, append a fresh sequence
  parented to the selected earlier cursor. Never update an old capture row.
- Workspace basis/accepted_basis must name a verified accepted record of the
  selected branch/context, not merely any public-record FK. Validate attachment
  identity and prefix nonoverlap, not just UNIQUE pathname bytes. Retirement
  clears scheduling/attachment explicitly without deleting captured identities.
- Every owned fact uses an active root set of the appropriate kind, with the
  complete verified root inventory. Root-set kind matching/cardinality is not
  proved by its integer FK. Validate inventory outside SQL; publish its exact
  immutable verification token under the shared gate. No empty-pin shortcut.
- Make plan control, authority facts, correspondence, action intent, operation
  identity/plan/workspace/expected version/reserved sequence, request arguments,
  outbound bytes and acknowledgements immutable. Only listed progress/result/
  release fields change through validated transitions. Generate corresponding
  triggers when the exact controls are frozen; do not silently permit SQL edits.
- Require `operation.phase` transitions from section 9, immutable pause origin,
  monotonically checked serial and expected workspace version. Unique plan to
  operation prevents another request key re-executing the same plan. Pending
  operation ownership blocks ordinary capture/navigation of that workspace only.
- Source observations, public records and target captures bind exact operation
  intent. Copy-out has no target capture/cursor allocation. Committed results
  cannot return to Applying/Recovery; retain historical result even after cleanup.
- Prefix-overlapping action paths are coalesced or rejected. A BYTE-path UNIQUE
  constraint does not exclude `a` versus `a/b`, hardlink/bind aliases, different
  repositories or another managed workspace. Destination rules are section 9.3.
- Before releasing owner pins, check every surviving fact/operation/outbox/reader/
  backup obligation is protected elsewhere in **the same transaction**. An active
  capture/admitted public fact cannot have its only root set released. Retired
  workspace captures remain roots. No automatic retention expiry in first tranches.
- A frozen outbound batch names exact obligation IDs, manifest/control bytes,
  endpoint identity and repository. Validate `outbound_member` kind and scope;
  a nullable endpoint on an obligation authorizes no network destination. An
  acknowledgement must verify that exact batch/endpoint, not an optimistic flag.
- Immutable results/tombstones survive retries; no idempotency-key TTL that allows
  old uncertain requests to execute twice. Future compaction needs explicit
  protocol and retention rules. Same key/different argument digest always refuses.

Expression feasibility: FK/CHECK/partial indexes cover identity/shape/uniqueness;
short conditional updates cover cursor/CAS and sequence allocation; typed private
intent covers dependency sets and physical plans. Graph, root completeness,
native ownership and cryptographic proof require adapter validation. Therefore
the skeleton can **represent** the required transitions but is not a fully frozen
or independently sufficient enforcing schema. No claim of complete SQL contract
freeze is made while those OPEN fields/transitions remain.
