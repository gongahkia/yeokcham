module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Object_id = Yeokcham_store.Stored_object_id
module Store = Yeokcham_store

type key = string
type nonce = string
type entry = { object_id : Object_id.t; envelope : Envelope.t }
type plaintext = { entries : entry list }
type t = { repository_digest : string; nonce : nonce; ciphertext : string }

type error =
  | Invalid_key_length of int
  | Invalid_nonce_length of int
  | Invalid_repository_format
  | Repository_format_mismatch
  | Invalid_entry_count of int
  | Duplicate_object_id of Object_id.t
  | Object_identity_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Plaintext_too_large of int
  | Ciphertext_too_large of int
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Authentication_failed
  | Envelope_error of Envelope.decode_error
  | Cryptographic_failure of string

let algorithm = "chacha20-poly1305"
let key_size = 32
let nonce_size = 12
let tag_size = Mirage_crypto.Chacha20.tag_size
let max_entries = 4096
let max_plaintext_bytes = 128 * 1024 * 1024
let max_ciphertext_bytes = max_plaintext_bytes + tag_size
let max_outer_overhead_bytes = 128
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_key_length length ->
      Printf.sprintf "bundle key must contain 32 bytes, got %d" length
  | Invalid_nonce_length length ->
      Printf.sprintf "bundle nonce must contain 12 bytes, got %d" length
  | Invalid_repository_format -> "bundle repository format is empty"
  | Repository_format_mismatch -> "bundle repository format does not match"
  | Invalid_entry_count count ->
      Printf.sprintf "bundle has %d entries; limit is %d" count max_entries
  | Duplicate_object_id object_id ->
      "duplicate bundle object ID: " ^ Object_id.to_hex object_id
  | Object_identity_mismatch { expected; actual } ->
      Printf.sprintf "bundle object ID mismatch: expected %s, got %s"
        (Object_id.to_hex expected)
        (Object_id.to_hex actual)
  | Plaintext_too_large size ->
      Printf.sprintf "bundle plaintext is %d bytes; limit is %d" size
        max_plaintext_bytes
  | Ciphertext_too_large size ->
      Printf.sprintf "bundle ciphertext is %d bytes; limit is %d" size
        max_ciphertext_bytes
  | Invalid_payload detail -> "invalid encrypted bundle payload: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported encrypted bundle schema version: %Ld" version
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported encrypted bundle algorithm: %s" value
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported encrypted bundle mandatory features: %Ld"
        features
  | Authentication_failed -> "bundle authentication failed"
  | Envelope_error error -> Envelope.decode_error_to_string error
  | Cryptographic_failure detail -> "bundle cryptographic failure: " ^ detail

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

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

let repository_digest repository_format =
  Hash.digest_string repository_format |> Hash.to_raw_string

let key_of_bytes bytes =
  if String.length bytes = key_size then Ok bytes
  else Error (Invalid_key_length (String.length bytes))

let nonce_of_bytes bytes =
  if String.length bytes = nonce_size then Ok bytes
  else Error (Invalid_nonce_length (String.length bytes))

let nonce_to_bytes nonce = nonce
let compare_entry left right = Object_id.compare left.object_id right.object_id

let check_entries entries =
  let count = List.length entries in
  if count > max_entries then Error (Invalid_entry_count count)
  else
    let rec loop previous = function
      | [] -> Ok ()
      | entry :: rest -> (
          match previous with
          | None -> loop (Some entry.object_id) rest
          | Some previous ->
              if Object_id.compare previous entry.object_id < 0 then
                loop (Some entry.object_id) rest
              else Error (Duplicate_object_id entry.object_id))
    in
    loop None entries

let entry_of_envelope ~object_id envelope =
  let actual = Store.id_of_envelope envelope in
  if Object_id.equal object_id actual then Ok { object_id; envelope }
  else Error (Object_identity_mismatch { expected = object_id; actual })

let entry_object_id entry = entry.object_id
let entry_envelope entry = entry.envelope

let plaintext_value plaintext =
  let rec entries values = function
    | [] -> Ok (List.rev values)
    | entry :: rest ->
        let* value =
          array
            [
              Encoding.bytes (Object_id.to_raw_bytes entry.object_id);
              Encoding.bytes (Envelope.encode entry.envelope);
            ]
        in
        entries (value :: values) rest
  in
  let* entries = entries [] plaintext.entries in
  let* entries = array entries in
  array [ Encoding.integer 1L; entries; Encoding.integer 0L ]

let check_plaintext_size plaintext =
  let* value = plaintext_value plaintext in
  let size = String.length (Encoding.encode value) in
  if size > max_plaintext_bytes then Error (Plaintext_too_large size) else Ok ()

let make_plaintext entries =
  let entries = List.sort compare_entry entries in
  let* () = check_entries entries in
  let* () =
    List.fold_left
      (fun result entry ->
        let* () = result in
        entry_of_envelope ~object_id:entry.object_id entry.envelope
        |> Result.map (fun _ -> ()))
      (Ok ()) entries
  in
  let plaintext = { entries } in
  let* () = check_plaintext_size plaintext in
  Ok plaintext

let plaintext_entries plaintext = plaintext.entries

let plaintext_bytes plaintext =
  match plaintext_value plaintext with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let header_value ~repository_digest ~nonce =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer 1L;
      algorithm;
      Encoding.bytes repository_digest;
      Encoding.bytes nonce;
      Encoding.integer 0L;
    ]

let bundle_value bundle =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer 1L;
      algorithm;
      Encoding.bytes bundle.repository_digest;
      Encoding.bytes bundle.nonce;
      Encoding.bytes bundle.ciphertext;
      Encoding.integer 0L;
    ]

let associated_data ~repository_digest ~nonce =
  header_value ~repository_digest ~nonce |> Result.map Encoding.encode

