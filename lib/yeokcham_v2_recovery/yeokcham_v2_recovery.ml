module Authority = Yeokcham_v2_authority
module Bootstrap = Yeokcham_v2_bootstrap
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model

type recovery_secret = string

type package = {
  package_id : Model.Recovery_package_id.t;
  repository_id : Model.Repository_id.t;
  user_id : Model.User_id.t;
  root_key_id : Model.Root_key_id.t;
  root_public_key : string;
  envelope : Envelope.t;
  mandatory_features : int64;
}

type recovered = {
  recovered_authority : Authority.repository_authority;
  recovered_root : Authority.root_signing_capability;
}

type ceremony = {
  secret : recovery_secret;
  verification_phrase : string;
  package : package;
}

type error =
  | Invalid_recovery_secret of string
  | Verification_phrase_mismatch
  | Invalid_package_id of Model.identity_error
  | Entropy_failure
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_package
  | Authority_error of Authority.error
  | Envelope_error of Envelope.error
  | Authority_root_mismatch
  | Package_binding_mismatch of string

let current_schema_version = 1L
let supported_mandatory_features = 0L
let recovery_secret_length = 32
let package_id_length = Model.Recovery_package_id.byte_length
let max_package_bytes = 4096
let phrase_domain = "yeokcham:v2:recovery-verification:1\000"
let key_domain = "yeokcham:v2:recovery-package-key:1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_recovery_secret detail -> "invalid recovery secret: " ^ detail
  | Verification_phrase_mismatch ->
      "recovery verification phrase does not match the secret"
  | Invalid_package_id error -> Model.identity_error_to_string error
  | Entropy_failure ->
      "OS CSPRNG unavailable while generating recovery material"
  | Invalid_payload detail -> "invalid V2 recovery package: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported recovery package schema version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid recovery mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported recovery mandatory feature bits: %Ld" features
  | Noncanonical_package -> "recovery package bytes are noncanonical"
  | Authority_error error -> Authority.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Authority_root_mismatch ->
      "recovery root does not match the repository authority"
  | Package_binding_mismatch detail ->
      "recovery payload does not match package binding: " ^ detail

let words =
  [|
    "amber";
    "birch";
    "cinder";
    "dawn";
    "ember";
    "fern";
    "grove";
    "harbor";
    "ivory";
    "juniper";
    "kestrel";
    "lunar";
    "meadow";
    "north";
    "opal";
    "pine";
    "quartz";
    "river";
    "sable";
    "thistle";
    "umber";
    "vale";
    "willow";
    "xenon";
    "yarrow";
    "zenith";
    "acorn";
    "bloom";
    "copper";
    "drift";
    "elm";
    "frost";
  |]

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let recovery_secret_of_bytes bytes =
  if String.length bytes = recovery_secret_length then Ok bytes
  else
    Error
      (Invalid_recovery_secret
         (Printf.sprintf "must contain %d bytes, got %d" recovery_secret_length
            (String.length bytes)))

let recovery_secret_to_hex secret =
  let digits = "0123456789abcdef" in
  let output = Bytes.create (String.length secret * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (2 * index) digits.[value lsr 4];
      Bytes.set output ((2 * index) + 1) digits.[value land 15])
    secret;
  Bytes.unsafe_to_string output

