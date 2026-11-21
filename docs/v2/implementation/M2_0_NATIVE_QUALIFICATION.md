# M2.0 native filesystem qualification

**NATIVE_PREREQUISITES_PARTIAL** for Linux x86-64 on the tested local Btrfs
mount. **M2_1_READY_FOR_SEPARATE_AUTHORIZATION** for the restricted
read-only observation and manual capture proposal below. The scratch
probes establish specific capabilities and refusal boundaries. A production
binding, filesystem application protocol, and full N01–N15 verification
remain future work. The historical issue has its own
[copy-out diagnosis](M2_0_COPYOUT_DIAGNOSIS.md).

## Baseline and scope

- HEAD and starting index and worktree were verified before changes.
  HEAD was `112f31474ba4899420a17bbcedf3f9ace13a6048` on clean
  `main...origin/main`, ahead of the previous reported source revision
  `1d75d7f1d6c666ea1474ceca4e33363068d4f444` in the local history.
- Host Linux `7.2.15-1-omarchy` x86-64, CPython `3.14.8` built with
  GCC `16.2.1`, glibc `2.44`, UID 1000. Native and private-store fixtures used the
  local Btrfs `/@home` subvolume (`noatime,compress=zstd:3`), device 51.
  Cross-device and historical contrasts also used `/tmp` tmpfs, device 55.
  The Python storage allowlist remains limited to its prior profile.
- Linked SQLite `3.54.0`, source
  `2026-10-09 15:46:58 be8d059e9a49089ab2dce5ed26dd87aaf598fdc5fbe0b107c0dd758464bcalt1`.
  Compile-options digest
  `b21634e22f921a220f8494a0e551605763d8f3d33e582075f574a42d718a152a`.
  The stdlib extension digest was
  `ed9dc2218de28a5725a171a18b2ae31c9065486bd54361b6cdf598d36682760a`.
  Linked libsqlite3 digest was
  `758544266d5060aff683efcc94ee9abf2625c6ff9d02b70bb6d1296e0ee9128f`.
  The prior runtime checks and SQLite mode tests passed. Application ID
  `0x594b5031`, schema `1`, DELETE journaling, synchronous EXTRA and
  foreign keys remain properties of the existing store.
  [Storage contract](M1B1_STORAGE_CONTRACT.md) ·
  [Pending-root recovery](M1B2_RECOVERY_CONTRACT.md) ·
  [M1b.1 results](M1B1_REPORT.md) · [M1b.2 results](M1B2_REPORT.md)

## Existing implementation facts

| Source | Inspected behavior and significance |
| --- | --- |
| [Native C stubs](../../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c) and [Native OCaml wrapper](../../../lib/yeokcham_snapshot/native.ml) | `yeokcham_scan_open_at` uses no-follow, nonblocking open with a directory flag when requested. `inspect_at` uses `AT_SYMLINK_NOFOLLOW`. The fingerprint includes mode, device, inode, link count, size, and nanosecond mtime and ctime. `names` opens a separate enumeration descriptor before sorting byte names. `check_destination` checks NAME_MAX and effective access and refuses positive Linux casefold. The old check continues when the ioctl fails. |
| [Snapshot observation](../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml) | `scan_with_observer` checks the opened root, enumerates before and after, reads nested ignore rules, checks per-entry and directory observations, reopens the root, and retries observed changes up to three attempts. Regular/executable and symlink are distinct. The scanner excludes `.yeokcham` and root `.git` and refuses special nodes. These are useful reference behaviors. |
| [Safe apply](../../../lib/yeokcham_v1_local_service/safe_apply.ml) | `valid_path` rejects empty/dot/parent/slash/NUL components, metadata anywhere, and root `.git`. `validate_parents` checks reopened native identity. `classify` compares pre/post pairs. `entry_bytes_match` additionally checks kinds, complete names, file bytes, executable status, symlink bytes, and stable observations. `prepare_copyout_with` uses realpath, lexical overlap checks and device comparisons. It allows a pre-existing empty directory, outside the proposed Python policy. Same-device bind aliases show why device checks alone are insufficient. |
| [Integration executor](../../../lib/yeokcham_v1_local_service/native_integration.ml) and [restore journal](../../../lib/yeokcham_v1_restore_journal/yeokcham_v1_restore_journal.ml) | Integration separates a local worktree writer lock, safety capture/plan checks, native mutations, and Prepared/Applying/Materialized/Committed/Completed boundaries. The older restore journal encodes immutable per-generation records and verifies their sequence. These are specifications and source evidence for later testing. |
| [Current Python store](../../../python/src/yeokcham/private_store.py), [object files](../../../python/src/yeokcham/object_files.py), and [store tests](../../../python/tests/test_private_store.py) | `workspace` gives a typed cursor/version. `append_capture` locks a workspace and a shared publication gate, checks the exact expectation, records pending intent, verifies and durably publishes objects outside the SQL transaction, then atomically changes history and cursor. It accepts `SnapshotId` plus a resolver. No workspace pathname, native operation, or persistent root attachment is defined. |

