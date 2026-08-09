(** Read-only local inspection for the currently implemented V2 canonical
    objects. No inspection index is persisted; every result is re-derived from
    authenticated bootstrap, object, ledger, and journal records. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Journal_store = Yeokcham_v2_restore_journal_store
module Scratch_store = Yeokcham_v2_scratch_store
module Verification = Yeokcham_v2_verification
module V2_model = Yeokcham_v2_model

type checkpoint = {
  event_id : Scratch_store.Ledger.Event_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
  snapshot_id : Yeokcham_id.Snapshot_id.t;
  entry_count : int;
}

type scratch =
  | No_checkpoint
  | Checkpoint of checkpoint
  | Divergent of string list

type status = {
  repository_id : V2_model.Repository_id.t;
  device_id : V2_model.Device_id.t;
  scratch : scratch;
  journal_record_count : int;
}

type storage = {
  encrypted_objects : int;
  encrypted_bytes : int64;
  ledger_frames : int;
  scratch_snapshot_frames : int;
  restore_journal_records : int;
}

type error =
  | Bootstrap_error of Yeokcham_v2_bootstrap.error
  | Scratch_store_error of Scratch_store.error
  | Object_store_error of Yeokcham_v2_object_store.error
  | Journal_store_error of Journal_store.error
  | Verification_error of Verification.error
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string

val status :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (status, error) result

val storage :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (storage, error) result

val verify :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (Verification.report, error) result
