type hunk = { first : int; last : int; replacement : string list }
(** TC06 line-hunks-v1, independent of filesystem and presentation context. *)

val max_bytes : int
val max_cells : int
val lines : string -> string array
val diff : base:string -> result:string -> (hunk list, string) result
val apply : base:string -> hunk list -> (string, string) result

val merge : base:string -> variants:string list -> (string, string) result
(** Variants are a set of base-relative edits. Equal hunks coalesce; different
    insertions at a boundary and insertions touching replacements conflict. *)
