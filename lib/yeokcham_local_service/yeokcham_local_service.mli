(** Reusable local filesystem operations at the V2 root boundary.

    This service owns no command-line parsing or rendering. It delegates every
    durable transition to the V2 cutover and store adapters. *)

type root_availability =
  | V2_ready
  | Uninitialized
  | Legacy
  | Mixed_or_unknown of string
  | Incomplete of string

type error =
  | Cutover_error of Yeokcham_cutover.error
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
