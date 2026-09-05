module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Mnemonic = Yeokcham_v1_mnemonic
module Trust = Yeokcham_v1_trust

let ( let* ) = Result.bind
let schema_version = 1L
let algorithm = "chacha20-poly1305"
let key_domain = "yeokcham:v1:recovery-package-key:1\000"
let max_package_bytes = 1_048_576

type secret = string

type package = {
  package_repository : Trust.Repository_id.t;
  package_recovery_device : Trust.device;
  package_nonce : string;
  package_ciphertext : string;
}

type recovered = {
  recovered_authority_value : Trust.authority;
  recovered_capability_value : Trust.signing_capability;
}

type ceremony = { mnemonic : string; package : package }

type error =
  | Invalid_secret of string
  | Invalid_mnemonic of Mnemonic.error
  | Entropy_failure
  | Invalid_package of string
  | Unsupported_version of int64
  | Unsupported_algorithm of string
  | Noncanonical_package
  | Decryption_failed
  | Trust_error of Trust.error

let error_to_string = function
  | Invalid_secret detail -> "invalid V1 recovery secret: " ^ detail
  | Invalid_mnemonic error -> Mnemonic.error_to_string error
  | Entropy_failure -> "V1 OS CSPRNG is unavailable"
  | Invalid_package detail -> "invalid V1 recovery package: " ^ detail
  | Unsupported_version version ->
      Printf.sprintf "unsupported V1 recovery package version: %Ld" version
  | Unsupported_algorithm value ->
      "unsupported V1 recovery encryption: " ^ value
  | Noncanonical_package -> "V1 recovery package is not canonically encoded"
  | Decryption_failed -> "V1 recovery package cannot be decrypted"
  | Trust_error error -> Trust.error_to_string error

let construction =
  Result.map_error (fun error ->
      Invalid_package (Encoding.construction_error_to_string error))

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error (Invalid_package (name ^ " has the wrong field count"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be bytes"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be an integer"))

let digest domain bytes =
  Hash.digest_string (domain ^ bytes) |> Hash.to_raw_string

let valid_nonce nonce = String.length nonce = 12

let check_secret secret =
  if String.length secret = 32 then Ok secret
  else
    Error
      (Invalid_secret
         (Printf.sprintf "must contain 32 bytes, got %d" (String.length secret)))

let generate_secret () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate 32 |> check_secret
  with _ -> Error Entropy_failure

let secret_of_mnemonic mnemonic =
  let* secret =
    Mnemonic.decode mnemonic
    |> Result.map_error (fun error -> Invalid_mnemonic error)
  in
  check_secret secret

let mnemonic secret =
  match Mnemonic.encode secret with
  | Ok mnemonic -> mnemonic
  | Error error -> invalid_arg (Mnemonic.error_to_string error)

let verification_phrase certificate =
  let entropy =
    digest "yeokcham:v1:root-verification-phrase:1\000"
      (Trust.encode_certificate certificate)
    |> fun digest -> String.sub digest 0 16
  in
  match Mnemonic.encode entropy with
  | Ok phrase -> phrase
  | Error error -> invalid_arg (Mnemonic.error_to_string error)

let encode_repository repository =
  Trust.Repository_id.to_string repository |> text

let decode_repository value =
  let* value = text_field "repository ID" value in
  Trust.Repository_id.of_string value
  |> Result.map_error (fun detail -> Invalid_package detail)

let encode_device device =
  let id = Trust.device_id device |> Yeokcham_v1_model.Device_id.to_string in
  let* id = text id in
  array [ id; Encoding.bytes (Trust.device_public_key device) ]

let decode_device value =
  let* fields = exact_array "recovery device" 2 value in
  match fields with
  | [ id; public_key ] ->
      let* id = text_field "recovery device ID" id in
      let* id =
        Yeokcham_v1_model.Device_id.of_string id
        |> Result.map_error (fun error ->
            Invalid_package (Yeokcham_v1_model.error_to_string error))
      in
      let* public_key = bytes_field "recovery public key" public_key in
      let* device =
        Trust.device_of_public_key public_key
        |> Result.map_error (fun error -> Trust_error error)
      in
      if Yeokcham_v1_model.Device_id.equal id (Trust.device_id device) then
        Ok device
      else
        Error
          (Invalid_package "recovery device ID is not derived from public key")
  | _ -> assert false

