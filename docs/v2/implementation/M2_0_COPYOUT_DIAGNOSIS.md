# M2.0 historical copy-out diagnosis

**BASELINE-COPYOUT-20261116 — REPRODUCED · ROOT_CAUSE_SUPPORTED.**

The historical OCaml binary reproduced the refusal in both fixture shapes.
An independent inventory found the entire installed tree matched the selected
checkpoint. A trace of the exact binary then showed a corrupted *returned
symlink string* inside the verifier. The kernel supplied the right bytes.
The readlink C stub retained a raw pointer into an OCaml string across a
second allocating call. When that allocation moved the rooted source, the
copy read the forwarding word from the old location. The observed verifier
compared those corrupt bytes to the correct symlink target and refused.
This explains the fresh reproductions. The original historical process
memory is unavailable. Production copy-out remains gated on a separately
authorized correction or isolation and full N01–N15 verification.

## Historical identity

| Item | Evidence |
| --- | --- |
| Earliest recorded failing source | `fba3daa945eb2c670595ab660576be30b8b3d380`. The UI closeout also recorded it at `8a0c768fefc3bdb9b62d92250de4b6e180bd3f16`. [2026-11-16 receipt](../../implementation/results/cli-graph-20261116.json) · [implementation ledger](../../IMPLEMENTATION_PROGRESS.md) |
| Original invocation | `DUNE_JOBS=1 make ci` exited 2. Dune's runtest alias runs `python3 test_benchmark_runner.py` with the V1 binary and the three benchmark tools declared as dependencies. The observed failing unittest was `RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs` for both shapes. [Dune rule](../../../test/dune) · [original test](../../../test/test_benchmark_runner.py) |
| Build and environment | Receipt records OCaml 5.5.0, Dune 3.25.0, ocamlformat 0.29.0, the P1 environment file and a Git archive with an independent build directory for the earliest revision. Historical `TMPDIR=/tmp/dune_87d263_actions`. The historical mount options, complete action environment, and contents of those exact per-test temporary directories were unavailable. |
| Recovered binary | Cache `~/.cache/yeokcham-cli-graph-20261116/baseline-build/default/bin/yeokcham_v1.exe`, ELF Linux x86-64, build ID `3031c59ac091ff2d2727352a8774de43f4dc542e`, SHA-256 `b5b8528d5aee3ada78dc4bd5c24fd702aa57a0b33dd5d9050551e8e3f0d0aca5`. Its dependencies resolved on the current host. |
| Recovered receipt inputs | `baseline-comparison.json` SHA-256 `0a94472d65a81e0bcaccad8493e597e445d8ab3eebc5abfe145ef75587b5eea9`. `baseline-copyout-02.log` SHA-256 `915048d72e85148894561198ea824b1194da85e65f9b6d453e6f63725e04ebcd`. Both matched the committed receipt and the log contained the two original exit-8 refusals. |
| Detector | `verify_checkpoint` copies only metadata to a disposable `source`, creates an empty `restored`, calls `restore --yes --root … --checkpoint … --destination …`, then compares the complete fixture manifest. The historical CLI refused before this last manifest check. [Runner](../../../tools/benchmark_runner.py) |

The fixture is generator v1, suite `asset`, seed 1, depth 3, fanout 8,
no designated large file, 8,192 total content bytes across eight 1,024-byte
files, and `--attributes`. Attributes add a real empty directory, a
symlink, and one executable file. Both main histories have five nodes.
The linear history extends the previous node. The branching run navigates
to node 0 before constructing later alternatives and repeats the initial
content at node 3. The original test uses one cold iteration, one warmup and
two warm iterations and interrupts the first sample `save` when reached.
It checks preservation of completed sample records and refusal on modified
inputs at resume. The two historical refusals appeared earlier, during
verification of an initial-capture sample with a fresh one-node capture
after all five main-history checkpoints verified. Both specified checkpoint
`c12b2f7fbfe29e53e4accdf369c4c02b1edf44c2f431bcd9a8b3dfb0079089f3`.
[Fixture generator](../../../tools/benchmark_fixture.py) ·
[Benchmark runner](../../../tools/benchmark_runner.py)

## Reproduction and contrasts

Source was exported with `git archive fba3daa…` into an external temporary
directory. The matching binary was copied into the export. A scratch shim
answered only `git rev-parse HEAD` when the archived runner asked from the
export; the historical test already mocks the source comparison.
Test source and assertions, CLI arguments, and native library files were
retained. The archived binary ran against current system libraries. The
primary Dune action was approximated from the recorded environment and
recreated TMPDIR. No historical build was attempted because the machine
lacked the historical OCaml compiler, Dune and configured opam switch.
The cached P1 environment's opam program reported that no switch was set.

