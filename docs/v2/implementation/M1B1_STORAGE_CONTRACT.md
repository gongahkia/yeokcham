# Restricted M1b.1 private storage contract

**Frozen for this experimental tranche, 2026-11-21.**
**Gate: QUALIFIED_FOR_M1B1_IMPLEMENTATION.** This is neither a public protocol
nor an amendment to older RFCs. No filesystem capture/application is consumed.

## Ownership and runtime

One repository-local `metadata.sqlite3` is the only mutable authority. Static
`FORMAT` bytes are `b"YEOKCHAM-PY-PRIVATE\n1\n" + repository_id.hex().encode()
+ b"\n"`; they bind the database identity, never a cursor. Application ID is
0x594b5031, user_version1. Exact DDL below, including trigger definitions, must
match on reopen. No migration, initialize-over, unknown-header write or empty-
directory takeover. A new exclusive0700 directory is initialized, file and parent
entries synced, and FORMAT is created last as readiness. Interrupted initialization
without the final marker refuses; it is not automatically repaired or removed.

Only a local Linux/x86_64/Btrfs experimental profile is qualified here. CPython
3.14.8, SQLite3.54.0 source ID `2026-10-09 15:46:58 be8d059e9a49089ab2dce5ed26dd87aaf598fdc5fbe0b107c0dd758464bcalt1`, compile-option SHA256
`b21634e22f921a220f8494a0e551605763d8f3d33e582075f574a42d718a152a`,
_sqlite3 extension SHA256 `ed9dc2218de28a5725a171a18b2ae31c9065486bd54361b6cdf598d36682760a`,
loaded libsqlite3 SHA256 `758544266d5060aff683efcc94ee9abf2625c6ff9d02b70bb6d1296e0ee9128f`.
Unknown profiles refuse before initialization. This is a tested local binary
allowlist, not full upstream equivalence/security or cross-platform qualification.
The vendor package is sqlite3.54.0-1, pacman inventory31 files/0 alterations.
The alt1 source differs from the upstream release suffix; no upstream identity
is claimed. SQLite3.54.1's32-bit overflow fix does not qualify or disqualify this
64-bit build; other patch differences remain a rollout risk. No dependency upgrade
is authorized or performed.

Use fresh process/thread-owned connections: autocommit=True; explicit SQL BEGIN
IMMEDIATE/COMMIT/ROLLBACK; connection.commit() is not used as a boundary. Check
DELETE, synchronous=EXTRA(3), foreign_keys=ON, STRICT support, exact schema,
application/version/repository. Unknown header refuses before SQLite opens RW.
Known-format hot-journal recovery is allowed; malformed known metadata refuses.
On open, integrity_check and foreign_key_check validate metadata ownership, then
the verified FORMAT file and store/parent directories are synced again. This
re-establishes readiness after an interrupted initializer reached the marker.
No connection survives fork or is shared between callers. Do not fork with an
open Store/operation: inherited flock descriptors can otherwise outlive the parent.
Use fresh spawned/exec processes, each opening its own Store. BUSY/lock waits default
1second, configurable only0..5seconds, explicit Busy result and no blind retry.

Store and fixed objects/locks directories are private0700, owned by the effective
user, no symlink components. DB is regular, single-linked, owner0600. Object paths
are fixed lowercase64-digit exact StoredObjectIds. SQLite opens only the verified
owned store path. All clients must cooperate with locks and not rename/replace
store directories or DB files. Same-user hostile modification, mount substitution,
remote filesystems, tmpfs/reboot persistence, device flush lies and physical power
loss are outside this profile. Ordinary workspace paths are not stored or opened.
`.yeokcham`/`.yeokcham-v2` path components explicitly refuse even if a marker exists.

## Exact private API semantics

RepositoryId32, WorkspaceId16, SnapshotId32 and StoredObjectId32 remain distinct
M1a types. Workspace registration is idempotent for one exact supplied ID and
starts(cursor=None,next_seq=version=0); no attachment or new authority. Namespace
reuse/delete is unavailable. CaptureId=(workspace,sequence), immutable parent is
exact prior cursor in that workspace. No branch navigation or cursor reset API.
All committed history is retained; equal old snapshots remain distinct occurrences
when revisited after another snapshot. A repeated *current* snapshot records an
unchanged request result, no new occurrence/counter change. There is no inference
of ancestry from content equality. Future branching may extend the schema; this
linear slice never deletes alternative retained occurrences/workspaces.

