# Architecture

V4 is layered so filesystem and platform adapters cannot change the model by
themselves.

```
CLI / inspection projection / Linux watch / Linux runtime / local custody adapters / HTTPS relay client
              │
       Local_service adapter / Receipt boundary
              │
 Model ─ Trust ─ Transport publication/feed ─ Package verification ─ Bootstrap ─ Recovery
              │
 V4 state wrapper / canonical CBOR / immutable object store
              │
 exact snapshot scanner and materialiser
```

`Yeokcham_v4_model` owns pure draft, shared-change, decision, projection, and
delivery transitions. `Yeokcham_v4_trust` owns pure certificate, epoch,
revocation, signature, adoption, and recovery-authority validation.
`Yeokcham_v4_package` verifies untrusted directory contents into a staging
object store before immutable import. `Yeokcham_v4_recovery` encrypts only the
active recovery capability and public authority closure; it never stores a
normal device private key.

`Yeokcham_v4_receipt` is the persistent receipt adapter for packages and relay
batches. It depends on model, trust, package, transport, and store only; it has
no snapshot scanner or materialiser dependency. `Yeokcham_v4_local_service`
delegates receive surfaces to it and otherwise captures snapshots, maintains
the compare-and-swap state head, obtains caller-provided signing capability
from a platform adapter, and never allows a collaborative wrapper to be
stripped by an ordinary save.

`Yeokcham_v4_transport` owns canonical signed courier publications and feed
validation. The relay owns only bounded, repository-scoped bearer access and
immutable byte storage; its versioned local access registry, reverse-proxy TLS,
aliases, URLs, and credentials remain outside the V4 project model. The
transport client stages relay artifacts and delegates
receipt solely to the receipt boundary; it has no second model or authority
path. A relay or any future network service cannot coordinate, select, or gate
authority epochs. `Yeokcham_v4_bootstrap` adds a separately signed
portable-state basis bound to an unchanged package-manifest-v1 closure; it is explicit
initialization, not a clone protocol.

ADR-094 specifies a future sealed-parcel adapter beside this plaintext relay
path. It will keep the relay as opaque immutable storage, use a private local
recipient-key directory, and pass decrypted exact bytes into the same receipt
boundary. It has no model, authority, key-custody, or working-tree role. No
such adapter is linked into V4 until its audited-HPKE dependency gate passes.

`Yeokcham_v4_inspection` is a pure terminal projection over a loaded project,
its signed revision records, deferred review references, and an optional
authority closure. The local service supplies that input without scanning the
working tree. It stores no layout, follows no remote, and cannot turn delivery
milestones or concurrent authority heads into inferred history or policy.

`Yeokcham_v4_restore_journal` records restartable destructive materialisation.
`Yeokcham_v4_restore_proof` is a separate local, canonical, create-only record
that keeps the exact safety and target snapshots reachable after a completed
journal is pruned. The local service validates both snapshot closures before
creating it and serializes proof, retain, forget, and compaction operations
under a repository-local lock. Neither module participates in package export,
bootstrap, receipt, relay transport, authority, or the project-state schema.

`Yeokcham_v4_gc` is a storage adapter, not a model or receipt adapter. It
loads one lock-consistent V4 state, derives a pure object-reachability plan,
and treats every named checkpoint closure as retained. It serializes after
restore retention and before the project-state head, writes only local
canonical quarantine receipts, and moves same-filesystem object paths with
directory sync. It has no package, relay, transport, authority, scanner, or
materialiser dependency. An explicit purge rechecks current reachability;
purge markers make an interrupted unlink sequence restartable rather than
silently treating missing quarantine files as safe.

`Yeokcham_v4_custody` is a local adapter that loads an existing native signer,
an explicitly selected `ssh-ed25519` SSH-agent key, or an explicitly selected
PKCS#11 Ed25519 key. Its small canonical local profile contains only the
selector and public key. It cannot add an authority, alter an existing device
identity, or enter project state, packages, relay data, bootstrap, recovery,
or working-tree transitions. The trust core receives an opaque capability and
continues to construct and verify every domain-separated signed record.

The unversioned hash, encoding, envelope, store, snapshot, chunking, testkit,
and watcher modules are V4 foundations. The Linux watcher emits advisory scan
requests and delegates all capture semantics to `save`; it is not a source of
canonical history. The Linux runtime gives that watcher a private disposable
process lifetime and delegates explicit `daemon sync` requests to the same
transport orchestration as foreground `sync`; it owns no model, authority,
receipt, or working-tree-materialisation path. macOS and Linux signer and
custody adapters are custody boundaries, not authority systems.
