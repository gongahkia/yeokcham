module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Store = Yeokcham_store
module Peer_sync = Yeokcham_peer_sync
module Peer_id = Id.Peer_id
module Sync_node_id = Id.Peer_sync_node_id

type object_entry = {
  object_id : Store.Stored_object_id.t;
  object_envelope : Envelope.t;
}

type package = {
  package_identity : string;
  package_sender_identity : Peer_sync.identity;
  package_destination_identity : Peer_id.t;
  package_tracking : string;
  package_head_identity : Sync_node_id.t;
  package_head_object : Store.Stored_object_id.t;
  package_issued_at : int64;
  package_expires_at : int64;
  package_nonce : string;
  package_objects : object_entry list;
  package_signature : string;
}

type advertisement = {
  advertisement_identity : string;
  advertisement_package : string;
  advertisement_sender_identity : Peer_sync.identity;
  advertisement_destination_identity : Peer_id.t;
  advertisement_tracking : string;
  advertisement_head_identity : Sync_node_id.t;
  advertisement_issued_at : int64;
  advertisement_expires_at : int64;
  advertisement_nonce : string;
  advertisement_signature : string;
}

type error =
  | Invalid_relay_path of string
  | Invalid_package of string
  | Invalid_advertisement of string
  | Package_too_large of int
  | Signature_verification_failed
  | Repository_format_mismatch
  | Contact_mismatch
  | Destination_mismatch
  | Tracking_mismatch
  | Expired of { issued_at : int64; expires_at : int64; now : int64 }
  | Replay of string
  | Missing_package of string
  | Publication_conflict of string
  | Io_error of string
  | Peer_error of Peer_sync.error
  | Store_error of Store.error

let max_package_bytes = 512 * 1024 * 1024
let max_package_objects = 100_000
let max_advertisement_age_seconds = 604_800L
let max_future_skew_seconds = 300L
let max_tracking_name_bytes = 128
let package_domain = "yeokcham:peer-sync:relay-package:v1\000"
let package_id_domain = "yeokcham:peer-sync:relay-package-id:v1\000"
let advertisement_domain = "yeokcham:peer-sync:relay-advertisement:v1\000"
let advertisement_id_domain = "yeokcham:peer-sync:relay-advertisement-id:v1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_relay_path detail -> "invalid relay path: " ^ detail
  | Invalid_package detail -> "invalid relay package: " ^ detail
  | Invalid_advertisement detail -> "invalid relay advertisement: " ^ detail
  | Package_too_large size ->
      Printf.sprintf "relay package is too large: %d bytes" size
  | Signature_verification_failed -> "relay signature verification failed"
  | Repository_format_mismatch ->
      "relay package repository format does not match"
  | Contact_mismatch -> "relay package does not match the pinned contact"
  | Destination_mismatch -> "relay package is not addressed to this identity"
  | Tracking_mismatch -> "relay package tracking name does not match"
  | Expired { issued_at; expires_at; now } ->
      Printf.sprintf
        "relay advertisement is outside its freshness window (issued=%Ld \
         expires=%Ld now=%Ld)"
        issued_at expires_at now
  | Replay package_id -> "relay package was already imported: " ^ package_id
  | Missing_package package_id -> "relay package is missing: " ^ package_id
  | Publication_conflict detail -> "relay publication conflict: " ^ detail
  | Io_error detail -> "relay I/O error: " ^ detail
  | Peer_error error -> Peer_sync.error_to_string error
  | Store_error error -> Store.error_to_string error

let is_replay_error = function
  | Invalid_relay_path _ | Invalid_package _ | Invalid_advertisement _
  | Package_too_large _ | Signature_verification_failed
  | Repository_format_mismatch | Contact_mismatch | Destination_mismatch
  | Tracking_mismatch | Expired _ | Missing_package _ | Publication_conflict _
  | Io_error _ | Peer_error _ | Store_error _ ->
      false
  | Replay _ -> true

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let repository_digest =
  Hash.digest_string Store.repository_format |> Hash.to_raw_string

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_package (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_package (Encoding.construction_error_to_string error))

let package_array values =
  match values with
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package "value must be an array")

let advertisement_array values =
  match values with
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_advertisement "value must be an array")

let package_fields name length value =
  let* values = package_array value in
  if List.length values = length then Ok values
  else Error (Invalid_package (name ^ " has the wrong field count"))

let advertisement_fields name length value =
  let* values = advertisement_array value in
  if List.length values = length then Ok values
  else Error (Invalid_advertisement (name ^ " has the wrong field count"))

let package_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be an integer"))

let advertisement_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_advertisement (name ^ " must be an integer"))

let package_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be bytes"))

let advertisement_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_advertisement (name ^ " must be bytes"))

let package_text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be text"))

let advertisement_text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_advertisement (name ^ " must be text"))

let valid_tracking_name value =
  (not (String.is_empty value))
  && String.length value <= max_tracking_name_bytes
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
         | _ -> false)
       value

let peer_id_from_package name value =
  let* raw = package_bytes name value in
  if String.length raw <> 32 then
    Error (Invalid_package (name ^ " must contain 32 bytes"))
  else
    Peer_id.of_bytes raw
    |> Result.map_error (fun error ->
        Invalid_package (Id.parse_error_to_string error))

