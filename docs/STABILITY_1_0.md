# 1.0 stability contract and release gate

## Status

This is the agreed 1.0 release contract, not a statement that Yeokcham 1.0
has shipped. The repository remains experimental until every gate in this
document has recorded passing evidence. In particular, the macOS and WSL
field trials, release signing, and opam publication have not yet happened.

## Compatibility promise

The first \`v1.0.0\` tag starts the 1.x compatibility line. A later 1.x release
must read and verify every repository written by an earlier 1.x release. It
must retain the meaning of existing scratch checkpoints, capsule revisions,
workspace revisions, validation evidence, releases, preserved Git records,
peer records, and their references.

The canonical format covered by that promise is the \`.yeokcham\` root format,
envelope format, canonical payload encodings, immutable object IDs, mutable
reference encodings, and the versioned V2 local-root records. It does not
include private signing keys, daemon sockets or state, relay delivery markers,
or any untracked working-tree file outside the repository archive.

For 1.x:

- Existing object-type codes, canonical encodings, object IDs, and record
  meanings are immutable.
- Existing decoders remain available; an additive record is allowed only when
  older readers reject it as an unknown mandatory feature or object type before
  they mutate state.
- Every new persistent record needs a version, canonical encoder/decoder,
  old-format fixture, inverse-decoding test, and documented migration effect.
- An incompatible schema, object type, object meaning, reference meaning, or
  command-semantic change requires \`2.0.0\` and an explicit migration tool.
- Private material and noncanonical runtime state never become part of this
  compatibility surface.

The frozen baseline is \`yeokcham-repository-root 2\`, root layout version 3,
the SHA-256 \`envelope-1-domain-v1\` object preimage, envelope version 1,
object-format version 1, and the envelope type registry in
\`lib/yeokcham_envelope\`. The format fixture and persistent-format audit in
\`make check\` are the executable checks for this baseline.

## Supported release surface

The supported 1.0 distribution is source and opam only. There is no promise
of native binaries, installers, a hosted service, or a package relay.

The release manager validates the source package on:

- a supported Linux host;
- macOS; and
- WSL running a supported Linux distribution.

Each field trial runs \`make check\`, creates a fresh repository, restores a
full archive, and exercises the documented direct known-contact SSH workflow.
The evidence records the OS/version, architecture, OCaml/opam/Dune versions,
Yeokcham revision, exact commands, and result. A green Linux CI job is useful
regression evidence, but cannot stand in for macOS or WSL evidence.

## Peer-sharing promise

Peer sharing is based on explicitly pinned contacts over SSH. SSH authenticates
the transport host; Yeokcham's pinned Ed25519 contact authenticates the peer.
Discovery and relay advertisements are hints only and never extend trust.

An authenticated sync may transfer verified immutable objects and advance only
that contact's peer-tracking reference. It must not alter scratch, a capsule,
a workspace, a release, or the working directory. Divergence is either an
exact snapshot merge or a durable conflict; no text guess is permitted.

The public API for this promise is not declared stable until issue #238's
acceptance criteria, including SSH transport, relay, daemon, and their
failure/restart fixtures, are complete.

## Backup and recovery

Before upgrade, sharing, or release testing, create an archive containing the
whole working root, including \`.yeokcham\`:

\`\`\`sh
sh tools/stability/backup-full-repository-v1.sh \
  --source /absolute/path/to/repository \
  --archive /absolute/path/to/repository-2026-08-16.tar
\`\`\`

The tool refuses to overwrite an archive, writes a SHA-256 sidecar, compares
the source to the archive, extracts it into a temporary directory, and compares
that extraction to the archive. It is a local byte/type/mode archive check;
keep the archive in independent storage and test a real restore before relying
on it for disaster recovery.

To restore, create a new empty directory and extract the archive into it:

\`\`\`sh
mkdir /absolute/path/to/restore-parent
tar -xf /absolute/path/to/repository-2026-08-16.tar \
  -C /absolute/path/to/restore-parent
\`\`\`

Then run \`yeokcham verify --root\` against the extracted repository before
using it. The archive is a recovery copy, not a replacement for independent
backup retention.

## Release gate

Only a maintainer may perform the following external actions:

1. Record passing Linux, macOS, and WSL field-trial evidence.
2. Run \`make check\` from the exact release commit and retain its log.
3. Build the source archive from that commit and publish its SHA-256 checksum.
4. Create an annotated GPG-signed \`vMAJOR.MINOR.PATCH\` tag and publish the
   maintainer fingerprint and verification command.
5. Publish the same source release to opam only after the tag and checksum are
   available.
6. Update the issue and release notes with actual host and signing evidence.

Consumers verify a release with:

\`\`\`sh
git verify-tag vMAJOR.MINOR.PATCH
git tag --verify vMAJOR.MINOR.PATCH
sha256sum -c yeokcham-MAJOR.MINOR.PATCH.tar.gz.sha256
\`\`\`

On systems without \`sha256sum\`, use \`shasum -a 256\` to calculate the archive
hash and compare it with the published value. Fingerprint verification must
use the fingerprint published with the release, not an unverified key lookup.

## GitHub Pages guide

The minimal Pages guide belongs on the dedicated \`docs\` branch only after the
release gate passes. Until then, publishing it as a stable learning path would
overstate the product status. Its source should remain static HTML/CSS/JS and
must state the version it documents.
