# Contributing to Yeokcham

## Before changing code

Read the project documents in the order listed in [`README.md`](README.md#read-order-for-an-implementation-agent). Work on the earliest incomplete milestone in [`TODO.md`](TODO.md), and discuss large or architectural changes in an issue before implementation.

## Development

Install [rustup](https://rustup.rs/), then clone the repository. The checked-in toolchain file installs the supported compiler, rustfmt, and Clippy.

Keep changes narrow and fail fast. Preserve the invariants in `AGENTS.md`, avoid unrelated refactors, and add normal and failure-path tests for changed behaviour. Persistent format changes require a version, migration implications, and an ADR.

Run the CI-equivalent checks before submitting:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features
RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps
```

## Pull requests

Describe the invariant introduced or preserved, tests proving it, format or migration impact, and deferred work. Update relevant documentation and `TODO.md`. Do not include secrets, keys, plaintext private source, generated build output, or unrelated changes.

By submitting a contribution, you agree that it is licensed under the repository's [MIT License](LICENSE).
