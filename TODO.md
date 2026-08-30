# V4 roadmap

## Seal current work

- Run `test/test_v4_watch.exe` on Linux or observe a green Ubuntu `dune runtest`.
- Push the V4-only cutover and restore a green Ubuntu CI baseline.
- Close obsolete product-track issues #242, #243, and #244 with the retirement
  disposition once the cutover commit is reviewed.

## Deliberately later

- Blob GC and immortal restore-safety after journal prune.
- Network transport and any delivery semantics beyond the existing model.
- macOS watcher adapter.

No work is queued for a removed V1–V3 product track.
