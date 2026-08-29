(** Versioned, directory-backed offline V4 exchange packages.

    A package is verified in a temporary immutable store before any object is
    copied to its destination. It has no mutable-head or working-tree effect. *)

module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type verified
type artifact
type prepared

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

val manifest_object_ids :
  string -> (Yeokcham_store.Stored_object_id.t list, error) result
(** Parses and canonicality-checks a manifest without reading its object files.
*)

val read_artifact : package:string -> (artifact, error) result
val artifact_manifest : artifact -> string

val artifact_objects :
  artifact -> (Yeokcham_store.Stored_object_id.t * string) list

val artifact_of_bytes :
  manifest:string ->
  objects:(Yeokcham_store.Stored_object_id.t * string) list ->
  (artifact, error) result
(** Validates an in-memory package payload before it is materialized for the
    normal staged verifier. No object or project state is persisted. *)

val materialize_artifact :
  destination:string -> artifact -> (unit, error) result
(** Writes a verified manifest/object byte set as an exclusive temporary
    directory package. The normal package receiver still performs all trust,
    closure, and model checks before import. *)

val create :
  source:Yeokcham_store.repository ->
  destination:string ->
  membership:Trust.membership ->
  revisions:Trust.signed_revision list ->
  (unit, error) result
(** Retained only to reject authority-less call paths explicitly. Released V4
    packages require [create_with_authority]. *)

val create_with_authority :
  source:Yeokcham_store.repository ->
  destination:string ->
  authority:Trust.authority ->
  revisions:Trust.signed_revision list ->
  authorizations:Trust.authorization list ->
  adoptions:Trust.adoption list ->
  (unit, error) result
(** Writes a package with the complete public authority closure that verifies
    its epoch-bound revisions and any exact exception records. *)

val create_bootstrap_with_authority :
  source:Yeokcham_store.repository ->
  destination:string ->
  authority:Trust.authority ->
  revisions:Trust.signed_revision list ->
  authorizations:Trust.authorization list ->
  adoptions:Trust.adoption list ->
  extra_snapshots:Model.Snapshot_id.t list ->
  (unit, error) result
(** Creates the unchanged package-manifest-v1 format with additional exact
    snapshot closure needed by a separately signed bootstrap basis. *)

val verify_and_import_with_authority :
  destination:Yeokcham_store.repository ->
  package:string ->
  authority:Trust.authority ->
  known_adoptions:Trust.adoption list ->
  project:Model.project ->
  (verified * Model.project, error) result
(** Extends only from the destination's verified root, validates the imported
    epoch graph before object import, and keeps authority forks explicit.
    [known_adoptions] are already verified, destination-local exact review
    records; they can authorize their matching package revision but are never
    imported from a mutable head. *)

val verify_and_import :
  destination:Yeokcham_store.repository ->
  package:string ->
  membership:Trust.membership ->
  project:Model.project ->
  (verified * Model.project, error) result
(** Retained only to reject authority-less call paths explicitly. Released V4
    packages require [verify_and_import_with_authority]. *)

val prepare_with_authority :
  package:string ->
  authority:Trust.authority ->
  known_adoptions:Trust.adoption list ->
  project:Model.project ->
  (prepared, error) result
(** Verifies all untrusted package bytes in an isolated store and applies the
    pure model transition, but does not import a destination object. Callers can
    validate a whole relay-discovery batch before importing any member. *)

val import_prepared :
  destination:Yeokcham_store.repository ->
  prepared ->
  (verified * Model.project, error) result

val prepared_verified : prepared -> verified
val prepared_project : prepared -> Model.project
val membership : verified -> Trust.membership
val authority : verified -> Trust.authority option
val revisions : verified -> Trust.signed_revision list
val authorizations : verified -> Trust.authorization list
val adoptions : verified -> Trust.adoption list

val inspect_authority : package:string -> (Trust.authority, error) result
(** Reads and cryptographically validates a package manifest's public authority
    closure. It neither imports objects nor changes any project. *)

val inspect_with_authority :
  package:string -> authority:Trust.authority -> (verified, error) result
(** Verifies the public manifest, membership continuity, authority graph,
    revision signatures, and declared exception records without reading package
    objects or changing a project. It is the inspection surface used before an
    administrator records an explicit late-arrival adoption. *)

val validate_with_authority :
  package:string -> authority:Trust.authority -> (verified, error) result
(** Performs authority inspection and exact object/snapshot closure validation
    in staging without applying a model transition or importing an object. It is
    used for a review-deferred relay package. *)

val validate_snapshot_closure :
  package:string -> snapshots:Model.Snapshot_id.t list -> (unit, error) result
(** Validates additional exact snapshot roots against an already versioned
    package artifact in an isolated store. Bootstrap uses this for delivery
    snapshots that are intentionally not revision records. *)

val apply_revisions : Model.project -> verified -> (Model.project, error) result
(** Adds verified shared records through the pure V4 receive transition and
    verified resolution records through the pure [resolve] transition, deferring
    only missing parents or not-yet-derived decisions. This pure operation
    neither persists nor materializes a tree. *)
