(** Versioned, directory-backed offline V1 exchange packages.

    A package is verified in a temporary immutable store before any object is
    copied to its destination. It has no mutable-head or working-tree effect. *)

module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust

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
  | Core_model_error of Model.Core.error
  | Core_record_error of Yeokcham_v1_record.Core.error
  | Core_trust_error of Trust.Core.error
  | Core_graph_error of Yeokcham_v1_composition.Graph.failure

val error_to_string : error -> string

module Core : sig
  type manifest
  type prepared

  val schema_version : int64
  val max_manifest_bytes : int
  val max_object_bytes : int
  val encode_manifest : manifest -> (string, error) result

  val decode_manifest :
    repository:Model.Core.Repository_id.t -> string -> (manifest, error) result

  val manifest_repository : manifest -> Model.Core.Repository_id.t
  val manifest_branch : manifest -> Model.Core.Branch_id.t

  val metadata_roots :
    manifest -> (string * Yeokcham_store.Stored_object_id.t) list

  val inventory :
    Yeokcham_store.repository ->
    manifest ->
    ((Yeokcham_store.Stored_object_id.t * int) list, error) result

  val create :
    source:Yeokcham_store.repository ->
    destination:string ->
    authority:Trust.authority ->
    records:(Model.Core.Record_id.t * Yeokcham_store.Stored_object_id.t) list ->
    selected_branch:Model.Core.Branch_id.t ->
    titles:(Model.Core.Record_id.t * string) list ->
    (artifact, error) result
  (** Public Core records, authority, courier labels and their exact verified
      dependency closure. Never traverses private history or the whole store.
      Creates a new directory artifact; no mutable head or file application. *)

  val prepare :
    package:string ->
    repository:Model.Core.Repository_id.t ->
    known_authority:Trust.authority option ->
    (prepared, error) result
  (** Verifies bytes in an isolated store, including exact public inventory and
      actual composition. Known authority pins its causal root; without it the
      caller must independently verify the public root before using the result.
      Historical signature checks are not current new-record admission. *)

  val prepared_artifact : prepared -> artifact
  val prepared_authority : prepared -> Trust.authority
  val prepared_pool : prepared -> Model.Core.pool

  val prepared_records :
    prepared ->
    (Model.Core.Record_id.t * Yeokcham_store.Stored_object_id.t) list

  val prepared_titles : prepared -> (Model.Core.Record_id.t * string) list
  val prepared_branch : prepared -> Model.Core.Branch_id.t

  val import_prepared :
    destination:Yeokcham_store.repository -> prepared -> (unit, error) result
  (** Copies verified immutable bytes only. The service must separately perform
      current trust admission and atomic metadata receipt; no cursor/files move.
  *)
end

val manifest_object_ids :
  string -> (Yeokcham_store.Stored_object_id.t list, error) result
(** Parses and canonicality-checks a manifest without reading its object files.
*)

val read_artifact : package:string -> (artifact, error) result
(** Reads and validates a package manifest and exact object-file names without
    retaining any object payload. Each object is validated only when an iterator
    consumer reaches it. *)

val artifact_manifest : artifact -> string

val claim_artifact : artifact -> cleanup:(unit -> unit) -> artifact
(** Attaches one cleanup action to a privately-created temporary package. The
    action runs at [dispose_artifact] and as a best-effort finalizer. Callers
    must not claim a user-supplied package path. *)

val dispose_artifact : artifact -> unit
(** Runs a claimed temporary-package cleanup at most once. Artifacts returned by
    [read_artifact] and [artifact_of_bytes] have no cleanup action. *)

val iter_artifact_objects :
  artifact ->
  f:(Yeokcham_store.Stored_object_id.t -> string -> (unit, error) result) ->
  (unit, error) result
(** Streams canonical, identity-checked object bytes one at a time. The callback
    must not retain the closure when a bounded-memory path is needed. *)

val find_artifact_object :
  artifact ->
  object_id:Yeokcham_store.Stored_object_id.t ->
  (string option, error) result
(** Reads at most the named package object after validating its canonical bytes
    and identity. *)

val artifact_of_bytes :
  manifest:string ->
  objects:(Yeokcham_store.Stored_object_id.t * string) list ->
  (artifact, error) result
(** Validates an in-memory package payload before it is materialized for the
    normal staged verifier. This test/helper adapter retains its caller-provided
    object bytes; capacity and receipt paths use [read_artifact] and
    [iter_artifact_objects] instead. No object or project state is persisted. *)

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
(** Retained only to reject authority-less call paths explicitly. Released V1
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
(** Retained only to reject authority-less call paths explicitly. Released V1
    packages require [verify_and_import_with_authority]. *)

val prepare_with_authority :
  package:string ->
  authority:Trust.authority ->
  known_adoptions:Trust.adoption list ->
  project:Model.project ->
  (prepared, error) result
(** Verifies all untrusted package bytes in an isolated store and applies the
    pure model transition, but does not import a destination object. Object
    bytes are streamed through the isolated store and reread with the same
    identity checks during later import; the prepared value never retains the
    closure in memory. Callers can validate a whole relay-discovery batch before
    importing any member. *)

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
(** Adds verified shared records through the pure V1 receive transition and
    verified resolution records through the pure [resolve] transition, deferring
    only missing parents or not-yet-derived decisions. This pure operation
    neither persists nor materializes a tree. *)
