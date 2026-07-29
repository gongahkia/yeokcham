# Local repository format

This specifies the first local Yeokcham repository. Creation is empty; later Milestone-1 publication may add immutable segments, segment indexes, and blob or metadata-object manifests.

## Layout

```text
<repository>/
  format/repository.bin
  segments/
  indexes/
  manifests/blobs/
  manifests/objects/ # created on first metadata-object publication
  manifests/generations/
  journals/refs/
  summaries/current/
```

`LocalRepository::create` requires a nonexistent repository root and an existing parent directory. It creates each directory, writes the bootstrap last with exclusive creation, syncs it, then validates the resulting repository. An interrupted initialization with no valid bootstrap is not an opened repository and contains no acknowledged Git data.

`LocalRepository::open` requires every listed path to be a directory and `format/repository.bin` to be a regular file. `manifests/objects/` is optional for repositories without metadata-object manifests. It rejects symlinks at these owned paths. The bootstrap file is bounded to 4096 bytes before reading.

## Bootstrap record

`format/repository.bin` is a canonical binary record with this V1 layout:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `YKRB` |
| 4 | 2 | format version, unsigned big-endian `u16` |
| 6 | 8 | required feature flags, unsigned big-endian `u64` |
| 14 | 8 | optional feature flags, unsigned big-endian `u64` |
| 22 | 16 | raw RFC 9562 UUIDv4 repository ID |

The V1 record is exactly 38 bytes. Existing V1 readers reject malformed, truncated, trailing, unknown-required-feature, and unsupported-version data before returning a repository handle. Unknown optional features are retained by the in-memory format declaration; V1 migration does not rewrite the bootstrap.

## Migration and deferred work

V1 is the first persisted repository format, so `LocalRepository::migrate` validates and returns the repository without writing. A future migration must use a new supported version or required feature bit, write a copy-on-write generation, verify it, retain the old readable bootstrap until finalization, and document recovery from interruption.

SQLite metadata is disposable local coordination state, not a recovery source. Ref journals, encryption, and remote backends are deferred to later milestones. Current immutable record layouts and publication paths are specified in [`docs/serialization.md`](serialization.md).