Background requirements and later qualifications are recorded in the
[D2 architecture, §9](../D2_PYTHON_ARCHITECTURE_RFC.md),
[D3 contract](../D3_CONTRACT_FREEZE.md),
[D4 destination ownership and recovery](../D4_BLOCKER_RESOLUTION.md),
and [M0 safety and tranche gates](../m0/M0_SAFETY_AND_TRANCHE_GATES.md).

## Native experiments

The [reference harness](../../../python/tests/native_qualification/native_probe.py)
and [header-built Linux probe](../../../python/tests/native_qualification/probe_linux.c)
passed **30 cases, zero failures or skips** in the final run. The harness
used bounded synthetic files. Mutations were sequenced at exact read or
descriptor boundaries, two claimants synchronized over pipes, and both
interruption cases used SIGKILL on a fresh Python process. Bind mounting ran
inside a new user and private mount namespace.

| Cases | Evidence and implementation implication |
| --- | --- |
| 01–05 regular stream and changes | A 4,352-byte binary read matched exactly and reached EOF. A split read observed `abcd5678` from a file changed from `abcdefgh` to `12345678`. Same device/inode/type/size/mtime after restoring mtime still allowed changed bytes, with ctime different in this test. A held descriptor read the original bytes after pathname replacement. Even identical replacement bytes had different inode identity. |
| 06–10 mode and fidelity | Same-inode mode-only change from 0600 to 0700 was visible. Executable bytes `0d0a00ff`, raw filename `6261642dff2d0a`, a real empty directory, and raw symlink target `6d697373696e672dfe0a` were preserved by the byte-level checks. Opening the link as a regular data target refused with ELOOP. |
| 11–15 substitutions, aliases, unsupported | An intermediate symlink refused with ELOOP through constrained open. A removed directory name gave ENOENT while the old handle still read the original bytes. After parent substitution, an anchored mutation in scratch followed the old parent to its new name and did not touch the foreign parent. Hardlink aliases shared device/inode with link count 2 and exclusive rename refused EEXIST. FIFO was identified before data access and a denied regular file returned EACCES for UID 1000. |
| 16–19 creation and exclusive publication | Exclusive file and directory creation, file/directory sync, absent directory install and inode checks passed. Existing file, existing empty directory, and a hardlink alias refused. Races in both launch orders each had one winner and retained the losing stage exactly. Btrfs-to-tmpfs rename refused EXDEV with the source intact and destination absent. |
| 20–21 sync failure | Successful real file and directory fsync calls on Btrfs preceded injected EIO at a regular file sync and at a parent sync after rename. In the first case the stage stayed exact and destination absent. In the second the destination held exact bytes with a durability-uncertain result. A real fsync on a pipe refused EINVAL. The EIOs were injected in Python, so these cases give no physical Btrfs device fault qualification. |
| 22–26 termination, external edits, unsupported flags | With a flushed stage, kill before publication left only the stage. Kill after rename and before parent sync left the exact completed tree visible at the destination. Editing after publication changed verified bytes. Exchange retained the old inode, and an old descriptor changed that retained file to `out` with its inode, size and mtime held equal while installed `new` remained exact. Invalid flag gave EINVAL and injected missing syscall gave ENOSYS. |
| 27–30 containment and time | `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV)` refused parent escape, absolute bypass and mount crossing. A file opened as a directory refused ENOTDIR. NAME_MAX was 255 and 256 bytes refused. The mount was case-sensitive and casefold flag clear. Fresh `openat(fd, ".")` had separate directory enumeration state, while `dup(fd)` shared the exhausted offset. A same-dev/inode bind alias was traversable with ordinary open, and constrained open refused EXDEV. A held O_PATH regular inode survived replacement by a FIFO and reopening the pinned inode through checked procfs read only the original file. O_PATH on a terminal symlink returned its exact target via empty-path readlink. The mixed-time case saw `01` while the tree went through `00 → 10 → 11` only. |

In a separate observation within case 08, an existing Btrfs directory
descriptor opened before creation did not list the new raw filename.
A freshly opened descriptor relative to that same directory returned the
name. A paired scratch reproduction found the old descriptor listed both
names on tmpfs and missed both on Btrfs. Use fresh enumerators for every
initial and final list, even when a traversal descriptor is held. This is
also what the OCaml `Native.names` wrapper requests.

## Observation and refusal contract for M2.1

