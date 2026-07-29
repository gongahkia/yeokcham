# ADR-0024: Preserve validated Git refname bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham must preserve Git refs at its compatibility boundary. Git refnames are byte sequences and may contain non-UTF-8 bytes, subject to the rules of [`git check-ref-format`](https://git-scm.com/docs/git-check-ref-format). Ref names are also sensitive metadata when metadata encryption is enabled. Normalizing malformed input would silently rename a ref and could make distinct inputs collide.

## Decision drivers

- Valid Git refnames must round-trip as exact bytes.
- Invalid input must fail before persistence or ref-event creation.
- Validation must match Git's default full-ref rules without invoking a subprocess.
- Diagnostics must not disclose sensitive ref names by default.
- Future storage encoding must preserve non-UTF-8 bytes unambiguously.

## Considered options

### UTF-8 string refnames

This is convenient for application code but rejects valid Git byte sequences and breaks exact compatibility.

### Normalize with Git-compatible rules

Git can normalize selected command input, but silently changing stored ref names can create collisions and violate exact export semantics.

### Validated byte-preserving refnames

This preserves valid Git bytes, rejects malformed forms, and leaves display and serialization explicit.

## Decision

`RefName` owns validated bytes and accepts `from_bytes`, `TryFrom<Vec<u8>>`, and UTF-8 `FromStr` convenience input. It applies the default `git check-ref-format` rules: at least one slash; no leading, trailing, or repeated slash; no dot-leading or `.lock`-ending component; no `..`, `@{`, terminal dot, singleton `@`, backslash, prohibited punctuation, space, or ASCII controls. It does not accept one-level names, branch shorthand, refspec patterns, or normalization.

`RefName` has no `Display` implementation because valid values need not be UTF-8 and ref names may be sensitive metadata. Explicit callers access exact bytes through `as_bytes`. `Debug` always renders a fixed redaction marker.

## Consequences

Git-compatible ref names retain their exact bytes through import, journal, export, and recovery. Callers that need display text must choose an explicit byte-safe presentation policy. Invalid inputs cannot be normalized into a different persisted ref. Full refnames such as `refs/heads/main` are accepted; pseudorefs and branch shorthand require separate semantics if added later.

## Invariants

- Every `RefName` satisfies the default Git full-ref validation rules.
- Exact valid bytes, including non-UTF-8 bytes, never change during construction or access.
- Ref validation never invokes Git or depends on locale, filesystem, or shell behaviour.
- Default diagnostic formatting never exposes ref names.

## Compatibility and migration

This defines the core type before a repository serialization format exists. The later serialization-policy ADR must use a length-delimited byte-preserving encoding. It must not assume UTF-8 or normalize ref names. No migration is required.

## Security and recovery

Ref names may disclose paths, branch topology, release information, and personal data. Parsing errors use static messages and formatting is redacted. Recovery restores the stored byte sequence only after validation and must not convert invalid remote input into another ref name.

## Verification

Unit tests cover ordinary names, valid non-UTF-8 bytes, byte round trips, each documented Git rejection rule, no-normalization rejection, redacted errors and `Debug`, and Send/Sync. CI checks the implementation on the MSRV and stable Rust.