let peer_id_from_advertisement name value =
  let* raw = advertisement_bytes name value in
  if String.length raw <> 32 then
    Error (Invalid_advertisement (name ^ " must contain 32 bytes"))
  else
    Peer_id.of_bytes raw
    |> Result.map_error (fun error ->
        Invalid_advertisement (Id.parse_error_to_string error))

let sync_node_id_from_package name value =
  let* raw = package_bytes name value in
  if String.length raw <> 32 then
    Error (Invalid_package (name ^ " must contain 32 bytes"))
  else
    Sync_node_id.of_bytes raw
    |> Result.map_error (fun error ->
        Invalid_package (Id.parse_error_to_string error))

let sync_node_id_from_advertisement name value =
  let* raw = advertisement_bytes name value in
  if String.length raw <> 32 then
    Error (Invalid_advertisement (name ^ " must contain 32 bytes"))
  else
    Sync_node_id.of_bytes raw
    |> Result.map_error (fun error ->
        Invalid_advertisement (Id.parse_error_to_string error))

let stored_object_id_from_package name value =
  let* raw = package_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some id -> Ok id
  | None -> Error (Invalid_package (name ^ " must contain 32 bytes"))

let raw_advertisement_id name value =
  let* raw = advertisement_bytes name value in
  if String.length raw = 32 then Ok raw
  else Error (Invalid_advertisement (name ^ " must contain 32 bytes"))

let package_object_value object_entry =
  array
    [
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes object_entry.object_id);
      Encoding.bytes (Envelope.encode object_entry.object_envelope);
    ]

let package_unsigned_value package =
  let* sender =
    Peer_sync.identity_payload package.package_sender_identity
    |> Result.map_error (fun error -> Peer_error error)
  in
  let* domain = text "yeokcham:peer-sync:relay-package:v1" in
  let* tracking = text package.package_tracking in
  let* objects =
    List.fold_left
      (fun result object_entry ->
        let* reversed = result in
        let* value = package_object_value object_entry in
        Ok (value :: reversed))
      (Ok []) package.package_objects
    |> Result.map List.rev
  in
  let* objects = array objects in
  array
    [
      Encoding.integer 1L;
      domain;
      Encoding.bytes repository_digest;
      sender;
      Encoding.bytes (Peer_id.to_bytes package.package_destination_identity);
      tracking;
      Encoding.bytes (Sync_node_id.to_bytes package.package_head_identity);
      Encoding.bytes
        (Store.Stored_object_id.to_raw_bytes package.package_head_object);
      Encoding.integer package.package_issued_at;
      Encoding.integer package.package_expires_at;
      Encoding.bytes package.package_nonce;
      objects;
    ]

let package_signing_bytes package =
  package_unsigned_value package
  |> Result.map Encoding.encode
  |> Result.map (fun value -> package_domain ^ value)

let package_payload package =
  if String.length package.package_signature <> 64 then
    Error (Invalid_package "signature must contain 64 bytes")
  else
    let* unsigned = package_unsigned_value package in
    let* algorithm = text Peer_sync.algorithm in
    array
      [
        Encoding.integer 1L;
        unsigned;
        algorithm;
        Encoding.bytes package.package_signature;
      ]

let package_id_of_payload payload =
  digest package_id_domain (Encoding.encode payload)

let verify_package_signature package =
  if String.length package.package_signature <> 64 then
    Error (Invalid_package "signature must contain 64 bytes")
  else
    let* signing_bytes = package_signing_bytes package in
    match
      Mirage_crypto_ec.Ed25519.pub_of_octets
        (Peer_sync.public_key package.package_sender_identity)
    with
    | Error _ -> Error Signature_verification_failed
    | Ok public_key -> (
        try
          if
            Mirage_crypto_ec.Ed25519.verify ~key:public_key
              package.package_signature ~msg:signing_bytes
          then Ok ()
          else Error Signature_verification_failed
        with _ -> Error Signature_verification_failed)

let package_id package = package.package_identity
let package_sender package = package.package_sender_identity
let package_destination package = package.package_destination_identity
let package_tracking_name package = package.package_tracking
let package_head package = package.package_head_identity

let compare_object_entry left right =
  Store.Stored_object_id.compare left.object_id right.object_id

let require_sorted_unique_objects values =
  let rec loop previous = function
    | [] -> Ok ()
    | value :: rest ->
        if
          Option.exists
            (fun previous -> compare_object_entry previous value >= 0)
            previous
        then Error (Invalid_package "objects must be in strict object-ID order")
        else loop (Some value) rest
  in
  loop None values

let decode_package_object value =
  let* fields = package_fields "relay package object" 2 value in
  match fields with
  | [ supplied_id; encoded ] ->
      let* object_id =
        stored_object_id_from_package "relay package object ID" supplied_id
      in
      let* encoded = package_bytes "relay package envelope" encoded in
      if String.length encoded > Store.max_object_bytes then
        Error (Package_too_large (String.length encoded))
      else
        let* envelope =
          Envelope.decode encoded
          |> Result.map_error (fun error ->
              Invalid_package (Envelope.decode_error_to_string error))
        in
        if
          not
            (Store.Stored_object_id.equal object_id
               (Store.id_of_envelope envelope))
        then
          Error (Invalid_package "relay package object ID does not match bytes")
        else if not (String.equal encoded (Envelope.encode envelope)) then
          Error (Invalid_package "relay package envelope is noncanonical")
        else Ok { object_id; object_envelope = envelope }
  | _ -> assert false

