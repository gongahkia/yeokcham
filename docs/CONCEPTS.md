# Concepts

## The vocabulary that keeps V1 honest

| Term | Meaning | Is not |
| --- | --- | --- |
| Snapshot | Exact directory tree: bytes, file modes, directories, and symlinks. | A semantic parse or inferred edit. |
| Checkpoint | A local saved snapshot in the active draft, used for scratch recovery. | A shared change, revision, or delivery. |
| Draft | The current local workspace line with a latest checkpoint. | A branch shared with the team. |
| Change | A user-named unit selected for sharing. | A filesystem event. |
| Revision | An immutable signed shared result for a change. | A checkpoint or release. |
| Decision | An explicit unresolved composition situation. | A process error or automatically merged conflict. |
| Delivery | A separately recorded milestone after shared work. | A revision, tag, CI result, or release. |
| Device | An Ed25519 public identity whose private signing capability stays in local custody. | A username or relay account. |
| Authority epoch | Signed membership and administrator state. Concurrent heads remain visible until an explicit reconciliation. | An online coordinator or lease. |
| Root-verification phrase | Public 12-word phrase independently compared while joining. | A secret or password. |
| Recovery mnemonic | Secret 24-word BIP-39 phrase that decrypts recovery material. | A normal login credential. |
| Package | Offline directory transfer of public authority closure, signed work, and exact objects. | A clone or private-key transfer. |
| Relay | Untrusted immutable byte courier behind operator-managed HTTPS. | Authority, a repository host, or end-to-end encrypted storage. |
| Semantic sidecar | Optional, disposable external-LSP observation attached to a proposal session. | Canonical source, a merge engine, or trust evidence. |

## Daily local loop

1. Edit ordinary files.
2. Run `yeokcham changes` to compare the current tree to the active draft's
   latest saved checkpoint.
3. Run `yeokcham save` when you want a new recovery checkpoint.
4. Use `timeline` and a destination restore to inspect earlier work safely.
5. Only then make an explicit `share`, `resolve`, or `deliver` action when that
   is your actual intention.

`status` answers a compact state question and says whether the current exact
scan differs from the saved checkpoint. `changes` is the path-level answer.
Neither command turns a difference into a save or a shared change.

## Design distinctions

The core distinction is deliberate: scratch recovery is automatic/local;
intent is explicit; conflict is a durable decision; delivery is separate. This
avoids pretending that modified bytes, a merge conflict, a device label, a
language server result, or a CI outcome says what a person intended.

For the formal types and invariants, read [FORMAL_MODEL.md](../FORMAL_MODEL.md).
For exact command and trust boundaries, read [V1_PRODUCT_CONTRACT.md](V1_PRODUCT_CONTRACT.md).
