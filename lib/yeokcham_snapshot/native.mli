(** Descriptor-relative filesystem observations. Every child open refuses
    symlinks; directory handles close deterministically and on finalization. *)
type kind = File | Directory | Link | Fifo | Socket | Character | Block

type directory

val open_at : Unix.file_descr option -> string -> bool -> Unix.file_descr
val inspect_at : Unix.file_descr -> string -> kind * string
val fingerprint : Unix.file_descr -> string
val readlink_at : Unix.file_descr -> string -> string
val names : Unix.file_descr -> string list
val create_at : Unix.file_descr -> string -> Unix.file_descr
val mkdir_at : Unix.file_descr -> string -> unit
val symlink_at : Unix.file_descr -> string -> string -> unit

val rename_at :
  Unix.file_descr -> string -> Unix.file_descr -> string -> bool -> unit
(** Exclusive move when false, atomic exchange when true. Unsupported adapters
    fail explicitly; no overwrite-prone fallback is used. Names are validated
    single components supplied by the materialization planner. *)

val identity : string -> string
val stable : string -> string
val device : string -> string
