# Testing and Benchmarks

## 1. Testing philosophy

Yeokcham must prove three things separately:

1. **Git correctness** — exported and served repositories are valid Git.
2. **Storage correctness** — manifests, chunks, segments, indexes, and refs survive failure.
3. **Performance value** — Yeokcham improves defined workloads without hiding regressions.

## 2. Test layers

### Unit tests

Cover:

- Object-ID calculation.
- Manifest encoding and decoding.
- Chunk boundary determinism.
- Compression round trips.
- Segment parsing.
- Index lookup.
- Ref event validation.
- Ed25519 ref-event signing, wrong-key rejection, and signature tampering with a recomputed checksum.
- Backend key generation.
- Filesystem backend create-only writes, bounded range reads, paginated listing, deletion, resumable completion, and symlink rejection.
- Backend fault injection before delegation, dynamic backend wrapping, and metrics counts for successful and failed operations plus transferred bytes.
- Encrypted backend ciphertext-only filesystem storage, plaintext round trips, domain-separated key derivation, wrong-key rejection, tamper rejection, associated-data mismatch rejection, and secret-redacted diagnostics.
- Recovery-key export/import, wrong-passphrase and tamper rejection, fixed Argon2id parameter validation, and encrypted recovery material redaction.
- Clean-machine-style encrypted repository recovery from backend plus imported recovery export, recognized-staging exclusion, post-restore Yeokcham verification, and `git fsck` of a fresh Git export.
- Drive Desktop OAuth PKCE URL construction, loopback state binding, malformed-token rejection, bounded transport responses, and credential redaction.
- Drive credential persistence, retrieval, deletion, missing-entry handling, and refresh-token redaction through an injected store seam; unit tests never access the user credential store.
- Drive CLI parsing for interactive and fixed-port forwarded authorization; integration tests do not create credentials or make network calls.
- Drive refresh exchange with the stored credential, a fixed token endpoint, `refresh_token` grant parameters, access-token lifetime validation, and no refresh-token replacement requirement.
- Encryption and decryption.
- Storage policy selection.
- In-memory decrypted-chunk and reconstructed-object cache bounds, corruption fallback, manifest/reference binding, and reuse after a valid cache fill.
- Parallel source-object read ordering, invalid worker bounds, serial/parallel import equivalence, final repository verification, conventional export, and C Git fsck.

### Property tests

Generate arbitrary:

- Byte blobs.
- File versions.
- Commit DAGs.
- Tree shapes.
- Ref updates.
- Segment layouts.
- Journal orderings.
- Backend failure schedules.

Important properties:

- Reconstructed bytes equal original bytes.
- Reconstructed Git object ID equals original ID.
- Import then export preserves reachable object set.
- Ref transactions are atomic.
- Applying valid journal events is deterministic.
- Duplicate immutable uploads are harmless.
- GC never deletes reachable records.
- Compaction preserves object resolution.
- Cache eviction does not change results.

### Differential tests

Compare Yeokcham with C Git:

- Reachable object IDs.
- Commit and tree traversal.
- Pack import results.
- Clone contents.
- Fetch updates.
- Push ref results.
- `git fsck --full`.
- Archive or checkout bytes where relevant.

### Integration tests

Test:

- `git clone yeokcham://...`
- `git fetch`
- `git push`
- Branch creation and deletion.
- Tags.
- Merge commits.
- Rebase-generated histories.
- Large blobs.
- Unicode paths.
- Executable bits.
- Symlinks.
- Empty files and directories represented through trees.
- Submodules, initially as unsupported or opaque depending on implementation.
- Interrupted remote operations.

The local remote-helper integration tests build repositories with branches and annotated tags, import them, run `git ls-remote`, clone through `yeokcham::<absolute-path>`, compare checkout bytes and reachable object IDs, and run `git fsck --full --strict`. They prove that an unchanged effective ref state reuses a validated snapshot pack, that a corrupted cached pack index is rebuilt before use, and that a later ref transition creates a separate validated cache entry. `yeokcham cache inspect` reports the generated snapshot cache. `yeokcham cache verify` succeeds for that cache, then fails after index corruption before the helper rebuilds it. A caller-selected cache-byte limit removes the least-recently-used of two snapshot caches. `yeokcham cache clear` is tested as idempotent and followed by repository verification; it refuses a symlinked cache path without touching its target. Separate `blob:none` and `blob:limit=1` clones verify C Git's promisor configuration, prove that the initial no-checkout clone retains an unrelated historical blob as promised, then hydrate only the current blob through the helper during checkout and run strict fsck. A cone-mode sparse checkout configured before checkout hydrates its selected current path while a current blob outside that cone remains promised. They also run `yeokcham sync`, fetch an updated branch, prune a deleted branch, and check the resulting checkout and fsck. The push test covers fast-forward main updates, branch creation and deletion, create-only tags, forced tag and branch rejection, canonical verification, a retry with intentionally stale local remote-tracking state after an accepted push, and a fresh clone after accepted pushes. The retry rediscovers canonical refs and leaves the journal at one event for that transition. It also verifies debug telemetry does not emit the requested source location. GitHub Actions builds checksum-pinned Git 2.54.0 and 2.55.0 from upstream source archives, then runs both remote-helper tests against each; update both entries when replacing the maintained-version matrix.

