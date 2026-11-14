(** Bounded display differences. These are not composition or acceptance proofs. *)
type kind = Context | Removed | Added
type line = { kind : kind; text : string; newline : bool }
type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  lines : line list;
}
type t = Text of hunk list | Opaque of string
val max_bytes : int
val max_cells : int
val compare : before:string -> after:string -> t
(** UTF-8 without NUL; exact CRLF/final-newline bytes. Prefix/suffix trimming,
    bounded LCS, deletion-first ties, three lines of context. *)
