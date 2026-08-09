(** Reusable local filesystem operations at the V2 root and inspection boundary.

    This service owns no command-line parsing or rendering. It delegates work to
    the V2 cutover, store, and inspection adapters. *)

type root_availability =
  | V2_ready
  | Uninitialized
  | Legacy
  | Mixed_or_unknown of string
  | Incomplete of string

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Inspection_error of Yeokcham_inspection.error
  | Store_error of Yeokcham_store.error
  | Root_unavailable of root_availability

type init_outcome =
  | Initialized
  | Already_initialized
  | Init_refused of root_availability

type archive_outcome = {
  archive_path : string;
  manifest_path : string;
  already_archived : bool;
}

type reset_outcome = Reset | Already_reset

val root_availability_to_string : root_availability -> string
val error_to_string : error -> string

val classify : root:string -> (root_availability, error) result
(** [classify] is read-only and preserves the cutover adapter's fail-closed
    classification. *)

val require_v2 : root:string -> (unit, error) result
(** [require_v2] returns only for a valid V2 root. *)

val initialize : root:string -> (init_outcome, error) result
(** [initialize] creates an empty V2 root or reports the already-initialized or
    explicitly refused root state without altering a non-V2 root. *)

val archive :
  root:string -> archive_name:string -> (archive_outcome, error) result
(** [archive] delegates the explicit legacy archive transition. *)

val reset :
  root:string ->
  archive_name:string ->
  confirm:bool ->
  (reset_outcome, error) result
(** [reset] delegates the explicitly confirmed V2 reset transition. *)

val status : root:string -> (Yeokcham_inspection.status, error) result

val timeline :
  root:string ->
  limit:int ->
  (Yeokcham_inspection.timeline_entry list, error) result

val storage : root:string -> (Yeokcham_inspection.storage_report, error) result

val verify :
  root:string -> (Yeokcham_inspection.verification_report, error) result
(** The inspection functions require a valid V2 root and never write an object,
    journal, or mutable reference. *)