let decode_package_payload value =
  let* fields = package_fields "relay package" 4 value in
  match fields with
  | [ version; unsigned; algorithm; signature ] -> (
      let* version = package_integer "relay package version" version in
      if not (Int64.equal version 1L) then
        Error (Invalid_package "unsupported relay package version")
      else
        let* unsigned_fields =
          package_fields "relay package unsigned" 12 unsigned
        in
        match unsigned_fields with
        | [
         unsigned_version;
         domain;
         format;
         sender;
         destination;
         tracking;
         head;
         head_object;
         issued_at;
         expires_at;
         nonce;
         objects;
        ] ->
            let* unsigned_version =
              package_integer "relay package unsigned version" unsigned_version
            in
            let* domain = package_text "relay package domain" domain in
            let* format = package_bytes "relay package format" format in
            let* sender =
              Peer_sync.decode_identity_payload sender
              |> Result.map_error (fun error -> Peer_error error)
            in
            let* destination =
              peer_id_from_package "relay package destination" destination
            in
            let* tracking =
              package_text "relay package tracking name" tracking
            in
            let* head = sync_node_id_from_package "relay package head" head in
            let* head_object =
              stored_object_id_from_package "relay package head object"
                head_object
            in
            let* issued_at =
              package_integer "relay package issued-at" issued_at
            in
            let* expires_at =
              package_integer "relay package expires-at" expires_at
            in
            let* nonce = package_bytes "relay package nonce" nonce in
            let* object_values = package_array objects in
            if not (Int64.equal unsigned_version 1L) then
              Error
                (Invalid_package "unsupported relay package unsigned version")
            else if
              not (String.equal domain "yeokcham:peer-sync:relay-package:v1")
            then Error (Invalid_package "relay package has the wrong domain")
            else if String.length format <> 32 then
              Error
                (Invalid_package
                   "relay package format digest must contain 32 bytes")
            else if not (String.equal format repository_digest) then
              Error Repository_format_mismatch
            else if not (valid_tracking_name tracking) then
              Error (Invalid_package "relay package tracking name is invalid")
            else if String.length nonce <> Peer_sync.nonce_bytes then
              Error (Invalid_package "relay package nonce has the wrong length")
            else if
              Int64.compare expires_at issued_at <= 0
              || Int64.compare
                   (Int64.sub expires_at issued_at)
                   max_advertisement_age_seconds
                 > 0
            then
              Error
                (Invalid_package "relay package expiry is outside its bound")
            else if
              List.length object_values = 0
              || List.length object_values > max_package_objects
            then
              Error
                (Invalid_package
                   "relay package object count is outside its bound")
            else
              let* objects =
                List.fold_left
                  (fun result object_value ->
                    let* reversed = result in
                    let* object_entry = decode_package_object object_value in
                    Ok (object_entry :: reversed))
                  (Ok []) object_values
                |> Result.map List.rev
              in
              let* () = require_sorted_unique_objects objects in
              if
                not
                  (List.exists
                     (fun object_entry ->
                       Store.Stored_object_id.equal object_entry.object_id
                         head_object)
                     objects)
              then Error (Invalid_package "relay package omits its head object")
              else
                let* algorithm =
                  package_text "relay package algorithm" algorithm
                in
                let* signature =
                  package_bytes "relay package signature" signature
                in
                if not (String.equal algorithm Peer_sync.algorithm) then
                  Error (Invalid_package "unsupported relay package algorithm")
                else if String.length signature <> 64 then
                  Error
                    (Invalid_package
                       "relay package signature must contain 64 bytes")
                else
                  let provisional =
                    {
                      package_identity = "";
                      package_sender_identity = sender;
                      package_destination_identity = destination;
                      package_tracking = tracking;
                      package_head_identity = head;
                      package_head_object = head_object;
                      package_issued_at = issued_at;
                      package_expires_at = expires_at;
                      package_nonce = nonce;
                      package_objects = objects;
                      package_signature = signature;
                    }
                  in
                  let* canonical = package_payload provisional in
                  if not (Encoding.equal canonical value) then
                    Error (Invalid_package "relay package is noncanonical")
                  else
                    let identity = package_id_of_payload canonical in
                    let package =
                      { provisional with package_identity = identity }
                    in
                    let* () = verify_package_signature package in
                    Ok package
        | _ -> assert false)
  | _ -> assert false

