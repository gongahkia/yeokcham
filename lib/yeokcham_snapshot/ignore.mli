type error = { source : string; line : int; pattern : string; message : string }
(** Native byte-oriented .yeokchamignore rules; no Git or filesystem effects. *)

val error_to_string : error -> string

type rule
type t

val empty : t

val extend :
  t -> source:string -> base:string list -> string -> (t, error) result

val source : rule -> string
val line : rule -> int
val pattern : rule -> string
val includes : rule -> bool

type decision = { ignored : bool; rule : rule option; blocked_by_parent : bool }

val evaluate : t -> path:string list -> directory:bool -> decision
(** Ancestor exclusion blocks descendant re-inclusion until the ancestor itself
    has been re-included. The returned rule explains the effective decision. *)
