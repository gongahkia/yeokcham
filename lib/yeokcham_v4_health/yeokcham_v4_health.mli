(** Pure, closure-scoped V4 health diagnosis and conservative repair planning.

    This module owns neither a filesystem nor an object-store handle. Adapters
    must turn their read observations into these values and may only execute an
    [Eligible] outcome with their own add-if-missing publication primitive. *)

type damage_code =
  | Missing_object
  | Malformed_envelope
  | Canonical_id_mismatch
  | Dangling_reference
  | Unreadable_durable_record
  | Restore_proof_mismatch
  | Unreachable_temporary_state

type blocked_operation =
  | Verify
  | Repair_plan
  | Repair_apply
  | Restore
  | Workspace
  | Compaction
  | Temporary_recovery

type durable_record_kind =
  | State_head
  | Restore_proof
  | Workspace_receipt
  | Gc_transaction
  | Repair_plan_record

type temporary_state_kind =
  | Restore_temporary
  | Gc_temporary
  | Transfer_temporary
  | Repair_temporary

type affected =
  | Object of string
  | Durable_record of durable_record_kind * string
  | Temporary_state of temporary_state_kind * string

type damage
type report
type object_status = Present | Missing | Malformed | Id_mismatch of string

type observation =
  | Object_observation of {
      object_id : string;
      status : object_status;
      references : string list;
    }
  | Durable_observation of {
      durable_kind : durable_record_kind;
      durable_id : string;
      readable : bool;
      restore_mismatch : bool;
    }
  | Temporary_observation of {
      temporary_kind : temporary_state_kind;
      temporary_id : string;
      reachable : bool;
    }

type repair_source =
  | Gc_quarantine of string
  | Offline_package of string
  | Configured_relay of string
  | Bootstrap_artifact of string
  | Backup of string

type repair_candidate
type repair_plan

type selection = {
  selection_plan_id : string;
  selection_candidate_id : string;
  selection_approved_digest : string;
}

type refusal =
  | Invalid_identifier of string
  | Invalid_locator of string
  | Duplicate_observation of string
  | No_damage
  | Invalid_expiry of { created_at : int64; expires_at : int64 }
  | Candidate_source_mismatch
  | Candidate_not_missing
  | Plan_expired
  | Plan_id_mismatch
  | Plan_digest_mismatch
  | Candidate_not_in_plan
  | Candidate_changed
  | State_head_changed
  | Damage_changed
  | Destination_no_longer_missing

type repair_outcome = Eligible of repair_candidate | Refused of refusal

val schema_version : int64
val damage_code_to_string : damage_code -> string
val blocked_operation_to_string : blocked_operation -> string
val refusal_to_string : refusal -> string
val repair_source_to_string : repair_source -> string
val valid_digest : string -> bool
val damage_code : damage -> damage_code
val damage_affected : damage -> affected
val damage_blocked_operations : damage -> blocked_operation list
val report_damages : report -> damage list
val report_is_clean : report -> bool

val verify : observation list -> (report, refusal) result
(** Purely derives sorted independent damage from supplied observations. It has
    no filesystem, network, clock, or mutation dependency. *)

val make_candidate :
  source:repair_source ->
  object_id:string ->
  canonical_bytes_id:string ->
  (repair_candidate, refusal) result

val candidate_id : repair_candidate -> string
val candidate_object_id : repair_candidate -> string
val candidate_bytes_id : repair_candidate -> string
val candidate_source : repair_candidate -> repair_source

val make_plan :
  repository:string ->
  state_head:string ->
  source:repair_source ->
  damages:damage list ->
  candidates:repair_candidate list ->
  created_at:int64 ->
  expires_at:int64 ->
  (repair_plan, refusal) result
(** Constructs one canonical immutable snapshot. Candidates can be empty, but
    every present candidate must be an exact byte match for a missing object in
    [damages] and must originate at the one named [source]. *)

val plan_id : repair_plan -> string
val plan_digest : repair_plan -> string
val plan_repository : repair_plan -> string
val plan_state_head : repair_plan -> string
val plan_source : repair_plan -> repair_source
val plan_damages : repair_plan -> damage list
val plan_candidates : repair_plan -> repair_candidate list
val plan_created_at : repair_plan -> int64
val plan_expires_at : repair_plan -> int64
val make_selection : repair_plan -> candidate_id:string -> selection

val apply_eligibility :
  plan:repair_plan ->
  selection:selection ->
  now:int64 ->
  current_state_head:string ->
  current:report ->
  reread_candidate:repair_candidate option ->
  repair_outcome
(** Revalidates the exact plan, diagnosis, and selected candidate. [Eligible]
    authorises only an adapter's add-if-still-missing attempt; it does not
    publish any bytes itself. *)

val encode_plan : repair_plan -> string
val decode_plan : string -> (repair_plan, refusal) result
