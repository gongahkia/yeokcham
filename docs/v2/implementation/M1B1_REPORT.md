# M1b.1 implementation and qualification report

Date: 2026-11-21, Singapore.

**Contract gate: QUALIFIED_FOR_M1B1_IMPLEMENTATION. M1b.1 verdict: PASS
within the restricted experimental runtime and fault profile.**

The implementation persists independently verified snapshots and private
history. The final checks exercise SQLite sync and write errors, a busy COMMIT,
and process kills inside COMMIT. The verdict covers the exact local profile
in the storage contract. Hardware failure and broader runtime qualification
remain open. No later tranche began.

## 1. Source, host and preservation

Initial HEAD `c3913af19bd1e8d99cb12b217b9322e674c834ae`, clean
`main...origin/main`, no staged/unstaged/nonignored untracked files. Final HEAD
`1d75d7f1d6c666ea1474ceca4e33363068d4f444`. External commits `f8e816f` and `1d75d7f` incorporated intermediate
versions during execution; their history and externally staged work were preserved.
This agent issued no commit, push, staging, reset, cleanup or branch mutation.

A SHA-256/native-mode inventory covers **552 pre-existing tracked/nonignored
untracked files**. All retain their initial contents/modes, including all original
Python source/tests, goldens, RFCs/M0/M1a reports, OCaml/C, README and ledgers.
Only the six task paths in section8 are additional relative to that inventory.
Ignored data was not recursively inventoried. New caches/builds were external;
no live `.yeokcham`/`.yeokcham-v2` store or ordinary working file was opened for
writing, no service registered and no default executable installed.

Host: Linux7.2.15-1-omarchy x86_64/glibc2.44, CPython3.14.8, linked SQLite3.54.0.
`/tmp` is tmpfs: it is used only for logs/builds/tools, not storage durability
qualification. All storage fixtures are in a disposable external **Btrfs** directory:
`/home/gongahkia/yeokcham-m1b1-fixtures-yulxdpqq/`.
No global dependency or manifest change. Existing pytest9.2.0, Hypothesis6.170.17,
Ruff0.17.6, mypy2.4.1/build1.6.1 tools were reused; the declared setuptools backend
and wheel installation used temporary environments only. OCaml/Dune/opam are
unavailable. No original full CI or fresh OCaml/native application suite ran.

The [storage contract](M1B1_STORAGE_CONTRACT.md) records exact source/build/options/
loaded-binary hashes and the local allowlist. Vendor sqlite3.54.0-1 inventory:
31 files/0 alterations; package metadata says checksum validated. That is not an
upstream signature/security audit. Its source ID ends in alt1, unlike the upstream
release identity; no exact upstream equivalence is claimed. The newer3.54.1 release
was researched, not installed. Other kernels/devices/providers/platforms are not
qualified by a successful local run. Runtime guards do not attest power-loss behavior.

Final observed Git status:

```text
## main...origin/main
?? docs/v2/implementation/M1B1_REPORT.md
```

## 2. Contract and qualification findings

Read/consulted current M1a reports, D2/D3/D4, M0 safety/vector register and retained
content/admission references; inspected actual Python package/tests, retained
content/hash/schema interfaces and D3 illustrative SQL/D4 corrections. The new
schema is independently exercised rather than copied as production-ready D3 DDL.

| Gate | Closure within M1b.1 | Deferred obligation |
| --- | --- | --- |
| O04 | Exact five-table STRICT schema,13 triggers, cyclic deferred root/completion FKs, immutable captures/roots/requests, workspace CAS and checked allocation | No plans/actions/public admissions; later schema expansion needs its own freeze |
| O05 | Exact capture-request digest/control columns and stored result identity | Native/private plans/actions/observations absent |
| O07 | All roots/history/request identities retained; no deletion/eviction/collector | Pending incomplete roots are a reclamation barrier; abandonment/quarantine/purge not defined here |
| O08 | Exact tested Linux/CPython/SQLite/source/options/binary profile, Btrfs fsync/link/flock probes, explicit unix VFS and metadata-admission protocol | Additional VFS failure points and broader provider, native, hardware and platform qualification |

Independent pre-production probes passed explicit BEGIN/COMMIT/ROLLBACK,
Connection.commit() no-op inside explicit BEGIN, STRICT/FKs, root/completion
constraints, five direct-SQL negatives, unchanged completion, file/directory fsync,
create-only hardlink collision and cross-process shared/exclusive flock. A separate
SQLite canary survived kills before/after COMMIT with integrity checks. These
finite checks qualified the initial restricted profile, not universal correctness.

### Reopened gate: descriptor-close locking hazard

