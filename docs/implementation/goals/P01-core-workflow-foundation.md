/goal Complete P1: Implement the core-workflow record foundation.

Read docs/PILOT_PLAN.md, docs/IMPLEMENTATION_WORKFLOW.md and
docs/IMPLEMENTATION_PROGRESS.md first. This is the first implementation slice of
the user's complete everyday VCS pilot, not an instruction to execute all G02-G20.
Verify the current checkout, preserve unrelated work, record starting main HEAD,
and verify the G01 handoff f3bd17705591413078e1504d46d8240eb6c47f2e is an ancestor.
Read applicable AGENTS.md and TC01, TC02, TC06 canonical records/identities and
TC08. Do not repeat G01 measurements.

Predecessor evidence: docs/PILOT_PLAN.md and
docs/implementation/results/PILOT-workflow-assessment.json. P0 exercised current
V1 and identified missing ordinary clone/branch/switch/diff/integration workflows.
Its disposable-signer WSL checks are not native-host acceptance evidence.

Scope: Own the common core record registry, signed revision/accepted-version/
branch-event bodies, workspace/history identities, and pure interfaces required
by the pilot's composition/materialization/CLI consumers. Start from
lib/yeokcham_encoding/, lib/yeokcham_envelope/, lib/yeokcham_v1_record/,
lib/yeokcham_v1_model/ and lib/yeokcham_v1_trust/. Reuse existing canonical
encoding/envelope/trust machinery; keep one registry and one source of truth.

Acceptance criteria:

1. Implement these core record families using TC06's ordered fields,
   domain-separated signing bytes, immutable envelope/hash identities, explicit
   scope/authority context and bounded canonical decoding. Allocate codes once
   and document them. Parent/head sets must be sorted and unique; reject wrong
   scope, mandatory versions, malformed references and oversized/noncanonical input.
2. Provide typed random 128-bit workspace/branch/change identities and workspace
   plus nonnegative int64 sequence history identities, with explicit collision,
   exhaustion and identical-repeat behavior. Content equality cannot collapse
   distinct history positions. Specify storage ownership for atomic allocation;
   do not pretend a pure type alone implements durable sequence allocation.
3. Expose actual pure module/function interfaces for core state, composition
   inputs/results, workspace observation/cursors and plan/error outcomes.
   Document actual names/signatures and invariants in
   docs/implementation/INTERFACES.md. Basic authority and concurrent-head context
   must remain representable; unsupported required policy must never mean success.
4. Add golden byte/signature-input/identity vectors and meaningful negative/
   property cases for the implemented families. Demonstrate consumption through
   the actual core model/validation boundary, not an unrelated duplicate record
   library. Keep the current repository buildable and existing workflows intact.
5. Record exact P1 coverage against original G02 criteria. Leave review/account/
   archive families and other unimplemented G02 criteria explicitly outstanding.
   A completed P1 does not complete G02 or demonstrate clone/integration services.

Exclusions: no PR/review services, private account/archive implementation, full
daemon, remote deployment, broad CLI rewrite, automatic deletion, legacy artifact
readers or performance claims. Do not add future feature stubs that report success.

Run focused encoding/envelope/record/trust and malformed-input/property checks,
then make build, make lint and make ci with the documented local test environment.
Record actual commands, exits, revision and any cached/unsupported evidence.

Make small coherent buildable commits on main under the current reconciled
workflow. Preserve the README constraint and unrelated files. No push, release,
deployment or later slice is authorized by this prompt. One owner freezes this
registry/API before parallel consumers are assigned.

Update the pilot slice and original-phase coverage in the shared progress
ledger. Save an evidence-backed P1 report using the report template; commit the
report/tracker update separately from code. Report exact remaining original G02
scope and the next eligible pilot slice. Do not automatically start P2/P3 or
print an unqualified claim that G02 or the product is complete.
