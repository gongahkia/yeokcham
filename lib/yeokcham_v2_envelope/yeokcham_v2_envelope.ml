module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type key = string
type nonce = string

type t =
  | Legacy of {
      nonce : nonce;
      ciphertext : string;
      mandatory_features : int64;
    }
  | Bound of {
      nonce : nonce;
      object_context : string;
      ciphertext : string;
      mandatory_features : int64;
    }

type context = {
  repository_id : string;
  epoch : int64;
  object_kind : int64;
}

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
  | Invalid_repository_context_length of int
  | Invalid_context_epoch of int64
  | Invalid_object_kind of int64
  | Context_required
  | Context_mismatch
  | Authentication_failed
  | Cryptographic_failure of string

let algorithm = "chacha20-poly1305"
let current_schema_version = 1L
let bound_schema_version = 2L
let supported_mandatory_features = 0L
let key_size = 32
let nonce_size = 12
let repository_id_size = 32
let object_context_size = 32
let tag_size = Mirage_crypto.Chacha20.tag_size
let max_plaintext_bytes = 128 * 1024 * 1024
let max_ciphertext_bytes = max_plaintext_bytes + tag_size
let max_outer_overhead_bytes = 192
let hmac_block_size = 64
let object_context_domain = "yeokcham:v2:object-context:1\000"
let object_key_domain = "yeokcham:v2:object-key:1\000"
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
  | Invalid_repository_context_length length ->
      Printf.sprintf
        "v2 bound-envelope repository context must contain 32 bytes, got %d"
        length
  | Invalid_context_epoch epoch ->
      Printf.sprintf "v2 bound-envelope epoch must be nonnegative, got %Ld"
        epoch
  | Invalid_object_kind kind ->
      Printf.sprintf
        "v2 bound-envelope object kind must be nonnegative, got %Ld" kind
  | Context_required ->
      "v2 bound envelope requires repository, epoch, and type context"
  | Context_mismatch -> "v2 bound-envelope object context does not match plaintext"
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

let make_context ~repository_id ~epoch ~object_kind =
  if String.length repository_id <> repository_id_size then
    Error (Invalid_repository_context_length (String.length repository_id))
  else if Int64.compare epoch 0L < 0 then Error (Invalid_context_epoch epoch)
  else if Int64.compare object_kind 0L < 0 then Error (Invalid_object_kind object_kind)
  else Ok { repository_id; epoch; object_kind }

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let legacy_header_value ~nonce ~mandatory_features =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer current_schema_version;
      algorithm;
      Encoding.bytes nonce;
      Encoding.integer mandatory_features;
    ]

let bound_header_value ~nonce ~object_context ~mandatory_features =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer bound_schema_version;
      algorithm;
      Encoding.bytes nonce;
      Encoding.bytes object_context;
      Encoding.integer mandatory_features;
    ]

let envelope_value = function
  | Legacy { nonce; ciphertext; mandatory_features } ->
      let* algorithm = text algorithm in
      array
        [
          Encoding.integer current_schema_version;
          algorithm;
          Encoding.bytes nonce;
          Encoding.bytes ciphertext;
          Encoding.integer mandatory_features;
        ]
  | Bound { nonce; object_context; ciphertext; mandatory_features } ->
      let* algorithm = text algorithm in
      array
        [
          Encoding.integer bound_schema_version;
          algorithm;
          Encoding.bytes nonce;
          Encoding.bytes object_context;
          Encoding.bytes ciphertext;
          Encoding.integer mandatory_features;
        ]

let associated_data = function
  | Legacy { nonce; mandatory_features; _ } ->
      legacy_header_value ~nonce ~mandatory_features |> Result.map Encoding.encode
  | Bound { nonce; object_context; mandatory_features; _ } ->
      bound_header_value ~nonce ~object_context ~mandatory_features
      |> Result.map Encoding.encode

let context_value context =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes context.repository_id;
      Encoding.integer context.epoch;
      Encoding.integer context.object_kind;
    ]
  |> Result.map Encoding.encode

