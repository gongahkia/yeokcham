# M1b.2 pending-root recovery and durability report

**Gate `QUALIFIED_FOR_M1B2_IMPLEMENTATION`. Verdict PASS for the restricted
M1b.1 profile and the exercised M1b.2 faults.**

A known request can now be inspected by key without invoking a resolver or
changing its capture, cursor or root. The application distinguishes SQL
authority from current object availability and eligibility to retry. A retry
reseals the store directory before relying on a recovered request. The checked
[recovery contract](M1B2_RECOVERY_CONTRACT.md) traces every publication and
COMMIT boundary. The existing [schema and format](M1B1_STORAGE_CONTRACT.md)
remain byte-for-byte unchanged.

## Recovery semantics

| SQL observation | Inspected closure | Retry behavior |
| --- | --- | --- |
| Key absent in recovered SQL | No closure inspected | Original key may start a claim after exact workspace validation. An orphan gives no authority. |
| Pending and eligible | Verified, missing, invalid or unverified | Reseal directory, verify or safely publish the original exact closure. Recheck the same intent and root inside the final transaction. |
| Pending and stale | Same four closure states | Refuse Stale. Preserve frozen key, digest, request and root. |
| Completed | Same four closure states | Reseal directory and reverify. Return the original result only with its verified closure. Retain history and roots on refusal. |
| Metadata read fails or COMMIT was uncertain | No inference from files | Return the typed failure. Resolve from fresh SQLite recovery and the original key. |

`inspect_request` returns frozen metadata, argument digest, expected workspace,
eligibility at the metadata read boundary, and the first closure refusal's
typed code. `verified` means an actual complete traversal. It does not attest
the previous fsync or a stable future observation. Missing/corrupt metadata
association raises InvalidStore rather than appearing to be a missing object.
Existing `lookup_request`, `append_capture`, `read_snapshot` and
`verify_roots` retain their return shapes.

Read inspection acquires the shared publication gate before the short
metadata read and releases SQLite and its lease before the object traversal.
Writers keep the original per-workspace EX, publication SH, metadata SH,
SQLite writer order. Exclusive metadata admission is still used for raw
header access and recovered authority checks. Open checks the exact schema,
SQLite integrity and FKs, plus cursor bounds, linear ancestry and exact
producer/completion links that FKs alone cannot express. These checks add
work proportional to history on admission. The exact digest is rederived
when looking up a key. No SQL row or schema is derived from a stage file.

A live publication syncs the same descriptor used to verify an existing
canonical name and refuses on failed sync. It removes only its own stage
when the observed inode still matches and syncs the objects directory.
Publication failure takes precedence over stage/descriptor cleanup errors.
Secondary errors are kept as exception notes. Capture completion revalidates
the pending owner and requires a one-row completion update. SQLite rollback
or close errors revealed to the adapter do not replace the primary error.
After attempting COMMIT, an error stays UncertainCommit even when SQL can
already see completed rows. No production path recycles a key or drops a root.

## Fault and concurrency evidence

The Python fault cases exercise the actual store through subprocesses. OS
adapter errors below are injected exceptions, while SIGKILL is process
termination. A separate inspector reads raw SQL rows and joins requests to
roots, runs SQLite integrity/FK checks, and decodes committed object closures.

| Cases reached | Expected and observed result |
| --- | --- |
| Before/after temp create, partial stream write, after write, file fsync, after fsync, canonical link | EIO and SIGKILL at each point left the new snapshot's canonical path absent, pending owner intact and old capture unchanged. A partial stage could survive. |
| After link, object-directory fsync, unlink, post-unlink directory fsync | EIO and SIGKILL at each point left exact canonical bytes present with no new committed capture. The old capture and pending owner matched SQL. |
| Existing canonical verification and durability re-establishment | EIO and SIGKILL at both points left the same inode and bytes. No overwrite or new capture. |
| Every object case | Original-key retry wrote sequence 1 once after inspecting the old cursor, both owner rows and original bytes. Reopen and retry preserved the unrelated stage fixture. |
| Pending request INSERT, pending root INSERT, completion UPDATE | Three additional SQL-boundary kills. The first two rolled back both claim rows. The completion kill left the original pending root and old cursor. |
| Invalid owner, FK-valid wrong result/cursor, malformed FORMAT and initializer interrupted before marker | Refusal without guessing authority. New faults were exercised only in disposable stores. Existing schema and repository identity refusal cases stayed green. |
| Three-process stalled writer, independent capture and read | Both peers finished while the victim was paused during a partial write. SIGKILL released the victim's locks. Two barrier-released retries on its original key both returned sequence 1. Inspector found histories of 2, 2 and 1 occurrences. |
| SQLite COMMIT BUSY | Separate reader held the SQLite read lock. Real SQLITE_BUSY surfaced as UncertainCommit in about 0.213 s for the measured child attempt, with a configured 0.15 s wait. Recovery preserved cursor and exact retry. |
| Reader publication gate | Separate exclusive contender refused while the reader was in closure access. It acquired the lease after the read ended. No collector was run. |

