type parse_error =
  | Empty
  | Odd_hex_length of int
  | Invalid_hex_character of int * char

val parse_error_to_string : parse_error -> string

module type S = sig
  type t

  val of_bytes : string -> (t, parse_error) result
  val to_bytes : t -> string
  val of_hex : string -> (t, parse_error) result
  val to_hex : t -> string
  val short_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Repository_id : S
module Content_id : S
module Snapshot_id : S
module Checkpoint_id : S
module Capsule_id : S
module Capsule_revision_id : S
module Workspace_id : S
module Workspace_revision_id : S
module Workspace_attempt_id : S
module Release_id : S
module Conflict_id : S
module Operation_id : S
module Device_id : S
module Validation_id : S
module Resolution_id : S