A later independent probe showed a real safety counterexample: SQLite held BEGIN
IMMEDIATE; a raw open/read/close of that same database then let another process
enter BEGIN IMMEDIATE. Observed child exits changed from Busy5 to admitted0.
This is the documented [POSIX descriptor-close hazard](https://sqlite.org/howtocorrupt.html#posix_advisory_locks_canceled_by_a_separate_thread_doing_close),
not a speculative lock optimization or a complete database-corruption experiment.

Production work paused for independent protocol requalification and RED regressions.
The first metadata EX-only guard restored exclusion but over-serialized an ordinary
reader: the complete suite reported425 passed/1 failed. Its original expectation
was retained. The final independently qualified rule is:

```text
workspace EX, when needed
  -> publication/GC SH
    -> metadata-access EX for raw header admission and its SQLite validation
       OR metadata-access SH for ordinary SQLite-only connection lifetimes
      -> short SQLite BEGIN IMMEDIATE / COMMIT / ROLLBACK
```

An ordinary connection uses stat binding plus SQLite queries, with no raw DB file
open/read/close. Raw admission requires EX and no managed SQLite connection. SQLite
closes before its metadata lease releases. SH readers retain old committed visibility;
new Store admission may return bounded Busy while another connection is active.
All same-process connections must use the API/lease; independent inspectors run
in separate processes. No fork with an open Store/operation, no DB/store rename,
no hostile same-UID edits or mixed VFS/provider access is supported. The final
same-process threaded/external-writer regression passes for both read and reopen.

This adds one coordination file, not another authority. Objects stream outside
metadata leases/SQL. SQLite still serializes writers; no global repository generation
or mutable head file exists. Startup integrity scans can delay metadata admission;
this prototype does not claim quiet-operation throughput or strict fairness.

## 3. Exact schema and authoritative ownership

The full startup DDL and private encodings are frozen in
[M1B1_STORAGE_CONTRACT.md](M1B1_STORAGE_CONTRACT.md) and implemented verbatim in
[private_schema.py](../../../python/src/yeokcham/private_schema.py).
DDL SHA256: `db11c234106130149cc00d6edfa4161d74f2261fccca31b66a0d58a75bd91b43`.
Application ID0x594b5031; user_version1; private FORMAT marker binds exact RepoId32.
Unknown existing directories, header/application/version/schema or identity refuse;
no implicit upgrade or initialize-over. An interrupted initializer leaves owned
partial data, never an acknowledged store; incomplete markers refuse on reopen.

| Table | Authoritative responsibility |
| --- | --- |
| repository | Exactly one immutable repository identity/format binding |
| workspace | WorkspaceId16, one cursor, next_seq/version; first empty, exact append transition only |
| request | Workspace-scoped key1..128, immutable arguments/snapshot/expected parent+version, pending or immutable completed result |
| root | Exactly one retained snapshot intent per request; bidirectional deferred FK enforces owner and matching snapshot |
| capture | Immutable `(workspace,sequence)`, exact parent/current snapshot/producer request; deferred FK requires completed producer |

Request completion validates cursor/version/result/snapshot linkage. A new capture
cannot commit while its producer remains pending. Roots/request/captures cannot
be deleted; no raw object-inventory Boolean proves physical availability. Adapter
verification/sync under the publication gate establishes capture eligibility before
COMMIT. The database is private authority; CAS alone cannot reconstruct successful
captures/cursors/requests after DB loss.

This deliberately linear slice does not navigate or create history branches. It
retains every occurrence and every workspace; A->B->A has two distinct A occurrences.
Only equality with the *current* snapshot suppresses a new occurrence. Initial
sequence0 yields version1. At next_seq/version2^63-1 allocation refuses before
overflow; maximum allocated sequence is2^63-2. This local restriction does not
change the general M1a CaptureId type. No native reservation/null counter semantics
are guessed. Helpers/schema boundary tests are not2^63 live appends.

## 4. APIs, objects, roots and retries

`PrivateStore.initialize/open/close`, `register_workspace`, `workspace`,
`put_object/put_stream/read_object`, `append_capture`, paginated `history`,
`read_snapshot`, `lookup_request`, `verify_roots`. Typed immutable outputs are
WorkspaceState, Capture, CaptureResult, RequestInfo and RootReport. Inputs use
M1a nominal IDs; no terminal scraping, scanner, orchestrator or CLI was added.
Constructing a Store cannot bypass admission. Store lifetime/close is caller-owned;
connections are fresh and explicitly closed. Registration is idempotent for its
exact supplied WorkspaceId; capture retries use explicit request keys.

`append_capture` consumes a preconstructed SnapshotId/immutable resolver and exact
workspace expectation. It independently verifies/syncs the full incoming closure,
then verifies the canonical stored closure again with M1a max_file_bytes0. Large
file contents remain chunked; no whole-file flattening is needed. Resolver-internal
allocation is caller-owned, and individual object buffering retains the M1a128MiB
ceiling; full worst-case RSS is not certified. Strict oversized inline admission
remains unchanged; this store has no legacy import/normalization mode.

Object layout is flat `objects/<exact hex ID>` with same-directory exclusive
.stage-random files, bounded streamed writes, canonical envelope/CBOR/local-schema
checks, file fsync, create-only hardlink, directory fsync and own-inode temp unlink/
sync. Existing bytes must match exactly and are reverified/resynced, not overwritten.
Closure eligibility additionally checks dependencies, kinds, hashes, full contents
and canonical chunk cuts through the unchanged M1a verifier. Standalone put is an
orphan publication, not a capture/retention/backup acknowledgement. Reopen does
not clean old stages. Missing files are Unavailable; checksum/ID and framing/schema
errors retain their precise M1a classifications. Committed corruption is not empty data.

A pending request/root commits before object production, freezing intent rather
than asserting availability. No captured history exists until objects are durable
and one final transaction inserts capture, advances cursor/counter and completes
the request. The producer request owns the captured root forever. Dependencies are
protected by its complete recursive closure. Incomplete pending roots require a
future collector to stop reclamation or use a separately qualified inventory/
abandonment protocol. There is no collector now, so partial/orphan bytes remain.

Digest: SHA256(`b"yeokcham/private-request/m1b1\\0"` plus canonical CBOR
`[1,workspace.raw,expected_version,parent_or_null,snapshot.raw]`). Scope is one
repository/workspace/action=capture/key. Same arguments replay the original result
and check its historical closure; changed arguments refuse RequestMismatch even
if the workspace advanced. Pending replay resumes exact intent or returns Stale;
it never substitutes a newer cursor or silently reuses a sequence. Lookup exposes
original pending/completed identity without claiming content availability.

COMMIT uncertainty returns UncertainCommit. Fresh retry/lookup resolves the original
key before deciding whether to continue; completed results do not allocate again.
Rollback cleanup cannot replace the primary uncertainty classification. Interrupted
transactions keep old cursor/history plus already committed pending ownership.
No ordinary working files are touched or rolled back. RootReport is diagnostic
counts for copied owner rows, not a durable verification token or backup manifest;
concurrent roots may arrive after that observation. Audits/history have explicit
10000-owner/row bounds; no unbounded whole-history serialization is introduced.

## 5. Verification and TDD

| Stage | Actual result |
| --- | --- |
| Initial RED |6 failed/49 setup errors,55 collected, missing production storage module; environment/package and fixtures otherwise present |
| First GREEN |55 passed,33.07s |
| Admission RED |2 failed: direct constructor bypass and invalid timeout created a store; fixed, refactor57 passed26.46s |
| Extended concurrency/FULL |6 focused passed6.56s: stalled stream, old reader state, fsync errors, actual SQLite FULL, deferred completion |
| Ownership RED |1 failed: exact schema alone missed an invalid owner FK on reopen |
| Cleanup/durability RED |2 failed: rollback error masked UncertainCommit; readiness marker not resynced |
| GREEN |68 passed34.47s |
| Vector fixture error |New test used nonexistent JSON key root; corrected to frozen content_object, without changing any expected bytes. Not meaningful RED |
| Broad verification before gate repair |422 passed108.21s; this did not establish raw descriptor locking safety |
| FD lifetime RED |2 failed: initialize-root and reopen-parent open faults leaked descriptors; corrected |
| Lock/VFS RED |2 failed: raw close broke another connection's kernel exclusion; file VFS not explicit |
| Failed refactor |A temporary indentation/SyntaxError caused typing/selected checks to fail; corrected, not counted as meaningful RED |
| EX-only verification |425 passed/1 failed108.51s, ordinary reader unnecessarily Busy |
| Shared-lease RED/qualification |1 failed/1 passed strengthened read/reopen regression; independent SH/EX probe then qualified before implementation |
| Targeted GREEN |16 passed16.62s, including original reader expectation, writer exclusion and12 kill boundaries |
| Final full VERIFY | 429 passed, 0 failures, 0 errors, 0 skips, 127.880s in JUnit |

Final generated examples: **484 passing/0 failing**, including unchanged469 earlier
examples and15 fixed-seed private-history sequences.15 generation retries/invalid
candidates in the final run are not skipped pytest tests. Finite properties do
not prove universal correctness. All353 earlier tests are unchanged and green.

Ruff lint/format pass17 Python files; strict mypy passes11 source modules. Source
and wheel distributions build. Installed-wheel `python -I` outside checkout passes
initialize/register/append/replay/read/reopen/root verification on Btrfs, with no
executable entry point. Installed source bytes match tested source. No runtime
dependency or original manifest change. All final verification commands exit0.

Retained compatibility: all original M1a vectors/tests remain green; the new store
admits/reads **60 canonical positive objects** from14 qualified file closures and
the mixed snapshot, byte-for-byte. Mixed raw-ff name, executable mode, symlink
bytes and empty directory survive through storage/read verification. This does
not claim all103 corpus envelopes are canonical admission positives; the corpus
also contains deliberately invalid/legacy representations, covered by old tests.

## 6. Concurrency, interruption and fault coverage

| Case | Evidence / exact limitation |
| --- | --- |
| Three workspaces/processes |All progress; distinct CaptureIds, same snapshot; exactly3 shared canonical objects (content/tree/snapshot) |
| Two writers, one workspace |One exact CAS winner; other Stale; no overwritten cursor |
| Concurrent duplicate key |One capture, same historical result |
| Long object producer |Other two workspaces commit while first is paused; first has pending/incomplete root, no capture; resumes normally |
| Ordinary reader during write |Old committed metadata visible, never partial capture/cursor/root |
| Same-process threads + third writer |Ordinary read preserves kernel exclusion; separate Store admission returns bounded Busy while a connection exists |
| SQLite BUSY |Separate process holds BEGIN; bounded explicit Busy. Earlier same-process raw test was replaced because it violated the newly identified descriptor protocol |
| Object production |A metadata writer lease/transaction can be acquired inside resolver; no SQL connection held while producing bytes |
|12 subprocess SIGKILL boundaries |Before/after pending COMMIT; temp create/write/file sync/link/dir sync; objects durable; capture insert/cursor update; before/after capture COMMIT. Independent SQL integrity/FK/closure/cursor/root audit then exact retry |
| Lost response / uncertain result |Committed callback error returns UncertainCommit; retry old expectation returns same CaptureId |
| Actual SQLite FULL |max_page_count yields real SQLITE_FULL, old cursor retained; not filesystem ENOSPC or real VFS IOERR |
| Filesystem EIO/ENOSPC adapters |Injected file/directory fsync and stage/commit-event errors: no new capture, retry exact key works. Simulated errors, not disk/device fault certification |
| Rollback failure |Adapter-level fake connection verifies primary uncertainty is retained; not real SQLite IOERR |
| Missing/corrupt committed bytes |Read/audit refuses; historical capture and owners retained, no empty-file fallback |
| Unknown app/schema/identity |Refusal without changing database bytes; no upgrade or old-store write |
| FD open failures |Explicit descriptor inventory proves no leaks for the tested initializer/admission failures |

The twelve suite points use actual SIGKILL at application boundaries. The
separate syscall-interposition probes below exercise SQLite's COMMIT itself.

Supplemental external tests (not extra collected pytest cases):

- **Three application-first reopen cases:** after request-before-COMMIT,
  capture-before-COMMIT and capture-after-COMMIT kills, the application opens before
  the independent inspector. Counts before retry are respectively0/0/1 captures,
 0/1/1 roots; exact retry always returns capture0, without double allocation.
- **One real hot-journal recovery:** cache_size1/cache_spillON forces page spill;
  SIGKILL after cursor update leaves journal magic d9d505f920a163d7. Independent
  read-only SQLite refuses SQLITE_READONLY_ROLLBACK, proving recovery is needed.
  Application reopen restores old cursor/pending root and retries exact capture0.
  This is process-crash recovery evidence, not physical power-loss qualification.

- **Seven injected SQLite syscall boundaries.** A test-only external shim
  affects a child and one exact disposable path. SQLite returned
  SQLITE_IOERR_FSYNC (1034) when either the rollback journal or database sync
  returned EIO. A database write returning ENOSPC yielded SQLITE_FULL (13).
  All three surfaced as UncertainCommit. Recovery found the old capture and
  the new pending root. Kills at journal sync, database sync, and immediately
  before journal unlink recovered the same state. A kill immediately after
  successful unlink left both captures committed. Every retry returned exact
  sequence1 with two completed roots and no duplicate occurrence. This also
  exercises a committed result discovered without a response.
- **Busy COMMIT.** A separate read transaction observed cursor0 and held its
  SQLite read lock across COMMIT. SQLite returned SQLITE_BUSY (5) after the
  writer's bounded wait. The API returned UncertainCommit and released the
  transaction. Reopen found the pending root and unchanged cursor. Retry
  produced sequence1. Measured child attempt including setup was 0.212s.
- **Reader protection.** A separate process attempting the exclusive publication
  lease received Busy after root lookup while the reader was paused in object
  access. It acquired the lease after the reader completed.

The injected syscalls exercise SQLite error handling on the installed VFS.
Actual device errors and physical power loss were not tested. Also unqualified
are additional VFS failure sites such as close, rollback sync and directory
sync inside SQLite, alternate providers and filesystems, adversarial store
mutation by the same UID, destructive collection, and consistent backup.
The original copy-out fixture failure remains undiagnosed and was not rerun.
It remains an M2 and parity issue.

## 7. Risks and next tranche

M1b.1 is a tested **private storage subset**, not general rollout approval.
The vendor/patch-specific allowlist intentionally rejects other runtime builds;
provider security/provenance review remains narrower than a full production matrix.
All requests/roots/history persist, including unchanged attempts and stale pending
intents: metadata grows, and incomplete pins can block future GC indefinitely.
Startup integrity scans, repeated full closure verification and fixed audit caps
are deliberate conservative costs. No throughput/latency superiority is claimed.
The package name/metadata remain from the content milestone; no replacement CLI
or ordinary editing workflow is delivered by this tranche.

Recommend **M1b.2 restricted durability hardening**: make the SQLite syscall fault harness repeatable across approved providers,
extend rollback and directory-sync coverage, and stress lease contention.
Freeze pending-root recovery and abandonment semantics before any reclamation. Keep GC/eviction and backup off until their own ownership,
quarantine/reachability/consistent-destination protocols qualify. Broader providers
need new allowlist/capability/fault evidence, not a version-number bypass.

M2 additionally needs native capture/observation and safe apply/recovery controls,
exact private plan/action/claim formats and the unresolved copy-out discriminator.
No native journal, workspace navigation or ordinary-file replacement can consume
an opaque placeholder in this schema. Full public composition/private catch-up,
signed publication, authority/review and exchange remain separately owned gates;
they are not artificial prerequisites for this isolated private-history slice.
No later tranche is implemented or automatically authorized.

## 8. Files and reproducible commands

Added relative to initial inventory:

- [private_store.py](../../../python/src/yeokcham/private_store.py): one typed
  application owner for admission, SQL transactions, requests/captures/cursors,
  root diagnostics and snapshot verification.
- [object_files.py](../../../python/src/yeokcham/object_files.py): qualified runtime,
  private directory bindings, process leases and create-only immutable IO.
- [private_schema.py](../../../python/src/yeokcham/private_schema.py): exact readable
  DDL and schema comparison, no ORM or future-table skeletons.
- [test_private_store.py](../../../python/tests/test_private_store.py):76 collected
  storage/fault/concurrency/vector/property tests and subprocess worker.
- [M1B1_STORAGE_CONTRACT.md](M1B1_STORAGE_CONTRACT.md) and this report.

No original production/test/manifest/reference file changed. Coordination files
are not a second state tree, and no global mutable history cache/registry is used.

Run from the checkout on the qualified platform. Place both the new
environment and fixture base outside the repository. The fixture base must
reside on Btrfs. Set these example paths to your disposable Btrfs location.

```sh
test_root=/absolute/path/to/disposable/btrfs-directory
python3 -m venv "$test_root/env"
"$test_root/env/bin/python" -m pip install './python[test,dev]'
PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
  HYPOTHESIS_STORAGE_DIRECTORY="$test_root/hypothesis" \
  "$test_root/env/bin/python" -m pytest python/tests -p no:cacheprovider \
  --basetemp="$test_root/tests" --hypothesis-show-statistics \
  --junitxml="$test_root/results.xml"
"$test_root/env/bin/ruff" check --no-cache python
"$test_root/env/bin/ruff" format --no-cache --check python
"$test_root/env/bin/mypy" --config-file python/pyproject.toml \
  --cache-dir "$test_root/mypy" python/src
cp -R python "$test_root/build-source"
"$test_root/env/bin/python" -m build "$test_root/build-source" --outdir "$test_root/dist"
python3 -B tools/check_doc_links.py
git diff --check
```

For an installed-wheel smoke test, create a second external venv and install
the wheel with `pip install --no-deps`. Run the smoke script described below
with that venv's Python, `-I`, and a nonexistent destination on Btrfs.

The report's fault harness requires the same runtime and a C compiler with
the system dynamic loader headers. Save the named source blocks together in
an external scratch directory and compile the shim there. Run while your
current directory is the checkout. The runner passes the shim only to its
disposable fixture children.

```sh
scratch=/absolute/path/to/external/scratch
cc -Wall -Wextra -Werror -shared -fPIC "$scratch/commit_fault.c" -ldl -o "$scratch/commit_fault.so"
PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
  "$test_root/env/bin/python" -B "$scratch/commit_fault.py" "$test_root"
PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
  "$test_root/env/bin/python" -B "$scratch/commit_busy.py" "$test_root"
PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
  "$test_root/env/bin/python" -B "$scratch/reader_gate.py" "$test_root"
"$test_root/wheel-env/bin/python" -I "$scratch/wheel_smoke.py" "$test_root/wheel-store"
```

The actual tool/log directory is `/tmp/yeokcham-m1b1-_z7uzy9o/`. The final
`verified.log/xml`, package artifacts, runtime fingerprints, application-first and
hot-journal traces are supplemental evidence. The following independent scripts
are reproduced for review/replay; they do not import production normalization or
generate normative expected content bytes. Create fresh external probe directories;
never run them against a live store. Their placeholder SQL snapshot bytes test
constraints only, not content eligibility. Real eligibility is covered by API tests.

### `commit_fault.c`

```c
/* Test-only interposition, only within a child and on its exact fixture DB. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fired;

static int selected_fd(int fd) {
    char fd_path[64], actual[4096];
    const char *target = getenv("M1B1_FAULT_FILE");
    if (!target || fired) return 0;
    snprintf(fd_path, sizeof fd_path, "/proc/self/fd/%d", fd);
    ssize_t length = readlink(fd_path, actual, sizeof actual - 1);
    if (length < 0) return 0;
    actual[length] = 0;
    return strcmp(actual, target) == 0;
}

static void announce(const char *where) {
    fired = 1;
    (void)write(STDERR_FILENO, where, strlen(where));
}

static int intercept_sync(int fd) {
    const char *mode = getenv("M1B1_FAULT_MODE");
    if (!mode || !selected_fd(fd)) return 0;
    if (strcmp(mode, "ioerr-sync") == 0) {
        announce("injected IOERR at SQLite sync\n");
        errno = EIO;
        return 1;
    }
    if (strcmp(mode, "kill-sync") == 0) {
        announce("injected SIGKILL at SQLite sync\n");
        kill(getpid(), SIGKILL);
    }
    return 0;
}

int fsync(int fd) {
    int (*real_fsync)(int) = dlsym(RTLD_NEXT, "fsync");
    if (intercept_sync(fd)) return -1;
    return real_fsync(fd);
}

int fdatasync(int fd) {
    int (*real_fdatasync)(int) = dlsym(RTLD_NEXT, "fdatasync");
    if (intercept_sync(fd)) return -1;
    return real_fdatasync(fd);
}

int unlink(const char *path) {
    int (*real_unlink)(const char *) = dlsym(RTLD_NEXT, "unlink");
    const char *target = getenv("M1B1_FAULT_FILE");
    const char *mode = getenv("M1B1_FAULT_MODE");
    if (fired || !target || !mode || strcmp(path, target) != 0)
        return real_unlink(path);
    if (strcmp(mode, "kill-before-unlink") == 0) {
        announce("injected SIGKILL before SQLite journal unlink\n");
        kill(getpid(), SIGKILL);
    }
    int result = real_unlink(path);
    if (result == 0 && strcmp(mode, "kill-after-unlink") == 0) {
        announce("injected SIGKILL after SQLite journal unlink\n");
        kill(getpid(), SIGKILL);
    }
    return result;
}

ssize_t pwrite64(int fd, const void *buffer, size_t size, off64_t offset) {
    ssize_t (*real_pwrite64)(int, const void *, size_t, off64_t) =
        dlsym(RTLD_NEXT, "pwrite64");
    const char *mode = getenv("M1B1_FAULT_MODE");
    if (mode && strcmp(mode, "full-write") == 0 && selected_fd(fd)) {
        announce("injected ENOSPC at SQLite write\n");
        errno = ENOSPC;
        return -1;
    }
    return real_pwrite64(fd, buffer, size, offset);
}
```

### `commit_fault.py`

```python
"""Independent child fault, then reopen and inspect exact roots and result."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

scratch = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd() / "python/tests"))
import test_private_store as t

store_api = t.api()
if len(sys.argv) == 5:
    _, _, name, mode, target = sys.argv
    with store_api.PrivateStore.open(Path(name), t.REPO) as store:
        def arm(event):
            if event == "capture-before-commit":
                os.environ["M1B1_FAULT_FILE"] = target
                os.environ["M1B1_FAULT_MODE"] = mode
        store.fault = arm
        try:
            t.append(store, key=b"next", data=b"next")
        except store_api.StoreError as error:
            cause = error.__cause__
            print(json.dumps({
                "result": error.code,
                "sqlite_errorname": getattr(cause, "sqlite_errorname", None),
                "sqlite_errorcode": getattr(cause, "sqlite_errorcode", None),
            }))
            assert error.code == "UncertainCommit"
            assert getattr(cause, "sqlite_errorcode", 0) & 255 == (13 if mode == "full-write" else 10)
            sys.exit(19)
    sys.exit("fault did not fire")

fixtures = Path(sys.argv[1]).resolve()
cases = (
    ("ioerr-journal", "ioerr-sync", "-journal", False),
    ("ioerr-db", "ioerr-sync", "", False),
    ("full-db-write", "full-write", "", False),
    ("kill-journal-sync", "kill-sync", "-journal", False),
    ("kill-db-sync", "kill-sync", "", False),
    ("kill-before-unlink", "kill-before-unlink", "-journal", False),
    ("kill-after-unlink", "kill-after-unlink", "-journal", True),
)
for label, mode, suffix, committed in cases:
    path = Path(tempfile.mkdtemp(prefix=label + "-", dir=fixtures)) / "store"
    with store_api.PrivateStore.initialize(path, t.REPO) as store:
        store.register_workspace(t.WS)
        first = t.append(store)
        expected = store.workspace(t.WS)
    child = subprocess.run(
        [sys.executable, "-B", __file__, "child", str(path), mode,
         str(path / ("metadata.sqlite3" + suffix))],
        env={**os.environ, "LD_PRELOAD": str(scratch / "commit_fault.so")},
        text=True, capture_output=True, timeout=15, check=False,
    )
    assert child.returncode == (19 if (mode.startswith("ioerr") or mode == "full-write") else -signal.SIGKILL), (label, child)
    assert "injected" in child.stderr, (label, child)
    with store_api.PrivateStore.open(path, t.REPO) as store:
        rows, requests, roots, workspaces = t.inspect(path)
        assert len(rows) == 1 + committed, (label, rows)
        assert roots == 2
        assert requests == ({"completed": 2} if committed else {"completed": 1, "pending": 1})
        assert workspaces[0][1] == int(committed)
        assert rows[0][1] == first.capture.sequence
        next_capture = t.append(store, key=b"next", data=b"next", expected=expected)
        assert next_capture.capture.sequence == 1
        assert store.verify_roots().completed == 2
        assert len(t.inspect(path)[0]) == 2
    print(json.dumps({
        "case": label, "child_return": child.returncode,
        "boundary": child.stderr.strip(), "fault": json.loads(child.stdout) if child.stdout else None,
        "captures_before_retry": len(rows), "replayed_sequence": next_capture.capture.sequence,
    }), flush=True)
```

### `commit_busy.py`

```python
"""Hold a distinct SQLite reader across a capture COMMIT on a disposable store."""
import json
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path.cwd() / "python/tests"))
import test_private_store as t

api = t.api()
if len(sys.argv) == 3:
    with api.PrivateStore.open(Path(sys.argv[2]), t.REPO, timeout=0.15) as store:
        def pause(event):
            if event == "capture-before-commit":
                print("ready", flush=True)
                assert sys.stdin.readline() == "go\n"
        store.fault = pause
        start = time.monotonic()
        try:
            t.append(store, key=b"next", data=b"next")
        except api.StoreError as error:
            code = getattr(error.__cause__, "sqlite_errorcode", None)
            assert error.code == "UncertainCommit" and code == sqlite3.SQLITE_BUSY
            print(json.dumps({"result": error.code, "code": code, "elapsed": time.monotonic()-start}))
            sys.exit(19)
    sys.exit("expected COMMIT BUSY")

path = Path(tempfile.mkdtemp(prefix="commit-busy-", dir=sys.argv[1])) / "store"
with api.PrivateStore.initialize(path, t.REPO) as store:
    store.register_workspace(t.WS)
    first = t.append(store)
    expected = store.workspace(t.WS)
child = subprocess.Popen(
    [sys.executable, "-B", __file__, "child", str(path)],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
try:
    assert select.select([child.stdout], [], [], 10)[0]
    assert child.stdout.readline() == "ready\n"
    uri = (path / "metadata.sqlite3").as_uri() + "?mode=ro&vfs=unix"
    reader = sqlite3.connect(uri, autocommit=True, uri=True)
    try:
        reader.execute("BEGIN")
        assert reader.execute("SELECT count(*) FROM capture").fetchone() == (1,)
        rest, error = child.communicate("go\n", timeout=10)
        assert child.returncode == 19, (child.returncode, rest, error)
        assert reader.execute("SELECT cursor FROM workspace").fetchone() == (0,)
        reader.execute("ROLLBACK")
    finally:
        reader.close()
finally:
    if child.poll() is None:
        child.kill()
        child.communicate(timeout=5)
with api.PrivateStore.open(path, t.REPO) as store:
    rows, requests, roots, _ = t.inspect(path)
    assert len(rows) == 1 and requests == {"completed": 1, "pending": 1} and roots == 2
    assert store.workspace(t.WS).cursor == first.capture
    result = t.append(store, key=b"next", data=b"next", expected=expected)
    assert result.capture.sequence == 1
    assert store.verify_roots().completed == 2
print(json.dumps({"commit_busy": json.loads(rest), "old_cursor_preserved": True, "replayed_sequence": result.capture.sequence}))
```

### `reader_gate.py`

```python
"""Assert an exclusive publication lease cannot interleave a rooted read."""
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path.cwd() / "python/tests"))
import test_private_store as t

api = t.api()
if len(sys.argv) == 3:
    with api.PrivateStore.open(Path(sys.argv[2]), t.REPO) as store:
        capture = store.workspace(t.WS).cursor
        assert capture is not None
        read = store.files.read
        stages = []
        def paused(identity):
            if not stages:
                stages.append(identity)
                print("ready", flush=True)
                assert sys.stdin.readline() == "go\n"
            return read(identity)
        store.files.read = paused
        assert store.read_snapshot(capture, max_file_bytes=3)[(b"file",)].data == b"one"
    sys.exit(0)

path = Path(tempfile.mkdtemp(prefix="reader-gate-", dir=sys.argv[1])) / "store"
with api.PrivateStore.initialize(path, t.REPO) as store:
    store.register_workspace(t.WS)
    t.append(store)
child = subprocess.Popen(
    [sys.executable, "-B", __file__, "child", str(path)],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
locker = """import fcntl,os,sys
with open(sys.argv[1], 'rb') as file:
    try: fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit(7)
"""
def probe():
    return subprocess.run([sys.executable, "-B", "-c", locker, str(path/"locks/publication")], check=False, timeout=5).returncode
try:
    assert select.select([child.stdout], [], [], 10)[0]
    assert child.stdout.readline() == "ready\n"
    assert probe() == 7
    stdout, stderr = child.communicate("go\n", timeout=10)
    assert child.returncode == 0, (stdout, stderr)
    assert probe() == 0
finally:
    if child.poll() is None:
        child.kill()
        child.communicate(timeout=5)
print(json.dumps({"exclusive_lease_during_read": "excluded", "after_reader_exits": "available", "destructive_collection": "not exercised"}))
```

### `wheel_smoke.py`

```python
import importlib.metadata,json,pathlib,sys
from yeokcham import codec,content
from yeokcham.identities import RepositoryId,WorkspaceId,SnapshotId,StoredObjectId,TreeId
from yeokcham.private_store import PrivateStore
objects={};cid=content.write_content([b'smoke'],objects.__setitem__)
raw=content.encode_tree([content.File(b'f',content.Mode.EXECUTABLE,cid)]);tid=codec.object_id(raw);objects[tid]=raw
raw=content.encode_snapshot(TreeId(tid.raw));snapshot=SnapshotId(codec.object_id(raw).raw);objects[StoredObjectId(snapshot.raw)]=raw
path=pathlib.Path(sys.argv[1]);repo=RepositoryId(b'r'*32);ws=WorkspaceId(b'w'*16)
with PrivateStore.initialize(path,repo) as s:
 s.register_workspace(ws);expected=s.workspace(ws)
 result=s.append_capture(ws,snapshot,objects.get,expected=expected,key=b'smoke')
 assert s.append_capture(ws,snapshot,objects.get,expected=expected,key=b'smoke')==result
 assert s.read_snapshot(result.capture,max_file_bytes=64)[(b'f',)].data==b'smoke'
with PrivateStore.open(path,repo) as s:
 assert s.workspace(ws).cursor==result.capture
 assert s.verify_roots().completed==1
assert not importlib.metadata.distribution('yeokcham-content').entry_points
import yeokcham.private_store
print(json.dumps({'module':yeokcham.private_store.__file__,'capture_sequence':result.capture.sequence,'reopen':'pass','no_executable_entry_points':True}))
```

**M1b.1 completed to the extent verified. No later tranche was authorized.**
