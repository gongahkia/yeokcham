(** Local, inspectable V4 object-store collection.

    The planner is conservative: every current checkpoint is a root, not only
    the checkpoints that have a special model reason. Collection first moves
    candidates into a durable local quarantine; only explicit purge unlinks
    them. No record in this module is package or transport data. *)

type root_reason =
  | State_head
  | Checkpoint of {
      snapshot : Yeokcham_v4_model.Snapshot_id.t;
      reasons : Yeokcham_v4_model.protection_reason list;
    }
  | Unsupported_object_type of Yeokcham_envelope.object_type

type disposition = Retain of root_reason list | Collect

type planned_object = {
  object_id : Yeokcham_store.Stored_object_id.t;
  object_type : Yeokcham_envelope.object_type;
  stored_bytes : int;
  disposition : disposition;
}

type plan = {
  state_head : Yeokcham_store.Stored_object_id.t;
  objects : planned_object list;
  retained_bytes : int;
  collectible_bytes : int;
}

type transaction = {
  transaction_id : string;
  transaction_state_head : Yeokcham_store.Stored_object_id.t;
  transaction_objects : planned_object list;
}

type transaction_progress = {
  progress_transaction : transaction;
  staged_objects : Yeokcham_store.Stored_object_id.t list;
  active_objects : Yeokcham_store.Stored_object_id.t list;
  purged_objects : Yeokcham_store.Stored_object_id.t list;
  purge_started : bool;
}

type error =
  | Store_error of Yeokcham_store.error
  | V4_store_error of Yeokcham_v4_store.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Model_error of Yeokcham_v4_model.error
  | Journal_error of Yeokcham_v4_restore_journal.error
  | Proof_error of Yeokcham_v4_restore_proof.error
  | Invalid_snapshot_id of string
  | Missing_reachable_object of Yeokcham_store.Stored_object_id.t
  | Duplicate_object of Yeokcham_store.Stored_object_id.t
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | No_collectible_objects
  | Transaction_not_found of string
  | Transaction_collision of string
  | Incomplete_transaction of string
  | Stale_transaction_object of Yeokcham_store.Stored_object_id.t
  | Transaction_object_missing of Yeokcham_store.Stored_object_id.t
  | Quarantine_collision of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string
val root_reason_to_string : root_reason -> string
val transaction_id : transaction -> string
val transaction_state_head : transaction -> Yeokcham_store.Stored_object_id.t
val transaction_objects : transaction -> planned_object list
val make_transaction : plan -> (transaction, error) result
val encode_transaction : transaction -> (string, error) result
val decode_transaction : string -> (transaction, error) result

val classify :
  state_head:Yeokcham_store.Stored_object_id.t ->
  objects:Yeokcham_store.object_info list ->
  reachable:(Yeokcham_store.Stored_object_id.t * root_reason list) list ->
  (plan, error) result
(** Pure deterministic classification. Every reachable object must appear in
    [objects]. Unsupported object categories remain retained. *)

val plan : root:string -> (plan, error) result
(** Reads and validates a consistent local V4 state without changing files. *)

val inspect : root:string -> (plan, error) result
(** Reads and validates the same V4 closure as [plan], but does not acquire an
    exclusive lock or create a lock file. It is the health-verification path; a
    later repair must revalidate under its own publication lock. *)

val apply : root:string -> (transaction_progress, error) result
(** Replans under the same locks, writes a canonical transaction, and moves
    every candidate into a local quarantine. It does not unlink objects. *)

val transactions : root:string -> (transaction_progress list, error) result
val resume : root:string -> id:string -> (transaction_progress, error) result
val restore : root:string -> id:string -> (unit, error) result

val purge : root:string -> id:string -> (int, error) result
(** [purge] revalidates that all quarantined objects are still unreachable, then
    durably marks and unlinks them. A transaction with a purge marker must be
    finished by [purge], not restored. The returned value is reclaimed stored
    bytes. *)
