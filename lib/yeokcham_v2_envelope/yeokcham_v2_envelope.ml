module Encoding = Yeokcham_encoding

type key = string
type nonce = string
type t = { nonce : nonce; ciphertext : string; mandatory_features : int64 }

type error =
  | Invalid_key_length of int
  | Invalid_nonce_length of int
  | Plaintext_too_large of int
  | Ciphertext_too_large of int
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Authentication_failed
  | Cryptographic_failure of string

let algorithm = "chacha20-poly1305"
let current_schema_version = 1L
let supported_mandatory_features = 0L
let key_size = 32
let nonce_size = 12
let tag_size = Mirage_crypto.Chacha20.tag_size
let max_plaintext_bytes = 128 * 1024 * 1024
let max_ciphertext_bytes = max_plaintext_bytes + tag_size
let max_outer_overhead_bytes = 128
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_key_length length ->
      Printf.sprintf "v2 envelope key must contain 32 bytes, got %d" length
  | Invalid_nonce_length length ->
      Printf.sprintf "v2 envelope nonce must contain 12 bytes, got %d" length
  | Plaintext_too_large size ->
      Printf.sprintf "v2 envelope plaintext is %d bytes; limit is %d" size
        max_plaintext_bytes
  | Ciphertext_too_large size ->
      Printf.sprintf "v2 envelope ciphertext is %d bytes; limit is %d" size
        max_ciphertext_bytes
  | Invalid_payload detail -> "invalid v2 encrypted-object envelope: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported v2 encrypted-object envelope version: %Ld"
        version
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported v2 encrypted-object envelope algorithm: %s"
        value
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid v2 mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported v2 mandatory feature bits: %Ld" features
  | Authentication_failed ->
      "v2 encrypted-object envelope authentication failed"
  | Cryptographic_failure detail ->
      "v2 encrypted-object envelope cryptographic failure: " ^ detail

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

let key_of_bytes bytes =
  if String.length bytes = key_size then Ok bytes
  else Error (Invalid_key_length (String.length bytes))

let key_to_bytes key = key

let nonce_of_bytes bytes =
  if String.length bytes = nonce_size then Ok bytes
  else Error (Invalid_nonce_length (String.length bytes))

let nonce_to_bytes nonce = nonce

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let header_value ~nonce ~mandatory_features =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer current_schema_version;
      algorithm;
      Encoding.bytes nonce;
      Encoding.integer mandatory_features;
    ]

let envelope_value envelope =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer current_schema_version;
      algorithm;
      Encoding.bytes envelope.nonce;
      Encoding.bytes envelope.ciphertext;
      Encoding.integer envelope.mandatory_features;
    ]

let associated_data ~nonce ~mandatory_features =
  header_value ~nonce ~mandatory_features |> Result.map Encoding.encode

let seal ~key ~nonce ~mandatory_features plaintext =
  let plaintext_size = String.length plaintext in
  if plaintext_size > max_plaintext_bytes then
    Error (Plaintext_too_large plaintext_size)
  else
    let* () = check_mandatory_features mandatory_features in
    let* associated_data = associated_data ~nonce ~mandatory_features in
    try
      let key = Mirage_crypto.Chacha20.of_secret key in
      let ciphertext =
        Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce
          ~adata:associated_data plaintext
      in
      if String.length ciphertext > max_ciphertext_bytes then
        Error (Ciphertext_too_large (String.length ciphertext))
      else Ok { nonce; ciphertext; mandatory_features }
    with Invalid_argument detail -> Error (Cryptographic_failure detail)

let encode envelope =
  match envelope_value envelope with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let header_bytes envelope =
  match
    associated_data ~nonce:envelope.nonce
      ~mandatory_features:envelope.mandatory_features
  with
  | Ok bytes -> bytes
  | Error error -> invalid_arg (error_to_string error)

let decode encoded =
  if String.length encoded > max_ciphertext_bytes + max_outer_overhead_bytes
  then Error (Ciphertext_too_large (String.length encoded))
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "v2 encrypted-object envelope" 5 value in
    match values with
    | [ version; algorithm_value; nonce; ciphertext; features ] ->
        let* version = integer "v2 envelope version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_schema_version version)
        else
          let* algorithm_value =
            text_field "v2 envelope algorithm" algorithm_value
          in
          if not (String.equal algorithm_value algorithm) then
            Error (Unsupported_algorithm algorithm_value)
          else
            let* nonce = bytes "v2 envelope nonce" nonce in
            let* nonce = nonce_of_bytes nonce in
            let* ciphertext = bytes "v2 envelope ciphertext" ciphertext in
            if String.length ciphertext < tag_size then
              Error
                (Invalid_payload
                   "v2 envelope ciphertext is shorter than its authentication \
                    tag")
            else if String.length ciphertext > max_ciphertext_bytes then
              Error (Ciphertext_too_large (String.length ciphertext))
            else
              let* mandatory_features =
                integer "v2 envelope mandatory features" features
              in
              let* () = check_mandatory_features mandatory_features in
              let envelope = { nonce; ciphertext; mandatory_features } in
              if String.equal encoded (encode envelope) then Ok envelope
              else Error (Invalid_payload "v2 envelope is noncanonical")
    | _ -> assert false

let open_envelope ~key envelope =
  let* associated_data =
    associated_data ~nonce:envelope.nonce
      ~mandatory_features:envelope.mandatory_features
  in
  try
    let key = Mirage_crypto.Chacha20.of_secret key in
    match
      Mirage_crypto.Chacha20.authenticate_decrypt ~key ~nonce:envelope.nonce
        ~adata:associated_data envelope.ciphertext
    with
    | Some plaintext -> Ok plaintext
    | None -> Error Authentication_failed
  with Invalid_argument detail -> Error (Cryptographic_failure detail)