Version and next_seq advance together; first capture sequence0 yields version1.
Both are nonnegative int64; at next_seq==2^63-1 capture allocation refuses Exhausted
before overflow, so this slice allocates at most sequence2^63-2. This explicit
restriction preserves the general M1a CaptureId type; no reserved native-operation
sequence/null/phase encoding is consumed. First parentNone, later parent=current
capture; stale version/cursor or arbitrary ancestry refuses. Version/cursor are
rechecked after object production, inside the final transaction.

Capture requests are scoped by (repository,workspace,action=capture,key bytes1..128).
There is no public/authenticated-caller namespace in this private-only slice.
Argument digest = SHA256(b"yeokcham/private-request/m1b1\0" + canonical retained
CBOR([1,workspace.raw,expected_version,parent_sequence_or_null,snapshot.raw])).
The exact columns are frozen by the first pending claim; same key/different digest
refuses RequestMismatch. Completed replay returns original CaptureId/version/changed
result, even after later captures, and rechecks historical closure availability.
It cannot allocate again. Pending replay reuses the original intent and roots;
if its expected cursor has changed it refuses Stale, retaining the pending intent.
No key expiry, abandonment, cancellation or automatic retry with fresh inputs.

## Object publication and roots

A caller supplies exact SnapshotId and an immutable-object byte resolver; it has
already built/verified its closure. The store independently rechecks full closure
with M1a Verifier(max_file_bytes=0); it never trusts a verification Boolean. Incoming
objects stream into exclusive same-directory .stage-random files; enforce declared
length and128MiB envelope ceiling, canonical CBOR/envelope/hash/type and strict
inline <=65536, chunk shape/size. Standalone put validates local framing/schema;
manifest/tree dependency eligibility is established only by full closure verification.
Standalone put is an orphan publication, not a capture or permanent retention ack.

File fsync precedes create-only hardlink publication; no rename-over or overwrite.
Existing IDs must have exact matching verified bytes, then file and directory sync
are re-established (an existing orphan is not assumed durable). Sync the objects
directory after publication and removal of the caller's own temp. Interrupted
stages remain untouched on reopen; no generic cleanup. Missing files are Unavailable,
corrupt IDs/bytes IntegrityFailure. Input/IO/storage failures return no capture.

The single authoritative `root` table owns one snapshot intent per request.
A pending request and root commit *before* object production. Captures reference
their immutable completed producer request, whose root owns that snapshot and its
complete recursive content closure. All roots, requests and captures are retained;
there is no independent root file/object inventory authority. Root ID membership
alone is not proof of available/durable bytes. The API verifies/syncs full closure
under the shared gate before capture COMMIT; reads verify it again when requested.

A pending root can be incomplete after failure and is explicitly an intent, not
eligible history. Future collection must refuse reclamation whenever any pending
root is not fully available, or first introduce a separately qualified complete
publication inventory/abandonment protocol. This conservative barrier can delay GC;
it does not permit deleting partial pending publication. GC/eviction is absent.
A reader of history metadata makes no content availability claim; read_snapshot
and verify_roots actually traverse required dependencies. DB loss cannot be rebuilt
as authoritative captures from orphan object files.

## Locks, transactions and failures

Exact order: workspace process flock(EX) -> repository publication gate flock(SH)
-> short SQLite writer. Object-only publishers/readers take gateSH first; future
collector takes gateEX then SQL, never workspace locks. Lock files are never
unlinked/renamed; flock release follows descriptor close/process termination, not
PID or timeout-based stealing. Independent workspaces may stream concurrently;
short global SQLite commits may return bounded Busy. No SQL transaction exists
while producing/verifying full object bytes, scanning, waiting for network/humans.
Readers acquire gate before root lookup, copy bounded SQL rows/close connections,
then stream while retaining the gate. No global repository-generation CAS. History queries page1..10000 rows; a root
audit refuses above10000 owners instead of allocating an unbounded report. Reopen
metadata integrity checks can scan the DB; no scalability claim is made.

Capture protocol: lock; replay-check; validate expected workspace; short pending
request+root transaction; publish/verify complete supplied closure and canonical
store closure; revalidate path bindings/workspace; BEGIN IMMEDIATE; insert capture
(if changed), advance cursor/sequence, complete original request; COMMIT; acknowledge.
No partial new capture can commit: deferred FK requires its producer completed;
completion trigger requires matching workspace transition. Unchanged requests bind
the existing capture/version. Root transfer is unnecessary because owners never
release in this slice. Physical availability validation remains adapter-owned.

