type identity_error =
  | Invalid_byte_length of { expected : int; actual : int }
  | Invalid_hex_length of { expected : int; actual : int }
  | Invalid_hex_character of { offset : int; character : char }

let identity_error_to_string = function
  | Invalid_byte_length { expected; actual } ->
      Printf.sprintf "identity must contain %d bytes, got %d" expected actual
  | Invalid_hex_length { expected; actual } ->
      Printf.sprintf "identity hex must contain %d characters, got %d" expected
        actual
  | Invalid_hex_character { offset; character } ->
      Printf.sprintf
        "identity hex has invalid lowercase hexadecimal character %C at %d"
        character offset

module type Identity = sig
  type t

  val byte_length : int
  val of_bytes : string -> (t, identity_error) result
  val to_bytes : t -> string
  val of_hex : string -> (t, identity_error) result
  val to_hex : t -> string
  val short_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

let identity_byte_length = 32

let hex_digit value =
  if value < 10 then Char.chr (Char.code '0' + value)
  else Char.chr (Char.code 'a' + value - 10)

let hex_value = function
  | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
  | _ -> None

module Make_identity () : Identity = struct
  type t = string

  let byte_length = identity_byte_length

  let of_bytes bytes =
    let actual = String.length bytes in
    if actual = byte_length then Ok bytes
    else Error (Invalid_byte_length { expected = byte_length; actual })

  let to_bytes identity = identity

  let of_hex hex =
    let expected = byte_length * 2 in
    let actual = String.length hex in
    if actual <> expected then Error (Invalid_hex_length { expected; actual })
    else
      let decoded = Bytes.create byte_length in
      let rec decode offset =
        if offset = expected then Ok (Bytes.unsafe_to_string decoded)
        else
          match (hex_value hex.[offset], hex_value hex.[offset + 1]) with
          | Some high, Some low ->
              Bytes.set decoded (offset / 2) (Char.chr ((high lsl 4) lor low));
              decode (offset + 2)
          | None, _ ->
              Error (Invalid_hex_character { offset; character = hex.[offset] })
          | _, None ->
              Error
                (Invalid_hex_character
                   { offset = offset + 1; character = hex.[offset + 1] })
      in
      decode 0

  let to_hex identity =
    let hex = Bytes.create (byte_length * 2) in
    String.iteri
      (fun index character ->
        let value = Char.code character in
        Bytes.set hex (index * 2) (hex_digit (value lsr 4));
        Bytes.set hex ((index * 2) + 1) (hex_digit (value land 0x0f)))
      identity;
    Bytes.unsafe_to_string hex

  let short_hex identity = String.sub (to_hex identity) 0 12
  let equal = String.equal
  let compare = String.compare
end

module Repository_id = Make_identity ()
module Organization_id = Make_identity ()
module Account_id = Make_identity ()
module User_id = Make_identity ()
module Root_key_id = Make_identity ()
module Device_id = Make_identity ()
module Repository_authority_id = Make_identity ()
module Device_certificate_id = Make_identity ()
module Device_revocation_id = Make_identity ()
module Recovery_package_id = Make_identity ()
module Secure_runtime_session_id = Make_identity ()
module Opaque_object_ref = Make_identity ()
module Ref_event_id = Make_identity ()
module Signer_key_id = Make_identity ()
module Transaction_id = Make_identity ()
module Capsule_id = Make_identity ()
module Capsule_revision_id = Make_identity ()
module Workspace_id = Make_identity ()
module Workspace_revision_id = Make_identity ()
module Workspace_attempt_id = Make_identity ()
module Conflict_id = Make_identity ()
module Resolution_id = Make_identity ()
module Validation_id = Make_identity ()
module Release_id = Make_identity ()

module Encrypted_ref_event = struct
  type t = { id : Ref_event_id.t; object_ref : Opaque_object_ref.t }

  let create ~id ~object_ref = { id; object_ref }
  let id event = event.id
  let object_ref event = event.object_ref
  let compare left right = Ref_event_id.compare left.id right.id
