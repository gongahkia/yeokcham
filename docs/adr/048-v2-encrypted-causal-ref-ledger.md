# ADR-048 — V2 encrypted causal ref-ledger with external key verification

- Status: Proposed
- Date: 2026-08-09
- Deciders: maintainer (pending review)
- Supersedes: None
- Superseded by: None
- Governing issue: [#127](https://github.com/gongahkia/yeokcham/issues/127)

## Context and problem statement

V2 must represent shared ref changes as immutable, encrypted, causally linked
records rather than mutable ref files. V2-005 deliberately precedes V2-023,
which defines device and signing-key hierarchy, public key records, enrollment,
rotation, and authorization. The ledger therefore needs a narrow distinction:
it can establish that a supplied public key cryptographically verifies a record,
but it cannot infer that the key is trusted, enrolled, authorized for a ref, or
owned by a user or device.

The existing V1 ref-event core demonstrates this separation, but its
Envelope-1 records, V1 repository-format digest, and mutable-ref adapter are
not V2 inputs. V2 must instead keep the complete ledger record inside the
already accepted encrypted-object envelope and expose no plaintext ref name,
target, event kind, or signer identity to an opaque object store.

## Decision drivers

- Bind repository, ref, causal predecessor, target, and signer to one
  canonical signed statement.
- Keep record metadata encrypted and server-invisible.
- Fail closed for malformed bytes, unsupported features, unknown signers, and
  invalid signatures.
- Represent a concurrent child of one predecessor as explicit divergence, not
  as an implicit winner or a process exception.
- Avoid creating a second key hierarchy before V2-023.

## Considered options

### Wait for V2-023 before any ledger work

- Benefits: one complete key hierarchy before signing code exists.
- Costs and risks: contradicts V2-005's dependency order and prevents the
  foundational causal-record model from being tested independently of identity
  authorization.

### Embed a public key and treat a valid signature as authority

- Benefits: a record can be self-contained.
- Costs and risks: a malicious or unrelated key can create apparently valid
  records; cryptographic validity would be confused with authorization.

### External bounded key registry for cryptographic verification only

- Benefits: permits exact signature checks now while preserving the later
  identity/trust boundary.
- Costs and risks: callers must supply public keys; an absent key has an
  explicit unavailable result rather than a successful ledger transition.

## Decision outcome

If accepted, V2-005 defines an immutable plaintext `ref-ledger-event-v1` that
is encoded canonically, then sealed as the plaintext of an ADR-045 V2
encrypted-object envelope. The encrypted envelope is published only at its
ADR-046 repository-bound opaque address. No V1 envelope, V1 object identity,
mutable ref, or plaintext ledger index participates in the transition.

The unsigned canonical record is:

```text
[
  1,
  repository-id,
  ref-name,
  signer-key-id,
  predecessor-event-id-or-null,
  target-opaque-object-ref-or-null,
  mandatory-features
]
```

All IDs and targets are exactly 32 raw bytes. `ref-name` is a bounded safe
UTF-8 name; it has no filesystem-path authority. The `event-id` is

```text
SHA-256("yeokcham:v2:ref-ledger-event:1\0" || canonical-unsigned-bytes)
```

The complete record appends the event ID, algorithm string `ed25519`, and one
64-byte Ed25519 signature. The exact signed bytes are

```text
"yeokcham:v2:ref-ledger-signature:1\0" || event-id
```

The `signer-key-id` is a 32-byte SHA-256 digest over one 32-byte Ed25519 public
key with the distinct `yeokcham:v2:ledger-signer-key:1\0` domain. A verifier
accepts a caller-supplied, bounded, canonical map from signer-key IDs to raw
public keys, recomputes the key ID, recomputes the event ID from the unsigned
record, and verifies the signature. A missing key is `Unknown_signer`, not a
valid, trusted, or authorized record. A valid signature is only
`Cryptographically_valid`; V2-023 later supplies public-key records, device
binding, trust, enrollment, revocation, rotation, and authorization.

A causal evaluator receives a verified, unique set of records for one
repository/ref. A root has no predecessor. A non-root record requires a known
cryptographically valid predecessor for the same repository and ref. Duplicate
input IDs reject; a byte-identical already-published encrypted object is a
create-only publication retry, not a new event. Two or more valid children of
one predecessor form an ordered explicit divergence set; the evaluator neither
selects a child nor advances a mutable ref. A missing predecessor, cross-ref
predecessor, malformed record, unknown signer, signature failure, or unsupported
mandatory feature is an explicit typed result and cannot become a head.

The first durable adapter stores exactly one verified encrypted envelope at its
opaque object address using create-only publication. It has no mutable current
ref, repair action, trust store, private-key store, object-type header, or
server-visible ledger index. A key-holding client discovers and decrypts
candidate opaque objects before evaluating records. V2-006 adds transaction
recovery when a higher-level operation needs multiple objects or refs; V2-044
later defines hosted ledger transport. Persistent ledger publication must also
wait for the accepted V2-only root boundary in ADR-047: it must never share the
current hybrid V2-marker/V1-data runtime.

## Consequences

- The ledger establishes cryptographic integrity and causal structure, not
  user/device identity, authorization, or trust.
- The opaque object store cannot route or inspect refs without client-held
  encryption/address keys.
- Divergence is durable data that later policies may inspect; it is not an
  automatic merge, winner choice, or mutable-ref write.
- V2-023 can replace the transient registry input with verified public-key
  records without changing the event's signed fields.
- The durable adapter is intentionally blocked by ADR-047 acceptance and the
  V2-only root cutover; this prevents persistence into the hybrid legacy root.

## Model and invariant impact

V2-005 adds distinct typed `signer_key_id`, `ref_name`, `ref_target`, and
opaque verified-ledger values. Its invariants are:

1. Re-encoding any decoded event produces identical canonical bytes.
2. Every accepted event ID recomputes from exactly its unsigned fields.
3. Every cryptographically valid event's signer-key ID recomputes from the
   supplied public key, and its 64-byte Ed25519 signature verifies the exact
   domain-separated signing bytes.
4. A record cannot reference a predecessor from another repository or ref.
5. Evaluation returns an explicit set of concurrent heads; it never writes,
   overwrites, or chooses a mutable ref.
6. No ledger result grants trust, membership, permission, or ownership.
7. Every persistent record is encrypted before opaque-address publication.

## Persistent-format and migration impact

`ref-ledger-event-v1` is a canonical encrypted plaintext schema. Its outer
bytes are unchanged ADR-045 envelopes and its persistent object address follows
ADR-046. Record mandatory features are independent of the outer envelope's
mandatory features; both fail closed. Valid, malformed, unknown-feature,
unknown-signer, and signature fixtures must be checked in. There is no V1
migration, V1 reader, or V1 object reuse. The object publication adapter must
use only an accepted V2-only root and never mutate the sole legacy copy.

## Verification

- Unit tests cover canonical encode/decode, record-ID recomputation,
  domain-separated signing bytes, fixed Ed25519 vectors, typed target access,
  malformed inputs, and feature rejection.
- Generated tests create bounded valid chains and verify deterministic head
  sets, duplicate rejection, same-predecessor divergence, missing predecessor,
  wrong repository/ref links, unknown signer, wrong key, and signature
  tampering.
- Persistence tests inject failures before and after create-only object
  publication, prove idempotent retry, and verify that rejected records leave
  every immutable object and future mutable-ref namespace unchanged.
- Golden fixtures include the inner record, encrypted envelope, and opaque
  address relation without exposing a production private key.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and focused ledger
  tests remain required.

## CLI and user impact

Not applicable in V2-005. This is a model and encrypted persistent-record
boundary. Future inspection may display cryptographic validity, unknown signer,
causal heads, and explicit divergence, but it must not present a valid
signature as authorization.

## References

- [RFC 8032, Edwards-Curve Digital Signature Algorithm (EdDSA)](https://www.rfc-editor.org/rfc/rfc8032.html), especially the Ed25519 key, signing, verification, and test-vector sections.