1. **Native identity** concerns an opened object and its name binding during
   the attempt. Track device, inode, kind, mode, link count, size, mtime_ns and
   ctime_ns, along with root and each rewalked parent membership. Opened
   identity survives rename. A later pathname observation requires a fresh
   constrained rewalk and comparison. A reused inode number is insufficient
   as a durable attachment ID.
2. **Exact content identity** comes from hashing the exact bytes read using
   M1a's existing content, object, tree, and snapshot rules. Names and target
   bytes never pass through Unicode normalization. Empty directories and the
   executable distinction appear in the tree. A regular-to-special race must
   refuse before opening the substituted name for data. Use a typed O_PATH
   leaf plus checked procfs reopen for that Linux subset, or refuse if the
   capability is unavailable. The only intentional magic-link reopen is the
   numeric descriptor in verified procfs while the pinned descriptor is
   alive. Record a supported procfs capability in the runtime check.
3. **Stable completed observation** means ordered per-node exact reads,
   exact size and EOF checks, before/after native comparisons, fresh sorted
   byte-name enumerations, a final rewalk, and bounded retry or refusal on
   interference. Recheck ignore inputs and managed boundaries as well.
   Record the observation interval. Atime is excluded from change checks.
   Two successful comparisons still leave race windows, including writes
   after recheck, changes restored before a check, and schedules across
   multiple files. A source with active uncooperative writers can require
   caller quiescence for stronger assurances. Status must describe the last
   completed observation.
4. **A verified historical object** is authenticated here by its requested
   M1a identity, type, exact representation, and verified complete closure.
   Native stamps are additional live-source evidence. Persisted immutable
   object identity remains valid independently of later worktree changes,
   subject to object availability/integrity checks.
5. **An eligible authoritative capture** requires supported stable
   observation, an exact verified detached closure and the original workspace
   expectation and request key. Only M1b can advance the cursor. If the source
   changes after a completed observation, persist that observed version
   under the original argument identity or require a new observation and
   request. Never reuse an existing key for new bytes or infer a completed
   capture from a readable object or pending root.

Operate on one byte component at a time. Reject empty components, dot,
parent, slash/NUL injection, and absolute child paths before any native call.
Enforce the M1a tree-name constraints and per-directory `fpathconf`.
Reserve `.yeokcham` and `.yeokcham-v2` components and exclude root
`.git`; specify and test exact ignores before extending the subset.
Bind a separately provisioned workspace root to a trusted opened parent and
its exact child name. Recheck the association, the root and the selected
parents, and refuse symlinked, replaced, ambiguous or unsupported roots.
Refuse an OCaml store marker at the root or in a binding ancestor and
refuse overlap with another managed root. Place detached staging outside
the observed tree. Restrict observation to a local, case-sensitive,
allowlisted mount.
Check directory flags and refuse a capability error or casefold.
Avoid crossing a mount even when device and inode match, as demonstrated by
case 29. Exclude aliased workspace/store placements. As a conservative
first policy, refuse multi-linked regular files and repeated directory
identities in the observation scope. Capturing bytes does not encode
hardlink topology.