let recovery_secret_of_hex value =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
    | _ -> None
  in
  if String.length value <> recovery_secret_length * 2 then
    Error
      (Invalid_recovery_secret "must be 64 lowercase hexadecimal characters")
  else
    let bytes = Bytes.create recovery_secret_length in
    let rec decode offset =
      if offset = String.length value then
        recovery_secret_of_bytes (Bytes.unsafe_to_string bytes)
      else
        match (nibble value.[offset], nibble value.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set bytes (offset / 2) (Char.chr ((high lsl 4) lor low));
            decode (offset + 2)
        | None, _ | _, None ->
            Error
              (Invalid_recovery_secret
                 "must use lowercase hexadecimal characters")
    in
    decode 0

let verification_phrase secret =
  let hash = digest phrase_domain secret in
  List.init 12 (fun index -> words.(Char.code hash.[index] land 31))
  |> String.concat "-"

let verify_phrase secret phrase =
  if String.equal (verification_phrase secret) phrase then Ok ()
  else Error Verification_phrase_mismatch

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let value_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let fields name count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ ->
      Error (Invalid_payload (name ^ " has wrong field count"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let root_matches_authority root authority =
  String.equal
    (Authority.root_public_key root)
    (Authority.repository_authority_root_public_key authority)
  && Model.Root_key_id.equal
       (Authority.root_key_id root)
       (Authority.repository_authority_root_key_id authority)
  && Model.User_id.equal (Authority.user_id root)
       (Authority.repository_authority_user_id authority)

let derive_key secret package_id =
  digest key_domain (secret ^ Model.Recovery_package_id.to_bytes package_id)
  |> Envelope.key_of_bytes
  |> Result.map_error (fun error -> Envelope_error error)

let payload_bytes ~package_id authority root =
  value_array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Recovery_package_id.to_bytes package_id);
      Encoding.bytes (Authority.encode_repository_authority authority);
      Encoding.bytes (Authority.root_private_key_bytes root);
    ]
  |> Result.map Encoding.encode

let package_value package =
  value_array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Recovery_package_id.to_bytes package.package_id);
      Encoding.bytes (Model.Repository_id.to_bytes package.repository_id);
      Encoding.bytes (Model.User_id.to_bytes package.user_id);
      Encoding.bytes (Model.Root_key_id.to_bytes package.root_key_id);
      Encoding.bytes package.root_public_key;
      Encoding.bytes (Envelope.encode package.envelope);
      Encoding.integer package.mandatory_features;
    ]

let encode package =
  match package_value package with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let make ~secret ~package_id ~nonce ~authority ~root ~mandatory_features =
  let* () = check_features mandatory_features in
  if not (root_matches_authority root authority) then
    Error Authority_root_mismatch
  else
    let* plaintext = payload_bytes ~package_id authority root in
    let* key = derive_key secret package_id in
    let* envelope =
      Envelope.seal ~key ~nonce ~mandatory_features plaintext
      |> Result.map_error (fun error -> Envelope_error error)
    in
    Ok
      {
        package_id;
        repository_id = Authority.repository_authority_repository_id authority;
        user_id = Authority.repository_authority_user_id authority;
        root_key_id = Authority.repository_authority_root_key_id authority;
        root_public_key =
          Authority.repository_authority_root_public_key authority;
        envelope;
        mandatory_features;
      }

let generate_bytes length =
  try
    Mirage_crypto_rng_unix.use_default ();
    Ok (Mirage_crypto_rng.generate length)
  with _ -> Error Entropy_failure

let generate_recovery_secret () =
  let* bytes = generate_bytes recovery_secret_length in
  recovery_secret_of_bytes bytes

let create ~authority ~root =
  let* secret = generate_recovery_secret () in
  let* package_id_bytes = generate_bytes package_id_length in
  let* package_id =
    Model.Recovery_package_id.of_bytes package_id_bytes
    |> Result.map_error (fun error -> Invalid_package_id error)
  in
  let* nonce_bytes = generate_bytes 12 in
  let* nonce =
    Envelope.nonce_of_bytes nonce_bytes
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* package =
    make ~secret ~package_id ~nonce ~authority ~root ~mandatory_features:0L
  in
  Ok { secret; verification_phrase = verification_phrase secret; package }

