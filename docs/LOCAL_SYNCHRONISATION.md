# Local synchronisation boundary

## V3 peer-exchange successor

ADR-077 implements the native peer workflow formerly planned by ADR-073 and
[#235](https://github.com/gongahkia/yeokcham/issues/235): a user explicitly
publishes a capsule revision or release; a local-path or SSH peer transfers
only a verified snapshot closure; and receiving creates an inspectable
publication proposal rather than a workspace/ref/working-directory mutation.
Scratch checkpoints remain local by default. Capsule proposals require an
explicit receiver-authored adoption; release proposals intentionally have no
native-release adoption. See [peer exchange](PEER_EXCHANGE.md) for the current
contract. This document's M10 fixture remains useful prior art, but is not the
user-facing V3 workflow.

## M10-11 vertical slice

This is a programmatic, two-local-repository demonstration. It runs without a
central service and exercises two deliberately separate transports:

- Direct, bounded ADR-038 immutable-object exchange between two local stores.
- Caller-selected ADR-042 encrypted object bundles through an ADR-043 local
  shared directory.

The fixture is self-contained: it creates source, destination, and shared
directories beneath one temporary directory, then removes that directory when
the test completes. It needs neither a network endpoint nor a daemon.

## Model boundary

The exercised values are existing transient `Exchange.session_id`, caller-held
`Bundle.key`, `Bundle_directory.complete`, exact immutable object IDs, and
mutable-ref observations. No new Yeokcham model type, persistent object, ref,
binding, schema, or CLI command is introduced by M10-11.

The fixture verifies these invariants:

1. Each received object has its source Envelope-1 bytes and stored-object ID.
2. Direct exchange and shared-directory import leave both application refs
   byte-for-byte unchanged.
3. The bundle is inspected before import; its file is not a peer identity,
   ref selection, or synchronisation claim.
4. Failure stays a structured adapter result; the fixture performs no fallback
   that mutates a ref or replaces an immutable object.

## What this does not provide

Neither path establishes peer identity, availability, authorisation, sender or
recipient identity, key recovery, key lifecycle, replay protection, automatic
object-set discovery, ref transfer, ref synchronisation, head selection, or
reconciliation. Direct exchange requires a caller-declared object list. Offline
transfer requires a caller-held 32-byte key and a caller-selected complete
file. A valid import only makes exact immutable objects available locally.

No local TCP listener, shared-directory file, encrypted bundle, device
declaration, signed event, or divergence set makes a remote peer trusted.

## Verification

Run the focused end-to-end fixture and its bounded restart/corruption
properties through Dune:

```sh
opam exec -- dune runtest test/test_decentralised_sync.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/two_device_sync_property_test.exe
PROPERTY_TEST_SEED=17 opam exec -- dune exec test/bundle_directory_property_test.exe
```

Run the repository gates before relying on the fixture:

```sh
make check
make property-test PROPERTY_TEST_SEED=17
```

The preceding test commands are verification operations, not user-facing
synchronisation commands. M10 introduces no sync CLI or secret-input
convention.

## External context

Git's documented bundle mechanism is an offline object transfer mechanism;
Yeokcham deliberately keeps its bundle narrower by transferring caller-declared
immutable objects without refs or ref-selection semantics. See the official
[git-bundle documentation](https://git-scm.com/docs/git-bundle.html).