The native HTTP V1 integration test imports a real Git fixture, creates a private generated token file, rejects absent and incorrect credentials, then serves health, ref discovery, and a commit body through loopback Bearer authentication. It opens the repository browser through browser-compatible Basic authentication, verifies HTML contains branch/object metadata, and verifies authenticated commit/tree pages show escaped fixture content and reject a verified object of the wrong kind. Parser tests accept valid commit/tree encodings, including continued commit headers, and reject malformed IDs or unsafe tree names. It rejects request bodies and non-GET methods and proves a `0.0.0.0` bind fails. A separate token-file test verifies generated lowercase-hex encoding and permissions, redacted diagnostics, and rejection of broad-permission, malformed, symlinked, and existing paths. It does not claim Git smart-HTTP compatibility, public-listener safety, blob browsing, pagination, or browser behaviour beyond the tested static pages.

### Crash-injection tests

Inject failure after every durable mutation boundary:

- Segment staging.
- Segment seal.
- Index write.
- Manifest write.
- Backend upload.
- Journal append.
- Local database commit.
- Cache update.
- GC copy.
- GC delete.

After restart, the repository must be:

- Old valid state.
- New valid state.
- Detectably incomplete but recoverable.

Never silently inconsistent.

The implemented local ref-transaction harness runs each bootstrap-upgrade and ref-event mutation through a fault-injecting filesystem wrapper. It aborts after staging-file creation, write, synchronization, bootstrap replacement, event hard-link publication, directory synchronization, and staging cleanup; each abort reopens the repository and verifies its ref state is either the complete predecessor or complete successor. Immutable object ingestion occurs before this transaction and may leave unreachable records after interruption, but it cannot acknowledge a ref update.

### Fuzz tests

Targets:

- Pack parser.
- Delta resolver.
- Segment parser.
- Index parser.
- Manifest parser.
- Ref event parser.
- Encrypted envelope parser.
- Remote-helper command parser.
- HTTP endpoints when added.

The current `fuzz/` cargo-fuzz package covers canonical decoding, `YKSG` segment reading, `YKIX` index decoding, blob/metadata/chunk manifests, ref names/snapshots/events, and remote-helper command parsing. Run `make fuzz-smoke` for 1,000 bounded executions per target, or `scripts/fuzz-smoke.sh <runs>` for a longer local campaign; it requires the Rust nightly toolchain. Fuzzer corpora and crash artifacts are local-only; minimized reproductions must become deterministic regression tests before committing.

Current-HEAD sparse hydration is unit-tested against an imported real Git repository: selected current blobs enter the process cache, excluded current blobs do not, absent exact paths are reported, and a byte budget below the current commit body prevents all reconstruction. These are correctness tests only; no daemon speed claim is recorded until the daemon and remote-helper consume this cache in one measured workload.

### Compatibility fixtures

Maintain fixtures for:

- Repository format versions.
- Old Git versions where practical.
- SHA-1 repositories.
- Corrupted objects.
- Truncated packs.
- Deep delta chains.
- Large path sets.
- Non-UTF-8 path bytes where platform support permits.
- Alternate and unusual Git histories.

## 3. Benchmark harness requirements

Every run records:

- Yeokcham commit.
- Git version.
- Rust version.
- OS and kernel.
- CPU.
- RAM.
- Storage device.
- Filesystem.
- Available disk space.
- Cache state.
- Backend.
- Network conditions.
- Repository fixture checksum.
- Configuration.
- Number of repetitions.
- Median, p95, and p99 where meaningful.
- Peak RSS.
- CPU time.
- Wall-clock time.
- Bytes read and written.
- Network requests and transferred bytes.
- Final storage size.

## 4. Benchmark baselines

Use:

- Current maintained C Git.
- C Git with relevant maintenance features.
- Git partial clone.
- Git sparse checkout.
- Git LFS for large-file cases.
- Scalar for supported large-repository cases.
- Xet-style tooling where a comparable workflow exists.
- Plain compressed archive or backup where relevant.

Do not benchmark only against an intentionally poor Git setup.

## 5. Workload fixtures

