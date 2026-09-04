(** Pure versioned stdout envelopes for V4 command results. *)

type command_error = { code : string; message : string }
type command_result = Completed
type envelope

val schema_version : int
val command_result_json : command_result -> Yojson.Safe.t

val success :
  command:string -> result:Yojson.Safe.t -> warnings:string list -> envelope

val failure :
  command:string -> error:command_error -> warnings:string list -> envelope

val command : envelope -> string
val ok : envelope -> bool
val result : envelope -> Yojson.Safe.t option
val warnings : envelope -> string list
val error : envelope -> command_error option
val encode : envelope -> string
val decode : string -> (envelope, string) result