| Run | Exit and observation |
| --- | --- |
| Original focused test, recreated literal `/tmp/dune_87d263_actions` on current tmpfs, cached P1 variables and `DUNE_JOBS=1` | Unittest exit 1, two subtest errors, each CLI exit 8 with `installed target bytes changed at "restored" after application`, 2.339 s. Plain environment at the same path independently gave the same two failures in 2.303 s. |
| Original focused test, private nested tmpfs with the same final directory name | Exit 0 with both shapes and interruptions, 19.695 s in the initial run. Also exit 0 under the cached P1 variables, 13.517 s. |
| Original focused test, new Btrfs TMPDIR | Exit 0, both shapes, 65.199 s. Different filesystem, parent path length and timings make this an additional contrast. |
| Original focused test with external post-failure inventory, exact literal TMPDIR | Exit 1, both shape errors in 3.187 s. The original CLI executed normally. After it returned exit 8 the diagnostic independently read the still-present destination, stage, journal, and source before Python's temporary-directory cleanup. |
| Direct archived CLI contrast | Five retained checkpoints and a fresh initial-capture sample for each shape on Btrfs and tmpfs. The first run was **24/24** successful. Final rerun found **24/24** exact installed trees and matching retained empty inodes, with **23/24** CLI successes. The linear fresh sample on tmpfs independently reproduced exit 8, with the same checkpoint, exact installed bytes, target inode 409018 and original inode 409013 retained. |
| Archived destination-restore control test | Exit 0 in 0.251 s. The existing test rejects deliberate post-restore corruption through its independent runner fidelity oracle. |
| GDB trace with unchanged inferior executable | Initial scratch trace observed a moved source and corrupt returned string immediately before each failing shape's refusal. A passing traced call kept the source in place and returned exact bytes. The reusable trace independently observed the corrupted result prefix equal the relocated buffer pointer. |
| Original focused test at literal TMPDIR with `OCAMLRUNPARAM=s=1M` | Exit 0 for both shapes in 14.198 s. The larger minor heap is a diagnostic perturbation. |

The benchmark runner, fixture generator, test, native snapshot stubs and
Safe_apply have identical Git blobs at the archived revision and the
audited HEAD. Runtime diagnosis used the verified archived executable.

The direct harness initially counted an unrelated retained undo slot in
branching replicas as a duplicate. Its corrected check identifies the
retained slot by the pre-opened destination inode and lists it with a
fresh descriptor. The exact byte oracle and CLI exit checks were retained.

A path/runner difference can change the reproducibility of this failure.
Both filesystems and multiple TMPDIR spellings can hold the exact installed
tree. The final direct failure confirms that the literal TMPDIR and runner
are each unnecessary for a reproduction. The controlled trace identifies what made the failing *predicate*
false. No claim about which environmental difference selected the precise
allocation timing is required for that diagnosis.

## Independent preservation evidence

In both fresh post-failure observations the intended checkpoint ID, the
copy-out plan safety ID and the plan target ID were the same 32-byte
snapshot identity shown above. The expected and actual ordered fixture
manifests had SHA-256
`969a9861f211bda77efa5d74158ff60bb11ce322c063ad455ed551e2022d319f`.
There were 34 entries outside the root: eight regular files, 25 directories,
and one symlink. The empty directory was present. The only executable
regular file was `d0-000/d1-000/d2-000/file-0000000.ts` (0755).
Its expected and installed SHA-256 was
`8ba3e73e1ebd0d58fe058c04ce95f147079799efa2f9b299ffe2a48050b6d755`.
The live sample had deliberately been edited and SHA-256 was
`b184c26cbcb1a952c713e3b01e5260c185782fd0ea5f6dffca3d5fbb45130799`.
Its starting bytes were ASCII `// fixture 0 block 0 token …` in the
expected and installed versions and ASCII `b858670a386431f274db0889b0b42e01…`
in the modified live sample. The exact full hex, sizes, hashes, mode,
timestamp and identities for every installed and live file are in the
external run evidence. The symlink target was exactly
`d0-000/d1-000/d2-000/file-0000000.ts`.

| Fresh failure | Descriptor/path state after CLI exit 8 |
| --- | --- |
| Linear | Device 55. Destination started as empty inode 339439. The prepared staged target inode 339446 was now installed under `restore-verification-*/restored`. Original inode 339439 was still empty and retained at `source/.yeokcham/restore-staging/8d589c6cfcfc56eb5a301accdee2e7f4c7fdef9440862f840e5c440bcada078e/0`. |
| Branching | Device 55. Original empty inode 341765 was retained at `source/.yeokcham/restore-staging/1b66cbad285d8a5e6090c31c9f70b80f68a620aa30fc6a01d4ced5fa356a5610/0`. Prepared staged target inode 341772 was installed under `restore-verification-*/restored`. |

Independent CBOR decoding of each `plan.cbor` matched the planned pre/post
inode pair to the independent stat records. Each journal held the exact
operation's generation 0 Prepared and generation 1 Applying. Neither
contained Materialized or Published. The archive's `Safe_apply.apply_with`
verified the precondition, exchanged with the existing empty destination,
synced both affected directories and re-ran `checked`. The error occurred
in its post-application full-content validation. It is a conservative
refusal after physical installation. This does not confer completion.
[Safe apply](../../../lib/yeokcham_v1_local_service/safe_apply.ml) ·
[V1 restore journal](../../../lib/yeokcham_v1_restore_journal/yeokcham_v1_restore_journal.ml)

