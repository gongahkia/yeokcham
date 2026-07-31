# Contributing to Yeokcham

## Before changing code

Read the project documents in the order listed in [`README.md`](README.md#read-order-for-an-implementation-agent). Work from a scoped [open GitHub issue](https://github.com/gongahkia/yeokcham/issues), and discuss large or architectural changes there before implementation.

## Development

Install [rustup](https://rustup.rs/), then clone the repository. The checked-in toolchain file installs the supported compiler, rustfmt, and Clippy.

Keep changes narrow and fail fast. Preserve the invariants in `AGENTS.md`, avoid unrelated refactors, and add normal and failure-path tests for changed behaviour. Persistent format changes require a version, migration implications, and an ADR.

Run the complete CI-equivalent gate before submitting:

```bash
make ci
```

Run `make help` for individual build, format, lint, test, documentation, and fixture targets.

## Pull requests

Describe the invariant introduced or preserved, tests proving it, format or migration impact, and deferred work. Update relevant documentation and the linked GitHub issue. Do not include secrets, keys, plaintext private source, generated build output, or unrelated changes.

By submitting a contribution, you agree that it is licensed under the repository's [MIT License](LICENSE).