let make_package ~source ~source_identity ~source_private_key ~destination
    ~tracking_name ~head ~issued_at ~expires_at ~nonce =
  if not (valid_tracking_name tracking_name) then
    Error (Invalid_package "tracking name is invalid")
  else if String.length nonce <> Peer_sync.nonce_bytes then
    Error (Invalid_package "nonce has the wrong length")
  else if
    Int64.compare expires_at issued_at <= 0
    || Int64.compare
         (Int64.sub expires_at issued_at)
         max_advertisement_age_seconds
       > 0
  then Error (Invalid_package "expiry is outside its bound")
  else
    let* configured_source =
      Peer_sync.load_identity source (Peer_sync.peer_id source_identity)
      |> Result.map_error (fun error -> Peer_error error)
    in
    if not (Peer_sync.identity_equal configured_source source_identity) then
      Error Contact_mismatch
    else
      let* head_node =
        Peer_sync.load_sync_node source head
        |> Result.map_error (fun error -> Peer_error error)
      in
      if
        not
          (Peer_id.equal
             (Peer_sync.sync_node_author head_node)
             (Peer_sync.peer_id source_identity))
      then Error Contact_mismatch
      else
        let* object_ids, head_object =
          Peer_sync.sync_transfer_closure source head
          |> Result.map_error (fun error -> Peer_error error)
        in
        if List.length object_ids > max_package_objects then
          Error (Invalid_package "closure object count is outside its bound")
        else
          let* objects =
            List.fold_left
              (fun result object_id ->
                let* reversed = result in
                let* object_envelope =
                  Store.get source object_id
                  |> Result.map_error (fun error -> Store_error error)
                in
                Ok ({ object_id; object_envelope } :: reversed))
              (Ok []) object_ids
            |> Result.map List.rev
          in
          let provisional =
            {
              package_identity = "";
              package_sender_identity = source_identity;
              package_destination_identity = Peer_sync.peer_id destination;
              package_tracking = tracking_name;
              package_head_identity = head;
              package_head_object = head_object;
              package_issued_at = issued_at;
              package_expires_at = expires_at;
              package_nonce = nonce;
              package_objects = objects;
              package_signature = "";
            }
          in
          let* signing_bytes = package_signing_bytes provisional in
          try
            let signature =
              Mirage_crypto_ec.Ed25519.sign ~key:source_private_key
                signing_bytes
            in
            if String.length signature <> 64 then
              Error
                (Invalid_package "Ed25519 signer returned an invalid signature")
            else
              let signed = { provisional with package_signature = signature } in
              let* payload = package_payload signed in
              let identity = package_id_of_payload payload in
              if String.length (Encoding.encode payload) > max_package_bytes
              then
                Error
                  (Package_too_large (String.length (Encoding.encode payload)))
              else Ok { signed with package_identity = identity }
          with _ -> Error (Invalid_package "Ed25519 signing failed")

let advertisement_unsigned_value advertisement =
  let* sender =
    Peer_sync.identity_payload advertisement.advertisement_sender_identity
    |> Result.map_error (fun error -> Peer_error error)
  in
  let* domain = text "yeokcham:peer-sync:relay-advertisement:v1" in
  let* tracking = text advertisement.advertisement_tracking in
  array
    [
      Encoding.integer 1L;
      domain;
      Encoding.bytes repository_digest;
      Encoding.bytes advertisement.advertisement_package;
      sender;
      Encoding.bytes
        (Peer_id.to_bytes advertisement.advertisement_destination_identity);
      tracking;
      Encoding.bytes
        (Sync_node_id.to_bytes advertisement.advertisement_head_identity);
      Encoding.integer advertisement.advertisement_issued_at;
      Encoding.integer advertisement.advertisement_expires_at;
      Encoding.bytes advertisement.advertisement_nonce;
    ]

let advertisement_signing_bytes advertisement =
  advertisement_unsigned_value advertisement
  |> Result.map Encoding.encode
  |> Result.map (fun value -> advertisement_domain ^ value)

let advertisement_payload advertisement =
  if String.length advertisement.advertisement_signature <> 64 then
    Error (Invalid_advertisement "signature must contain 64 bytes")
  else
    let* unsigned = advertisement_unsigned_value advertisement in
    let algorithm =
      Encoding.text Peer_sync.algorithm
      |> Result.map_error (fun error ->
          Invalid_advertisement (Encoding.construction_error_to_string error))
    in
    let* algorithm = algorithm in
    Encoding.array
      [
        Encoding.integer 1L;
        unsigned;
        algorithm;
        Encoding.bytes advertisement.advertisement_signature;
      ]
    |> Result.map_error (fun error ->
        Invalid_advertisement (Encoding.construction_error_to_string error))

let advertisement_id_of_payload payload =
  digest advertisement_id_domain (Encoding.encode payload)

let verify_advertisement_signature advertisement =
  if String.length advertisement.advertisement_signature <> 64 then
    Error (Invalid_advertisement "signature must contain 64 bytes")
  else
    let* signing_bytes = advertisement_signing_bytes advertisement in
    match
      Mirage_crypto_ec.Ed25519.pub_of_octets
        (Peer_sync.public_key advertisement.advertisement_sender_identity)
    with
    | Error _ -> Error Signature_verification_failed
    | Ok public_key -> (
        try
          if
            Mirage_crypto_ec.Ed25519.verify ~key:public_key
              advertisement.advertisement_signature ~msg:signing_bytes
          then Ok ()
          else Error Signature_verification_failed
        with _ -> Error Signature_verification_failed)

let advertisement_id advertisement = advertisement.advertisement_identity
let advertisement_package_id advertisement = advertisement.advertisement_package

let advertisement_sender advertisement =
  advertisement.advertisement_sender_identity

let advertisement_destination advertisement =
  advertisement.advertisement_destination_identity

let advertisement_tracking_name advertisement =
  advertisement.advertisement_tracking

let advertisement_head advertisement = advertisement.advertisement_head_identity