### W1 — Tiny files

- 100,000 files.
- 1,000,000 files.
- Small edits across 1%, 10%, and 50% of files.
- Deep directory trees.
- Wide directory trees.

Measure:

- Import.
- Clone.
- Status where Yeokcham daemon exists.
- Checkout.
- Index size.
- Storage overhead.
- Peak memory.

### W2 — Long source history

- 100,000 commits.
- 500,000 commits.
- Regular branching and merging.
- Rebase-heavy variant.

Measure:

- Import.
- Fetch negotiation.
- Clone metadata.
- Log traversal.
- Export.
- GC.
- Ref operations.

### W3 — Large changing binary

For example:

- 4 GiB file.
- 100 versions.
- Each version modifies 1%, 5%, or 20% of bytes.
- Variants with shifted insertions to test content-defined boundaries.

Measure:

- Incremental storage.
- Upload bytes.
- Reconstruction time.
- Cache effect.
- CPU cost.
- Comparison with Git LFS and ordinary Git.

### W4 — Already-compressed assets

- ZIP.
- JPEG.
- MP4.
- Compressed model artefacts.

Measure whether Yeokcham correctly avoids wasteful recompression and pathological chunk overhead.

### W5 — Monorepo sparse workspace

- Large commit graph.
- Hundreds of thousands of paths.
- User requests 1%, 10%, and 50% of current paths.

Measure:

- Time to usable workspace.
- Bytes transferred.
- Later path hydration.
- Warm and cold cache.

### W6 — Drive backend

Simulate:

- Cold start.
- Warm metadata cache.
- High latency.
- Rate limiting.
- Interrupted multipart upload.
- Stale listing.
- Multiple devices.

Measure:

- API calls.
- Time to first checkout.
- Recovery.
- Reconciliation.

### W7 — GitHub mirror

The publication-preview integration test imports a repository with an annotated tag, asks `yeokcham github plan --show-objects` to reconstruct its selected refs, and checks that the reported object IDs and count exactly equal the selected exported Git graph without printing object bodies. The publication test uses a real local bare C Git remote: it publishes only configured main/tag refs, proves an unselected private branch is absent, confirms remote IDs, and verifies that all checkpoints persist together. A pull-request-branch test publishes one selected local branch to a named remote branch, proves the same-name remote branch is absent, rejects an unselected source, and verifies the explicit checkpoint mapping. The fetch fixture force-rewrites remote main, adds a selected remote-only branch, verifies both graphs are imported, records the unequal remote checkpoint, and proves canonical refs remain unchanged. It then explicitly resolves remote main, verifies exactly one checked journal event, the new canonical ID, and the repaired equal-ID checkpoint. Policy tests require `--apply`, restrict transport parsing, produce a force lease only for an exact recorded branch checkpoint, and reject tag replacement. No test contacts GitHub or a user credential helper/agent.

GitHub documents pull requests as comparisons between two branches and supports selecting a head branch; Actions workflow `push` filters operate on branch and tag ref names. Yeokcham's named PR-branch publication and selected standard ref pushes therefore provide the Git transport required for ordinary PR/CI workflows. This is bounded local-bare plus documented-protocol evidence, not a live GitHub-account integration test. See [GitHub pull-request creation](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-a-pull-request) and [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

Measure:

- Initial publication.
- Incremental publication.
- Remote-only commits.
- Divergence detection.
- Full export and republish.

## 6. Initial benchmark hypotheses

These are not claims.

### H1

Content-defined chunking substantially reduces storage growth for large files with localised modifications compared with whole-file external storage.

### H2

Aggregating tiny blobs avoids the per-object overhead that a naive chunk store would create.

### H3

Metadata-first clone reaches a useful sparse working set with materially fewer transferred bytes than a full clone.

### H4

A warm local cache can hide much of the latency of a dumb cloud backend.

### H5

Pack synthesis may be slower than serving precomputed Git packs unless packs are cached.

### H6

Yeokcham may lose to modern Git on small, source-only repositories; this should be reported rather than hidden.

## 7. Release gates

### Prototype gate

- Import/export round trip passes `git fsck`.
- Local clone produces identical checkout.
- All object IDs match.
- At least one chunked blob fixture works.
- Benchmark harness produces reproducible machine-readable output.

### Alpha gate

- Push is crash-safe.
- Corruption is detected.
- Encrypted local backend works.
- Drive backend passes interruption tests.
- Key recovery works on a clean environment.

### Beta gate

- Partial retrieval works for documented workflows.
- GitHub mirror conflict handling is tested.
- Published benchmark matrix includes wins and losses.
- Fuzzing has run continuously in CI or scheduled infrastructure.
- Repository format and migration policy are documented.