let decode encoded =
  if String.length encoded > max_package_bytes then
    Error (Invalid_payload "package exceeds size limit")
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "recovery package" 8 value in
    match values with
    | [
     version;
     package_id;
     repository_id;
     user_id;
     root_key_id;
     root_public_key;
     envelope;
     features;
    ] ->
        let* version = integer "recovery package version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_schema_version version)
        else
          let* features = integer "recovery mandatory features" features in
          let* () = check_features features in
          let* package_id_bytes = bytes "recovery package ID" package_id in
          let* package_id =
            Model.Recovery_package_id.of_bytes package_id_bytes
            |> Result.map_error (fun error -> Invalid_package_id error)
          in
          let* repository_id_bytes =
            bytes "recovery repository ID" repository_id
          in
          let* repository_id =
            Model.Repository_id.of_bytes repository_id_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* user_id_bytes = bytes "recovery user ID" user_id in
          let* user_id =
            Model.User_id.of_bytes user_id_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* root_key_id_bytes = bytes "recovery root key ID" root_key_id in
          let* root_key_id =
            Model.Root_key_id.of_bytes root_key_id_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* root_public_key =
            bytes "recovery root public key" root_public_key
          in
          let* public_root_key_id =
            Authority.root_key_id_of_public_key root_public_key
            |> Result.map_error (fun error -> Authority_error error)
          in
          let* public_user_id =
            Authority.user_id_of_root_public_key root_public_key
            |> Result.map_error (fun error -> Authority_error error)
          in
          if not (Model.Root_key_id.equal root_key_id public_root_key_id) then
            Error (Package_binding_mismatch "root public key ID")
          else if not (Model.User_id.equal user_id public_user_id) then
            Error (Package_binding_mismatch "root public key user ID")
          else
            let* envelope_bytes = bytes "recovery encrypted payload" envelope in
            let* envelope =
              Envelope.decode envelope_bytes
              |> Result.map_error (fun error -> Envelope_error error)
            in
            if not (Int64.equal features (Envelope.mandatory_features envelope))
            then Error (Package_binding_mismatch "envelope feature bits")
            else
              let package =
                {
                  package_id;
                  repository_id;
                  user_id;
                  root_key_id;
                  root_public_key;
                  envelope;
                  mandatory_features = features;
                }
              in
              if String.equal encoded (encode package) then Ok package
              else Error Noncanonical_package
    | _ -> assert false

let package_id package = package.package_id
let repository_id package = package.repository_id
let user_id package = package.user_id

let recover ~secret ~verification_phrase:phrase ~package =
  let* () = verify_phrase secret phrase in
  let* key = derive_key secret package.package_id in
  let* plaintext =
    Envelope.open_envelope ~key package.envelope
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* value =
    Encoding.decode plaintext
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "recovery payload" 4 value in
  match values with
  | [ version; package_id; authority; root_private ] ->
      let* version = integer "recovery payload version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* package_id = bytes "recovery payload package ID" package_id in
        if
          not
            (String.equal package_id
               (Model.Recovery_package_id.to_bytes package.package_id))
        then Error (Package_binding_mismatch "package ID")
        else
          let* authority_bytes = bytes "recovery payload authority" authority in
          let* authority =
            Authority.decode_repository_authority authority_bytes
            |> Result.map_error (fun error -> Authority_error error)
          in
          let* root_private = bytes "recovery root private key" root_private in
          let* root =
            Authority.root_signing_capability_of_private_key root_private
            |> Result.map_error (fun error -> Authority_error error)
          in
          if not (root_matches_authority root authority) then
            Error Authority_root_mismatch
          else if
            not
              (Model.Repository_id.equal package.repository_id
                 (Authority.repository_authority_repository_id authority))
          then Error (Package_binding_mismatch "repository ID")
          else if
            not
              (Model.User_id.equal package.user_id
                 (Authority.repository_authority_user_id authority))
          then Error (Package_binding_mismatch "user ID")
          else if
            not
              (Model.Root_key_id.equal package.root_key_id
                 (Authority.repository_authority_root_key_id authority))
          then Error (Package_binding_mismatch "root key ID")
          else if
            not
              (String.equal package.root_public_key
                 (Authority.repository_authority_root_public_key authority))
          then Error (Package_binding_mismatch "root public key")
          else Ok { recovered_authority = authority; recovered_root = root }
  | _ -> assert false

let recovered_authority recovered = recovered.recovered_authority

let make_replacement_device_certificate ~recovered ~device_id ~key_handle
    ~capability =
  Authority.make_device_certificate ~authority:recovered.recovered_authority
    ~root:recovered.recovered_root ~device_id
    ~signer_public_key:(Bootstrap.capability_signer_public_key capability)
    ~envelope_key_commitment:
      (Bootstrap.capability_encryption_key_commitment capability)
    ~address_key_commitment:
      (Bootstrap.capability_address_key_commitment capability)
    ~key_handle:(Bootstrap.Key_handle.to_bytes key_handle)
    ~mandatory_features:0L
  |> Result.map_error (fun error -> Authority_error error)