let decode_advertisement_payload value =
  let* fields = advertisement_fields "relay advertisement" 4 value in
  match fields with
  | [ version; unsigned; algorithm; signature ] -> (
      let* version =
        advertisement_integer "relay advertisement version" version
      in
      if not (Int64.equal version 1L) then
        Error (Invalid_advertisement "unsupported relay advertisement version")
      else
        let* unsigned_fields =
          advertisement_fields "relay advertisement unsigned" 11 unsigned
        in
        match unsigned_fields with
        | [
         unsigned_version;
         domain;
         format;
         package_id;
         sender;
         destination;
         tracking;
         head;
         issued_at;
         expires_at;
         nonce;
        ] ->
            let* unsigned_version =
              advertisement_integer "relay advertisement unsigned version"
                unsigned_version
            in
            let* domain =
              advertisement_text "relay advertisement domain" domain
            in
            let* format =
              advertisement_bytes "relay advertisement format" format
            in
            let* package_id =
              raw_advertisement_id "relay advertisement package ID" package_id
            in
            let* sender =
              Peer_sync.decode_identity_payload sender
              |> Result.map_error (fun error -> Peer_error error)
            in
            let* destination =
              peer_id_from_advertisement "relay advertisement destination"
                destination
            in
            let* tracking =
              advertisement_text "relay advertisement tracking name" tracking
            in
            let* head =
              sync_node_id_from_advertisement "relay advertisement head" head
            in
            let* issued_at =
              advertisement_integer "relay advertisement issued-at" issued_at
            in
            let* expires_at =
              advertisement_integer "relay advertisement expires-at" expires_at
            in
            let* nonce =
              advertisement_bytes "relay advertisement nonce" nonce
            in
            let* algorithm =
              advertisement_text "relay advertisement algorithm" algorithm
            in
            let* signature =
              advertisement_bytes "relay advertisement signature" signature
            in
            if not (Int64.equal unsigned_version 1L) then
              Error
                (Invalid_advertisement
                   "unsupported relay advertisement unsigned version")
            else if
              not
                (String.equal domain "yeokcham:peer-sync:relay-advertisement:v1")
            then
              Error
                (Invalid_advertisement
                   "relay advertisement has the wrong domain")
            else if String.length format <> 32 then
              Error
                (Invalid_advertisement
                   "relay advertisement format digest must contain 32 bytes")
            else if not (String.equal format repository_digest) then
              Error Repository_format_mismatch
            else if not (valid_tracking_name tracking) then
              Error
                (Invalid_advertisement
                   "relay advertisement tracking name is invalid")
            else if String.length nonce <> Peer_sync.nonce_bytes then
              Error
                (Invalid_advertisement
                   "relay advertisement nonce has the wrong length")
            else if
              Int64.compare expires_at issued_at <= 0
              || Int64.compare
                   (Int64.sub expires_at issued_at)
                   max_advertisement_age_seconds
                 > 0
            then
              Error
                (Invalid_advertisement
                   "relay advertisement expiry is outside its bound")
            else if not (String.equal algorithm Peer_sync.algorithm) then
              Error
                (Invalid_advertisement
                   "unsupported relay advertisement algorithm")
            else if String.length signature <> 64 then
              Error
                (Invalid_advertisement
                   "relay advertisement signature must contain 64 bytes")
            else
              let provisional =
                {
                  advertisement_identity = "";
                  advertisement_package = package_id;
                  advertisement_sender_identity = sender;
                  advertisement_destination_identity = destination;
                  advertisement_tracking = tracking;
                  advertisement_head_identity = head;
                  advertisement_issued_at = issued_at;
                  advertisement_expires_at = expires_at;
                  advertisement_nonce = nonce;
                  advertisement_signature = signature;
                }
              in
              let* canonical = advertisement_payload provisional in
              if not (Encoding.equal canonical value) then
                Error
                  (Invalid_advertisement "relay advertisement is noncanonical")
              else
                let identity = advertisement_id_of_payload canonical in
                let advertisement =
                  { provisional with advertisement_identity = identity }
                in
                let* () = verify_advertisement_signature advertisement in
                Ok advertisement
        | _ -> assert false)
  | _ -> assert false

let make_advertisement package ~private_key =
  let provisional =
    {
      advertisement_identity = "";
      advertisement_package = package.package_identity;
      advertisement_sender_identity = package.package_sender_identity;
      advertisement_destination_identity = package.package_destination_identity;
      advertisement_tracking = package.package_tracking;
      advertisement_head_identity = package.package_head_identity;
      advertisement_issued_at = package.package_issued_at;
      advertisement_expires_at = package.package_expires_at;
      advertisement_nonce = package.package_nonce;
      advertisement_signature = "";
    }
  in
  let* signing_bytes = advertisement_signing_bytes provisional in
  try
    let signature =
      Mirage_crypto_ec.Ed25519.sign ~key:private_key signing_bytes
    in
    if String.length signature <> 64 then
      Error
        (Invalid_advertisement "Ed25519 signer returned an invalid signature")
    else
      let signed = { provisional with advertisement_signature = signature } in
      let* payload = advertisement_payload signed in
      Ok
        {
          signed with
          advertisement_identity = advertisement_id_of_payload payload;
        }
  with _ -> Error (Invalid_advertisement "Ed25519 signing failed")

