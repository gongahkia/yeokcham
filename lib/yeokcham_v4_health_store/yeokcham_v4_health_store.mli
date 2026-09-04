(** Local create-only storage for canonical [repair-plan-v1] bytes.

    Repair plans are operator-local approval records. They are never V4 objects,
    project state, packages, relay bytes, or source-tree data. *)

type error =
  | Health_error of Yeokcham_v4_health.refusal
  | Invalid_plan_id of string
  | Metadata_missing of string
  | Invalid_metadata_path of string
  | Plan_collision of string
  | Not_found of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string
val directory : root:string -> string
val path : root:string -> id:string -> (string, error) result

val append :
  root:string -> Yeokcham_v4_health.repair_plan -> (unit, error) result
(** Creates only a missing matching canonical plan. A divergent existing file
    remains in place and returns [Plan_collision]. *)

val find :
  root:string -> id:string -> (Yeokcham_v4_health.repair_plan, error) result

val scan : root:string -> (Yeokcham_v4_health.repair_plan list, error) result
(** Reads every strict [repair-plan-v1] entry in canonical plan-ID order. *)
