(** Redacted argv-list execution for post-success local observers. *)

type public_event

type warning =
  | Missing_executable of string
  | Nonzero_exit of int
  | Signalled of int
  | Timed_out
  | Malformed_output
  | Io_failure of string

val schema_version : int
val default_timeout_seconds : int
val warning_to_string : warning -> string

val make_event :
  event:Yeokcham_v1_hook.event ->
  command:string ->
  repository:string option ->
  paths:string list ->
  identifiers:(string * string) list ->
  (public_event, string) result
(** Rejects secret-shaped identifier names and unredacted values. *)

val encode_event : public_event -> string

val invoke :
  timeout_seconds:int -> public_event -> Yeokcham_v1_hook.hook -> warning option
(** Runs the hook only with the event JSON on stdin and a minimal fixed
    environment. Any observer failure is returned as a warning. *)