let valid_absolute_path path =
  (not (String.is_empty path))
  && (not (Filename.is_relative path))
  && String.length path <= 4096
  && not (String.contains path '\000')

let hex_of_bytes bytes =
  let digits = "0123456789abcdef" in
  let output = Bytes.create (2 * String.length bytes) in
  String.iteri
    (fun index value ->
      Bytes.set output (2 * index) digits.[Char.code value lsr 4];
      Bytes.set output ((2 * index) + 1) digits.[Char.code value land 15])
    bytes;
  Bytes.unsafe_to_string output

let valid_hex value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let io operation path error =
  Io_error
    (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error))

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io "lstat" path error)

let rec ensure_directory path =
  let* stat = lstat_or_missing path in
  match stat with
  | Some stat when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Some _ -> Error (Invalid_relay_path (path ^ " is not a directory"))
  | None -> (
      try
        Unix.mkdir path 0o755;
        Ok ()
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory path
      | Unix.Unix_error (error, _, _) -> Error (io "mkdir" path error))

let relay_components relay destination =
  let root = Filename.concat relay "mailboxes" in
  let mailbox =
    Filename.concat root (hex_of_bytes (Peer_id.to_bytes destination))
  in
  (root, mailbox)

let ensure_mailbox relay destination =
  if not (valid_absolute_path relay) then
    Error (Invalid_relay_path "must be absolute, bounded, and NUL-free")
  else
    let* () = ensure_directory relay in
    let mailboxes, mailbox = relay_components relay destination in
    let* () = ensure_directory mailboxes in
    let* () = ensure_directory mailbox in
    Ok mailbox

let read_regular_limited path limit =
  let* before = lstat_or_missing path in
  match before with
  | None -> Error (Missing_package (Filename.basename path))
  | Some before when before.Unix.st_kind <> Unix.S_REG ->
      Error (Io_error (path ^ " is not a regular file"))
  | Some before when before.Unix.st_size > limit ->
      Error (Package_too_large before.Unix.st_size)
  | Some before -> (
      try
        let descriptor =
          Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
        in
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            let after = Unix.fstat descriptor in
            if
              after.Unix.st_kind <> Unix.S_REG
              || after.Unix.st_dev <> before.Unix.st_dev
              || after.Unix.st_ino <> before.Unix.st_ino
            then Error (Io_error (path ^ " changed while opening"))
            else if after.Unix.st_size > limit then
              Error (Package_too_large after.Unix.st_size)
            else
              let bytes = Bytes.create after.Unix.st_size in
              let rec read offset =
                if offset = after.Unix.st_size then Ok ()
                else
                  try
                    match
                      Unix.read descriptor bytes offset
                        (after.Unix.st_size - offset)
                    with
                    | 0 ->
                        Error
                          (Io_error (path ^ " ended before its stated size"))
                    | count -> read (offset + count)
                  with Unix.Unix_error (error, _, _) ->
                    Error (io "read" path error)
              in
              let* () = read 0 in
              let extra = Bytes.create 1 in
              let* extra_count =
                try Ok (Unix.read descriptor extra 0 1)
                with Unix.Unix_error (error, _, _) ->
                  Error (io "read" path error)
              in
              if extra_count = 0 then Ok (Bytes.unsafe_to_string bytes)
              else Error (Io_error (path ^ " grew while reading")))
      with Unix.Unix_error (error, _, _) -> Error (io "open" path error))

let write_all descriptor path bytes =
  let rec write offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count = 0 then
          Error (Io_error (path ^ " accepted a zero-byte write"))
        else write (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (io "write" path error)
  in
  write 0

let fsync descriptor path =
  try
    Unix.fsync descriptor;
    Ok ()
  with Unix.Unix_error (error, _, _) -> Error (io "fsync" path error)

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        try
          Unix.fsync descriptor;
          Ok ()
        with
        | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _)
          ->
            Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error (io "fsync directory" path error))
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) ->
      Ok ()
  | Unix.Unix_error (error, _, _) -> Error (io "open directory" path error)

let publish_file path bytes =
  let directory = Filename.dirname path in
  let final_name = Filename.basename path in
  let existing () =
    let* current = read_regular_limited path max_package_bytes in
    if String.equal current bytes then Ok ()
    else Error (Publication_conflict path)
  in
  let rec create attempt =
    if attempt = 128 then
      Error (Publication_conflict ("temporary-name exhaustion in " ^ directory))
    else
      let temporary =
        Filename.concat directory
          (Printf.sprintf ".%s.tmp-%d-%d" final_name (Unix.getpid ()) attempt)
      in
      try
        let descriptor =
          Unix.openfile temporary
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
            0o644
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () = write_all descriptor temporary bytes in
              fsync descriptor temporary)
        in
        match result with
        | Error _ as error ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            error
        | Ok () -> (
            try
              Unix.link temporary path;
              Unix.unlink temporary;
              fsync_directory directory
            with
            | Unix.Unix_error (Unix.EEXIST, _, _) ->
                (try Unix.unlink temporary with Unix.Unix_error _ -> ());
                existing ()
            | Unix.Unix_error (error, _, _) ->
                (try Unix.unlink temporary with Unix.Unix_error _ -> ());
                Error (io "publish" path error))
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) -> Error (io "create" temporary error)
  in
  create 0

let package_file mailbox package_id =
  Filename.concat mailbox (hex_of_bytes package_id ^ ".package")

