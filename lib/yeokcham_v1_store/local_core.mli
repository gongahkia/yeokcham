module Core = Yeokcham_v1_model.Core
(** Authenticated local branch metadata for the P2 adapter. Stored in the
    existing project-state root, never a separate mutable ref. *)

type t

type position = {
  branch : Core.Branch_id.t;
  cursor : int64;
  basis : Core.Record_id.t;
}

val selected : t -> position
val positions : t -> position list
val branches : t -> Core.branch_state list
val empty_snapshot : t -> Core.Object_id.t

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
    and P2's empty/fork-only accepted semantics. Other acceptance is refused
    until its actual integration/verification boundary exists. *)

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

module For_test : sig
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
  (** Trusted deterministic collision/entropy tests; ordinary calls use the OS
      CSPRNG. *)
end
