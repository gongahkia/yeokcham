# ADR-095 — V4 source-release verification

- Status: Accepted
- Date: 2026-08-31
- Deciders: maintainers
- Implements: [#243](https://github.com/gongahkia/yeokcham/issues/243)

## Context

V4's identity, authority, package receipt, relay, and delivery rules concern a
Yeokcham repository. They do not answer a different question: whether a source
archive distributed as *Yeokcham itself* came from the expected maintainer and
the expected source commit.

That source-distribution question needs a small, inspectable supply-chain
check. It must not turn a Git signer into a V4 device, trust a public key by
first observation, create a release record, or silently publish anything.

## Decision

`tools/verify-v4-source-release.sh` verifies one candidate supplied entirely
by its caller:

- a local Git repository containing the candidate tag;
- tag name and full expected commit object ID;
- full expected OpenPGP fingerprint;
- local source-archive path and expected SHA-256 digest.

The tool accepts a candidate only when all of the following hold:

1. the named reference exists and is an annotated tag object, not a lightweight
   tag;
2. Git and GnuPG validate its OpenPGP signature;
3. the signature's primary key or signing-subkey fingerprint equals the full
   expected fingerprint;
4. the tag dereferences to the exact expected commit; and
5. the archive's SHA-256 equals the exact expected digest.

All inputs are explicit. The verifier never downloads an archive, discovers a
key, creates a tag, creates a release, or opens an opam submission. It uses an
existing local GnuPG keyring, so a consumer must independently acquire the
public key and compare its fingerprint before running it. Git's system and
global configuration are ignored for the verification invocation; the caller
may choose an executable through `GPG`, but it must name one executable rather
than shell syntax.

The verifier writes a private system temporary directory only for the
short-lived GnuPG status output, cleans it on exit, and never invokes the
`yeokcham` executable. GnuPG itself may maintain its ordinary local keyring or
agent state; that state is outside a Yeokcham repository and is not release
evidence.

## Invariants

1. A source-release signature is maintainer/consumer supply-chain evidence,
   never V4 device identity, authority, membership, package validity, relay
   permission, delivery, or history.
2. A full expected fingerprint is compared explicitly. A merely valid
   signature, a short key ID, or an unverified key download is insufficient.
3. The checked tag, source commit, and archive bytes are distinct inputs; no
   one of them implies either of the others.
4. Rejection changes no Yeokcham project state, object, working tree,
   authority, package, or transport state.
5. A successful local check establishes only the supplied provenance tuple. It
   is not a stable-release declaration or a claim about field trials, opam,
   support, or security beyond that tuple.

## Consequences

Maintainers and consumers get one repeatable failure boundary before treating a
source archive as a claimed release. A maintainer must still publish the real
public fingerprint independently, create and push a real signed tag, host the
archive, obtain platform evidence, and pursue opam publication through their
own authority. Those actions remain deliberately outside this tool and issue
slice.

## Verification

The test creates an isolated GnuPG home and disposable Git repository. It
proves a valid signed candidate, accepts both the primary and signing-subkey
fingerprints of a subkey signature, and rejects missing input, malformed
fingerprints, lightweight tags, unsigned annotated tags, a fingerprint
mismatch, a wrong commit, and modified archive bytes. It also proves the test
repository receives no `.yeokcham` state.

## References

- [Git tag documentation](https://git-scm.com/docs/git-tag.html)
- [Git verify-tag documentation](https://git-scm.com/docs/git-verify-tag)
- [GnuPG manual](https://www.gnupg.org/documentation/manuals/gnupg.pdf)
