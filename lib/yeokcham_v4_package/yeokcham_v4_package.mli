(** Versioned, directory-backed offline V4 exchange packages.

    A package is verified in a temporary immutable store before any object is
    copied to its destination. It has no mutable-head or working-tree effect. *)

module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type verified

type error =
  | Io_error of { path : string; operation : string; message : string }
  | Destination_exists of string
  | Invalid_package of string
  | Noncanonical_manifest
  | Store_error of Yeokcham_store.error
  | Envelope_error of Yeokcham_envelope.decode_error
  | Object_identity_mismatch of string
  | Trust_error of Trust.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Model_error of Model.error

val error_to_string : error -> string

val create :
  source:Yeokcham_store.repository ->
  destination:string ->
  membership:Trust.membership ->
  revisions:Trust.signed_revision list ->
  (unit, error) result
(** Writes a new package directory containing all currently immutable source
    objects plus the verified identity/certificate/revision records. The
    complete store is intentionally included in this first package format; a
    later transport may optimize the closure without changing verification. *)

val verify_and_import :
  destination:Yeokcham_store.repository ->
  package:string ->
  repository:Trust.Repository_id.t ->
  (verified, error) result
(** Verifies package bytes, membership, revision signatures, and each received
    snapshot closure in staging. Only after successful verification are
    immutable objects copied to [destination]. No mutable ref changes. *)

val membership : verified -> Trust.membership
val revisions : verified -> Trust.signed_revision list

val apply_revisions : Model.project -> verified -> (Model.project, error) result
(** Adds verified revisions through the pure V4 receive transition in causal
    order. This pure operation neither persists nor materializes a tree. *)