let xor_pad key byte =
  Bytes.init hmac_block_size (fun index ->
      let source =
        if index < String.length key then Char.code key.[index] else 0
      in
      Char.chr (source lxor byte))
  |> Bytes.unsafe_to_string

let hmac_sha256 ~key chunks =
  let inner =
    List.fold_left
      (fun hash chunk -> Hash.feed_string hash chunk)
      (Hash.feed_string Hash.empty (xor_pad key 0x36))
      chunks
    |> Hash.get |> Hash.to_raw_string
  in
  Hash.feed_string Hash.empty (xor_pad key 0x5c) |> fun outer ->
  Hash.feed_string outer inner |> Hash.get |> Hash.to_raw_string

let derive_object_context ~key ~context ~nonce plaintext =
  let* context = context_value context in
  Ok (hmac_sha256 ~key [ object_context_domain; context; nonce; plaintext ])

let derive_object_key ~key ~context ~object_context =
  let* context = context_value context in
  let derived = hmac_sha256 ~key [ object_key_domain; context; object_context ] in
  key_of_bytes derived

let decrypt ~key ~envelope =
  let* associated_data = associated_data envelope in
  let nonce, ciphertext =
    match envelope with
    | Legacy { nonce; ciphertext; _ }
    | Bound { nonce; ciphertext; _ } ->
        (nonce, ciphertext)
  in
  try
    let key = Mirage_crypto.Chacha20.of_secret key in
    match
      Mirage_crypto.Chacha20.authenticate_decrypt ~key ~nonce
        ~adata:associated_data ciphertext
    with
    | Some plaintext -> Ok plaintext
    | None -> Error Authentication_failed
  with Invalid_argument detail -> Error (Cryptographic_failure detail)

let encrypt ~key ~envelope plaintext =
  let* associated_data = associated_data envelope in
  let nonce =
    match envelope with Legacy { nonce; _ } | Bound { nonce; _ } -> nonce
  in
  try
    let key = Mirage_crypto.Chacha20.of_secret key in
    let ciphertext =
      Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce
        ~adata:associated_data plaintext
    in
    if String.length ciphertext > max_ciphertext_bytes then
      Error (Ciphertext_too_large (String.length ciphertext))
    else Ok ciphertext
  with Invalid_argument detail -> Error (Cryptographic_failure detail)

let seal ~key ~nonce ~mandatory_features plaintext =
  let plaintext_size = String.length plaintext in
  if plaintext_size > max_plaintext_bytes then
    Error (Plaintext_too_large plaintext_size)
  else
    let* () = check_mandatory_features mandatory_features in
    let envelope = Legacy { nonce; ciphertext = ""; mandatory_features } in
    let* ciphertext = encrypt ~key ~envelope plaintext in
    Ok (Legacy { nonce; ciphertext; mandatory_features })

let seal_bound ~key ~nonce ~mandatory_features ~context plaintext =
  let plaintext_size = String.length plaintext in
  if plaintext_size > max_plaintext_bytes then
    Error (Plaintext_too_large plaintext_size)
  else
    let* () = check_mandatory_features mandatory_features in
    let* object_context =
      derive_object_context ~key ~context ~nonce plaintext
    in
    let* object_key = derive_object_key ~key ~context ~object_context in
    let envelope =
      Bound { nonce; object_context; ciphertext = ""; mandatory_features }
    in
    let* ciphertext = encrypt ~key:object_key ~envelope plaintext in
    Ok (Bound { nonce; object_context; ciphertext; mandatory_features })

let encode envelope =
  match envelope_value envelope with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let header_bytes envelope =
  match associated_data envelope with
  | Ok bytes -> bytes
  | Error error -> invalid_arg (error_to_string error)

let mandatory_features = function
  | Legacy { mandatory_features; _ } | Bound { mandatory_features; _ } ->
      mandatory_features

let make_legacy ~nonce ~ciphertext ~mandatory_features =
  if String.length ciphertext < tag_size then
    Error
      (Invalid_payload
         "v2 envelope ciphertext is shorter than its authentication tag")
  else if String.length ciphertext > max_ciphertext_bytes then
    Error (Ciphertext_too_large (String.length ciphertext))
  else
    let* () = check_mandatory_features mandatory_features in
    Ok (Legacy { nonce; ciphertext; mandatory_features })

