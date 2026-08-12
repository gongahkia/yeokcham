# Yeokcham secure runtime

This is V2-029's isolated, one-shot MLS bootstrap runtime. It reads two
ADR-069 length-prefixed canonical-CBOR frames from standard input: a required
MLS Hello then one MLS request. It writes the acknowledgement and one response
to standard output. No arguments, repository paths, object IDs, refs, files,
network sockets, or persistent storage are accepted.

The only V1 requests are:

```text
Bootstrap = (version=1, operation=1, group-id, device-id, empty-state)
Exporter  = (version=1, operation=2, group-id, device-id, opaque-MLS-state)
```

Bootstrap returns an opaque `mls-rs` group snapshot for exactly one initial
device credential. Exporter reloads that snapshot, verifies the group ID and
that its sole initial Basic credential is the requested device ID, then derives
a fixed, domain-separated 32-byte MLS exporter secret. The parent must
immediately encrypt the snapshot with the existing device envelope key. The
runtime neither receives that envelope key nor writes snapshot/key material to
disk.

The initial credential is a Basic MLS credential carrying only opaque device
bytes. It is sufficient to bind the local bootstrap member; it is not a remote
identity or invitation authorization scheme. V2-030 owns credential validation
for added devices. The runtime uses the OpenSSL `mls-rs` provider because its
documented cipher-suite support is stable. It creates no custom cryptography.

```sh
cargo build --locked --release
cargo fmt --check
cargo test --locked
```

This package is deliberately limited to the V2-029 bootstrap. V2-073 expands
this directory into the reviewed transport workspace and adds mesh/libp2p,
license/SBOM, platform, and supply-chain policy. It must retain the rule that
runtime source cannot read Yeokcham repository storage.