The publication suite has **26 subprocess cases**, 13 with EIO and 13 with
SIGKILL. Before each case the fixture verifies its old capture. After each
fault the separate inspector asserts the specific pending root, completed
root and capture rows. The test checks new canonical presence and exact bytes
against the input envelope. It then runs successful retry and same-key replay.

Supplemental probes extend the [M1b.1 harness](M1B1_REPORT.md). The baseline
seven SQLite syscall cases were rerun through the same linked library.
Journal/database sync returned SQLITE_IOERR_FSYNC, and ENOSPC at SQLite
database write surfaced as SQLITE_FULL. Kills at journal sync, database sync
and before unlink retained the old capture, while the kill after unlink
retained the completed result. Each case recovered and replayed sequence 1.

New SQLite probes use a child-scoped, test-only syscall interposer extracted
from the prior report and extended in external scratch:

| Trigger reached | SQL result and independent inspection |
| --- | --- |
| Failure after pending request INSERT | StorageFull from the injected body error. Fresh inspection found neither the new request nor its root. |
| Actual SQLite rollback sync EIO after pager spill | Interposer confirmed EIO inside SQLite sync. The qualified build did not return a secondary rollback exception to Python. Primary StorageFull remained, and fresh inspection proved old cursor and verified pending closure. Exception injection separately proved secondary rollback errors are retained as notes when reported by the provider. |
| Hot journal after completion UPDATE, before COMMIT | SIGKILL after forced spill. The child checked hot-journal magic `d9d505f920a163d7`. An independent read-only SQLite connection returned SQLITE_READONLY_ROLLBACK. Application reopen recovered the old cursor and verified pending closure. |
| Directory sync after SQLite successfully unlinked the journal | Injected EIO yielded SQLITE_IOERR_DIR_FSYNC and UncertainCommit. Reopen plus independent inspection found both completed captures and both roots. Replaying the original key returned the already completed sequence 1. |
| SIGKILL at that same directory sync | Recovered the completed SQL result, with the same exact sequence. This result depends on process-crash conditions and says nothing about unsynced bytes after device power loss. |
| Retry directory still unsynced | Pending and completed same-handle retries refuse UncertainCommit under injected EIO. The successful sync path returns exactly the original capture identity. |

The contention barriers use flushed pipes with timeouts. The three-workspace
focused run observed about 0.179 s for both peers during the stall. These are
fixture timings with no starvation-freedom claim. The previous stale writers,
reader isolation, same-process SQLite lock and no-SQL-during-stream checks ran
as part of the full suite.

## TDD and verification

- Immutable baseline at entry. **429 passed** in 95.71 s.
- RED. **17 failed**, with no setup errors in the actual RED run. Missing
  per-key diagnostics and named fault boundaries failed alongside confirmed
  cleanup masking, descriptor reuse, rollback-note, admission and logical
  link regressions.
- GREEN and refactor. **17 passed**. An intermediate lint autofix removed a
  fixture import, causing 17 setup errors. The fixture wiring was corrected
  separately. An indentation error in an intermediate close-handler refactor
  was caught by syntax/lint checks and corrected before successful testing.
- Expanded matrix. **44 passed** in 55.97 s.
- Same-handle directory re-sync RED. **2 failed** after the real SQLite
  post-unlink finding. Both **2 passed** after the retry sync fix.
- Further inspection, initialization and frozen digest tests. **4 passed**.
- Final full suite **479 passed, zero failures, zero errors and zero skips**, 172.79 s in JUnit.
- Hypothesis **500 passing examples, zero failing examples** and 25 rejected generation attempts. The new property independently hand-encodes the original
  control digest and checks exact result/key replay after reopen. Generation
  rejections and retries are not pytest skips.
- Compatibility. All 429 old tests were executed unmodified, including the
  60 canonical stored-object round-trips, full earlier content vectors and
  digest identities, all 22 M0 semantic cases, oversized-inline refusal,
  Compose/literal cases, and original capture counter and replay tests.
