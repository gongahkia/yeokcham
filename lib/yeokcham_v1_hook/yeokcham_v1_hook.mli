(** Pure local post-operation observer records. They are never V1 history,
    authority, intent, source, or receipt records. *)

type event =
  | Init
  | Save
  | Restore
  | Workspace_activate
  | Workspace_update
  | Draft_new
  | Share
  | Withdraw
  | Resolve
  | Deliver
  | Pin
  | Unpin
  | Compact

type hook
type registry

type error =
  | Invalid_id of string
  | Invalid_argv of string
  | Duplicate_hook of string
  | Unknown_hook of string
  | Unsupported_version of int64
  | Invalid_encoding of string
  | Noncanonical_encoding

val schema_version : int64
val error_to_string : error -> string
val event_to_string : event -> string
val event_of_string : string -> (event, error) result
val make : event:event -> argv:string list -> (hook, error) result
val hook_id : hook -> string
val hook_event : hook -> event
val hook_argv : hook -> string list
val empty : registry
val hooks : registry -> hook list
val add : registry -> hook -> (registry, error) result
val remove : registry -> id:string -> (registry, error) result
val encode : registry -> string
val decode : string -> (registry, error) result