let advertisement_file mailbox package_id =
  Filename.concat mailbox (hex_of_bytes package_id ^ ".advertisement")

let receipt_file mailbox package_id =
  Filename.concat mailbox (hex_of_bytes package_id ^ ".receipt")

let advertisement_matches_package advertisement package =
  String.equal advertisement.advertisement_package package.package_identity
  && Peer_sync.identity_equal advertisement.advertisement_sender_identity
       package.package_sender_identity
  && Peer_id.equal advertisement.advertisement_destination_identity
       package.package_destination_identity
  && String.equal advertisement.advertisement_tracking package.package_tracking
  && Sync_node_id.equal advertisement.advertisement_head_identity
       package.package_head_identity
  && Int64.equal advertisement.advertisement_issued_at package.package_issued_at
  && Int64.equal advertisement.advertisement_expires_at
       package.package_expires_at
  && String.equal advertisement.advertisement_nonce package.package_nonce

let publish ~relay ~package ~advertisement =
  let* package_payload = package_payload package in
  let* advertisement_payload = advertisement_payload advertisement in
  let package_bytes = Encoding.encode package_payload in
  let advertisement_bytes = Encoding.encode advertisement_payload in
  if String.length package_bytes > max_package_bytes then
    Error (Package_too_large (String.length package_bytes))
  else if not (advertisement_matches_package advertisement package) then
    Error (Invalid_advertisement "does not match the package it announces")
  else
    let* () = verify_package_signature package in
    let* () = verify_advertisement_signature advertisement in
    let* mailbox = ensure_mailbox relay package.package_destination_identity in
    let* () =
      publish_file (package_file mailbox package.package_identity) package_bytes
    in
    publish_file
      (advertisement_file mailbox package.package_identity)
      advertisement_bytes

let suffix value suffix =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  if value_length <= suffix_length then None
  else if
    String.equal
      (String.sub value (value_length - suffix_length) suffix_length)
      suffix
  then Some (String.sub value 0 (value_length - suffix_length))
  else None

let directory_entries path =
  try
    let directory = Unix.opendir path in
    Fun.protect
      ~finally:(fun () -> Unix.closedir directory)
      (fun () ->
        let rec read values =
          try
            let value = Unix.readdir directory in
            if String.equal value "." || String.equal value ".." then
              read values
            else read (value :: values)
          with End_of_file -> Ok (List.sort String.compare values)
        in
        read [])
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | Unix.Unix_error (error, _, _) -> Error (io "opendir" path error)

let fresh ~now ~issued_at ~expires_at =
  if
    Int64.compare expires_at issued_at <= 0
    || Int64.compare
         (Int64.sub expires_at issued_at)
         max_advertisement_age_seconds
       > 0
    || Int64.compare issued_at (Int64.add now max_future_skew_seconds) > 0
    || Int64.compare expires_at now < 0
  then Error (Expired { issued_at; expires_at; now })
  else Ok ()

let list_advertisements ~relay ~now =
  if not (valid_absolute_path relay) then
    Error (Invalid_relay_path "must be absolute, bounded, and NUL-free")
  else
    let mailboxes = Filename.concat relay "mailboxes" in
    let* roots = directory_entries mailboxes in
    let rec scan_mailboxes found = function
      | [] -> Ok found
      | root :: rest -> (
          if not (valid_hex root) then scan_mailboxes found rest
          else
            let mailbox = Filename.concat mailboxes root in
            let* stat = lstat_or_missing mailbox in
            match stat with
            | Some stat when stat.Unix.st_kind = Unix.S_DIR ->
                let* names = directory_entries mailbox in
                let rec scan_files found = function
                  | [] -> Ok found
                  | name :: names -> (
                      match suffix name ".advertisement" with
                      | Some identity when valid_hex identity -> (
                          let path = Filename.concat mailbox name in
                          let parsed =
                            let* bytes =
                              read_regular_limited path (1024 * 1024)
                            in
                            let* value =
                              Encoding.decode bytes
                              |> Result.map_error (fun error ->
                                  Invalid_advertisement
                                    (Encoding.decode_error_to_string error))
                            in
                            decode_advertisement_payload value
                          in
                          (* A filename is an untrusted routing hint.  The
                             signed package ID remains the sole authority. *)
                          match parsed with
                          | Ok advertisement
                            when String.equal
                                   (hex_of_bytes
                                      advertisement.advertisement_package)
                                   identity -> (
                              match
                                fresh ~now
                                  ~issued_at:
                                    advertisement.advertisement_issued_at
                                  ~expires_at:
                                    advertisement.advertisement_expires_at
                              with
                              | Ok () ->
                                  scan_files (advertisement :: found) names
                              | Error _ -> scan_files found names)
                          | Ok _ | Error _ -> scan_files found names)
                      | None | Some _ -> scan_files found names)
                in
                let* found = scan_files found names in
                scan_mailboxes found rest
            | Some _ | None -> scan_mailboxes found rest)
    in
    let* advertisements = scan_mailboxes [] roots in
    Ok
      (List.sort_uniq
         (fun left right ->
           String.compare left.advertisement_identity
             right.advertisement_identity)
         advertisements)