Python `os` supports dir_fd operations, descriptor reads and stats,
raw names, independent `open(".")`, exclusive creation, and file/directory
fsync. A small reviewed Linux binding is appropriate for `openat2` and
verified mount/procfs checks. `renameat2` with explicit flags can use the
glibc wrapper through a narrowly reviewed ABI or a header-built binding.
Pass through and classify the kernel error, with no ordinary rename or
recursive-copy fallback. The scratch C code is a capability probe.
[Python os](https://docs.python.org/3.14/library/os.html) ·
[Linux open](https://man7.org/linux/man-pages/man2/open.2.html) ·
[Linux openat2](https://man7.org/linux/man-pages/man2/openat2.2.html) ·
[Linux readlinkat](https://man7.org/linux/man-pages/man2/readlink.2.html) ·
[Linux renameat2](https://man7.org/linux/man-pages/man2/rename.2.html)

## Publication and application boundary

A future absent-only install needs a private same-mount stage with verified
tree bytes and attributes, file fsync, bottom-up directory sync, and
exclusive publication by `RENAME_NOREPLACE` anchored to the verified
destination parent. After the syscall, re-open the installed name, verify
stage identity and complete bytes, verify parent/root membership, and sync
all affected directories before reporting durability. An existing empty
directory refuses. If the parent moves, post-checks can reveal that the
mutation landed in the displaced parent. Both trees and the recovery
evidence need preservation. Any sync or post-check failure after the
syscall is an uncertain or interference outcome. File sync alone does
not cover an entry created or renamed in its containing directory.
[Linux fsync](https://man7.org/linux/man-pages/man2/fsync.2.html)

In-place application additionally needs preservation of displaced originals,
a plan bound to exact safety and target roots, verified action ownership
and progress, revalidation of both installed and retained results, and
recovery decisions that preserve later external changes. Exchange in case 25
only demonstrated an atomic namespace primitive. An old descriptor remained
able to mutate the retained inode. Bytes and ownership must be independently
checked before counting a step complete. Whether the durable roots and
journals are sufficient remains an implementation qualification gate.

Casefold-positive and unsupported-platform behavior, production ABI, full
staging/install and in-place protocols, controlled ENOSPC and real failing
Btrfs writeback, reboot/power interruption, storage-controller behavior,
and macOS/Windows are **NOT QUALIFIED**. Cross-device and same-device mount
refusals cover the demonstrated Linux cases. No process kill supplies evidence
about controller caches or physical power loss. Scratch results contribute
evidence to N05, N08–N13 and N15, with fidelity witnesses for N14. No full
executor test in N01–N15 is counted as closed.

## M2.1 scope and test-first gate

- Start with one explicit manual request against a separately provisioned
  native root, serial observation within that workspace, and a private
  detached verified object closure. Native observation and the content
  resolver should be testable without opening SQLite. Test raw names, files,
  modes, symlinks, empty dirs, exclusions, byte fidelity and the cross-mount,
  alias and replacement refusals above before implementing the adapter.
- Test stationary, unstable, wrong-root, ignored, unsupported-kind,
  oversized and interrupted observation before implementation. Refuse an
  ambiguous or unsupported scope before publishing capture metadata.
  Include bounded streaming and private staging limits. A staged or
  incomplete observation has no cursor side effect. Emit typed status
  and refusal with enough evidence to distinguish unavailable, unstable,
  unsupported, stale and uncertain outcomes.
- From a completed observation, reuse `PrivateStore.workspace`,
  `append_capture`, `inspect_request` and `read_snapshot`. Freeze the
  expected state, exact snapshot and key for one request. Keep potentially
  long IO out of SQL. Resolve uncertain acknowledgments by original key.
  The existing schema suffices for an explicit call with a trusted root
  binding and verified closure. It cannot persist that binding or an
  application intent. Any future durable attachment requires separate
  schema and identity review.
- Add exec-process tests using barriers for three independent workspaces,
  one unstable or interrupted observer, another successful capture, and
  a third historical reader. For one workspace, revalidate ownership
  after observation and rely on M1b CAS to refuse a stale append. If one
  continuous same-workspace lease spans observation through commit, add a
  reviewed internal ownership handoff. Reacquiring the already-held M1b
  workspace flock through `append_capture` is unsafe as a composition
  technique. A workspace label provides no isolation or security authority.
- Keep observe-only entry points separate from any future executor.
  Keep physical worktree restoration, checkout, attachment of arbitrary
  roots, copy-out, watchers and collaboration outside M2.1. Later
  application must establish a workspace-local exclusion and explicit
  recovery state before allowing capture. The current storage schema has
  no such application records.

## Reproduction and regression

Run from the repository with the prior qualified Python environment.
Choose fresh external Btrfs and tmpfs directories. Compiled artifacts
and all fixture trees stay external.

```sh
cc -O2 -Wall -Wextra -Werror -fPIC -shared \
  python/tests/native_qualification/probe_linux.c -o "$SCRATCH/native-probe.so"
python3 -B python/tests/native_qualification/native_probe.py \
  "$SCRATCH/native-probe.so" "$BTRFS_FIXTURES" "$SCRATCH" > "$SCRATCH/native.jsonl"
PYTHONPATH=python/src PYTHONDONTWRITEBYTECODE=1 \
  HYPOTHESIS_STORAGE_DIRECTORY="$SCRATCH/hyp" "$QUALIFIED_PYTHON" -m pytest \
  python/tests -p no:cacheprovider --basetemp="$BTRFS_FIXTURES/regression" \
  --hypothesis-show-statistics --junitxml="$SCRATCH/regression.xml"
```

The compile and native run exited 0. Pytest exited 0 with **479 passed,
zero failed or skipped in 421.39 seconds**. Fourteen Hypothesis properties
reported **500 passing examples** in total. The existing M1b test suite ran
on local Btrfs and exercised the prior store profile. Matrix JSONL,
JUnit and detailed test logs were recorded in the disposable scratch
directory `/tmp/yeokcham-m20-smitmwho`.

Final inspection checked the SHA-256 and mode of all 561 pre-existing
tracked or visible untracked paths. All matched the starting manifest.
HEAD and the index were unchanged, and Git listed only the two reports
and four standalone qualification sources as additions. Ruff lint and
format checks, the repository documentation-link check, and whitespace
checks passed. The harnesses have no new Python package dependencies.
