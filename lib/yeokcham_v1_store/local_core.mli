module Core = Yeokcham_v1_model.Core
(** Authenticated local branch metadata for the P2 adapter. Stored in the
    existing project-state root, never a separate mutable ref. *)

type t

type position = {
  branch : Core.Branch_id.t;
  cursor : int64;
  basis : Core.Record_id.t;
}

type publication = private {
  operation : Core.Operation_id.t;
  intent : Core.Digest.t;
  revision : Core.Record_id.t;
  publication_branch : Core.Branch_id.t;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  contributed_scope : Core.Object_id.t;
  title : string;
  witness_root : Yeokcham_store.Stored_object_id.t;
  witnesses : Yeokcham_store.Stored_object_id.t list;
}

val publications : t -> publication list
val find_publication : t -> intent:Core.Digest.t -> publication option

val record_publication :
  store:Yeokcham_store.repository ->
  intent:Core.Digest.t ->
  revision:Core.Record_id.t ->
  source:Core.History_id.t ->
  observed:Core.Object_id.t ->
  contributed_scope:Core.Object_id.t ->
  title:string ->
  t ->
  (t * publication, string) result
(** Stages a private receipt and its exact source Merkle witnesses. The caller
    atomically publishes it with the source history node and signed revision.
    The receipt retains the revision as outbound work; it is not a transfer
    acknowledgement. Identical intent retries reuse the operation identity. *)

val validate_history : Yeokcham_v1_undo.t -> t -> (unit, string) result
val selected : t -> position
val positions : t -> position list
val branches : t -> Core.branch_state list
val empty_snapshot : t -> Core.Object_id.t
val pool : t -> Core.pool

val record_objects :
  t -> (Core.Record_id.t * Yeokcham_store.Stored_object_id.t) list

val initialize :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  certificate:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  cursor:int64 ->
  (t, string) result
(** Creates authenticated empty accepted genesis and the generated main branch.
    Existing workspace files are not passed to or accepted by this operation. *)

val create_branch :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  certificate:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  name:string ->
  cursor:int64 ->
  t ->
  (t, string) result

val lookup : t -> string -> (position, string) result
val remember : t -> cursor:int64 -> (t, string) result

val select : t -> Core.Branch_id.t -> (t, string) result
(** Metadata selection only. The service must complete verified journaled
    materialization before publishing this with the target history cursor. *)

val encode : t -> (string, string) result

val decode :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  string ->
  (t, string) result
(** Verifies canonical typed objects, historical signatures, reference closure
    and actual revision-scope/deterministic accepted-result semantics. Missing
    required contents or unsupported review/resolution semantics refuse. *)

val validate_update : previous:t -> t -> (unit, string) result
(** Existing authenticated records and branch identities cannot be erased. *)

val admit_update :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  previous:t option ->
  t ->
  (unit, string) result
(** New records cross current trust admission; retained historical records do
    not become late arrivals merely because authority subsequently changed. *)

val prepare_revision :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  certificate:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  change:Core.Change_id.t option ->
  previous_revisions:Core.Record_id.t list ->
  base_snapshot:Core.Object_id.t ->
  result_snapshot:Core.Object_id.t ->
  edit_scope_root:Core.Object_id.t ->
  dependencies:Core.Record_id.t list ->
  t ->
  (t * Core.Record_id.t, string) result

val prepare_acceptance :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  certificate:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  parents:Core.Record_id.t list ->
  chosen_revisions:Core.Record_id.t list ->
  result_snapshot:Core.Object_id.t ->
  cursor:int64 ->
  t ->
  (t * Core.Record_id.t, string) result
(** Stages signed immutable records and returns metadata only. These functions
    do not publish a state root, create an outbox, or apply working files. The
    service must journal materialization and atomically commit corresponding
    history/basis/outbound state before announcing acceptance. *)

module For_test : sig
  val record_publication :
    random_bytes:(int -> (string, string) result) ->
    store:Yeokcham_store.repository ->
    intent:Core.Digest.t ->
    revision:Core.Record_id.t ->
    source:Core.History_id.t ->
    observed:Core.Object_id.t ->
    contributed_scope:Core.Object_id.t ->
    title:string ->
    t ->
    (t * publication, string) result

  val create_branch :
    random_bytes:(int -> (string, string) result) ->
    store:Yeokcham_store.repository ->
    authority:Yeokcham_v1_trust.authority ->
    certificate:string ->
    signing_capability:Yeokcham_v1_trust.signing_capability ->
    name:string ->
    cursor:int64 ->
    t ->
    (t, string) result

  val fresh_change :
    random_bytes:(int -> (string, string) result) ->
    t ->
    (Core.Change_id.t, string) result
  (** Trusted deterministic collision/entropy tests; ordinary calls use the OS
      CSPRNG. *)
end
