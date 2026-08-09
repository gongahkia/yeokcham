(** Process-local monotonic milliseconds for daemon scheduling. The value has no
    wall-clock meaning and is never persisted. *)

type error = Unavailable of string

val error_to_string : error -> string
val now : unit -> (int64, error) result
