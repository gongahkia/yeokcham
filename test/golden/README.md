# Canonical golden fixtures

Each fixture is exactly one nonempty line of lowercase ASCII hexadecimal digits followed by one LF. It represents the exact binary bytes that a persistent codec or envelope must retain; fixtures are test inputs, never generated test outputs.

`profile1-v1-composite.cbor.hex` is the canonical Yeokcham CBOR Profile 1 encoding of:

```text
{
  0: h'00ff80414243',
  1: "Yeokcham ✓",
  24: [-9223372036854775808, 9223372036854775807, false, true, null],
  256: {0: -25, 1: h'', 24: []}
}
```

`envelope-v1-snapshot.yeok.hex` is Fixed Object Envelope 1 for object type `Snapshot`, object-format version `1`, mandatory-feature mask `0`, and Profile 1 payload `{1: true}`. Its checksum is SHA-256 over the prescribed header prefix and payload.

`envelope-v1-snapshot-feature-bit-0.yeok.hex` and `envelope-v1-snapshot-feature-bit-63.yeok.hex` have the same valid Envelope-1 header and payload, except for mandatory feature bit `0` or bit `63` respectively. Their checksums are valid. Current readers must reject both at header offset `8` before payload decoding.

`model-v1-snapshot-empty.yeok.hex`, `model-v1-snapshot-nested.yeok.hex`, `model-v1-scratch-event.yeok.hex`, and `model-v1-checkpoint.yeok.hex` are Envelope-1 bytes containing the existing model canonical payload schemas. They cover empty and nested trees, canonical ordering, all file modes, all five scratch operations, checkpoint metadata, and retention reasons.

`store-v1-content.yeok.hex`, `store-v1-tree.yeok.hex`, and `store-v1-snapshot.yeok.hex` are Envelope-1 bytes for ADR-021's persisted Content, Tree, and Snapshot schemas. They cover exact binary content, executable mode, a typed content reference, and a typed root-tree reference.

`store-v1-chunk.yeok.hex` and `store-v1-file-manifest.yeok.hex` are Envelope-1 bytes for ADR-022's Chunk and File_manifest schemas. They cover raw chunk bytes and a canonical manifest reference for a file one byte over the 64 KiB inline limit.

`scratch-v1-event.yeok.hex`, `scratch-v1-checkpoint.yeok.hex`, and
`scratch-v1-retention-change.yeok.hex` are Envelope-1 bytes for ADR-023's
Scratch_event, Checkpoint, and Retention_change v1 schemas. They cover replay
links, timestamps, intrinsic retention, and immutable pin changes.
`scratch-v1-head.ref.hex` is the exact checksummed mutable-ref v1 byte record;
it is deliberately not an Envelope-1 object.

`scratch-v1-cleanup-manifest.yeok.hex`, `scratch-v1-generation-segment.yeok.hex`,
and `scratch-v1-generation.yeok.hex` are ADR-024's canonical immutable cleanup,
bounded alias-segment, and generation-root objects. `scratch-v1-generation.ref.hex`
is the unchanged mutable-ref v1 encoding when naming a generation.

`exchange-v1-hello.frame.hex`, `exchange-v1-inventory.frame.hex`,
`exchange-v1-want.frame.hex`, `exchange-v1-object.frame.hex`,
`exchange-v1-end.frame.hex`, and `exchange-v1-error.frame.hex` are ADR-038
transient exchange-v1 frames. They cover the exact u64-be framing and canonical
CBOR schema for every v1 message kind; they are not persistent object records.

`ref-event-v1.yeok.hex` is ADR-039's Ref_event v1 Envelope. It retains one
canonical Ed25519-signed immutable ref-transition proposal; it does not prove a
trusted signer or update a mutable ref.

`device-identity-v1.yeok.hex` is ADR-040's Device_identity v1 Envelope. It
retains one opaque random device ID and Ed25519 public-key binding; it contains
no private key, host metadata, trust map, or mutable ref.

`legacy-archive-manifest-v1.cbor.hex` is the canonical external archive
manifest from ADR-047 for a V2-marker/V1-data legacy root. It records sorted
relative nodes, modes, sizes, and SHA-256 digests. It is recovery evidence for
the relocated V1 tree, not a V2 object or source of history authority.

The `v2-ciphertext-envelope-v1.*.cbor.hex` and
`v2-ref-ledger-event-v1.*.cbor.hex` fixture families contain the valid
canonical V2 envelope/ledger bytes plus fixed truncation, trailing-byte,
unsupported-feature, and wrong-event-ID failures. The
`v2-opaque-object-address-v1.wrong-identity.hex` fixture is a valid-length
but repository/key-mismatched opaque address. These fixtures are deliberately
static inputs; tests may derive additional bounded corruptions from the valid
fixture through `Golden_fixture` but never regenerate a fixture file.

Changing any fixture bytes requires a format decision and retained compatibility evidence; adding a new schema requires a new named fixture.