- Ruff check and format check, strict mypy, link check, `git diff --check`,
  isolated source and wheel build, installed-wheel original and recovery
  smoke tests all passed. The wheel smoke observes incomplete pending state,
  supplies the exact missing tree, and checks the resulting completed request.

## Profile, preservation and handoff

Observed HEAD `1d75d7f1d6c666ea1474ceca4e33363068d4f444` at entry and at completion. The starting inventory recorded **558** pre-existing
tracked and nonignored untracked files. The only changed initial files are
`python/src/yeokcham/private_store.py` and
`python/src/yeokcham/object_files.py`. Added
`python/tests/test_private_recovery.py`, the recovery contract and this report.
The untracked prior report and all unrelated original fingerprints and modes
were retained. No ordinary worktree, live store, Git history or branch changed.

The qualified runtime is local Btrfs on Linux 7.2.15 x86-64, CPython 3.14.8
(GCC 16.2.1), vendor SQLite 3.54.0 with source ID
`2026-10-09 15:46:58 be8d059e9a49089ab2dce5ed26dd87aaf598fdc5fbe0b107c0dd758464bcalt1`.
The compile options hash is
`b21634e22f921a220f8494a0e551605763d8f3d33e582075f574a42d718a152a`.
Verified loaded libsqlite3 SHA-256
`758544266d5060aff683efcc94ee9abf2625c6ff9d02b70bb6d1296e0ee9128f`
and Python sqlite extension SHA-256
`ed9dc2218de28a5725a171a18b2ae31c9065486bd54361b6cdf598d36682760a`.
Store checks and regression assertions exercised explicit `unix` VFS, DELETE,
EXTRA, foreign keys, `0x594b5031` and schema version 1. The unchanged runtime
allowlist rejected unsupported profiles. Filesystem sync and lock checks were
on external Btrfs fixtures. Tmpfs held tooling and logs. The pytest parent reached an observed VmHWM of 276,472 KiB
across 275 samples. This understates aggregate usage by subprocesses.

Actual device faults, power loss, controller cache behavior, alternate
providers and filesystems, unsupported native platforms and store tampering
outside the cooperative model remain unqualified. Completed roots and stale
pending intents remain retained. Incomplete or unverifiable roots can delay
future collection indefinitely. Any future GC or backup tranche needs separate
ownership and durability qualification.

**M2 readiness BLOCKED.** Recommend a separately authorized read-only native
prerequisite gate for identity, locking, observation and flush assumptions,
then independently discriminate the copy-out baseline failure before a
preservation-aware application tranche. BASELINE-COPYOUT-20261116 remains
unresolved. No native worktree operation, GC, backup, later tranche or migration
was implemented.

## Reproduction

Run from the checkout on the qualified profile. Place all runtime fixtures
outside the checkout on Btrfs and tooling in an external venv. The
[M1b.1 report](M1B1_REPORT.md) gives the installation and build commands.

```sh
test_root=/absolute/path/to/disposable/btrfs-directory
PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
  HYPOTHESIS_STORAGE_DIRECTORY="$test_root/hypothesis" \
  "$test_root/env/bin/python" -m pytest python/tests -s -p no:cacheprovider \
  --basetemp="$test_root/suite" --hypothesis-show-statistics \
  --junitxml="$test_root/results.xml"
"$test_root/env/bin/ruff" check --no-cache python
"$test_root/env/bin/ruff" format --no-cache --check python
"$test_root/env/bin/mypy" --config-file python/pyproject.toml --cache-dir "$test_root/mypy" python/src
python3 -B tools/check_doc_links.py
git diff --check
```

Save the appendix scripts in external scratch and run from the checkout.
The runner creates a new store before each fault. It passes the shared object
only to the designated child.

```sh
scratch=/absolute/path/to/external/scratch
python3 -B "$scratch/build_probe.py"
cc -Wall -Wextra -Werror -shared -fPIC "$scratch/commit_fault.c" -ldl -o "$scratch/commit_fault.so"
for probe in commit_fault commit_busy reader_gate sqlite_probe
do
  PYTHONPATH="$PWD/python/src" PYTHONDONTWRITEBYTECODE=1 \
    "$test_root/env/bin/python" -B "$scratch/$probe.py" "$test_root"
done
```

