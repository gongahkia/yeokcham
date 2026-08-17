# Field-trial evidence v1

Issue #242 requires actual source-host evidence for macOS and WSL. A passing
record is never generated for a platform other than the host that ran it; a
missing or failed platform remains a release-gate blocker.

## Vertical slice

`tools/stability/record-field-trial-v1.sh` runs the documented local source
workflow, `make check`, a fresh full repository archive/restore followed by
`yeokcham verify`, and the real loopback known-contact OpenSSH peer-sync test.
It writes a bounded JSON evidence record and a retained command log to a
caller-selected directory outside canonical repository data.

```sh
sh tools/stability/record-field-trial-v1.sh \
  --platform macos --release-version 1.0.0 \
  --evidence-dir /absolute/path/to/release-evidence
```

Run the same command from an actual supported WSL host with `--platform wsl`.
After all required platforms have independently passed for the same signed
commit and release version, give that directory to `make release-gate`.

## Evidence invariants

- Platform detection must match the requested `macos` or `wsl` value before
  any passing record is written.
- The JSON record has schema version 1, identifies the exact `HEAD`, and is
  emitted only after every required command succeeds.
- The log contains command output but never source private keys, repository
  contents, or user-supplied credentials; fixtures live in a removed temporary
  directory.
- The runner writes no canonical Yeokcham object, ref, archive, or runtime
  record in the repository under test.

## Verification

`tools/stability/test-field-trial-v1.sh` syntax-checks the runner and verifies
that invalid arguments and a mismatched platform are rejected. A real field
trial is deliberately not part of `make check`: it is host evidence, not a CI
substitute.

No ADR change is required. This is release evidence plumbing only; it does not
change the model or persistent formats.
