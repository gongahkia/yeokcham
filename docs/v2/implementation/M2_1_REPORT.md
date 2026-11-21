# M2.1 native observation and manual Save report

| Gate | Verdict |
| --- | --- |
| Native observation | PASS for the restricted Linux observation profile |
| Manual Save | PASS through the existing private store |
| M2.1 overall | PASS within the verified scope |

The observer returns an exact detached snapshot and evidence of a bounded
observation interval. The manual Save API records it through M1b's existing
cursor compare-and-swap and durability boundary. M1b retained its schema,
identity domains, object format, lock order, cursor rules and retry semantics.
[Observation contract](M2_1_OBSERVATION_CONTRACT.md) ·
[M1b recovery contract](M1B2_RECOVERY_CONTRACT.md)

## Source, host and capabilities

Starting HEAD was `1df2a6192c6d6386f9f779d1b8b91bf13d12cfab` on clean
`main...origin/main`. An external commit advanced HEAD to
`6924d9ad738e56ac582d650fb56600101c4d595d` during this work. It included the
initial M2.1 contract and RED observation tests. The working versions of those
two files include the subsequently verified contract details and fixture
corrections.

The tested profile was Linux `7.2.15-1-omarchy` x86-64, glibc 2.44,
CPython 3.14.8, local Btrfs `/@home` with `noatime` and system tmpfs
`/tmp`. Save used the exact admitted SQLite 3.54.0 build. The M1b allowlist,
application ID `0x594b5031`, schema 1, DELETE journaling, EXTRA synchronous
mode and foreign-key policy stayed intact. [M1b.2 runtime identity](M1B2_REPORT.md)