Rollback cleanup errors do not replace the original uncertain-COMMIT result.
If COMMIT raises, do not guess: rollback only while in_transaction, close, report
UncertainCommit with original request identity; fresh retry looks up that key.
A lost response after COMMIT returns the same historical result. A crash before
COMMIT leaves old capture/cursor and the already committed pending intent/root;
objects may be orphan/partial. Hot-journal recovery precedes inspection. Unexpected
missing committed bytes refuse; never rewrite history or fabricate an empty file.

Typed storage failures: InvalidStore, UnsupportedRuntime, IdentityMismatch,
Busy, Stale, RequestMismatch, Exhausted, UncertainCommit, StorageFull, StorageIO.
M1a ContentError retains its exact encoding/integrity/unavailable/resource taxonomy.

## Qualification and remaining gates

Independent Btrfs probe: direct SQL FK/trigger negatives, cyclic completion/root
FKs, unchanged completion, integrity/foreign-key checks; Connection.commit() no-op
inside explicit BEGIN; explicit ROLLBACK and COMMIT; two subprocess kills before/
after COMMIT; create-only hardlink collision, file/directory fsync and cross-process
shared/exclusive flock. All exit0. This closes the consumed O04/O05 logical subset
and a local O08 capability profile, not future plans/actions/authority/backup/GC.

O07 stays deferred: no deletion API or collector. Native working-file action
controls and recovery, public encodings, private backup, archive, signing, exchange,
background capture, agent lanes and OCaml migration remain absent. Actual SQLite
IOERR/FULL/BUSY/fault qualification and process tests are M1b.1 acceptance work;
missing exercises must remain unqualified in the report, not be counted as passes.
No power-loss or production deployment qualification follows from these probes.