SQLite rollback and sync interpretations were checked against the
[atomic commit protocol](https://www.sqlite.org/atomiccommit.html) and
[SQLite synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous).
The fault placements and SQL/Python error observations in this report are
from the locally linked binary.

### `build_probe.py`

````python
"""Extend the frozen M1b.1 syscall interposer in an external directory."""
import re
from pathlib import Path

scratch = Path(__file__).resolve().parent
report = Path("docs/v2/implementation/M1B1_REPORT.md").read_text()
base = re.search(r"### `commit_fault\.c`\s+```c\n(.*?)\n```", report, re.S)[1]
base = base.replace("static int fired;", "static int fired, journal_removed;")
base = base.replace(
    'if (strcmp(mode, "ioerr-sync") == 0) {',
    '''if (strcmp(mode, "ioerr-dir") == 0 && journal_removed) {
        announce("injected EIO at SQLite directory sync after journal unlink\\n");
        errno = EIO;
        return 1;
    }
    if (strcmp(mode, "kill-dir") == 0 && journal_removed) {
        announce("injected SIGKILL at SQLite directory sync after journal unlink\\n");
        kill(getpid(), SIGKILL);
    }
    if (strcmp(mode, "ioerr-sync") == 0) {''',
)
base = base.replace(
    '    if (fired || !target || !mode || strcmp(path, target) != 0)',
    '''    const char *journal = getenv("M1B2_JOURNAL");
    if (journal && strcmp(path, journal) == 0) {
        int rc = real_unlink(path);
        if (rc == 0) journal_removed = 1;
        return rc;
    }
    if (fired || !target || !mode || strcmp(path, target) != 0)''',
)
(scratch / "commit_fault.c").write_text(base + "\n")
for name in ("commit_fault.py", "commit_busy.py", "reader_gate.py", "wheel_smoke.py"):
    (scratch / name).write_text(re.search(
        rf"### `{re.escape(name)}`\s+```python\n(.*?)\n```", report, re.S,
    )[1] + "\n")
````

### `sqlite_probe.py`

````python
"""SQLite faults inside rollback or final journal finalization on fresh stores."""
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

scratch = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd() / "python/tests"))
import test_private_recovery as recovery
import test_private_store as t


def writer(path, scenario):
    opened = t.api().PrivateStore.open(path, t.REPO, timeout=0.15)
    with opened:
        original = opened._connection

        @contextmanager
        def spill():
            with original() as c:
                c.execute("PRAGMA cache_size=1")
                c.execute("PRAGMA cache_spill=ON")
                yield c

        def event(name):
            if scenario == "rollback-claim" and name == "request-inserted":
                raise OSError(28, "primary claim failure")
            if scenario in ("rollback-sync", "hot-journal") and name == "request-completed":
                journal = path / "metadata.sqlite3-journal"
                assert journal.read_bytes()[:8].hex() == "d9d505f920a163d7"
                if scenario == "hot-journal":
                    os.kill(os.getpid(), signal.SIGKILL)
                os.environ["M1B1_FAULT_FILE"] = str(path / "metadata.sqlite3")
                os.environ["M1B1_FAULT_MODE"] = "ioerr-sync"
                raise OSError(28, "primary capture failure")
            if scenario in ("dir-sync", "dir-kill") and name == "capture-before-commit":
                os.environ["M1B2_JOURNAL"] = str(path / "metadata.sqlite3-journal")
                os.environ["M1B1_FAULT_FILE"] = str(path)
                os.environ["M1B1_FAULT_MODE"] = "ioerr-dir" if scenario == "dir-sync" else "kill-dir"

        if scenario in ("rollback-sync", "hot-journal"):
            opened._connection = spill
        opened.fault = event
        try:
            result = t.append(opened, key=b"next", data=b"next")
        except t.api().StoreError as error:
            cause = error.__cause__
            print(json.dumps({
                "outcome": error.code, "cause": str(cause),
                "sqlite": getattr(cause, "sqlite_errorname", None),
                "notes": getattr(error, "__notes__", []) + getattr(cause, "__notes__", []),
            }), flush=True)
            sys.exit(19)
        print(json.dumps({"outcome": "returned", "sequence": result.capture.sequence}))


