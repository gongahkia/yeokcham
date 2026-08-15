type parse_error =
  | Empty
  | Odd_hex_length of int
  | Invalid_hex_character of int * char

let parse_error_to_string = function
  | Empty -> "identity bytes are empty"
  | Odd_hex_length length ->
      Printf.sprintf "hex identity has odd length: %d" length
  | Invalid_hex_character (index, character) ->
      Printf.sprintf "invalid hex character at index %d: %C" index character

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

let hex_digit value =
  if value < 10 then Char.chr (Char.code '0' + value)
  else Char.chr (Char.code 'a' + value - 10)

let hex_value = function
  | '0' .. '9' as character -> Ok (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Ok (Char.code character - Char.code 'a' + 10)
  | 'A' .. 'F' as character -> Ok (Char.code character - Char.code 'A' + 10)
  | character -> Error character

let bytes_to_hex raw =
  let encoded = Bytes.create (String.length raw * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set encoded (index * 2) (hex_digit (value lsr 4));
      Bytes.set encoded ((index * 2) + 1) (hex_digit (value land 0x0f)))
    raw;
  Bytes.unsafe_to_string encoded

let bytes_of_hex encoded =
  let length = String.length encoded in
  if length = 0 then Error Empty
  else if length mod 2 <> 0 then Error (Odd_hex_length length)
  else
    let raw = Bytes.create (length / 2) in
    let rec decode index =
      if index = length then Ok (Bytes.unsafe_to_string raw)
      else
        match hex_value encoded.[index] with
        | Error character -> Error (Invalid_hex_character (index, character))
        | Ok high -> (
            match hex_value encoded.[index + 1] with
            | Error character ->
                Error (Invalid_hex_character (index + 1, character))
            | Ok low ->
                Bytes.set raw (index / 2) (Char.chr ((high lsl 4) lor low));
                decode (index + 2))
    in
    decode 0

module Make () : S = struct
  type t = string

  let of_bytes raw = if String.is_empty raw then Error Empty else Ok raw
  let to_bytes identity = identity
  let of_hex = bytes_of_hex
  let to_hex = bytes_to_hex

  let short_hex identity =
    let full = to_hex identity in
    String.sub full 0 (min 12 (String.length full))

  let equal = String.equal
  let compare = String.compare
end

module Repository_id = Make ()
module Content_id = Make ()
module Snapshot_id = Make ()
module Checkpoint_id = Make ()
module Capsule_id = Make ()
module Capsule_revision_id = Make ()
module Workspace_id = Make ()
module Workspace_revision_id = Make ()
module Workspace_attempt_id = Make ()
module Release_id = Make ()
module Conflict_id = Make ()
module Operation_id = Make ()
module Device_id = Make ()
module Validation_id = Make ()
module Resolution_id = Make ()
module Git_mapping_id = Make ()
module Imported_transition_id = Make ()
module Imported_tag_id = Make ()
module Ref_event_id = Make ()
module Git_archive_id = Make ()
module Git_adoption_id = Make ()
module Publication_id = Make ()
module Peer_integration_id = Make ()
module Git_lineage_id = Make ()
module Git_lineage_node_id = Make ()
module Peer_id = Make ()
module Peer_contact_id = Make ()
module Peer_sync_node_id = Make ()
module Peer_sync_conflict_id = Make ()