let with_staging run =
  let root = Filename.temp_file "yeokcham-peer-relay-stage-" "" in
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  in
  try
    Unix.unlink root;
    Unix.mkdir root 0o700;
    Fun.protect
      ~finally:(fun () -> try remove root with Unix.Unix_error _ -> ())
      (fun () ->
        let* store =
          Store.init ~root |> Result.map_error (fun error -> Store_error error)
        in
        run store)
  with Unix.Unix_error (error, _, _) ->
    Error (io "create staging repository" root error)

let receipt_bytes package_id =
  "yeokcham:peer-sync:relay-receipt:v1\000" ^ package_id

let receipt_exists mailbox package_id =
  let path = receipt_file mailbox package_id in
  match lstat_or_missing path with
  | Ok None -> false
  | Ok (Some _) -> (
      match read_regular_limited path 128 with
      | Ok bytes -> String.equal bytes (receipt_bytes package_id)
      | Error _ -> true)
  | Error _ -> true

let contact_uses_relay contact relay =
  List.exists
    (function
      | Peer_sync.Local_path _ -> false
      | Peer_sync.Ssh _ -> false
      | Peer_sync.Relay path -> String.equal path relay)
    (Peer_sync.contact_endpoints contact)

let import_advertisement ~destination ~contact ~destination_identity ~relay
    ~tracking_name ~now ~advertisement =
  if not (contact_uses_relay contact relay) then
    Error (Invalid_relay_path "is not configured on the pinned contact")
  else if not (valid_tracking_name tracking_name) then Error Tracking_mismatch
  else
    let* () =
      fresh ~now ~issued_at:advertisement.advertisement_issued_at
        ~expires_at:advertisement.advertisement_expires_at
    in
    if
      not
        (Peer_sync.identity_equal advertisement.advertisement_sender_identity
           (Peer_sync.contact_identity contact))
    then Error Contact_mismatch
    else if
      not
        (Peer_id.equal advertisement.advertisement_destination_identity
           (Peer_sync.peer_id destination_identity))
    then Error Destination_mismatch
    else if
      not (String.equal advertisement.advertisement_tracking tracking_name)
    then Error Tracking_mismatch
    else
      let* configured_destination =
        Peer_sync.load_identity destination
          (Peer_sync.peer_id destination_identity)
        |> Result.map_error (fun error -> Peer_error error)
      in
      if
        not
          (Peer_sync.identity_equal configured_destination destination_identity)
      then Error Destination_mismatch
      else
        let* mailbox =
          ensure_mailbox relay advertisement.advertisement_destination_identity
        in
        if receipt_exists mailbox advertisement.advertisement_package then
          Error (Replay (hex_of_bytes advertisement.advertisement_package))
        else
          let* package_bytes =
            read_regular_limited
              (package_file mailbox advertisement.advertisement_package)
              max_package_bytes
          in
          let* package_value =
            Encoding.decode package_bytes
            |> Result.map_error (fun error ->
                Invalid_package (Encoding.decode_error_to_string error))
          in
          let* package = decode_package_payload package_value in
          if
            not
              (String.equal package.package_identity
                 advertisement.advertisement_package)
          then
            Error
              (Invalid_package
                 "file bytes do not match the advertised package ID")
          else if not (advertisement_matches_package advertisement package) then
            Error
              (Invalid_advertisement "does not match the package it announces")
          else
            let* () =
              fresh ~now ~issued_at:package.package_issued_at
                ~expires_at:package.package_expires_at
            in
            if
              not
                (Peer_sync.identity_equal package.package_sender_identity
                   (Peer_sync.contact_identity contact))
            then Error Contact_mismatch
            else if
              not
                (Peer_id.equal package.package_destination_identity
                   (Peer_sync.peer_id destination_identity))
            then Error Destination_mismatch
            else if not (String.equal package.package_tracking tracking_name)
            then Error Tracking_mismatch
            else
              let offered =
                List.map (fun entry -> entry.object_id) package.package_objects
              in
              let* () =
                with_staging (fun stage ->
                    let* () =
                      List.fold_left
                        (fun result entry ->
                          let* () = result in
                          Store.put stage entry.object_envelope
                          |> Result.map_error (fun error -> Store_error error)
                          |> Result.map (fun _ -> ()))
                        (Ok ()) package.package_objects
                    in
                    Peer_sync.import_sync_closure stage ~contact
                      ~head_object:package.package_head_object
                      ~head:package.package_head_identity ~offered
                    |> Result.map_error (fun error -> Peer_error error))
              in
              let* () =
                List.fold_left
                  (fun result entry ->
                    let* () = result in
                    Store.put destination entry.object_envelope
                    |> Result.map_error (fun error -> Store_error error)
                    |> Result.map (fun _ -> ()))
                  (Ok ()) package.package_objects
              in
              let* () =
                Peer_sync.import_sync_closure destination ~contact
                  ~head_object:package.package_head_object
                  ~head:package.package_head_identity ~offered
                |> Result.map_error (fun error -> Peer_error error)
              in
              let* decision =
                Peer_sync.advance_tracking destination ~contact ~tracking_name
                  ~head:package.package_head_identity
                |> Result.map_error (fun error -> Peer_error error)
              in
              let* () =
                publish_file
                  (receipt_file mailbox advertisement.advertisement_package)
                  (receipt_bytes advertisement.advertisement_package)
              in
              Ok decision