let seal ~repository_format ~key ~nonce plaintext =
  if String.length repository_format = 0 then Error Invalid_repository_format
  else
    let* () = check_plaintext_size plaintext in
    let* plaintext = plaintext_value plaintext in
    let plaintext = Encoding.encode plaintext in
    let repository_digest = repository_digest repository_format in
    let* associated_data = associated_data ~repository_digest ~nonce in
    try
      let key = Mirage_crypto.Chacha20.of_secret key in
      let ciphertext =
        Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce
          ~adata:associated_data plaintext
      in
      if String.length ciphertext > max_ciphertext_bytes then
        Error (Ciphertext_too_large (String.length ciphertext))
      else Ok { repository_digest; nonce; ciphertext }
    with Invalid_argument detail -> Error (Cryptographic_failure detail)

let encode bundle =
  match bundle_value bundle with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let header_bytes bundle =
  match
    associated_data ~repository_digest:bundle.repository_digest
      ~nonce:bundle.nonce
  with
  | Ok bytes -> bytes
  | Error error -> invalid_arg (error_to_string error)

let decode_entry value =
  let* values = fields "bundle plaintext entry" 2 value in
  match values with
  | [ raw_object_id; raw_envelope ] ->
      let* raw_object_id = bytes "bundle object ID" raw_object_id in
      let* object_id =
        match Object_id.of_raw_bytes raw_object_id with
        | Some object_id -> Ok object_id
        | None ->
            Error (Invalid_payload "bundle object ID must contain 32 bytes")
      in
      let* raw_envelope = bytes "bundle envelope bytes" raw_envelope in
      let* envelope =
        Envelope.decode raw_envelope
        |> Result.map_error (fun error -> Envelope_error error)
      in
      if not (String.equal raw_envelope (Envelope.encode envelope)) then
        Error (Invalid_payload "bundle envelope bytes are noncanonical")
      else entry_of_envelope ~object_id envelope
  | _ -> assert false

let decode_plaintext encoded =
  if String.length encoded > max_plaintext_bytes then
    Error (Plaintext_too_large (String.length encoded))
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "bundle plaintext" 3 value in
    match values with
    | [ version; raw_entries; features ] ->
        let* version = integer "bundle plaintext schema version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* features =
            integer "bundle plaintext mandatory features" features
          in
          if not (Int64.equal features 0L) then
            Error (Unsupported_mandatory_features features)
          else
            let* raw_entries =
              match raw_entries with
              | Encoding.Array entries -> Ok entries
              | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
              | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                  Error
                    (Invalid_payload "bundle plaintext entries must be an array")
            in
            let rec entries values = function
              | [] -> Ok (List.rev values)
              | value :: rest ->
                  let* entry = decode_entry value in
                  entries (entry :: values) rest
            in
            let* entries = entries [] raw_entries in
            let plaintext = { entries } in
            let* () = check_entries entries in
            let* () = check_plaintext_size plaintext in
            let* canonical = plaintext_value plaintext in
            if String.equal encoded (Encoding.encode canonical) then
              Ok plaintext
            else Error (Invalid_payload "bundle plaintext is noncanonical")
    | _ -> assert false

let decode encoded =
  if String.length encoded > max_ciphertext_bytes + max_outer_overhead_bytes
  then Error (Ciphertext_too_large (String.length encoded))
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "encrypted bundle" 6 value in
    match values with
    | [
     version; algorithm_value; repository_digest; nonce; ciphertext; features;
    ] ->
        let* version = integer "bundle schema version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* algorithm_value =
            text_field "bundle algorithm" algorithm_value
          in
          if not (String.equal algorithm_value algorithm) then
            Error (Unsupported_algorithm algorithm_value)
          else
            let* features = integer "bundle mandatory features" features in
            if not (Int64.equal features 0L) then
              Error (Unsupported_mandatory_features features)
            else
              let* repository_digest =
                bytes "bundle repository digest" repository_digest
              in
              if String.length repository_digest <> Hash.digest_size then
                Error
                  (Invalid_payload
                     "bundle repository digest must contain 32 bytes")
              else
                let* nonce = bytes "bundle nonce" nonce in
                let* nonce = nonce_of_bytes nonce in
                let* ciphertext = bytes "bundle ciphertext" ciphertext in
                if String.length ciphertext < tag_size then
                  Error
                    (Invalid_payload "bundle ciphertext is shorter than its tag")
                else if String.length ciphertext > max_ciphertext_bytes then
                  Error (Ciphertext_too_large (String.length ciphertext))
                else
                  let bundle = { repository_digest; nonce; ciphertext } in
                  let* canonical = bundle_value bundle in
                  if String.equal encoded (Encoding.encode canonical) then
                    Ok bundle
                  else
                    Error (Invalid_payload "encrypted bundle is noncanonical")
    | _ -> assert false

let open_bundle ~repository_format ~key bundle =
  if String.length repository_format = 0 then Error Invalid_repository_format
  else if
    not
      (String.equal bundle.repository_digest
         (repository_digest repository_format))
  then Error Repository_format_mismatch
  else
    let* associated_data =
      associated_data ~repository_digest:bundle.repository_digest
        ~nonce:bundle.nonce
    in
    try
      let key = Mirage_crypto.Chacha20.of_secret key in
      match
        Mirage_crypto.Chacha20.authenticate_decrypt ~key ~nonce:bundle.nonce
          ~adata:associated_data bundle.ciphertext
      with
      | None -> Error Authentication_failed
      | Some plaintext ->
          if String.length plaintext > max_plaintext_bytes then
            Error (Plaintext_too_large (String.length plaintext))
          else decode_plaintext plaintext
    with Invalid_argument detail -> Error (Cryptographic_failure detail)