let make_bound ~nonce ~object_context ~ciphertext ~mandatory_features =
  if String.length object_context <> object_context_size then
    Error (Invalid_payload "v2 bound-envelope object context must contain 32 bytes")
  else if String.length ciphertext < tag_size then
    Error
      (Invalid_payload
         "v2 envelope ciphertext is shorter than its authentication tag")
  else if String.length ciphertext > max_ciphertext_bytes then
    Error (Ciphertext_too_large (String.length ciphertext))
  else
    let* () = check_mandatory_features mandatory_features in
    Ok (Bound { nonce; object_context; ciphertext; mandatory_features })

let rec decode encoded =
  if String.length encoded > max_ciphertext_bytes + max_outer_overhead_bytes
  then Error (Ciphertext_too_large (String.length encoded))
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    match value with
    | Encoding.Array values ->
        let* version =
          match values with
          | version :: _ -> integer "v2 envelope version" version
          | [] -> Error (Invalid_payload "v2 encrypted-object envelope is empty")
        in
        if Int64.equal version current_schema_version then
          let* values = fields "v2 encrypted-object envelope" 5 value in
          decode_legacy encoded values
        else if Int64.equal version bound_schema_version then
          let* values = fields "v2 bound envelope" 6 value in
          decode_bound encoded values
        else Error (Unsupported_schema_version version)
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Invalid_payload "v2 encrypted-object envelope must be an array")

and decode_legacy encoded = function
  | [ _; algorithm_value; nonce; ciphertext; features ] ->
      let* algorithm_value = text_field "v2 envelope algorithm" algorithm_value in
      if not (String.equal algorithm_value algorithm) then
        Error (Unsupported_algorithm algorithm_value)
      else
        let* nonce = bytes "v2 envelope nonce" nonce in
        let* nonce = nonce_of_bytes nonce in
        let* ciphertext = bytes "v2 envelope ciphertext" ciphertext in
        let* mandatory_features = integer "v2 envelope mandatory features" features in
        let* envelope = make_legacy ~nonce ~ciphertext ~mandatory_features in
        if String.equal encoded (encode envelope) then Ok envelope
        else Error (Invalid_payload "v2 envelope is noncanonical")
  | _ -> assert false

and decode_bound encoded = function
  | [ _; algorithm_value; nonce; object_context; ciphertext; features ] ->
      let* algorithm_value =
        text_field "v2 bound-envelope algorithm" algorithm_value
      in
      if not (String.equal algorithm_value algorithm) then
        Error (Unsupported_algorithm algorithm_value)
      else
        let* nonce = bytes "v2 bound-envelope nonce" nonce in
        let* nonce = nonce_of_bytes nonce in
        let* object_context =
          bytes "v2 bound-envelope object context" object_context
        in
        let* ciphertext = bytes "v2 bound-envelope ciphertext" ciphertext in
        let* mandatory_features =
          integer "v2 bound-envelope mandatory features" features
        in
        let* envelope =
          make_bound ~nonce ~object_context ~ciphertext ~mandatory_features
        in
        if String.equal encoded (encode envelope) then Ok envelope
        else Error (Invalid_payload "v2 bound envelope is noncanonical")
  | _ -> assert false

let open_envelope ~key = function
  | Legacy _ as envelope -> decrypt ~key ~envelope
  | Bound _ -> Error Context_required

let open_bound ~key ~context = function
  | Legacy _ -> Error Context_required
  | Bound { nonce; object_context; _ } as envelope ->
      let* object_key = derive_object_key ~key ~context ~object_context in
      let* plaintext = decrypt ~key:object_key ~envelope in
      let* expected_context =
        derive_object_context ~key ~context ~nonce plaintext
      in
      if String.equal object_context expected_context then Ok plaintext
      else Error Context_mismatch

let is_bound = function Legacy _ -> false | Bound _ -> true
