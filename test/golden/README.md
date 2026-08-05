# Canonical golden fixtures

Each fixture is exactly one nonempty line of lowercase ASCII hexadecimal digits followed by one LF. It represents the exact binary bytes that a persistent codec or envelope must retain; fixtures are test inputs, never generated test outputs.

`profile1-v1-composite.cbor.hex` is the canonical Paengi CBOR Profile 1 encoding of:

```text
{
  0: h'00ff80414243',
  1: "Paengi ✓",
  24: [-9223372036854775808, 9223372036854775807, false, true, null],
  256: {0: -25, 1: h'', 24: []}
}
```

`envelope-v1-snapshot.peng.hex` is Fixed Object Envelope 1 for object type `Snapshot`, object-format version `1`, mandatory-feature mask `0`, and Profile 1 payload `{1: true}`. Its checksum is SHA-256 over the prescribed header prefix and payload.

`envelope-v1-snapshot-feature-bit-0.peng.hex` and `envelope-v1-snapshot-feature-bit-63.peng.hex` have the same valid Envelope-1 header and payload, except for mandatory feature bit `0` or bit `63` respectively. Their checksums are valid. Current readers must reject both at header offset `8` before payload decoding.

`model-v1-snapshot-empty.peng.hex`, `model-v1-snapshot-nested.peng.hex`, `model-v1-scratch-event.peng.hex`, and `model-v1-checkpoint.peng.hex` are Envelope-1 bytes containing the existing model canonical payload schemas. They cover empty and nested trees, canonical ordering, all file modes, all five scratch operations, checkpoint metadata, and retention reasons.

`store-v1-content.peng.hex`, `store-v1-tree.peng.hex`, and `store-v1-snapshot.peng.hex` are Envelope-1 bytes for ADR-021's persisted Content, Tree, and Snapshot schemas. They cover exact binary content, executable mode, a typed content reference, and a typed root-tree reference.

`store-v1-chunk.peng.hex` and `store-v1-file-manifest.peng.hex` are Envelope-1 bytes for ADR-022's Chunk and File_manifest schemas. They cover raw chunk bytes and a canonical manifest reference for a file one byte over the 64 KiB inline limit.

`scratch-v1-event.peng.hex`, `scratch-v1-checkpoint.peng.hex`, and
`scratch-v1-retention-change.peng.hex` are Envelope-1 bytes for ADR-023's
Scratch_event, Checkpoint, and Retention_change v1 schemas. They cover replay
links, timestamps, intrinsic retention, and immutable pin changes.
`scratch-v1-head.ref.hex` is the exact checksummed mutable-ref v1 byte record;
it is deliberately not an Envelope-1 object.

`scratch-v1-cleanup-manifest.peng.hex`, `scratch-v1-generation-segment.peng.hex`,
and `scratch-v1-generation.peng.hex` are ADR-024's canonical immutable cleanup,
bounded alias-segment, and generation-root objects. `scratch-v1-generation.ref.hex`
is the unchanged mutable-ref v1 encoding when naming a generation.

`exchange-v1-hello.frame.hex`, `exchange-v1-inventory.frame.hex`,
`exchange-v1-want.frame.hex`, `exchange-v1-object.frame.hex`,
`exchange-v1-end.frame.hex`, and `exchange-v1-error.frame.hex` are ADR-038
transient exchange-v1 frames. They cover the exact u64-be framing and canonical
CBOR schema for every v1 message kind; they are not persistent object records.

Changing any fixture bytes requires a format decision and retained compatibility evidence; adding a new schema requires a new named fixture.
