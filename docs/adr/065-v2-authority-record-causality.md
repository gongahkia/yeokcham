# ADR-065 — V2 authority record causality

- Status: Superseded by ADR-073
- Date: 2026-08-13
- Deciders: maintainer (standing implementation approval 2026-08-13)
- Governing issue: [#145](https://github.com/gongahkia/yeokcham/issues/145)
- Related decisions: ADR-048, ADR-053, ADR-064
- Supersedes: ADR-064
- Superseded by: ADR-073

## Context and problem statement

ADR-064 correctly separates a repository-scoped root authority from device
signers, but its displayed certificate shape includes an `authority-predecessor`
that is the identifier of the ledger event which stores the certificate. An
immutable event targets the immutable certificate object, so that representation
would make each object identifier depend on the other object's identifier. It
cannot be constructed without an invalid placeholder, a cycle, or a
non-canonical second write.

Current milestone: V2-02 Device identity and end-to-end encryption. Vertical
slice: make root-signed authority records independently constructible, then use
the existing immutable causal ledger to order their publication. This changes
no root/device role or recovery policy from ADR-064.

## Decision drivers

- Preserve immutable create-only objects and domain-separated identities.
- Use one causal edge representation rather than duplicate inconsistent edges.
- Allow a certificate or revocation record to be validated before it is stored.
- Keep the existing generic ledger as the source of authority-event ordering.

## Considered options

### Keep the predecessor in the authority record

This produces a certificate/event identity cycle. A placeholder or mutation
would violate the canonical create-only persistent-format rules. It is
rejected.

### Derive a synthetic predecessor unrelated to the ledger event

This avoids the direct cycle but creates a second causal model that may disagree
with the ledger. It is rejected.

### Put causal predecessors only in immutable authority-ledger events

Repository authority, device certificates, and revocations are independent
root-signed records. The authority-scoped `ref_event` targets exactly one such
record and its existing predecessor links provide the sole authority ordering.
This is selected.

## Decision outcome

The canonical authority records are:

```text
Repository_authority = signed-by(User_root,
  repository-id, user-id, root-key-id, root-public-key, mandatory-features)
Device_certificate = signed-by(User_root,
  repository-id, user-id, device-id, signer-key-id, signer-public-key,
  envelope-key-commitment, address-key-commitment, local-key-handle,
  mandatory-features)
Device_revocation = signed-by(User_root,
  repository-id, user-id, device-certificate-id, mandatory-features)
Authority_event = existing-ref-event(target = one authority record,
  predecessor = prior authority-event or none)
```

An authority event's target must be a typed repository-authority, certificate,
or revocation object. The initial event targets the repository-authority. A
later event targets one certificate or revocation and uses ADR-048's existing
predecessor field. No authority record includes an event ID, event signature,
or mutable head pointer. Certificate and revocation verification requires the
repository-authority public root and never infers a ledger position.

## Consequences

- Authority records have deterministic identities before persistence and may be
  independently decoded and signature-checked.
- One verified, complete, nondivergent authority-ledger chain determines active
  versus revoked state; record bytes do not duplicate that relationship.
- Bootstrap binding and ordinary-event authority observations remain later
  versioned formats, as ADR-064 specified.

## Model and invariant impact

1. A certificate or revocation ID depends only on its own canonical signed
   record, never on an object reference or ledger event that stores it.
2. A valid authority record alone does not make a device active: it needs the
   matching complete authority-ledger state.
3. An authority event targets exactly one known authority-record frame; its
   causal predecessor is ADR-048's event predecessor and is the only ordering
   edge.
4. Root signatures bind every certificate and revocation field listed above;
   records cross-check repository and user IDs against their authority anchor.

## Persistent-format and migration impact

The authority records are separate strict canonical CBOR typed frames with a
schema version and mandatory-feature mask. Their record IDs derive from
domain-separated canonical unsigned bodies; their root signatures use separate
domains. A future authority-ledger adapter reuses the existing versioned
`ref_event` predecessor encoding and rejects a target with an unexpected
authority frame kind. No pre-release V2 record is rewritten or reinterpreted,
and no private root bytes appear in an object, fixture, log, or command line.

## Verification

- Golden fixtures and strict inverse decoders cover each authority record.
- Unit tests cover independent construction, root-signature verification,
  cross-repository/user rejection, and exact target-kind checks.
- Generated tests permute independently valid records and ledger chains;
  identical valid input has identical authority state and divergence is refused.
- Durable tests cover every immutable object and authority-event publication
  boundary; interruption leaves a valid prefix or inert unreachable object.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.
- No benchmark is required because this correction changes representation, not
  a performance claim.

## CLI and user impact

Not applicable: this correction adds no command. Future inspection presents
record identity separately from its authority-ledger event and head state.
