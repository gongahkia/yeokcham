module Device_id = Paengi_id.Device_id
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Event = Paengi_ref_event
module Object_id = Paengi_store.Stored_object_id
module Store = Paengi_store

type t = {
  device_id : Device_id.t;
  signer_key_id : Event.signer_key_id;
  public_key : string;
  mandatory_features : int64;
}

type signing_capability = Mirage_crypto_ec.Ed25519.priv

type generated = {
  generated_identity : t;
  signing_capability : signing_capability;
}

type registry_entry = { entry_identity : t; object_id : Object_id.t }
type registry = registry_entry list

type resolution =
  | Device_resolved of { device_id : Device_id.t; object_id : Object_id.t }
  | Device_unmapped of Event.signer_key_id
  | Device_ambiguous of {
      signer_key_id : Event.signer_key_id;
      device_ids : Device_id.t list;
    }

type error =
  | Invalid_device_id of int
  | Invalid_public_key of int
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Invalid_identity of string
  | Invalid_payload of string
  | Entropy_failure of string
  | Registry_too_large of int
  | Invalid_registry of string
  | Object_id_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Event_error of Event.error
  | Envelope_error of Envelope.creation_error

let algorithm = Event.algorithm
let max_registry_entries = 256
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_device_id length ->
      Printf.sprintf "device ID must contain 32 bytes, got %d" length
  | Invalid_public_key length ->
      Printf.sprintf "device Ed25519 public key must contain 32 bytes, got %d"
        length
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported device signing algorithm: %s" value
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported device mandatory features: %Ld" features
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported device schema version: %Ld" version
  | Invalid_identity detail -> "invalid device identity: " ^ detail
  | Invalid_payload detail -> "invalid device payload: " ^ detail
  | Entropy_failure detail -> "device entropy failure: " ^ detail
  | Registry_too_large count ->
      Printf.sprintf "device registry has %d entries; limit is %d" count
        max_registry_entries
  | Invalid_registry detail -> "invalid device registry: " ^ detail
  | Object_id_mismatch { expected; actual } ->
      Printf.sprintf "device object ID mismatch: expected %s, got %s"
        (Object_id.to_hex expected)
        (Object_id.to_hex actual)
  | Event_error error -> Event.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error

let lowercase_hex bytes =
  let encoded = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index byte ->
      Bytes.set encoded (index * 2) "0123456789abcdef".[Char.code byte lsr 4];
      Bytes.set encoded
        ((index * 2) + 1)
        "0123456789abcdef".[Char.code byte land 15])
    bytes;
  Bytes.unsafe_to_string encoded

let signer_key_id_to_hex key_id =
  Event.signer_key_id_to_bytes key_id |> lowercase_hex

let resolution_to_string = function
  | Device_resolved { device_id; object_id } ->
      "device-resolved:" ^ Device_id.to_hex device_id ^ ":"
      ^ Object_id.to_hex object_id
  | Device_unmapped signer_key_id ->
      "device-unmapped:" ^ signer_key_id_to_hex signer_key_id
  | Device_ambiguous { signer_key_id; device_ids } ->
      "device-ambiguous:"
      ^ signer_key_id_to_hex signer_key_id
      ^ ":"
      ^ String.concat "," (List.map Device_id.to_hex device_ids)

let device_id_of_bytes bytes =
  if String.length bytes <> 32 then
    Error (Invalid_device_id (String.length bytes))
  else
    Device_id.of_bytes bytes
    |> Result.map_error (fun error ->
        Invalid_identity (Paengi_id.parse_error_to_string error))

let device_id_to_bytes = Device_id.to_bytes

let check_features features =
  if Int64.equal features 0L then Ok ()
  else Error (Unsupported_mandatory_features features)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let make ~device_id ~public_key ~mandatory_features =
  if String.length (Device_id.to_bytes device_id) <> 32 then
    Error (Invalid_device_id (String.length (Device_id.to_bytes device_id)))
  else if String.length public_key <> 32 then
    Error (Invalid_public_key (String.length public_key))
  else
    let* () = check_features mandatory_features in
    let* signer_key_id =
      Event.signer_key_id_of_public_key public_key
      |> Result.map_error (fun error -> Event_error error)
    in
    Ok { device_id; signer_key_id; public_key; mandatory_features }

let make_generated ~device_id ~private_key ~mandatory_features =
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let* identity = make ~device_id ~public_key ~mandatory_features in
  Ok { generated_identity = identity; signing_capability = private_key }

let generate () =
  try
    Mirage_crypto_rng_unix.use_default ();
    let* device_id = device_id_of_bytes (Mirage_crypto_rng.generate 32) in
    let private_key, _ = Mirage_crypto_ec.Ed25519.generate () in
    make_generated ~device_id ~private_key ~mandatory_features:0L
  with _ -> Error (Entropy_failure "OS CSPRNG unavailable")

