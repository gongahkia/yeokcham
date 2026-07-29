module type S = sig
  val algorithm : string
  val digest_size : int

  type context
  type digest

  val empty : context
  val feed_bytes : context -> ?off:int -> ?len:int -> bytes -> context
  val feed_string : context -> ?off:int -> ?len:int -> string -> context
  val get : context -> digest
  val digest_bytes : ?off:int -> ?len:int -> bytes -> digest
  val digest_string : ?off:int -> ?len:int -> string -> digest
  val of_raw_string : string -> digest option
  val to_raw_string : digest -> string
  val equal : digest -> digest -> bool
  val compare : digest -> digest -> int
end

module Sha256 : S
