# Architecture

V4 is layered so filesystem and platform adapters cannot change the model by
themselves.

```
CLI / inspection projection / Linux watch / platform signer / HTTPS relay client
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
path. `Yeokcham_v4_bootstrap` adds a separately signed portable-state basis
bound to an unchanged package-manifest-v1 closure; it is explicit
initialization, not a clone protocol.

`Yeokcham_v4_inspection` is a pure terminal projection over a loaded project,
its signed revision records, deferred review references, and an optional
authority closure. The local service supplies that input without scanning the
working tree. It stores no layout, follows no remote, and cannot turn delivery
milestones or concurrent authority heads into inferred history or policy.

The unversioned hash, encoding, envelope, store, snapshot, chunking, testkit,
and watcher modules are V4 foundations. The Linux watcher emits advisory scan
requests and delegates all capture semantics to `save`; it is not a source of
canonical history. macOS and Linux signer adapters are custody boundaries, not
authority systems.