let generated_identity generated = generated.generated_identity
let generated_signing_capability generated = generated.signing_capability
let signing_private_key capability = capability
let device_id identity = identity.device_id
let signer_key_id identity = identity.signer_key_id
let public_key identity = identity.public_key
let mandatory_features identity = identity.mandatory_features

let identity_equal left right =
  Device_id.equal left.device_id right.device_id
  && String.equal
       (Event.signer_key_id_to_bytes left.signer_key_id)
       (Event.signer_key_id_to_bytes right.signer_key_id)
  && String.equal left.public_key right.public_key
  && Int64.equal left.mandatory_features right.mandatory_features

let identity_payload identity =
  let* algorithm_value = text algorithm in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Device_id.to_bytes identity.device_id);
      Encoding.bytes (Event.signer_key_id_to_bytes identity.signer_key_id);
      algorithm_value;
      Encoding.bytes identity.public_key;
      Encoding.integer identity.mandatory_features;
    ]

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let nonnegative_integer name value =
  let* value = integer name value in
  if Int64.compare value 0L < 0 then
    Error (Invalid_payload (name ^ " must be non-negative"))
  else Ok value

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let decode_identity_payload value =
  let* values = fields "device identity" 6 value in
  match values with
  | [ version; device_id; signer_key_id; algorithm_value; public_key; features ]
    ->
      let* version = nonnegative_integer "device schema version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* device_id = bytes "device ID" device_id in
        let* device_id = device_id_of_bytes device_id in
        let* supplied_signer_key_id =
          bytes "device signer key ID" signer_key_id
        in
        let* supplied_signer_key_id =
          Event.signer_key_id_of_bytes supplied_signer_key_id
          |> Result.map_error (fun error -> Event_error error)
        in
        let* algorithm_value =
          text_field "device signing algorithm" algorithm_value
        in
        if not (String.equal algorithm_value algorithm) then
          Error (Unsupported_algorithm algorithm_value)
        else
          let* public_key = bytes "device public key" public_key in
          let* mandatory_features =
            integer "device mandatory features" features
          in
          let* identity = make ~device_id ~public_key ~mandatory_features in
          if
            not
              (String.equal
                 (Event.signer_key_id_to_bytes supplied_signer_key_id)
                 (Event.signer_key_id_to_bytes identity.signer_key_id))
          then
            Error (Invalid_identity "signer key ID does not match public key")
          else
            let* canonical = identity_payload identity in
            if Encoding.equal canonical value then Ok identity
            else
              Error (Invalid_payload "device identity payload is noncanonical")
  | _ -> Error (Invalid_payload "device identity has the wrong field count")

let identity_envelope identity =
  let* payload = identity_payload identity in
  Envelope.create ~object_type:Envelope.Device_identity
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let stored_object_id identity =
  identity_envelope identity |> Result.map Store.id_of_envelope

let registry_entry ~identity ~object_id =
  let* expected = stored_object_id identity in
  if Object_id.equal expected object_id then
    Ok { entry_identity = identity; object_id }
  else Error (Object_id_mismatch { expected; actual = object_id })

let compare_registry_entry left right =
  let device =
    Device_id.compare left.entry_identity.device_id
      right.entry_identity.device_id
  in
  if device <> 0 then device
  else Object_id.compare left.object_id right.object_id

let make_registry entries =
  if List.length entries > max_registry_entries then
    Error (Registry_too_large (List.length entries))
  else
    let rec loop previous = function
      | [] -> Ok entries
      | entry :: rest -> (
          match previous with
          | Some previous ->
              let ordering = compare_registry_entry previous entry in
              if ordering = 0 then
                Error (Invalid_registry "duplicate registry row")
              else if ordering > 0 then
                Error
                  (Invalid_registry "registry rows are not canonically sorted")
              else loop (Some entry) rest
          | None -> loop (Some entry) rest)
    in
    loop None entries

let unique_device_ids entries =
  entries
  |> List.map (fun entry -> entry.entry_identity.device_id)
  |> List.sort_uniq Device_id.compare

let resolve_verified registry verified =
  let event = Event.verified_event verified in
  let signer_key_id =
    Event.unsigned_signer_key_id (Event.event_unsigned event)
  in
  let same_signer entry =
    String.equal
      (Event.signer_key_id_to_bytes entry.entry_identity.signer_key_id)
      (Event.signer_key_id_to_bytes signer_key_id)
  in
  let matching = List.filter same_signer registry in
  match matching with
  | [] -> Device_unmapped signer_key_id
  | [ entry ] ->
      let same_device candidate =
        Device_id.equal candidate.entry_identity.device_id
          entry.entry_identity.device_id
      in
      if List.length (List.filter same_device registry) = 1 then
        Device_resolved
          {
            device_id = entry.entry_identity.device_id;
            object_id = entry.object_id;
          }
      else
        Device_ambiguous
          {
            signer_key_id;
            device_ids = unique_device_ids (List.filter same_device registry);
          }
  | _ ->
      Device_ambiguous
        { signer_key_id; device_ids = unique_device_ids matching }