Primary references: [Python3.14 transaction control](https://docs.python.org/3.14/library/sqlite3.html#transaction-control-via-the-autocommit-attribute),
[SQLite synchronous](https://sqlite.org/pragma.html#pragma_synchronous),
[atomic commit assumptions](https://sqlite.org/atomiccommit.html),
[3.54.0 identity](https://sqlite.org/releaselog/3_54_0.html),
[3.54.1 changes](https://sqlite.org/releaselog/3_54_1.html).
Exact startup DDL follows. It is independently exercised, not copied from D3.

```sql
CREATE TABLE repository (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 identity BLOB NOT NULL CHECK(length(identity)=32),
 format INTEGER NOT NULL CHECK(format=1)
) STRICT;
CREATE TABLE workspace (
 id BLOB PRIMARY KEY NOT NULL CHECK(length(id)=16),
 cursor INTEGER CHECK(cursor>=0),
 next_seq INTEGER NOT NULL CHECK(next_seq BETWEEN 0 AND 9223372036854775807),
 version INTEGER NOT NULL CHECK(version=next_seq),
 CHECK((cursor IS NULL AND next_seq=0) OR (cursor IS NOT NULL AND cursor=next_seq-1)),
 FOREIGN KEY(id,cursor) REFERENCES capture(workspace,sequence) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE request (
 workspace BLOB NOT NULL REFERENCES workspace(id),
 key BLOB NOT NULL CHECK(length(key) BETWEEN 1 AND 128),
 arguments BLOB NOT NULL CHECK(length(arguments)=32),
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 expected_version INTEGER NOT NULL CHECK(expected_version>=0),
 parent INTEGER CHECK(parent>=0),
 state TEXT NOT NULL CHECK(state IN ('pending','completed')),
 result_sequence INTEGER CHECK(result_sequence>=0),
 result_version INTEGER CHECK(result_version>=0),
 changed INTEGER CHECK(changed IN (0,1)),
 PRIMARY KEY(workspace,key),
 UNIQUE(workspace,key,state),
 CHECK((state='pending' AND result_sequence IS NULL AND result_version IS NULL AND changed IS NULL)
 OR (state='completed' AND result_sequence IS NOT NULL AND result_version IS NOT NULL AND changed IS NOT NULL)),
 FOREIGN KEY(workspace,parent) REFERENCES capture(workspace,sequence),
 FOREIGN KEY(workspace,result_sequence) REFERENCES capture(workspace,sequence) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(workspace,key,snapshot) REFERENCES root(workspace,key,snapshot) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE root (
 workspace BLOB NOT NULL,
 key BLOB NOT NULL,
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 PRIMARY KEY(workspace,key),
 UNIQUE(workspace,key,snapshot),
 FOREIGN KEY(workspace,key) REFERENCES request(workspace,key) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE capture (
 workspace BLOB NOT NULL REFERENCES workspace(id),
 sequence INTEGER NOT NULL CHECK(sequence BETWEEN 0 AND 9223372036854775806),
 parent INTEGER CHECK(parent>=0 AND parent<sequence),
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 request_key BLOB NOT NULL,
 request_state TEXT NOT NULL DEFAULT 'completed' CHECK(request_state='completed'),
 PRIMARY KEY(workspace,sequence),
 UNIQUE(workspace,request_key),
 FOREIGN KEY(workspace,parent) REFERENCES capture(workspace,sequence),
 FOREIGN KEY(workspace,request_key,request_state) REFERENCES request(workspace,key,state) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TRIGGER repository_update BEFORE UPDATE ON repository BEGIN SELECT RAISE(ABORT,'immutable repository'); END;
CREATE TRIGGER repository_delete BEFORE DELETE ON repository BEGIN SELECT RAISE(ABORT,'retained repository'); END;
CREATE TRIGGER workspace_insert BEFORE INSERT ON workspace
 WHEN NEW.cursor IS NOT NULL OR NEW.next_seq!=0 OR NEW.version!=0
 BEGIN SELECT RAISE(ABORT,'initial workspace'); END;
CREATE TRIGGER workspace_update BEFORE UPDATE ON workspace
 WHEN NEW.id IS NOT OLD.id OR NEW.version!=OLD.version+1 OR NEW.next_seq!=OLD.next_seq+1
 OR NEW.cursor IS NOT OLD.next_seq
 OR NOT EXISTS(SELECT 1 FROM capture c JOIN request r ON r.workspace=c.workspace AND r.key=c.request_key
 WHERE c.workspace=OLD.id AND c.sequence=OLD.next_seq AND c.parent IS OLD.cursor
 AND r.state='pending' AND r.expected_version=OLD.version)
 BEGIN SELECT RAISE(ABORT,'capture cursor transition'); END;
CREATE TRIGGER workspace_delete BEFORE DELETE ON workspace BEGIN SELECT RAISE(ABORT,'retained workspace'); END;
CREATE TRIGGER request_insert BEFORE INSERT ON request
 WHEN NEW.state!='pending' OR NOT EXISTS(SELECT 1 FROM workspace w WHERE w.id=NEW.workspace
 AND w.version=NEW.expected_version AND w.cursor IS NEW.parent)
 BEGIN SELECT RAISE(ABORT,'pending request CAS'); END;
CREATE TRIGGER request_update BEFORE UPDATE ON request
 WHEN OLD.state!='pending' OR NEW.state!='completed'
 OR NEW.workspace IS NOT OLD.workspace OR NEW.key IS NOT OLD.key
 OR NEW.arguments IS NOT OLD.arguments OR NEW.snapshot IS NOT OLD.snapshot
 OR NEW.expected_version IS NOT OLD.expected_version OR NEW.parent IS NOT OLD.parent
 OR NOT EXISTS(SELECT 1 FROM workspace w JOIN capture c ON c.workspace=w.id AND c.sequence=NEW.result_sequence
 WHERE w.id=NEW.workspace AND c.snapshot=NEW.snapshot AND w.cursor=NEW.result_sequence
 AND w.version=NEW.result_version AND
 ((NEW.changed=1 AND c.request_key=NEW.key AND c.parent IS NEW.parent AND NEW.result_version=NEW.expected_version+1)
 OR (NEW.changed=0 AND c.sequence=NEW.parent AND NEW.result_version=NEW.expected_version)))
 BEGIN SELECT RAISE(ABORT,'completion transition'); END;
CREATE TRIGGER request_delete BEFORE DELETE ON request BEGIN SELECT RAISE(ABORT,'retained request'); END;
CREATE TRIGGER root_update BEFORE UPDATE ON root BEGIN SELECT RAISE(ABORT,'immutable root'); END;
CREATE TRIGGER root_delete BEFORE DELETE ON root BEGIN SELECT RAISE(ABORT,'retained root'); END;
CREATE TRIGGER capture_insert BEFORE INSERT ON capture
 WHEN NOT EXISTS(SELECT 1 FROM workspace w JOIN request r ON r.workspace=w.id
 WHERE w.id=NEW.workspace AND r.key=NEW.request_key AND r.state='pending'
 AND w.cursor IS NEW.parent AND w.next_seq=NEW.sequence AND w.version=r.expected_version
 AND r.parent IS NEW.parent AND r.snapshot=NEW.snapshot)
 BEGIN SELECT RAISE(ABORT,'capture allocation'); END;
CREATE TRIGGER capture_update BEFORE UPDATE ON capture BEGIN SELECT RAISE(ABORT,'immutable capture'); END;
CREATE TRIGGER capture_delete BEFORE DELETE ON capture BEGIN SELECT RAISE(ABORT,'retained capture'); END;
```