end

type state_error =
  | Duplicate_object_ref of Opaque_object_ref.t
  | Noncanonical_object_ref_order of {
      previous : Opaque_object_ref.t;
      current : Opaque_object_ref.t;
    }
  | Duplicate_ref_event of Ref_event_id.t
  | Noncanonical_ref_event_order of {
      previous : Ref_event_id.t;
      current : Ref_event_id.t;
    }
  | Dangling_ref_event of {
      event_id : Ref_event_id.t;
      object_ref : Opaque_object_ref.t;
    }

let state_error_to_string = function
  | Duplicate_object_ref object_ref ->
      Printf.sprintf "duplicate opaque object reference: %s"
        (Opaque_object_ref.to_hex object_ref)
  | Noncanonical_object_ref_order { previous; current } ->
      Printf.sprintf
        "opaque object references are not in canonical order: %s >= %s"
        (Opaque_object_ref.to_hex previous)
        (Opaque_object_ref.to_hex current)
  | Duplicate_ref_event event_id ->
      Printf.sprintf "duplicate encrypted ref event: %s"
        (Ref_event_id.to_hex event_id)
  | Noncanonical_ref_event_order { previous; current } ->
      Printf.sprintf "encrypted ref events are not in canonical order: %s >= %s"
        (Ref_event_id.to_hex previous)
        (Ref_event_id.to_hex current)
  | Dangling_ref_event { event_id; object_ref } ->
      Printf.sprintf "encrypted ref event %s references unknown object %s"
        (Ref_event_id.to_hex event_id)
        (Opaque_object_ref.to_hex object_ref)

type local_state = {
  repository_id : Repository_id.t;
  device_id : Device_id.t;
  object_refs : Opaque_object_ref.t list;
  ref_events : Encrypted_ref_event.t list;
}

type verified_repository_state = Verified of local_state

let ( let* ) = Result.bind

let rec validate_object_refs = function
  | [] | [ _ ] -> Ok ()
  | previous :: (current :: _ as rest) ->
      let comparison = Opaque_object_ref.compare previous current in
      if comparison = 0 then Error (Duplicate_object_ref current)
      else if comparison > 0 then
        Error (Noncanonical_object_ref_order { previous; current })
      else validate_object_refs rest

let rec validate_ref_events = function
  | [] | [ _ ] -> Ok ()
  | previous :: (current :: _ as rest) ->
      let previous_id = Encrypted_ref_event.id previous in
      let current_id = Encrypted_ref_event.id current in
      let comparison = Ref_event_id.compare previous_id current_id in
      if comparison = 0 then Error (Duplicate_ref_event current_id)
      else if comparison > 0 then
        Error
          (Noncanonical_ref_event_order
             { previous = previous_id; current = current_id })
      else validate_ref_events rest

let create_local_state ~repository_id ~device_id ~object_refs ~ref_events =
  let* () = validate_object_refs object_refs in
  let* () = validate_ref_events ref_events in
  Ok { repository_id; device_id; object_refs; ref_events }

let contains_object object_refs object_ref =
  List.exists (Opaque_object_ref.equal object_ref) object_refs

let verify state =
  let rec verify_ref_events = function
    | [] -> Ok (Verified state)
    | event :: rest ->
        let object_ref = Encrypted_ref_event.object_ref event in
        if contains_object state.object_refs object_ref then
          verify_ref_events rest
        else
          Error
            (Dangling_ref_event
               { event_id = Encrypted_ref_event.id event; object_ref })
  in
  verify_ref_events state.ref_events

let verified_repository_id (Verified state) = state.repository_id
let verified_device_id (Verified state) = state.device_id
let verified_object_refs (Verified state) = state.object_refs
let verified_ref_events (Verified state) = state.ref_events
