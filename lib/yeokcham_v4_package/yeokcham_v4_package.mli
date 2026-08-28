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
(** Writes a new package directory containing the exact immutable snapshot
    closure required by the verified revisions, plus public
    identity/certificate/revision records. It never copies private signing
    material or a mutable project-state head. *)

val create_with_authority :
  source:Yeokcham_store.repository ->
  destination:string ->
  authority:Trust.authority ->
  revisions:Trust.signed_revision list ->
  authorizations:Trust.authorization list ->
  adoptions:Trust.adoption list ->
  (unit, error) result
(** V2 package creation. The manifest carries the complete public authority
    closure that verifies its epoch-bound revisions and any exact exception
    records. *)

val verify_and_import :
  destination:Yeokcham_store.repository ->
  package:string ->
  membership:Trust.membership ->
  project:Model.project ->
  (verified * Model.project, error) result
(** Verifies package bytes, membership continuity, revision signatures, and each
    received snapshot closure and causal model transition in staging. Only after
    successful verification are immutable objects copied to [destination]. The
    supplied membership prevents a package with an unrelated root from joining
    merely by naming the same repository identifier. No mutable ref changes. *)

val verify_and_import_with_authority :
  destination:Yeokcham_store.repository ->
  package:string ->
  authority:Trust.authority ->
  known_adoptions:Trust.adoption list ->
  project:Model.project ->
  (verified * Model.project, error) result
(** The authority-aware V2 counterpart. It extends only from the destination's
    verified root, validates the imported epoch graph before object import, and
    keeps authority forks explicit. [known_adoptions] are already verified,
    destination-local exact review records; they can authorize their matching
    package revision but are never imported from a mutable head. *)

val membership : verified -> Trust.membership
val authority : verified -> Trust.authority option
val revisions : verified -> Trust.signed_revision list
val authorizations : verified -> Trust.authorization list
val adoptions : verified -> Trust.adoption list

val inspect_authority : package:string -> (Trust.authority, error) result
(** Reads and cryptographically validates only a V2 package manifest's public
    authority closure. It neither imports objects nor changes any project. *)

val inspect_with_authority :
  package:string -> authority:Trust.authority -> (verified, error) result
(** Verifies the public V2 manifest, membership continuity, authority graph,
    revision signatures, and declared exception records without reading package
    objects or changing a project. It is the inspection surface used before an
    administrator records an explicit late-arrival adoption. *)

val apply_revisions : Model.project -> verified -> (Model.project, error) result
(** Adds verified revisions through the pure V4 receive transition in causal
    order. This pure operation neither persists nor materializes a tree. *)
