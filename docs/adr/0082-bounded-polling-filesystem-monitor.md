# ADR-0082: Monitor explicit roots through bounded polling snapshots

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The daemon needs to notice local source changes without changing Git or Yeokcham state. No daemon runtime or platform listener exists yet, so binding to a macOS-specific callback API now would introduce unsafe FFI and lifecycle coupling before cancellation and shutdown semantics are defined.

## Decision drivers

- Detect useful filesystem changes with no persistent state.
- Bound scans and metadata allocation.
- Do not follow symbolic links outside an explicit root.
- Preserve a known-good baseline when a scan fails.

## Considered options

### Option 1: macOS FSEvents immediately

This is efficient but requires platform-specific runtime, callback, and shutdown design before a daemon exists.

### Option 2: Hash all file contents every scan

This makes normal monitoring expensive and duplicates the later measured hashing pipeline.

### Option 3: Bounded metadata polling snapshots

Track relative path, entry kind, length, and modification time beneath an explicit root, then compare complete snapshots.

## Decision

Use Option 3 as the initial monitor. `FilesystemMonitor` captures a bounded baseline and `poll` returns sorted relative-path created, modified, and removed events. It follows no symlinks, records a symlink only as an entry, rejects unsupported entry types, and replaces the baseline only after a complete successful scan. V1 is a polling seam; a later native watcher may feed the same verified rescan path after lifecycle behavior is benchmarked.

## Consequences

Detection latency is controlled by the future caller's polling schedule. Metadata polling is not a durable event journal and does not claim to observe every transient write or preserve event order between scans.

## Invariants

- Monitoring never mutates the filesystem, Git state, or Yeokcham storage.
- All events are relative to a caller-owned non-symlink root.
- A failed poll retains the last complete snapshot.
- Directory depth, directory count, total entries, and per-directory sorting are bounded.

## Compatibility and migration

No persistent format or migration. Disabling monitoring changes no repository bytes.

## Security and recovery

Snapshots contain metadata only and debug output redacts paths. The monitor does not follow links or read file content. Recovery never depends on transient events or an in-memory snapshot.

## Verification

Tests cover sorted create/modify/remove detection, no-change polls, limits, symlink non-following, snapshot replacement, redacted debug output, and thread-safety bounds.