let map_result f values =
  let rec go reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = f value in
        go (value :: reversed) rest
  in
  go [] values

let encode_bytes_array values = values |> List.map Encoding.bytes |> array

let decode_bytes_array name = function
  | Encoding.Array values -> map_result (bytes_field name) values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be an array"))

let header_value package =
  let* repository = encode_repository package.package_repository in
  let* device = encode_device package.package_recovery_device in
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer schema_version;
      repository;
      device;
      Encoding.bytes package.package_nonce;
      algorithm;
    ]

let header_bytes package = header_value package |> Result.map Encoding.encode

let package_value package =
  let* header = header_value package in
  array [ header; Encoding.bytes package.package_ciphertext ]

let encode package =
  match package_value package with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let decode encoded =
  if String.length encoded > max_package_bytes then
    Error (Invalid_package "exceeds maximum package size")
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_package (Encoding.decode_error_to_string error))
    in
    let* fields = exact_array "V1 recovery package" 2 value in
    match fields with
    | [ header; ciphertext ] -> (
        let* header = exact_array "V1 recovery package header" 5 header in
        match header with
        | [ version; repository; device; nonce; algorithm_value ] ->
            let* version = integer_field "recovery package version" version in
            let* repository = decode_repository repository in
            let* recovery_device = decode_device device in
            let* nonce = bytes_field "recovery package nonce" nonce in
            let* algorithm_value =
              text_field "recovery package algorithm" algorithm_value
            in
            let* ciphertext =
              bytes_field "recovery package ciphertext" ciphertext
            in
            if not (Int64.equal version schema_version) then
              Error (Unsupported_version version)
            else if not (String.equal algorithm_value algorithm) then
              Error (Unsupported_algorithm algorithm_value)
            else if not (valid_nonce nonce) then
              Error (Invalid_package "nonce must contain 12 bytes")
            else if String.length ciphertext < Mirage_crypto.Chacha20.tag_size
            then
              Error
                (Invalid_package
                   "ciphertext is shorter than the authentication tag")
            else
              let package =
                {
                  package_repository = repository;
                  package_recovery_device = recovery_device;
                  package_nonce = nonce;
                  package_ciphertext = ciphertext;
                }
              in
              if String.equal encoded (encode package) then Ok package
              else Error Noncanonical_package
        | _ -> assert false)
    | _ -> assert false

let recovery_device package = package.package_recovery_device

let current_recovery_device authority =
  match Trust.authority_heads authority with
  | [] -> Error (Trust_error (Trust.Invalid_epoch "authority has no heads"))
  | first :: rest ->
      let* first =
        Trust.authority_epoch authority first
        |> Result.map_error (fun error -> Trust_error error)
      in
      let device = Trust.epoch_recovery_device first in
      let* _ =
        map_result
          (fun head ->
            let* epoch =
              Trust.authority_epoch authority head
              |> Result.map_error (fun error -> Trust_error error)
            in
            if Trust.device_equal device (Trust.epoch_recovery_device epoch)
            then Ok ()
            else Error (Trust_error Trust.Invalid_recovery_authority))
          rest
      in
      Ok device

let payload_value ~authority ~recovery_capability =
  let membership = Trust.authority_membership authority in
  let certificates =
    Trust.certificates membership |> List.map Trust.encode_certificate
  in
  let epochs =
    Trust.authority_epochs authority |> List.map Trust.encode_epoch
  in
  let* repository = encode_repository (Trust.repository membership) in
  let* certificates = encode_bytes_array certificates in
  let* epochs = encode_bytes_array epochs in
  let* recovery_private_key =
    Trust.signing_private_key_bytes recovery_capability
    |> Result.map_error (fun _ ->
        Invalid_secret "recovery capability must be exportable")
  in
  array
    [
      Encoding.integer schema_version;
      repository;
      Encoding.bytes recovery_private_key;
      certificates;
      epochs;
    ]

let payload_bytes ~authority ~recovery_capability =
  payload_value ~authority ~recovery_capability |> Result.map Encoding.encode

