# M0 safety evidence and implementation gates

Version: `m0-reference-1`. Recorded 2026-11-20.
Status: proposed contracts, evidence classifications and acceptance specifications;
no production persistence, filesystem executor or migration is implemented here.

Read [baseline](M0_BASELINE.md), [semantic reference](M0_SEMANTIC_REFERENCE.md)
and [vector inventory](M0_VECTOR_INVENTORY.md). The owner provisionally authorized
A–E for M0 planning only. Later contracts are not approved by implication.

## Evidence levels and current findings

| Level | Meaning |
| --- | --- |
| DESIGN_CONTRACT | Explicit proposed safety rule; inferred protection conditional on a correct qualified implementation |
| REFERENCE_VERIFIED | Narrow property checked against named reference evidence, with exact host/source and failure-model limits |
| REQUIRES_RUNTIME_TEST | Native, concurrent, fault, provider or service behavior not established by documentation/symbolic checks |
| OPEN | Decision/specification still missing; its named consumer must not invent it while coding |

These levels are not interchangeable. A design can be coherent while runtime
qualification and an encoding choice are both pending.

| Property | Evidence level / observation | Limit |
| --- | --- | --- |
| Existing 34 golden files match independent reference generation | REFERENCE_VERIFIED, fresh M0; exact inputs/families in vector inventory | Old bytes only; no Python production decoder/native VCS pass |
| D4 small graph cases and 1,800 permutation comparisons | REFERENCE_VERIFIED, **historical D4** | Examples/falsification, not general proof or resource/structural qualification |
| D3 23 SQL feasibility checks plus strengthened negatives | REFERENCE_VERIFIED, **historical D3** | Shape/relational feasibility; not enforcing production schema or crash safety |
| Explicit sqlite3 transaction behavior | REFERENCE_VERIFIED, fresh M0 external probe: 11 checks on CPython 3.15.0/SQLite 3.54.1 | Toy STRICT table; no VCS schema, process faults, object bridge, concurrent GC or 3.13/3.14 allowlist |
| Object-before-SQL, shared/exclusive gate, root transfer, idempotency and backup ordering | DESIGN_CONTRACT, D4 section 11 | Every runtime interval below still needs M1b tests |
| No-replace absent destination, preservation-aware in-place application and phase rules | DESIGN_CONTRACT, D4 sections 8–12; existing OCaml/C/tests inspected | Python ABI/identity/flush and cross-store native races REQUIRES_RUNTIME_TEST |
| Full normalization charging, structural/resource corpus; complete SQL/native/public control bytes | OPEN | Exact consumer gates below |
| BASELINE-COPYOUT-20261116 | OPEN historical root cause | No fix/reproduction/waiver in M0 |

M0's transaction probe used only disposable `transaction-probe.sqlite` and a backup
under the external M0 scratch directory. It verified DELETE, EXTRA=3, FK=1,
STRICT-table creation, `Connection.commit()`/`rollback()` leaving an explicitly
opened transaction active under `autocommit=True`, explicit SQL ROLLBACK discarding
the row, SQL COMMIT/reopen retaining it, backup row agreement and integrity_check.
The 11 assertions exclude STRICT creation as a separately counted assertion.
It was not an M1b store implementation or a crash/power-loss experiment.
For reproducibility, the toy schema was
`CREATE TABLE probe (id INTEGER PRIMARY KEY,value TEXT NOT NULL) STRICT`.
On a fresh external file with `autocommit=True`, set/check DELETE, EXTRA and FK;
BEGIN IMMEDIATE, insert `(1,'pending')`, call connection commit and rollback and
check both leave `in_transaction=True`, then SQL ROLLBACK and check zero rows.
BEGIN IMMEDIATE, insert `(1,'committed')`, SQL COMMIT, check closed transaction,
close/reopen and read the same row. Backup to a second fresh external DB, compare
that row and check integrity. No artificial fault or concurrent writer was used.

