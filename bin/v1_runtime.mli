(** Linux-only, disposable V1 runtime lifecycle. *)

val start : root:string -> unit
val status : root:string -> unit
val stop : root:string -> unit
val sync : root:string -> remote:string -> unit
val run : root:string -> unit