let encryption_key secret = digest key_domain secret

let make ~secret ~nonce ~authority ~recovery_capability =
  let* secret = check_secret secret in
  if not (valid_nonce nonce) then
    Error (Invalid_package "nonce must contain 12 bytes")
  else
    let* recovery_device = current_recovery_device authority in
    if
      not
        (String.equal
           (Trust.signing_public_key recovery_capability)
           (Trust.device_public_key recovery_device))
    then Error (Invalid_secret "does not match the active recovery device")
    else
      let* plaintext = payload_bytes ~authority ~recovery_capability in
      let package_without_ciphertext =
        {
          package_repository =
            Trust.repository (Trust.authority_membership authority);
          package_recovery_device = recovery_device;
          package_nonce = nonce;
          package_ciphertext = "";
        }
      in
      let* ad = header_bytes package_without_ciphertext in
      try
        let key = Mirage_crypto.Chacha20.of_secret (encryption_key secret) in
        let ciphertext =
          Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce ~adata:ad
            plaintext
        in
        Ok { package_without_ciphertext with package_ciphertext = ciphertext }
      with Invalid_argument detail -> Error (Invalid_package detail)

let rec create ~authority ~recovery_capability =
  let* secret = generate_secret () in
  let* package = refresh ~secret ~authority ~recovery_capability in
  Ok { mnemonic = mnemonic secret; package }

and refresh ~secret ~authority ~recovery_capability =
  try
    Mirage_crypto_rng_unix.use_default ();
    let nonce = Mirage_crypto_rng.generate 12 in
    make ~secret ~nonce ~authority ~recovery_capability
  with _ -> Error Entropy_failure

let decode_payload bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Invalid_package (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "V1 recovery payload" 5 value in
  match fields with
  | [ version; repository; private_key; certificates; epochs ] ->
      let* version = integer_field "recovery payload version" version in
      let* repository = decode_repository repository in
      let* private_key = bytes_field "recovery private key" private_key in
      let* certificates =
        decode_bytes_array "recovery certificates" certificates
      in
      let* epochs = decode_bytes_array "recovery epochs" epochs in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_version version)
      else
        let* capability =
          Trust.signing_capability_of_private_key private_key
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* certificates =
          map_result
            (fun bytes ->
              Trust.decode_certificate bytes
              |> Result.map_error (fun error -> Trust_error error))
            certificates
        in
        let* membership =
          Trust.verify_membership ~repository certificates
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* epochs =
          map_result
            (fun bytes ->
              Trust.decode_epoch bytes
              |> Result.map_error (fun error -> Trust_error error))
            epochs
        in
        let* authority =
          Trust.verify_authority ~membership epochs
          |> Result.map_error (fun error -> Trust_error error)
        in
        Ok (repository, capability, authority)
  | _ -> assert false

let recover ~mnemonic:phrase ~package =
  let* secret = secret_of_mnemonic phrase in
  let* ad = header_bytes package in
  try
    let key = Mirage_crypto.Chacha20.of_secret (encryption_key secret) in
    match
      Mirage_crypto.Chacha20.authenticate_decrypt ~key
        ~nonce:package.package_nonce ~adata:ad package.package_ciphertext
    with
    | None -> Error Decryption_failed
    | Some plaintext ->
        let* repository, capability, authority = decode_payload plaintext in
        if not (Trust.Repository_id.equal repository package.package_repository)
        then
          Error
            (Invalid_package "payload repository does not match package header")
        else if
          not
            (String.equal
               (Trust.signing_public_key capability)
               (Trust.device_public_key package.package_recovery_device))
        then
          Error
            (Invalid_package
               "payload recovery key does not match package header")
        else
          let* active_recovery = current_recovery_device authority in
          if
            not
              (Trust.device_equal active_recovery
                 package.package_recovery_device)
          then
            Error
              (Invalid_package
                 "package recovery device is not active in authority")
          else
            Ok
              {
                recovered_authority_value = authority;
                recovered_capability_value = capability;
              }
  with Invalid_argument _ -> Error Decryption_failed

let recovered_authority recovered = recovered.recovered_authority_value
let recovered_capability recovered = recovered.recovered_capability_value
