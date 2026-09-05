(** Shared foreground adapter loop. Sources report advisory scan requests; only
    this runner invokes the existing exact [save] transition. *)

module type Source = sig
  module Watcher : module type of Yeokcham_watcher

  type t
  type error

  val start : root:string -> (t, error) result
  val poll : t -> timeout:float -> (Watcher.scan_request option, error) result
  val close : t -> unit
  val error_to_string : error -> string
  val retry_start : error -> bool
  val restart_error : error -> bool
  val closed_error : error -> bool
end

module Make (_ : Source) : sig
  val run : root:string -> unit
end
