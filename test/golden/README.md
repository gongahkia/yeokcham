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

Changing any fixture bytes requires a format decision and retained compatibility evidence; adding a new schema requires a new named fixture.
