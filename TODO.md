# V4 roadmap

## Live backlog

GitHub Issues, rather than this file, is the source of truth for V4 work.

- #251 is deferred macOS advisory-watcher work. It is a platform adapter only;
  it needs an ADR amendment before implementation and must retain exact-scan
  authority.
- #242 is macOS field-trial evidence for a future V4 source release. It is not
  a watcher feature and is blocked on a real release candidate.
- #244 is opam publication after the actual signed source release and macOS
  field evidence; its upstream review is a maintainer/external dependency.

## Platform boundary

WSL is unsupported and not planned. It is neither an implementation target nor
release-gate evidence for Yeokcham V4.

No work is queued for a removed V1–V3 product track.
