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
- Backend key generation.
- Encryption and decryption.
- Storage policy selection.

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

The local remote-helper integration tests build repositories with branches and annotated tags, import them, run `git ls-remote`, clone through `yeokcham::<absolute-path>`, compare checkout bytes and reachable object IDs, and run `git fsck --full --strict`. They prove that an unchanged effective ref state reuses a validated snapshot pack, that a corrupted cached pack index is rebuilt before use, and that a later ref transition creates a separate validated cache entry. They also run `yeokcham sync`, fetch an updated branch, prune a deleted branch, and check the resulting checkout and fsck. The push test covers fast-forward main updates, branch creation and deletion, create-only tags, forced tag and branch rejection, canonical verification, and a fresh clone after accepted pushes. It also verifies debug telemetry does not emit the requested source location. GitHub Actions builds checksum-pinned Git 2.54.0 and 2.55.0 from upstream source archives, then runs both remote-helper tests against each; update both entries when replacing the maintained-version matrix.

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