An independent header-built C probe on disposable Btrfs fixtures confirmed
Linux x86-64 syscall 437, the 24-byte open_how structure, Btrfs magic
`0x9123683e`, x86-64 statfs size 120, ioctl `0x80086601`, and
`OPENAT2_REGULAR=0x100000000`. A regular open succeeded. FIFO and symlink
data opens refused with EFTYPE on this kernel. The probe expectation was
updated from an assumed symlink ELOOP to the observed EFTYPE before
implementation. The production adapter classifies either when a path
changes after pinning. A real character device also refused at the
regular-only kernel boundary. Creating a character-device fixture on
Btrfs under the unprivileged namespace returned EPERM, so that specific
end-to-end setup remains unqualified. The public observer separately
refused actual FIFO and socket fixtures. [Linux openat2](https://man7.org/linux/man-pages/man2/openat2.2.html)

## Implementation

- [Linux ABI adapter](../../../python/src/yeokcham/_observation_linux.py)
  provides only descriptor-relative opens, filesystem class and casefold
  probes. The syntax and caps are explicit for the x86-64 Linux ABI.
- [Observer](../../../python/src/yeokcham/observation.py) binds the root
  below the noatime Btrfs `/home` anchor. It pins the ancestry, uses
  constrained opens for all descendant lookup and final membership checks,
  protects private-store directory identities, and refuses reserved
  metadata and unsupported mount or type conditions. A real private
  mount-namespace test verified same-device, same-inode bind refusal.
- `observe_directory(root, limits=...)` is a context manager yielding
  `ObservedDirectory` or `ObservationRefused`. A complete observation
  supplies `SnapshotId`, a lifetime-bounded resolver, the verified root
  stamp, per-entry stamp and byte digest, UTC wall-clock stamps, monotonic
  elapsed time and attempt count. Refusals identify the code, affected raw
  path when known, attempt count and detail.
- Reads support ordinary and executable files, raw names, symlink targets
  as bytes, nested and empty directories, and canonical chunked content.
  Fresh enumeration checks directory names in both passes. Streaming
  consumes exact length and EOF, and records mode, kind, device, inode,
  link count and nanosecond timestamps. The final walk reopens names,
  repeats exact byte hashing and rechecks the root and ancestors. A
  synthetic second-read byte mismatch with unchanged stat evidence
  exhausted all three attempts. File or directory interference may
  retry, while a substituted root refuses without retargeting the call.
- Blank or comment-only regular `.yeokchamignore` files are supported and
  saved exactly. Effectful, malformed, nonregular and oversized
  configurations refuse. Root `.git` is excluded. Other ordinary contents
  receive no heuristic filtering. Hardlinked regular files, metadata
  marker overlap, aliases and filesystem conditions outside the profile
  refuse explicitly.
- The detached spool is an unnamed private tmpfs file. It stores encoded
  objects by offset, with explicit per-attempt limits. The observer
  reuses M1a content/chunking, tree/snapshot encoders and full closure
  verification. Retry, refusal and process death release detached spool
  storage. M1b can separately retain published objects and an exact
  pending root after a publication fault.
- [Manual Save](../../../python/src/yeokcham/manual_save.py) exposes
  `save_directory(store, workspace, root, *, expected, key, limits=...)`
  and `resume_save(store, workspace, *, snapshot, expected, key)`.
  `SaveRecorded` carries the exact CaptureId and SnapshotId via the
  existing `CaptureResult`, plus evidence for a newly run observation.
  Its status distinguishes completed and unchanged. `SaveRefused`
  retains the typed reason and any exact observed snapshot/evidence.
  Replay of a recovered request returns its original identity with no new
  observation. Uncertain COMMIT remains structured and recoverable by
  the same caller key. A changed source cannot substitute for a pending
  exact snapshot.
- No store lock or SQL transaction spans observation. The application
  validates the backing store's native binding before scanning and calls
  `PrivateStore.append_capture` only after complete closure verification
  and native recheck. That existing method owns the Space lock, publication
  gate and cursor/metadata transactions. It refuses an intervening stale
  cursor. Source descriptors close before that handoff. No SQLite schema,
  format or persisted attachment was added.

The time window describes two bounded observations, including their
comparison and root recheck. Concurrent external writes can still fall
outside or between checks. The evidence supplies neither an atomic
whole-tree instant nor a later cleanliness assertion.

## TDD and verification

| Run | Result |
| --- | --- |
| Initial RED | 64 collected, 64 failed with the three M2.1 modules absent. The disposable fixture, pytest environment and existing M1b store initialized. No collection errors or skips. |
| Additional exact-byte RED | 1 failed because the observer was absent. The test requires exact final-read disagreement even with matching native metadata. |
| First GREEN attempt | 60 passed, five fixture assertions exposed. The mixed reference input needed its existing nested note, the persisted request state is `completed`, and M1b requires explicit `max_file_bytes` to display payload bytes. Corrected the test setup against the retained emitter and M1b contract. No reference vectors or stored expectations changed. |
| Focused GREEN | 65 passed, including 20 generated raw-byte tree examples. |
| Refactor and final pytest | Froze shared default limits, reused the libc handle, removed the pre-observation metadata read, and added the actual kernel character-device check. **545 passed, zero failed/errors/skipped**, 186.86 s. The output recorded **520 passing Hypothesis examples** across 15 properties. |
| Prior regression | All 479 previous tests passed, including 76 private-store and 50 private-recovery tests. The private recovery suite exercised interrupted object publication, roots and exact retry on the existing runtime. |
| Native requalification | All 30 retained M2.0 scratch cases exited successfully. New tests covered native observations, bounds, race handling and independent store progress. |
| Independent vectors | Native construction matched the RC03 mixed snapshot and all nine reachable object bytes in the focused test. An additional detached native run matched all 14 independently emitted file snapshots and 53 distinct reachable objects byte for byte, including chunked boundaries and CRLF/binary data. Manifest output matched the checked-in vector manifest. |
| Packaging and static checks | Ruff lint and format, strict mypy on 14 source files, documentation links and whitespace checks passed. Isolated sdist and wheel builds passed. A fresh installed-wheel smoke test saved 65,792 raw-named file bytes and an opaque symlink target, checked SQLite integrity and foreign keys, reopened the store and replayed the exact original key. |

The initial packaging attempt used the test environment without build
isolation and could not import setuptools. The successful build used the
declared isolated build environment. The package manifest and dependencies
were unchanged. The new fixture tests are in
[observation tests](../../../python/tests/test_observation.py) and
[manual Save tests](../../../python/tests/test_manual_save.py).

### Concurrency and recovery

Three separate Spaces first recorded distinct base Saves. A spawned worker
blocked after its first ordinary file read. While it was blocked, an
independent SQLite connection acquired `BEGIN IMMEDIATE` and committed, a
separate process read completed history, and two unrelated processes
recorded different exact snapshots. Killing the stalled observer left its
original Save and cursor intact and created no request. The test verified
full object closures and the retained root counts.

A separate two-process race submitted different observed snapshots against
the same expected Space state. The intervening winner held the cursor and
the stale observer refused without creating a request. Other tests checked
unchanged observations, distinct Saves with equal historical content,
frozen request mismatches, failed observation and failed publication, and
replay after a simulated lost successful COMMIT response.

## Reproduction and preservation

Use disposable Btrfs fixture paths below the tested `/home` mount and
separate scratch paths. Data, builds, qualification binaries, venvs and logs
were external to the checkout.

```sh
PYTHONPATH=python/src PYTHONDONTWRITEBYTECODE=1 \
  HYPOTHESIS_STORAGE_DIRECTORY="$SCRATCH/hyp" "$TEST_PYTHON" -m pytest \
  python/tests -p no:cacheprovider --basetemp="$BTRFS_FIXTURES/full" \
  --hypothesis-show-statistics --junitxml="$SCRATCH/full.xml"
ruff check --no-cache python/src python/tests
ruff format --check --no-cache python/src python/tests
mypy --strict --cache-dir "$SCRATCH/mypy" python/src
python3 -B tools/check_doc_links.py
git diff --check
cc -O2 -Wall -Wextra -Werror -fPIC -shared \
  python/tests/native_qualification/probe_linux.c -o "$SCRATCH/native-probe.so"
python3 -B python/tests/native_qualification/native_probe.py \
  "$SCRATCH/native-probe.so" "$BTRFS_FIXTURES" "$SCRATCH"
```

The run records are in `/tmp/yeokcham-m21-Ghqrqw` and the disposable
fixtures are under `/home/gongahkia/yeokcham-m21-fixtures-JVnjsL`.
The expected seven tranche paths are the three new source files, two
tests, and two implementation documents. The final preservation check
matched hashes and modes for the 567 pre-existing paths. The observed
trees and stores used by verification were disposable. Source observation
opened ordinary entries read-only. No Git mutation was made by this work.

## Remaining qualification

Only the documented local Linux profile is qualified. Existing-root
management, per-Space path registration, broader ignore grammar,
unsupported filesystem types and aliases, macOS and Windows remain
outside it. The observer imposes aggregate caps and can refuse an
otherwise valid larger tree. Process-kill and fault evidence do not
establish physical power-loss or hardware behavior.

The historical OCaml copy-out issue remains unfixed.
[Historical diagnosis](M2_0_COPYOUT_DIAGNOSIS.md)

For a separately authorized M2.2, freeze physical operation ownership,
native action and recovery controls, and exact retained-original and
target proof before an executor writes ordinary files. Require
independently qualified file/directory sync and mutation primitives,
absent-only no-replace ownership, obstruction and external-edit refusal,
interrupted recovery with complete roots, and N01–N15. Resolve or
explicitly isolate the historical issue before copy-out promotion.
[M0 gate and test matrix](../m0/M0_SAFETY_AND_TRANCHE_GATES.md) ·
[D4 recovery and ownership](../D4_BLOCKER_RESOLUTION.md)
