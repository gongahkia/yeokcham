(** Descriptor-relative filesystem observations. Every child open refuses
    symlinks; directory handles close deterministically and on finalization. *)
type kind = File | Directory | Link | Fifo | Socket | Character | Block

type directory

val open_at : Unix.file_descr option -> string -> bool -> Unix.file_descr
val inspect_at : Unix.file_descr -> string -> kind * string
val fingerprint : Unix.file_descr -> string
val readlink_at : Unix.file_descr -> string -> string
val names : Unix.file_descr -> string list
