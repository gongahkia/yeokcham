# Architecture Decision Records

Yeokcham records architecturally significant choices as version-controlled ADRs. The initial ADR-001 through ADR-015 remain in [`DECISIONS.md`](../../DECISIONS.md). New records use this directory and continue at ADR-0016.

## When to write an ADR

Write one before implementing a decision that changes persistent formats, security or cryptographic design, compatibility boundaries, crate or service architecture, public interfaces, durability semantics, or major dependencies. Routine implementation details do not need an ADR.

## Process

1. Copy [`0000-template.md`](0000-template.md) to `NNNN-kebab-case-title.md` using the next unused four-digit number.
2. Set the status to `Proposed` and document context, considered options, the decision, consequences, invariants, compatibility, migration, security, recovery, and verification.
3. Submit the ADR with or before its implementation. Review must resolve correctness, recovery, format-version, and migration effects.
4. Change the status to `Accepted` or `Rejected` when the decision is resolved.
5. Do not rewrite an accepted or rejected decision. Later changes require a new ADR; mark the old record `Superseded by ADR-NNNN` and link both records.

Valid statuses are `Proposed`, `Accepted`, `Rejected`, `Deprecated`, and `Superseded by ADR-NNNN`. Numbers are never reused, including for rejected or superseded records.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-001–ADR-015](../../DECISIONS.md) | Accepted | Initial architecture decisions |
| [ADR-0016](0016-structured-error-contract.md) | Accepted | Use an opaque structured core error contract |
| [ADR-0017](0017-allowlisted-structured-tracing.md) | Accepted | Use allowlisted structured tracing |
| [ADR-0018](0018-versioned-benchmark-result-schema.md) | Accepted | Use a versioned JSON Schema for benchmark results |
| [ADR-0019](0019-repository-id-as-uuid-v4.md) | Accepted | Represent repository IDs as UUIDv4 bytes |
| [ADR-0020](0020-tagged-content-identities.md) | Accepted | Use tagged, configurable content identities |
| [ADR-0021](0021-segment-id-as-uuid-v4.md) | Accepted | Represent segment IDs as UUIDv4 bytes |
| [ADR-0022](0022-manifest-id-as-uuid-v4.md) | Accepted | Represent manifest IDs as UUIDv4 bytes |
| [ADR-0023](0023-device-id-as-uuid-v4.md) | Accepted | Represent device IDs as UUIDv4 bytes |
| [ADR-0024](0024-byte-preserving-git-refnames.md) | Accepted | Preserve validated Git refname bytes |
| [ADR-0025](0025-repository-format-compatibility.md) | Accepted | Version repository formats with required and optional flags |
| [ADR-0026](0026-canonical-binary-serialization.md) | Accepted | Use fixed-width canonical binary serialization |
| [ADR-0027](0027-local-repository-bootstrap.md) | Accepted | Store the V1 repository bootstrap as canonical binary |
| [ADR-0028](0028-gitoxide-repository-adapter.md) | Accepted | Open Git repositories through a minimal gitoxide adapter |
| [ADR-0029](0029-bounded-regular-ref-enumeration.md) | Accepted | Enumerate bounded regular Git refs by raw bytes |
| [ADR-0030](0030-bounded-reachable-git-object-traversal.md) | Accepted | Traverse bounded reachable SHA-1 Git objects |
| [ADR-0031](0031-bounded-git-object-body-reads.md) | Accepted | Read bounded Git object bodies before trust |
| [ADR-0032](0032-canonical-sha1-git-object-verification.md) | Accepted | Verify SHA-1 Git objects from canonical header and body bytes |
| [ADR-0033](0033-local-sqlite-object-metadata.md) | Accepted | Store verified Git object metadata in a local versioned SQLite database |
| [ADR-0034](0034-reject-unsupported-git-object-hashes-at-open.md) | Accepted | Reject unsupported Git object hash formats during repository opening |
| [ADR-0035](0035-versioned-whole-blob-record.md) | Accepted | Store verified small-slice blobs as canonical whole-blob records |
| [ADR-0036](0036-bounded-tiny-blob-aggregation.md) | Accepted | Aggregate bounded distinct tiny blobs in one canonical record |
| [ADR-0037](0037-fastcdc-v2016-chunk-boundaries.md) | Accepted | Use bounded FastCDC v2016 chunk boundaries |
| [ADR-0038](0038-bounded-uncompressed-codec-abstraction.md) | Accepted | Use a bounded uncompressed codec abstraction first |
| [ADR-0039](0039-append-only-segment-v1-writer.md) | Accepted | Write sealed append-only segments with create-new publication |
| [ADR-0040](0040-bounded-segment-v1-reader.md) | Accepted | Read and verify bounded `YKSG` version-1 segments |
| [ADR-0041](0041-rebuildable-per-segment-index.md) | Accepted | Use a rebuildable canonical index per immutable segment |
| [ADR-0042](0042-immutable-single-record-blob-manifest.md) | Superseded by ADR-0052 | Reference one verified segment record per blob manifest |
| [ADR-0043](0043-record-explicit-blob-storage-policy.md) | Accepted | Record explicit storage policy in new blob manifests |
| [ADR-0044](0044-immutable-local-blob-manifest-publication.md) | Accepted | Publish and scan immutable local blob manifests |
| [ADR-0045](0045-verify-local-manifest-record-resolution.md) | Accepted | Resolve manifest records through verified local segments |
| [ADR-0046](0046-reconstruct-exact-blob-body-bytes.md) | Accepted | Reconstruct exact blob bytes from a verified manifest record |
| [ADR-0047](0047-verify-final-reconstructed-git-blob-id.md) | Accepted | Verify final Git blob identity after reconstruction |
| [ADR-0048](0048-store-nonblob-git-objects-in-segments.md) | Accepted | Store and resolve non-blob Git objects through segments and direct manifests |
| [ADR-0049](0049-verify-published-immutable-local-storage.md) | Accepted | Publish and fully verify immutable local storage |
| [ADR-0050](0050-export-published-objects-as-loose-git-objects.md) | Accepted | Export published objects as standard loose Git objects |
| [ADR-0051](0051-immutable-local-ref-snapshot.md) | Superseded by ADR-0056 | Publish one immutable local ref snapshot before journals |
| [ADR-0052](0052-chunked-blob-descriptor-and-manifest-v2.md) | Accepted | Store chunked blobs through immutable descriptors and `YKMF` version 2 |
| [ADR-0053](0053-bounded-git-import-and-local-cli-workflows.md) | Accepted | Import Git repositories through bounded local CLI workflows |
| [ADR-0054](0054-compact-tiny-blob-group-manifests.md) | Accepted | Publish compact mappings for tiny-blob aggregations |
| [ADR-0055](0055-local-remote-helper-upload-pack-bridge.md) | Superseded by ADR-0056 | Serve local clone and unchanged fetch through an upload-pack bridge |
| [ADR-0056](0056-checked-local-ref-journal-and-fetch-updates.md) | Accepted | Append checked local ref transitions for fetch updates |
| [ADR-0057](0057-verified-local-snapshot-pack-cache.md) | Accepted | Cache verified full local snapshot packs, never negotiated responses |
| [ADR-0058](0058-staged-local-receive-pack-ingestion.md) | Accepted | Stage local receive-pack before publishing a Yeokcham ref transition |
| [ADR-0059](0059-ed25519-signed-ref-events.md) | Accepted | Add caller-supplied Ed25519 signatures to ref events |
| [ADR-0060](0060-fault-injected-ref-transactions.md) | Accepted | Fault-inject local bootstrap and ref-journal transactions |
| [ADR-0061](0061-runtime-neutral-async-backend-contract.md) | Accepted | Define a runtime-neutral async backend contract |
| [ADR-0062](0062-bounded-local-filesystem-backend.md) | Accepted | Implement bounded local backend object storage |
| [ADR-0063](0063-backend-observability-and-fault-wrappers.md) | Accepted | Add backend fault-injection and metrics wrappers |
| [ADR-0064](0064-versioned-encryption-suite.md) | Accepted | Select the initial versioned encryption suite |
| [ADR-0065](0065-complete-object-encrypted-backend-envelopes.md) | Accepted | Encrypt complete backend objects with bound envelopes |
| [ADR-0066](0066-passphrase-encrypted-recovery-key-exports.md) | Accepted | Export and import repository keys with Argon2id |
| [ADR-0067](0067-encrypted-repository-recovery-snapshots.md) | Accepted | Recover canonical repository files from encrypted backend storage |
| [ADR-0068](0068-drive-desktop-oauth-and-dedicated-folder.md) | Accepted | Use Desktop OAuth and a dedicated Drive folder |
| [ADR-0069](0069-opaque-drive-object-names.md) | Accepted | Derive opaque Drive object names from repository key material |
| [ADR-0070](0070-root-pinned-device-journal-authorization.md) | Accepted | Authorize remote device journals with a pinned root registry |
| [ADR-0071](0071-native-filtered-upload-pack-bridge.md) | Accepted | Delegate partial-clone filtering to C Git upload-pack |
| [ADR-0072](0072-explicit-lru-snapshot-cache-trimming.md) | Accepted | Trim snapshot cache explicitly with LRU |
| [ADR-0073](0073-checksummed-ciphertext-read-cache.md) | Accepted | Cache immutable encrypted segments and indexes by opaque key |
| [ADR-0074](0074-bounded-in-memory-plaintext-resolver-caches.md) | Accepted | Cache verified resolver plaintext only in bounded process memory |
| [ADR-0075](0075-checksummed-token-free-github-mirror-policy.md) | Accepted | Store token-free GitHub mirror policy and checkpoints canonically |
| [ADR-0076](0076-standard-git-github-publication.md) | Accepted | Publish selected GitHub refs through standard Git credentials |
| [ADR-0077](0077-explicit-github-pull-request-branch-mapping.md) | Accepted | Publish one selected branch to an explicit pull-request branch |
