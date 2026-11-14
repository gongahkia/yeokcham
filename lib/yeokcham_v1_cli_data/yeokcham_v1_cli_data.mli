(** Pure versioned stdout envelopes for V1 command results. *)

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


type success_outcome = [ `Completed | `Unchanged | `Incomplete ]
type failure_outcome = [ `Invalid | `Choice_required | `Conflict | `Unavailable | `Integrity_failure | `Blocked | `Interrupted | `Incomplete | `Failed ]
type outcome = [ success_outcome | failure_outcome ]
type next_action = {
  arguments : string list;
  explanation : string;
  applicable : bool;
  confirmation_required : bool;
}

val domain_schema_version : int
val domain_success :
  ?operation_id:string -> ?plan_id:string -> command:string -> outcome:success_outcome ->
  code:string -> message:string -> data:Yojson.Safe.t -> warnings:string list ->
  next_actions:next_action list -> unit -> envelope

val domain_failure :
  ?operation_id:string -> ?plan_id:string -> command:string -> outcome:failure_outcome ->
  error:command_error -> data:Yojson.Safe.t -> warnings:string list ->
  next_actions:next_action list -> unit -> envelope

val version : envelope -> int
val outcome : envelope -> outcome option
val data : envelope -> Yojson.Safe.t option
val next_actions : envelope -> next_action list
(** Schema 2 provides domain outcomes/data/actions while retaining checked V1
    aliases. Legacy schema-1 codecs and golden bytes remain supported. *)