The proposed adapter uses `autocommit=True` with explicit SQL BEGIN IMMEDIATE,
COMMIT and ROLLBACK, inspecting `in_transaction`; the Python connection methods
are not those boundaries in this mode. This matches the
[Python transaction documentation](https://docs.python.org/3.15/library/sqlite3.html#transaction-control).
Keep DELETE/EXTRA; EXTRA adds synchronization associated with rollback-journal
deletion, subject to underlying storage assumptions.
[SQLite synchronous documentation](https://www.sqlite.org/pragma.html#pragma_synchronous)
No evidence here warrants WAL or a silent lower durability setting.

## Storage ordering, ownership and transaction obligations

DESIGN_CONTRACT, conditional on qualified locks/filesystem/SQLite:

1. Validate and durably publish immutable objects create-only, including complete
   type/length/hash/canonical/closure checks, file sync and every new shard/ancestor
   directory sync. Existing-ID mismatch refuses; never overwrite canonical bytes.
2. Protect the actual inputs under the shared publication/GC gate or a committed
   root owner. Acquire reader protection **before** reading SQL roots. A reference
   or verified flag alone proves neither valid bytes nor their durable publication.
3. Reload/revalidate exact relevant inputs and commit authoritative facts/roots/
   request results in one short SQL transaction. Objects alone are not a capture,
   publication or acceptance. A failed/uncertain commit is resolved by its original
   request/plan/operation identity, never new signing/allocation as a guessed retry.
4. Acknowledge the exact committed transition. Lost response does not revoke it.
   Same key/different argument digest refuses. Plan-to-operation is unique even
   across different request keys. Pending unsigned intent owns pins across waits.
5. Transfer all surviving root ownership in the same transaction that releases
   the old owner. Capture/admission/outbox/reader/plan/recovery roots have one owner
   each; derived counts/head indexes never authorize deletion.

Lock order: own workspace/process lock when needed -> shared publication/GC gate
-> short SQL transaction. Collector: exclusive gate -> short SQL snapshot/progress;
never wait for a workspace. Never take SQL first and wait for the gate. Multi-
workspace operations order workspace IDs by raw bytes. Human/network/signing
provider waits hold none of these locks; long scans/streaming/native actions hold
no SQL transaction. Long readers use a shared gate or durable reader pins, not a
SQL snapshot held through rendering. Timeout/PID reuse cannot steal a live pin.

Capture append atomically allocates sequence, immutable occurrence/roots, cursor/
version and request result; unchanged ordinary capture creates no new occurrence.
Prepared burns an operation reservation once. `next_seq=NULL` means exhausted;
ordinary append refuses. Only the exact pending operation can insert its previously
reserved sequence. Cancelled reservation gaps are never recycled. Copy-out does
not allocate a source capture or move its cursor/counter/basis.

Receipt stages/validates outside SQL, then admits only eligible exact public facts
and roots atomically; it does not move workspace state or perform application.
Acceptance commit follows Materialized and revalidates accepted/event/authority/
policy/workspace inputs, preserving unrelated receipts. Completion transfers pins
to retention before releasing the pending owner. Every phase needs CAS/serial and
immutable-intent checks; illustrative D3 DDL alone does not enforce all of them.

Automatic history eviction remains disabled. Collection cannot be enabled until
quarantine/purge controls and owner-survival/re-reachability behavior are frozen
and qualified. Physical operation stages/displaced originals are never generic
object-GC temporaries. Orphan signed objects cannot be auto-admitted as published
or accepted history; CAS alone cannot reconstruct lost authoritative metadata.

Consistent backup uses the completed destination SQLite snapshot's actual inventory,
not a start timestamp or a later live DB query. While holding the shared gate,
seal/sync that artifact and commit live backup-intent pins; only then release and
stream its objects. Concurrent SQL writers may continue. A resumable-operation
bundle additionally covers exact staging/displaced native state with workspace
locks, byte checks and required quiescence. A history-only backup with pending
operation rows is not a resumable filesystem bundle.
[SQLite online backup API](https://www.sqlite.org/backup.html)

## Concrete M1b fault-verification matrix

All rows below are DESIGN_CONTRACT expectations plus REQUIRES_RUNTIME_TEST.
Run each pre/post fault in disposable new-format stores; preserve raw bytes,
SQL/integrity/FK inventories, roots, request/operation IDs and complete injected
schedule. Validate the recovered state with an independent inspector, not only
the writer's own flags. No active OCaml/user stores or accepted G01 artifacts.

| ID / initial state and injection | Required oracle after restart / retry | Gate |
| --- | --- | --- |
| F01 old capture C, new object temp T; terminate during write or file fsync | C/cursor/roots remain authoritative; T is owned staging, no success. Same request checks its stored state first | M1b object publication |
| F02 terminate after file fsync, before canonical name publication | Temp may be durable; no new metadata root. Reclaim only verified dead owned staging, not an accepted/captured fact | M1b |
| F03 canonical create-only publication and each directory sync; inject IOERR/FULL | Metadata may reference only fully valid durably published closure; sync failure reports incomplete, old capture retained. No replacing fallback | M1b + native flush qualification |
| F04 objects published before SQL BEGIN | Unreachable objects can survive, metadata still C. No orphan scan invents history/signing success; original-key retry may reuse verified bytes | M1b |
| F05 terminate inside append after counter/reservation/fact/cursor/root statements | Either old state or complete new state after recovery; no cursor to absent occurrence, duplicate/reused sequence or partial request result | M1b production constraint closure |
| F06 COMMIT returns BUSY while transaction remains active | Bounded COMMIT retry or explicit SQL ROLLBACK, inspect transaction state. Do not rerun transaction body blindly | M1b contention/error handling |
| F07 terminate/disconnect/IOERR around COMMIT outcome | Reopen/recover, query original key and exact plan association; original committed result, same pending identity or explicit unknown/unavailable. Never allocate/sign/apply again merely because response missing | M1b |
| F08 commit succeeds, response lost; same key and second key for same plan | First returns same IDs/result; second resolves the existing plan operation. Changed arguments refuse. Retained results have no unsafe TTL | M1b request schema |
| F09 three writers A/B/C; B waits on prompt or is Paused, A scans, C commits | B owns no SQL/gate while waiting; A/C preserve independent rows and progress. Only short SQL write contention, bounded retries/fairness measured | M1b locks; M3 scheduling |
| F10 reader takes SQL root while collector wants object | Shared gate precedes lookup or durable pins commit before gate release; object remains usable for entire stream. PID/timeout uncertainty leaks protection rather than deletes bytes | M1b reader/GC |
| F11 two publishers race collector over unrooted/quarantined O | Exclusive gate excludes publication/root handoff; later publisher verifies/restores/republishes O before root commit. Purge rechecks current roots | M1b; GC control OPEN |
| F12 terminate at old-plan/operation pin release and new-retention insertion | Every committed recovered state has complete surviving root owner. No unprotected interval or independently deleted physical staging | M1b root ownership |
| F13 delete or corrupt referenced object/chunk | Unavailable versus IntegrityFailure as appropriate; stop affected mutation, preserve metadata/diagnostics. Never infer Absent or rebuild admission from orphans | M1b |
| F14 disk full at temp, object publication, rollback journal, SQL COMMIT, result/cleanup | No false completed capture; previous captures and pending roots remain. Resolve uncertain commit by lookup; cleanup may lag, not delete sole copies to meet quota | M1b and M2 stages |
| F15 consistent backup while captures publish and older live roots release | Completed destination DB inventory remains protected through backup pins. Restore exactly that boundary, not later capture claims; no ordinary live-file copy | M1b backup |
| F16 terminate before/after sealed-backup artifact and backup-intent COMMIT | Before intent: unacknowledged staging; after: same frozen retryable backup intent. Object stream starts after ownership handoff | M1b |
| F17 restore DB+objects missing one required object, or DB lost but objects remain | Incomplete/unavailable history; no claimed full recovery, no cursor/admission reconstruction by scanning orphan signatures | M1b restore/repair |
| F18 backup includes pending Applying operation but lacks stage/displaced tree | History-only bundle; inspect missing physical scope and refuse replay/Completed fabrication. Original staging or explicit recovery decision required | M1b classification, M2 executor |
| F19 unsigned pending publication waits on signer then process dies/authority changes | Pending key keeps source/plan pins, no held transaction. Retry same intent/source; changed authority/exclusions refuse/replan rather than substitute latest | M1b storage shape; M4 security consumer |
| F20 B3 receipt versus exact-A2 plan; then accepted head/authority/workspace changes | S17 stays valid; S18/relevant change stales/refuses. Commit preserves unrelated admitted facts; partial physical output remains rooted/Paused | M1b mock transition, M4/M5 real public admission |
| F21 quarantine/progress/purge interruption; object becomes reachable again | Restartable frozen intent, latest roots rechecked under exclusive gate; no stale mark authorizes deletion | Before enabling GC; control encoding OPEN |
| F22 schema/repository/application mismatch; counter/serial int64 exhaustion | Refuse unknown writer format and overflow before coercion; no initialize-over, sequence reuse or silent schema upgrade | M1b schema/build qualification |

Fault tests need real subprocess termination and injected IO errors/BUSY/FULL,
not just exceptions inside a rolled-back test connection. They still do **not**
prove controller flush honesty, torn-sector resilience or physical power-loss
behavior. State qualified filesystem/hardware assumptions separately. No automatic
eviction or hardware-independent durability claim follows from green process tests.

## Native filesystem inventory and qualification

The [C adapter](../../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c) and
[Native wrapper](../../../lib/yeokcham_snapshot/native.ml) establish concrete
existing primitives. [Snapshot observation](../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml),
[Safe_apply](../../../lib/yeokcham_v1_local_service/safe_apply.ml),
[restore journals](../../../lib/yeokcham_v1_restore_journal/yeokcham_v1_restore_journal.ml)
and [native integration](../../../lib/yeokcham_v1_local_service/native_integration.ml)
show their use. These are source facts, not a qualified Python ABI.

| Responsibility / exact existing operation | Linux | macOS | Windows / qualification |
| --- | --- | --- | --- |
| Anchored no-follow traversal | `openat` with O_RDONLY/O_CLOEXEC/O_NOFOLLOW/O_NONBLOCK; O_DIRECTORY for directory; `fstatat(...,AT_SYMLINK_NOFOLLOW)` | Same POSIX adapter branch; dev/ino/mode identities | Current C stubs refuse. Handle-relative no-reparse contract/binding OPEN |
| Stable observations | `fstat`, dev/ino/mode/nlink/size and ns mtime/ctime; recheck path/membership/rules after streaming | Uses `st_mtimespec/st_ctimespec` rather than Linux `st_mtim/st_ctim` | No Windows proof. Fingerprints are observations, not full byte identity or a global multi-file instant |
| Directory enumeration | Fresh `openat(fd,".",O_DIRECTORY|O_CLOEXEC)` ->fdopendir/readdir; independent open description | Same source path | Native support/handle lifetime and races still need Python tests |
| Symlink observation | `readlinkat` raw bytes, no following target | Same source | Representation/limits/invalid target native gate; no symlink-as-text fallback |
| Exclusive creation | `openat` O_WRONLY/O_CREAT/O_EXCL/O_CLOEXEC/O_NOFOLLOW mode0600; mkdirat0700; symlinkat | Same source | Python/native Windows capability OPEN; creation does not prove synced bytes |
| Preservation-aware move/exchange | `syscall(SYS_renameat2, ..., RENAME_NOREPLACE/RENAME_EXCHANGE)`; unavailable syscall refuses | `renameatx_np(...,RENAME_EXCL/RENAME_SWAP)` | No qualified Windows replacement/flush. No ordinary replacing rename fallback |
| Native destination preflight | fpathconf NAME_MAX, faccessat; source rejects FS_CASEFOLD_FL directory application | Actual name/case/normalization representation must still be probed | Cannot infer all OS/filesystem names are representable from canonical bytes |
| Staging/displacement | Same-filesystem private staging, retained slots; deletion by preserved move, not unlink | Required behavior, not freshly run on this host | No generic recursive overwrite/copytree or os.replace substitute |
| Flush/publication | Safe_apply file/directory Unix.fsync; store fsync/create-only publication | Stronger required macOS flush capability remains separately qualified | Current OCaml store tolerates certain unsupported directory-fsync errors. Python strong mode must refuse/report capability instead of inheriting silent success |
| Post-application validation | `entry_bytes_match`, Content.verify_fd, names/modes/symlink bytes, pre/post and retained pairing | Same required checker contract; no fresh macOS run | Identity/mtime-only checks insufficient. This guard must remain despite the old failure |
| Journal/proof/retry | Existing versioned restore intent/proofs and native integration phases/token lookup | Source consumer exists; runtime qualification separate | SQL operation encoding will differ, not remove preservation semantics |

Native Linux P2/P3 tests are **historical qualification of their scoped builds**,
not proof for all Linux filesystems or the current Python binding. macOS API
presence is KNOWN_BY_SOURCE but executor/flush qualification here is UNKNOWN.
Windows preservation is UNSUPPORTED/UNQUALIFIED. Network/shared/cloud-synced live
stores remain unsupported. Advisory locks cannot stop arbitrary external writers
or same-user hostile access; retaining unexpected nodes is the recovery obligation.

### Initial copy-out / new workspace ownership

DESIGN_CONTRACT from D4 sections 8–9, accepted as an M0 assumption:

- Destination entry must genuinely be absent; direct parent already exists.
  Existing empty/occupied directories refuse DestinationExists. Do not rmdir for
  the user or create a missing parent hierarchy. Existing/nested unmanaged-tree
  attachment remains OPEN and unsupported by this initial mode.
- Build/sync/verify the complete private same-filesystem target and immutable
  `.yeokcham-v2/claim.cbor` locator. Proposed DestinationClaim-v1 binds repo32,
  operation16, PlanId32, target32, random token16 and role0 copy-out/1 new workspace;
  <=512 bytes, depth<=8/items<=64. SQL intent remains sole execution authority.
- Prepared commits exact stage native identity, parent/name/ancestor identities,
  marker bytes, request/plan association and pins; Applying precedes mutation.
  A native directory-relative NOREPLACE/EXCL rename is the claim and complete-tree
  exposure. One competing store wins; the loser preserves its own staging.
- Sync both parents and verify identity, claim and complete target bytes; rewalk
  requested parent/ancestor identities before Materialized. A moved/substituted
  path pauses and is never adopted merely because marker/bytes match.
- Lost progress retries verify the owned installed pair, never redo rename or
  populate the directory again. Missing stage plus foreign/absent destination is
  location unknown. Explicit relocation/recovery is required; no host-wide guess.
- Copy-out source files/cursor/counter/basis remain unchanged. Its destination
  pre-state is Absent, with no displaced original. In-place application still
  retains original nodes; do not generalize this exception.
- Matching repo/op/token **and** native identity/intent/bytes are required; copied
  marker alone is insufficient. Cooperative clients honor pending-prefix markers;
  external writers remain uncooperative. Owned locator cleanup follows durable
  commit through verified handles; unknown children/foreign directories survive.

If a target requires ordinary user data at the reserved metadata name/native
alias, refuse exact materialization rather than omit those bytes. Cross-store
claims need native race/identity/flush vectors before M2, not a global database
or second execution journal.

## Concrete M2 recovery and copy-out tests

Preserve `Prepared -> Applying -> Materialized -> Committed -> Completed`, with
Paused recording its origin and explicit linked Recovery intent under the same
pending owner. Original intent is immutable. Pending ownership retains safety/
target CAS, exact op/plan/key, physical stages/displaced originals and SQL pins;
normal capture must not record a partial application as ordinary editing.

Use exact original O=`b"original\n"`, target T=`b"target\n"`, external
U=`b"external\n"`, plus a second file for partial-action tests. Record native
identities, actual byte hashes, paths, progress serials and retained roots before
and after each boundary. Every test is REQUIRES_RUNTIME_TEST here.

| ID / timeline | Expected independent oracle |
| --- | --- |
| N01 staged T, no O replaced, crash | Live O, stage T, Prepared and pins. Checked resume only; prewrite cancellation retains safety. Changed stage/source refuses/pauses |
| N02 native exchange O/T succeeds before progress write | Live T, retained O, old progress. Classify complete pair and advance once; never exchange again and swap O back |
| N03 first file T, second still O, crash | Classify every pre/post pair; retain complete safety/target/stage/displacement; resume only verified pairs; no ordinary partial-tree capture |
| N04 user changes installed T to U before Materialized | Pause with U/live, O/retained, T/CAS. Explicit recovery preserves U; retry does not overwrite it |
| N05 old open descriptor changes retained O to U while metadata appears unchanged | Full-byte retained check detects mismatch even with same inode/size/mtime; preserve U and live T; pause |
| N06 Materialized T, new accepted head before metadata commit | Stale plan, no public acceptance; retain T and later U if present, O/safety/physical roots. No file replay after Materialized |
| N07 commit/response loss or later edit after Materialized | Same key/plan/op returns historical result or finishes metadata/retention only; no second navigation, acceptance or overwrite of later U |
| N08 two independent stores race same absent destination, both orders and case aliases | Exactly one exclusive publication wins; loser DestinationExists retains its stage. Equal output bytes never authorize adoption |
| N09 crash after exclusive publication before Materialized | Whole tree already exposed; matching original identity/token/intent permits verification/sync only. Changed bytes pause. No exposed partially populated output is an eligible state |
| N10 external rename of owned destination plus foreign replacement at original spelling | Preserve moved original and foreign replacement. LocationChanged/RecoveryRequired; explicit supplied relocated path must match native identity/intent, not marker alone |
| N11 nested destinations, old/unknown/foreign marker, symlink/parent/root substitution, source/staging/store alias | Refuse unsupported overlap/representation, retain uncertain nodes. Preflight scan/SQL UNIQUE path alone is insufficient |
| N12 empty existing destination versus absent; old open empty-directory descriptor | Existing empty **refuses before mutation**. Old OCaml takeover test stays unchanged as historical regression; Python must not implement its old allowance |
| N13 benign metadata difference with exact T versus changed T with preserved metadata | Positive exact target accepted under qualified identity rules; real byte mismatch fails. Never weaken complete-byte validation to make a fixture pass |
| N14 ignored/untracked obstruction, file-directory/deletion interaction, raw names/exec/symlink/empty dirs, large/chunked target | Exact supported fidelity or prewrite refusal. No omission/normalization or total-file cutoff disguised as success |
| N15 disk full/flush failure at every stage/action/progress/phase/root transition | Preserve previous safety and uncertain physical nodes, keep pending owner; no false Materialized/Completed or deleted retained originals |

### BASELINE-COPYOUT-20261116 disposition

**OPEN; historical failure reproduced then, root cause unknown, not rerun or fixed
in M0.** Preserve the exact test/assertions/fixtures and the
[receipt](../../implementation/results/cli-graph-20261116.json),
[ledger](../../IMPLEMENTATION_PROGRESS.md), source/binary/log digests, Dune action/
TMPDIR environment, direct-run contrasts, both tiny history shapes and their
original/staged/installed/retained byte observations. Some full historical logs/
Linux cache artifacts are not available on this host; committed digests are not
the logs themselves. No accepted G01 data is a disposable reproduction fixture.

M2 must independently implement N01–N15 plus the historical `asset-8192-8`,
attributes, five-node linear/branching, interrupted runner/retry environment
contrasts. Deliberate byte mutation must be rejected; exact unchanged bytes must
not fail merely because an assumed fingerprint changed. M2 cannot pass from a
happy-path port, absent-only restriction or a weakened checker.

**Resolved** requires separate authorized OCaml diagnosis/correction and relevant
regression/full verification on its exact source. **Isolated** requires an
independently qualified different Python path covering the relevant environmental,
fidelity, fault and mismatch cases plus an explicitly approved limitation; it
does not make old CI green. Without either evidence-backed disposition, M2 rollout
remains blocked. M1a pure/content and isolated M1b work do not depend on diagnosing
the old copy-out bug, but remain subject to their own contract gates.

## Open contract register and exact consumers

| ID | Exact missing choice/evidence | Consumer / prohibition | Safe deferral |
| --- | --- | --- | --- |
| O01 | Full independent retained-content/chunker/tree/snapshot corpus RC01–07, reviewed expected bytes and independent decoding | Before promoting corresponding M1a content consumer; old control vectors are insufficient | Can prepare corpus before production; no persistence/native dependency |
| O02 | Path-frontiers exact work charging/iteration, final upper bounds, structural/resolution/nonconfluence and long-history qualification | Before full M1a normalization implementation/profile claim, then M4/M5 | Typed ID/content-only subset can exclude this consumer; cannot silently choose constants while coding |
| O03 | Candidate/PublicBasis/revised accepted/resolution ordered bytes, OriginRef/context/profile encoding and independent signed vectors | M4 codecs/signing/admission; accepted transport M5 | No public bytes in M0/M1a. D3 draft direct-input/proof fields must not reappear by accident |
| O04 | Complete production SQL constraints/immutability/phase/root-release/exhaustion enforcement, schema/application IDs, private request/verification inventory controls | M1b authoritative store; illustrative D3 DDL is not sufficient | Restrict any approved local-store slice to explicitly frozen facts; unsupported plan/public tables must not accept placeholders |
| O05 | Canonical private plan/native observation bytes, action/native identities, linked recovery-generation encoding and required flush class | M1b when retaining those controls; M2 physical executor | Defer action variants until executor; no opaque valid-looking bytes or second JSON journal |
| O06 | Native binding/ABI, DestinationClaim-v1 independent bytes, no-replace/exchange/handle/flush qualification, existing-tree attachment exclusion | M2 writer/setup; Windows seam M2/M3, full M8 | Initially absent-only; arbitrary existing/nested unmanaged attachment refuses |
| O07 | Quarantine/purge intent/progress/receipt and current-root re-reachability enforcement | Before enabling M1b GC | Keep collection/history eviction off; retained pending native stages are never generic temp cleanup |
| O08 | Exact CPython/SQLite/VFS/build/options allowlist, canonical provider/bounded decoder and licenses/hashes/platform artifacts | Before dependent M1a codec/provider or M1b adapter; each native/crypto consumer separately | Installed host version is observation only; no dependencies installed by M0 |
| O09 | Authority/custody bundle carriage/reuse, historical/current admission and private-cache eligibility proof | M4 public mutation, M5 receipt | Required unsupported policy/adoption refuses. No plaintext signer convenience; security not postponed to M7 |
| O10 | Bounded version/profile/type/mandatory-feature negotiation, routes/media, frozen manifests/ack schema | M5 exchange | No old-protocol fallback or wire interoperability claim from content compatibility |
| O11 | Complete principal/review/private-account/archive/key recovery/retention formats and evidence | M7a/M7b; minimum custody/current trust already M4 | Keep unsupported required modes and automatic eviction off; cannot relabel public backup as private archive |
| O12 | Explicit export/import mappings, quiescence/recovery bundle, migration/rollback-reader and platform qualification | M8 transition | No Python writer opens an OCaml store or overlaps managed files; no silent default executable takeover |
| O13 | Existing Content writer switches above 65,536 bytes but inline reader branch lacks that cutoff: specify read-only inspection versus verified admission of oversized inline envelopes | M1a content reader/admission consumer; writer output remains canonical manifest | No new format, hash reinterpretation or OCaml change; source observation is not a runtime rejection test |

These are consumer gates, not a demand to solve every later protocol before pure
content work. Nor does deferral mean implementation may pick the missing contract.
Any new false-Ready normalization counterexample reopens its design gate.

## Definitive tranche dependency and rollback table

Every row requires a **separate instruction**. None is started or declared fully
ready by M0. “Must not modify” throughout means no old source/vector/ledger/data
changes unless a later task explicitly authorizes that exact scope.

| Tranche | May assume / must implement | Must refuse / independent exit tests | Preserve and do not modify |
| --- | --- | --- | --- |
| M1a pure domain/content | M0 A–E, exact inherited widths/formulas/leaf source, independently closed RC corpus/O13 reader-admission treatment; typed immutable facts/in-memory transformations only. Full normalizer additionally consumes O02 | Refuse unsupported profiles/ambiguous comparisons/missing or invalid scope; no IO/public signing/store/native writer. RC01–07, Python strict type/size/CBOR negatives, semantic cases/properties for the exact authorized subset | Old store/code/tests/goldens untouched; separate experimental source/fixtures/reader; stop without data rollback |
| M1b metadata/object persistence | Qualified M1a subset; close O04/O05 as consumed, O08 build/locks and object publication/root protocol; authoritative SQL and create-only CAS/idempotency/backup | No managed capture/public acceptance/native application; GC off until O07 and runtime tests. F01–F22 with real processes/independent inspector and exact error classes | Matching schema reader/bundle, original keys/IDs/roots and uncertain results; no live OCaml writer/shared mutable directories |
| M2 local history/restoration | M1b, qualified native binding/identities/flush O05/O06; manual observe/capture/history/diff/preview/restore/copy-out/recovery, one typed API | Empty destinations/existing-tree attachment/unsafe platform/obstructions refuse; no quiet service/network/archive claim. N01–N15, mixed fidelity, ignores, stable observations, resolved-or-isolated copy-out disposition | Safety/target/staging/displacements/op identity and matching executor/reader; source rollback cannot undo working files |
| M3 managed capture | Qualified M2; service lifecycle/readiness, advisory hints/full reconciliation, bounded workers, durable pauses/fairness | No backup success without archive; no saved claim from heartbeat/mtime. J1/J2/J7 restart/wake/overflow/full/unstable/paused and three-workspace resource tests | Stop service without deleting captures/registration/recovery; manual API remains. No old executable dispatch change |
| M4 signed continuation | M1a semantics/content plus M2; close O02/O03/O09 and selected crypto/custody providers; exact-source publication/private witnesses/current admission and minimum protected setup | Unsupported required review/adoption/policy refuses; no native remote readiness claim. Independent signed/domain vectors, scope/privacy/private-cache and A2/B2/old-source/D/E regressions | Signed IDs/correspondence/outbox and matching reader; no signature rewrite or plaintext-key fallback |
| M5 exchange/acceptance | M3/M4, closed O10; verified bounded transport/frozen batches/acks, nonapplying receipt, exact safe acceptance and accepted-head reconciliation | Unknown control/profile/capability refuses; no old fallback, account/archive/review claims. Controlled TLS/offline/lost-response/concurrent-head/private-output/fault J4/J5 | Published data cannot be unshared by rollback; preserve exact batch bytes, admitted facts, pending ops and compatible reader |
| M6 agent experiment | Existing M2/M4 typed API and M3/M5 workflows; snapshot-bound evidence/recovery/retirement plus fair adapted Git/jj baseline | No orchestrator/lane/agent authority or sandbox claim. J6 three workers, separate agent/capture-worker failures, contamination/ignored deletion checks, counterbalanced operator trials | Keep workspaces/history/pending work on adapter removal; evidence exactness and source API ownership remain |
| M7a security/review | Minimum security already M4/M5; close O11 principal/member/review/onboarding contracts | Unsupported policy submodes refuse, never downgrade enforcement. Independent principals/devices, forks/revocation/withdrawal/blocker/renewed-review/confirmation matrices | Rollback reader must enforce admitted policy; custody/recovery identities and immutable evidence retained |
| M7b private archive | M3/M5 and O11 account/crypto/key recovery/consistent metadata+object backup; complete manifest/ack/readback and retention eligibility | No automatic eviction before complete recoverability proof. J3/J8 fresh-device recovery, lost ack/key/object, quota/offline/revocation/fork matrix | Disable eviction first on rollback; retain keys/manifests/sole local copies and pending operation roots |
| M8 qualification/migration | Qualified preceding capabilities, O12 reviewed explicit transition. Windows binding/service work starts M2/M3, not deferred to M8 alone | Unsupported platform/materialization/migration refuses; native/human/source-asset-monorepo/resource/packaging/rehearsal evidence required | Separate stores/executable, old data/readers/recovery tools; no implicit upgrade/default replacement/deprecation |

M2's local-only setup may explicitly use null public basis and refuse collaboration;
minimum public setup before M4/M5 creates authenticated **empty** genesis, not
acceptance of private existing files. The broader existing-tree onboarding gap
must remain visible rather than inventing an unsafe setup path.

Mapping to original roadmap: M1a overlaps parts of G02/G04/G05; M1b G06/G07;
M2 G05/G13/G14; M3 G15–G17; M4/M5 G02/G03/G04/G08/G13/G14; M6 value/journey
work in G18/G19; M7 G03/G09–G12; M8 G17–G20 plus reviewed transition work.
These overlaps do not close original prerequisites or criteria. P4 native/human
pilot remains unstarted. G01 accepted results remain unchanged; only G01 is a
complete original phase. No ledger is updated by M0.

## Readiness and proposed Codex Prompt 06

**M0: COMPLETE as reference preparation, subject to the recorded verification.**
Every requested inventory/case/gate is provided; OPEN questions are explicit
deliverables, not invented answers. There is no product implementation readiness
or globally approved D1–D4 contract claim.

**M1a: NOT READY AS A COMPLETE DOMAIN/NORMALIZATION TRANCHE.** O01's independent
content corpus, O13 reader-admission choice and O02's charging/structural/resource qualification are not
complete. It is incorrect to mark full M1a ready because M0 documents those gaps.
A narrowly scoped typed-ID/content task can be designed without O03–O12, but
must settle its own reference corpus/provider/subset gates before production code.
M1b/M2/M4/M5 have additional independent gates; none is implied ready.

Proposed **Codex Prompt 06: close M1a reference prerequisites**, separately authorized:

1. Reverify HEAD/status, preserve user work and use these source hashes/current D4.
   Freeze an exact content-only versus full-normalization scope before coding.
2. Settle O13's inspected writer/reader distinction and generate/review RC01–07
   through independent reference emission and decoding,
   with complete retained closure bytes/IDs and unchanged-source OCaml comparison
   in disposable fixtures. New reference artifacts only in an explicitly assigned
   experimental test/reference directory; no old fixture rewrite or dependency
   installation without that later instruction's scope.
3. Settle O02's exact charging/iteration/bounds and structural/resolution negatives
   before a full normalizer; require 22 semantic cases, permutations, discarded/
   rebased origins, and actual nonconfluence/budget negatives. Return an explicit
   restricted subset/refusal instead of silently selecting semantics.
4. Freeze supported Python/provider/build/test choices only for the selected pure
   consumer and record remaining gates. Do not pull SQLite/native/signing/network
   consumers into a domain task to finish open contracts opportunistically.
5. Return a concrete M1a implementation scope/readiness finding. Production code
   requires an explicit subsequent or separately scoped authorization; this M0
   task and proposed prompt start none.

All D2 section 17 numbers remain **proposed acceptance budgets**, not observations.
They require fixture hashes/native host CPU/RAM/SSD/filesystem/power/build and
measurement definitions before use. Current host/tool observations do not freeze
a benchmark host. No new performance result or fair Git/jj superiority claim was
produced. Lane need is falsified if workspace identity plus a small adapter suffices
or the best reasonably automated Git/jj baseline matches the relevant outcomes.

M0 rollback is to stop and preserve these four new references for review. Any
future removal must inspect those files and external snapshots first; no reset,
branch change, old-reader removal or live-data rollback is part of this task.
No production Python, OCaml/test change, service, later tranche or migration starts.