## 8. Suggested tooling

- `cargo test`
- `proptest`
- `cargo fuzz`
- `criterion` or a custom process-level harness
- `hyperfine` for reproducible CLI timing
- `git fsck --full`
- `git verify-pack`
- Fault-injecting backend wrapper
- Network shaping for remote tests
- Sanitised fixture generation scripts

Do not rely only on microbenchmarks. End-to-end process benchmarks are required.

The W5 harness is `scripts/benchmark-sparse-workspace.sh`. It times `git clone --no-checkout --filter=blob:none`, cone sparse selection of `app/`, and `git checkout main` as the usable-workspace boundary. Cold samples clear only Yeokcham's disposable snapshot-pack cache before every timed run; warm samples populate it once before timing. It records client `.pack` payload bytes as local remote-helper transport bytes and does not claim physical-network or OS-cache control.

The daemon harness is `scripts/benchmark-daemon.sh`. It runs a private Unix-socket daemon through V1 `ping` and orderly `shutdown`, recording launch-to-exit wall/CPU time and peak RSS with macOS `/usr/bin/time -l`. It measures daemon baseline overhead only; it does not claim a workload improvement.

The committed 2026-07-31 daemon baseline has five Apple M3 runs at commit `8439053`: 70 ms median launch-to-shutdown wall time and 5,931,008 B peak RSS. It establishes only V1 daemon control overhead on that machine.

The V1 daemon is opt-in and has no repository-format or cache-file dependency. Existing local import/export, remote-helper, cache, encrypted-recovery, and fixture round trips run in CI without starting it. Snapshot-pack cache reuse is verified by exact ref-state reuse plus strict `git fsck`; sparse current-path prefetch remains deterministic. An opt-in supplied canonical C Git cone sparse-checkout file can derive its recursive directory selection without worktree discovery.

Published loss case: for every current import, export, receive-pack, or remote-helper workload, starting V1 adds the measured 70 ms median process lifetime and up to 5,931,008 B RSS while contributing no work, because none of those paths connects to it. This is a baseline-overhead result, not a comparative workload claim; it must not be counted as a daemon improvement.

An explicit daemon sparse-prefetch configuration validates one Yeokcham repository plus either exact relative paths or one supplied regular canonical C Git cone sparse-checkout file, fills the bounded process cache and prebuilds the validated ref-state-keyed snapshot-pack cache at startup, and reruns after ref-snapshot, ref-journal, or exact sparse-checkout-file metadata changes. Its tests verify selected-only hydration, configuration-derived selection refresh, cache rehydration after a metadata change, and strict Git validation of the prebuilt pack cache. The daemon has no remote-helper IPC; the W5 daemon-prebuilt benchmark measures the later helper workflow separately from prewarm cost.

The committed 2026-07-31 W5 result has five clean Apple M3 samples at commit `4d31ebe`: 0.83 s median cold and 0.30 s median warm usable-workspace time, with 772 B median received helper pack payload in both states. It establishes this fixture's local cold/warm behavior only.

The same harness reproduced those medians and the 772 B payload on five clean samples at commit `a740b46`; the schema-validated files are `benchmarks/results/2026-07-31-sparse-workspace-a740b46/`. This closes same-host harness reproducibility only; results across hardware, filesystems, and Git versions remain separate measurements.

[`2026-07-31-daemon-prewarmed`](benchmarks/results/2026-07-31-daemon-prewarmed/) records five clean Apple M3 W5 samples at commit `4dc5abb`: cold helper checkout median 2.56 s and p95 2.76 s; daemon-prebuilt helper checkout median 1.10 s and p95 1.48 s; ordinary helper-warm median 1.01 s and p95 1.16 s. The daemon-prebuilt post-prewarm checkout is 57% lower at median and 46% lower at p95 than that cold case, with the same 772 B median received helper pack payload. It excludes daemon startup and prewarm cost and establishes this fixture's later-helper improvement only.

The import-read harness is `scripts/benchmark-parallel-import.sh`. It creates one deterministic packed single-revision 32 MiB binary fixture, compares one source-object-read worker with two, and records end-to-end local import wall/CPU/RSS/storage metrics. The immutable-record and ref-publication stages remain serial, so its result applies only to this fixture and host.

The five-sample [two-worker result](benchmarks/results/2026-07-31-parallel-import-two-workers/parallel.json) at dirty commit `ed7613b` reports a 1.91 s median versus 2.01 s serial, but worsens p95 from 2.05 s to 2.31 s. The [eight-worker result](benchmarks/results/2026-07-31-parallel-import/parallel.json) reports a 4.19 s median versus 2.05 s serial. Neither result changes the serial default; they are evidence for the deferred hashing-parallelism task.
