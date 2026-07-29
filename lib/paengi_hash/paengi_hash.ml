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

module Sha256 : S = struct
  module Backend = Digestif.SHA256

  let algorithm = "sha256"
  let digest_size = Backend.digest_size

  type context = Backend.ctx
  type digest = Backend.t

  let empty = Backend.empty

  let feed_bytes context ?off ?len input =
    Backend.feed_bytes context ?off ?len input

  let feed_string context ?off ?len input =
    Backend.feed_string context ?off ?len input

  let get = Backend.get
  let digest_bytes ?off ?len input = Backend.digest_bytes ?off ?len input
  let digest_string ?off ?len input = Backend.digest_string ?off ?len input
  let of_raw_string = Backend.of_raw_string_opt
  let to_raw_string = Backend.to_raw_string
  let equal = Backend.equal
  let compare = Backend.unsafe_compare
end
