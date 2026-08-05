# ADR-0045: Resolve manifest records through verified local segments

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Local `YKMF` resolution now finds a manifest, but reconstruction cannot trust that metadata alone. The referenced `YKSG` segment must be located, completely decoded, and bound to the manifest before its whole-blob or tiny-aggregation record becomes usable. Segment indexes are rebuildable acceleration metadata and are not a verification substitute.

## Decision drivers

- Verify every segment byte before exposing its selected typed record.
- Bind repository identity, segment identity, and segment checksum to the manifest.
- Check the selected blob identity, content identity, and exact length again.
- Bound file reads independently from segment decoder limits.
- Use a simple local path convention without inventing a mutable index.

## Considered options

### Trust a `YKIX` index offset

An index can be stale or corrupt. Trusting it before segment verification violates recovery requirements.

### Read only the manifest's expected payload range

This does not verify segment framing, footer totals, checksum, or other records and creates a second partial parser.

### Fully decode the local segment then select the typed record

The existing bounded segment reader centralizes validation. It is slower for this slice but gives one recovery boundary and leaves indexed range reads to a later verified optimization.

## Decision

Use `segments/<lowercase-segment-uuid>` as the version-1 local final segment path. `LocalRepository::resolve_manifest_record` accepts a manifest, caller maximum segment bytes, and `SegmentReadLimits`. It rejects a foreign manifest and zero file bound, reads a regular nonsymlink segment file within that bound, and invokes `SegmentReader::decode` over the complete bytes.

The decoded segment repository ID, segment ID, and SHA-256 checksum must equal the manifest. The resolver finds exactly one outer record matching the manifest's representation and record content ID. For a whole record it requires the stored Git ID, content ID, and length to equal the manifest. For a tiny aggregation it finds the manifest Git ID entry and requires its content ID and length to equal. It returns the typed verified `ReadSegmentRecord` only after these checks; missing segments are `NotFound`, while mismatches are corrupt data.

## Consequences

The path convention allows writers to seal a segment before publishing any referencing manifest. This first resolver parses complete segments and is O(segment size); an index-backed range-read optimization must retain whole-segment verification or add an equivalent verified trust boundary. The API does not yet reconstruct raw blob bytes or select among multiple manifests.

## Invariants

- A manifest record is never returned from an unverified segment.
- Segment repository ID, segment ID, and checksum exactly bind to the manifest.
- The selected whole blob or tiny entry exactly binds Git ID, content ID, and plaintext length.
- Segment files are bounded, regular, and nonsymlink before reading.
- Indexes never bypass this verification path.
- Missing data and corruption remain distinguishable.

## Compatibility and migration

No `YKSG` or `YKMF` bytes change. The local path convention applies to new version-1 storage; future sharding, encryption, remote keys, or range-verified formats require a documented new path/resolution contract. Existing files remain immutable and readable under their recorded format.

## Security and recovery

Segment paths and bytes are hostile. Caller bounds limit file and nested decode work; regular-file checks reject direct symlinks; the segment reader checks framing and checksum before record selection; final blob checks protect manifest substitution. SHA-256 detects accidental corruption but does not authenticate a backend. Recovery can report missing/corrupt segments and must not return their selected blob record as trusted.

## Verification

Tests cover whole and tiny record resolution, selected-entry checks, zero and small file limits, tampered checksum, mismatched segment ID with a recomputed checksum, and missing segments. Existing segment and manifest tests cover redacted diagnostics and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
