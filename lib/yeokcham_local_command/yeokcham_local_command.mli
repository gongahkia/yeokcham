(** Parsing and rendering adapters for the V2 root service.

    Parsing and rendering are pure. [execute] is the sole adapter that invokes a
    local filesystem service transition. *)

type command =
  | Init
  | Archive of { archive_name : string }
  | Reset of { archive_name : string }

type parse_error = Invalid_arguments

type response =
  | Initialized
  | Already_initialized
  | Init_refused of Yeokcham_local_service.root_availability
  | Archived of Yeokcham_local_service.archive_outcome
  | Reset_completed
  | Already_reset

val parse :
  name:string -> arguments:string list -> (command, parse_error) result
(** Parses only exact root-command arguments; it performs no filesystem access.
*)

val execute :
  root:string -> command -> (response, Yeokcham_local_service.error) result
(** Executes one already-parsed command without rendering it. *)

val render : response -> string
(** [render] is deterministic and has no filesystem effects. *)

val parse_error_to_string : parse_error -> string