def run(fixtures):
    for scenario in ("rollback-claim", "rollback-sync", "hot-journal", "dir-sync", "dir-kill"):
        path = Path(tempfile.mkdtemp(prefix=scenario + "-", dir=fixtures)) / "store"
        with t.api().PrivateStore.initialize(path, t.REPO) as store:
            store.register_workspace(t.WS)
            t.append(store)
            expected = store.workspace(t.WS)
        child = subprocess.run(
            [sys.executable, "-B", __file__, "child", str(path), scenario],
            env={**os.environ, "LD_PRELOAD": str(scratch / "commit_fault.so")},
            capture_output=True, text=True, check=False, timeout=15,
        )
        outcome = json.loads(child.stdout) if child.stdout else {}
        if scenario == "rollback-sync":
            assert child.returncode == 19 and "injected IOERR" in child.stderr, (scenario, child)
            assert outcome["outcome"] == "StorageFull"
            # Record whether this SQLite build propagates or absorbs the sync error.
        elif scenario == "rollback-claim":
            assert child.returncode == 19 and outcome["outcome"] == "StorageFull", child
        elif scenario == "hot-journal":
            assert child.returncode == -signal.SIGKILL, child
            c = sqlite3.connect((path / "metadata.sqlite3").as_uri() + "?mode=ro&vfs=unix", uri=True, autocommit=True)
            try:
                try:
                    c.execute("SELECT count(*) FROM capture").fetchone()
                    raise AssertionError("missing hot journal")
                except sqlite3.OperationalError as error:
                    assert error.sqlite_errorname == "SQLITE_READONLY_ROLLBACK", error
            finally:
                c.close()
        elif scenario == "dir-kill":
            assert child.returncode == -signal.SIGKILL and "after journal unlink" in child.stderr, child
        else:
            assert child.returncode in (0, 19) and "after journal unlink" in child.stderr, child
            if child.returncode == 19:
                assert outcome["outcome"] == "UncertainCommit"
        with t.api().PrivateStore.open(path, t.REPO) as reopened:
            status = reopened.inspect_request(t.WS, b"next")
            before = recovery.outside_inspection(path)
            if scenario == "rollback-claim":
                assert status is None and len(before["owners"]) == 1
            elif scenario in ("rollback-sync", "hot-journal"):
                assert status.request.state == "pending" and status.closure == "verified" and status.eligible
            else:
                assert status.request.state == "completed" and status.closure == "verified"
            assert len(before["captures"]) == (2 if scenario.startswith("dir-") else 1)
            retried = t.append(reopened, key=b"next", data=b"next", expected=expected)
            assert retried.capture.sequence == 1
            after = recovery.outside_inspection(path)
            assert len(after["captures"]) == len(after["owners"]) == 2
        print(json.dumps({
            "scenario": scenario, "child_exit": child.returncode, "fault": child.stderr.strip(),
            "response": outcome, "verified_rows_before_retry": len(before["captures"]),
            "retry_sequence": retried.capture.sequence,
        }), flush=True)


if sys.argv[1] == "child":
    writer(Path(sys.argv[2]), sys.argv[3])
else:
    run(Path(sys.argv[1]))
````

### `wheel_recovery.py`

````python
from pathlib import Path
import sys

from yeokcham import codec, content
from yeokcham.errors import Code, ContentError
from yeokcham.identities import RepositoryId, SnapshotId, StoredObjectId, TreeId, WorkspaceId
from yeokcham.private_store import PrivateStore, RecoveryInfo

path = Path(sys.argv[1])
repo = RepositoryId(b"r" * 32)
workspace = WorkspaceId(b"w" * 16)
objects = {}
tree = content.encode_tree([])
tree_id = codec.object_id(tree)
objects[tree_id] = tree
snap = content.encode_snapshot(TreeId(tree_id.raw))
snapshot = SnapshotId(codec.object_id(snap).raw)
objects[StoredObjectId(snapshot.raw)] = snap
with PrivateStore.initialize(path, repo) as store:
    expected = store.register_workspace(workspace)
    try:
        store.append_capture(
            workspace, snapshot, {StoredObjectId(snapshot.raw): snap}.get,
            expected=expected, key=b"smoke",
        )
    except ContentError as error:
        assert error.code == Code.UNAVAILABLE
    else:
        raise AssertionError("incomplete closure was accepted")
with PrivateStore.open(path, repo) as store:
    pending = store.inspect_request(workspace, b"smoke")
    assert isinstance(pending, RecoveryInfo)
    assert pending.eligible and pending.closure == "missing"
    result = store.append_capture(
        workspace, snapshot, objects.get, expected=pending.expected, key=b"smoke",
    )
    completed = store.inspect_request(workspace, b"smoke")
    assert completed.request.result == result and completed.closure == "verified"
    assert completed.eligible is None and store.verify_roots().completed == 1
print("installed wheel pending recovery and exact replay passed")
````

**M1b.2 completed to the extent verified. No later tranche was authorized.**