## Cause discrimination

The exact source call in `yeokcham_scan_readlink_at` passes
`String_val(buffer)` to `caml_alloc_initialized_string` after the kernel
fills the rooted source. In the historical executable
`caml_alloc_initialized_string` calls `caml_alloc_string` and then uses
`memcpy` from the raw pointer saved before allocation. GDB 18.1 recorded
the kernel-filled bytes immediately before the allocator call, then read
the returned string and the potentially updated rooted source just after
the call. In the failing case, the source moved. Its rooted bytes still
matched the kernel result and the independently read target. The returned
string's first eight bytes differed and equaled the pointer to the moved
source. In passing calls the pointer and bytes stayed equal. This evidence
supports a stale interior pointer across a moving allocation in the stub.
The OCaml C FFI rooting rule for values allows the collector to update a
registered value and does not update a separately copied C address.
[Native C stub](../../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c) ·
[OCaml C interface, GC rules](https://ocaml.org/manual/5.4/intfc.html)

| Candidate explanation | Discriminating test and outcome |
| --- | --- |
| Real file or link mutation, wrong fixture hash, wrong mode, wrong checkpoint | Independent full inventory and raw readlink, with exact expected checkpoint and live source mutation. The complete installed bytes and attributes matched in both observed failures. The traced kernel link bytes also matched. |
| Wrong stage, source or destination identity, old destination descriptor pointing at installed output, or wrong undo selection | Decode the prepared plan and phases, stat actual inodes at original/installed/retained paths and compare known snapshot and manifest. The designated target was installed and the empty original retained. Direct contrast also held the original descriptor across exchange and independently inspected the old inode. |
| Directory enumeration or a native timestamp changed a legitimate comparison | Record kernel target and allocator values during the failing check. The decisive failure was a symlink string mismatch with a relocated source. The Btrfs stale-iterator observation from Track A is independent. |
| TMPDIR and runner sequencing | Change TMPDIR and the environment independently, keep test and binary exact, and trace the failing fresh node-0 verification. Literal TMPDIR reproduces with and without cached P1 variables. Nested tmpfs and Btrfs runs pass. The trigger sensitivity is observed and the corruption mechanism is directly traced. |
| Old open descriptor writes or post-install external interference | No external writer was launched for these fixtures. Independent after-error bytes and traced kernel bytes matched. The separate native test demonstrates why future recovery still has to check the bytes of a retained original and installed target. |

A separately authorized OCaml repair should allocate a rooted destination
and reacquire the rooted source pointer *after* allocation, or copy via
nonmoving native memory. Require an allocator-pressure symlink test with
exact bytes, both historical runner shapes, the direct fixtures, deliberate
installed-byte mismatch and complete CI on the repaired revision. Heap
or TMPDIR tuning supplies diagnostic evidence only. For Python, preserve
full-byte checks and separately qualify the proposed absent-only ownership
and recovery protocol. Diagnosis alone supplies neither an OCaml fix nor a
production-ready Python copy-out.

## Reusable evidence

The [Python copy-out probe](../../../python/tests/native_qualification/copyout_probe.py)
supports a direct contrast, focused original-test invocation with post-failure
inventory, and focused invocation using the
[GDB readlink trace](../../../python/tests/native_qualification/trace_copyout_readlink.gdb).
Output is recorded outside the repo. The tracing offsets apply only to the
hash-pinned x86-64 executable. GDB traces contain synthetic paths and process
data for diagnostic use.

```sh
git archive fba3daa945eb2c670595ab660576be30b8b3d380 | tar -x -C "$EXPORT"
install -m 0555 "$CACHED_HISTORICAL_BINARY" "$EXPORT/bin/yeokcham_v1.exe"
# For focused mode run with cwd "$EXPORT", TMPDIR set to a fresh external
# directory and a rev-parse HEAD shim scoped to that export and command.
python3 -B "$CHECKOUT/python/tests/native_qualification/copyout_probe.py" \
  "$EXPORT" "$EXPORT/bin/yeokcham_v1.exe" "$NEW_EVIDENCE_DIR"
python3 -B "$CHECKOUT/python/tests/native_qualification/copyout_probe.py" \
  "$EXPORT" "$EXPORT/bin/yeokcham_v1.exe" "$NEW_FOCUSED_DIR" --focused
python3 -B "$CHECKOUT/python/tests/native_qualification/copyout_probe.py" \
  "$EXPORT" "$EXPORT/bin/yeokcham_v1.exe" "$NEW_TRACED_DIR" \
  --focused --trace-readlink
```

Original receipts, expected fixtures, source, accepted performance data and
live stores were preserved. Run logs, exact bytes and native evidence were
recorded under disposable `/tmp/yeokcham-m20-smitmwho` and
`/home/gongahkia/yeokcham-m20-fixtures-x557v9e1`. Further native scope and
M2.1 prerequisites are in [Track A](M2_0_NATIVE_QUALIFICATION.md).
