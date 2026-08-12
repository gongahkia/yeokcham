module Model = Yeokcham_v2_model
module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type role = Envelope_encryption | Opaque_address | Ledger_signing

type capability = {
  cap_encryption_key : Envelope.key;
  cap_address_key : Address.key;
  cap_signing_key : Mirage_crypto_ec.Ed25519.priv;
  cap_signer_public_key : string;
  cap_signer_key_id : Ledger.Signer_key_id.t;
  cap_encryption_key_commitment : string;
  cap_address_key_commitment : string;
}

module Key_handle = struct
  type t = string

  let byte_length = 32

  let of_bytes bytes =
    let actual = String.length bytes in
    if actual = byte_length then Ok bytes
    else Error (Model.Invalid_byte_length { expected = byte_length; actual })

  let to_bytes handle = handle

  let to_hex handle =
    let digits = "0123456789abcdef" in
    let encoded = Bytes.create (String.length handle * 2) in
    String.iteri
      (fun index character ->
        let value = Char.code character in
        Bytes.set encoded (index * 2) digits.[value lsr 4];
        Bytes.set encoded ((index * 2) + 1) digits.[value land 0x0f])
      handle;
    Bytes.unsafe_to_string encoded

  let equal = String.equal
end

type t = {
  repository_id : Model.Repository_id.t;
  device_id : Model.Device_id.t;
  key_handle : Key_handle.t;
  signer_key_id : Ledger.Signer_key_id.t;
  signer_public_key : string;
  encryption_key_commitment : string;
  address_key_commitment : string;
  mandatory_features : int64;
  signature : string;
}

type error =
  | Reused_key_material of { first : role; second : role }
  | Invalid_public_key_length of int
  | Invalid_signature_length of int
  | Invalid_key_commitment_length of int
  | Invalid_key_handle_length of int
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Invalid_payload of string
  | Invalid_signer_key_id
  | Noncanonical_bootstrap
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Capability_signer_mismatch
  | Capability_encryption_key_mismatch
  | Capability_address_key_mismatch
  | Ledger_error of Ledger.error

let current_schema_version = 2L
let supported_mandatory_features = 0L
let max_bootstrap_bytes = 1024
let public_key_size = 32
let signature_size = 64
let key_commitment_size = 32
let bootstrap_domain = "yeokcham:v2:local-bootstrap:2\000"
let envelope_key_domain = "yeokcham:v2:bootstrap-envelope-key:1\000"
let address_key_domain = "yeokcham:v2:bootstrap-address-key:1\000"
let ( let* ) = Result.bind

let role_to_string = function
  | Envelope_encryption -> "envelope encryption"
  | Opaque_address -> "opaque address"
  | Ledger_signing -> "ledger signing"

let error_to_string = function
  | Reused_key_material { first; second } ->
      Printf.sprintf "%s and %s keys must use distinct raw key material"
        (role_to_string first) (role_to_string second)
  | Invalid_public_key_length length ->
      Printf.sprintf
        "bootstrap Ed25519 public key must contain 32 bytes, got %d" length
  | Invalid_signature_length length ->
      Printf.sprintf "bootstrap signature must contain 64 bytes, got %d" length
  | Invalid_key_commitment_length length ->
      Printf.sprintf "bootstrap key commitment must contain 32 bytes, got %d"
        length
  | Invalid_key_handle_length length ->
      Printf.sprintf "bootstrap local key handle must contain 32 bytes, got %d"
        length
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid bootstrap mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported bootstrap mandatory feature bits: %Ld"
        features
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported local bootstrap schema version: %Ld" version
  | Invalid_payload detail -> "invalid local bootstrap: " ^ detail
  | Invalid_signer_key_id ->
      "bootstrap signer-key ID does not match its Ed25519 public key"
  | Noncanonical_bootstrap -> "local bootstrap bytes are noncanonical"
  | Signature_verification_failed -> "local bootstrap signature is invalid"
  | Cryptographic_failure detail -> "bootstrap cryptographic failure: " ^ detail
  | Capability_signer_mismatch ->
      "injected signing capability does not match the local bootstrap signer"
  | Capability_encryption_key_mismatch ->
      "injected envelope-encryption capability does not match the local \
       bootstrap"
  | Capability_address_key_mismatch ->
      "injected opaque-address capability does not match the local bootstrap"
  | Ledger_error error -> Ledger.error_to_string error

let array values =
  Encoding.array values
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

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let commitment domain key =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context key |> Hash.get |> Hash.to_raw_string

let encryption_key_commitment key =
  Envelope.key_to_bytes key |> commitment envelope_key_domain

let address_key_commitment key =
  Address.key_to_bytes key |> commitment address_key_domain

let make_capability ~encryption_key ~address_key ~signing_key =
  let encryption_bytes = Envelope.key_to_bytes encryption_key in
  let address_bytes = Address.key_to_bytes address_key in
  let signing_bytes = Mirage_crypto_ec.Ed25519.priv_to_octets signing_key in
  if String.equal encryption_bytes address_bytes then
    Error
      (Reused_key_material
         { first = Envelope_encryption; second = Opaque_address })
  else if String.equal encryption_bytes signing_bytes then
    Error
      (Reused_key_material
         { first = Envelope_encryption; second = Ledger_signing })
  else if String.equal address_bytes signing_bytes then
    Error
      (Reused_key_material { first = Opaque_address; second = Ledger_signing })
  else
    let signer_public_key =
      Mirage_crypto_ec.Ed25519.pub_of_priv signing_key
      |> Mirage_crypto_ec.Ed25519.pub_to_octets
    in
    let* signer_key_id =
      Ledger.signer_key_id_of_public_key signer_public_key
      |> Result.map_error (fun error -> Ledger_error error)
    in
    Ok
      {
        cap_encryption_key = encryption_key;
        cap_address_key = address_key;
        cap_signing_key = signing_key;
        cap_signer_public_key = signer_public_key;
        cap_signer_key_id = signer_key_id;
        cap_encryption_key_commitment = encryption_key_commitment encryption_key;
        cap_address_key_commitment = address_key_commitment address_key;
      }

let secret_material capability =
  ( Envelope.key_to_bytes capability.cap_encryption_key,
    Address.key_to_bytes capability.cap_address_key,
    Mirage_crypto_ec.Ed25519.priv_to_octets capability.cap_signing_key )

let capability_of_secret_material ~encryption_key ~address_key ~signing_key =
  let* encryption_key =
    Envelope.key_of_bytes encryption_key
    |> Result.map_error (fun error ->
        Invalid_payload (Envelope.error_to_string error))
  in
  let* address_key =
    Address.key_of_bytes address_key
    |> Result.map_error (fun error ->
        Invalid_payload (Address.error_to_string error))
  in
  let* signing_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets signing_key
    |> Result.map_error (fun error ->
        Cryptographic_failure
          (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))
  in
  make_capability ~encryption_key ~address_key ~signing_key

let envelope_key capability = capability.cap_encryption_key
let address_key capability = capability.cap_address_key
let capability_signer_key_id capability = capability.cap_signer_key_id
let capability_signer_public_key capability = capability.cap_signer_public_key

let capability_encryption_key_commitment capability =
  capability.cap_encryption_key_commitment

let capability_address_key_commitment capability =
  capability.cap_address_key_commitment

let sign_ledger capability unsigned =
  Ledger.signing_bytes unsigned
  |> Mirage_crypto_ec.Ed25519.sign ~key:capability.cap_signing_key

let public_key_registry capability =
  Ledger.make_public_key_registry
    [ (capability.cap_signer_key_id, capability.cap_signer_public_key) ]
  |> Result.map_error (fun error -> Ledger_error error)

let unsigned_value bootstrap =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes bootstrap.repository_id);
      Encoding.bytes (Model.Device_id.to_bytes bootstrap.device_id);
      Encoding.bytes (Key_handle.to_bytes bootstrap.key_handle);
      Encoding.bytes (Ledger.Signer_key_id.to_bytes bootstrap.signer_key_id);
      Encoding.bytes bootstrap.signer_public_key;
      Encoding.bytes bootstrap.encryption_key_commitment;
      Encoding.bytes bootstrap.address_key_commitment;
      Encoding.integer bootstrap.mandatory_features;
    ]

let unsigned_bytes bootstrap =
  unsigned_value bootstrap |> Result.map Encoding.encode

let signing_bytes bootstrap =
  unsigned_bytes bootstrap |> Result.map (fun bytes -> bootstrap_domain ^ bytes)

let encode bootstrap =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes bootstrap.repository_id);
      Encoding.bytes (Model.Device_id.to_bytes bootstrap.device_id);
      Encoding.bytes (Key_handle.to_bytes bootstrap.key_handle);
      Encoding.bytes (Ledger.Signer_key_id.to_bytes bootstrap.signer_key_id);
      Encoding.bytes bootstrap.signer_public_key;
      Encoding.bytes bootstrap.encryption_key_commitment;
      Encoding.bytes bootstrap.address_key_commitment;
      Encoding.integer bootstrap.mandatory_features;
      Encoding.bytes bootstrap.signature;
    ]
  |> Result.map Encoding.encode
  |> function
  | Ok bytes -> bytes
  | Error _ -> assert false

let check_public_key public_key =
  if String.length public_key <> public_key_size then
    Error (Invalid_public_key_length (String.length public_key))
  else
    match Mirage_crypto_ec.Ed25519.pub_of_octets public_key with
    | Ok _ -> Ok ()
    | Error error ->
        Error
          (Cryptographic_failure
             (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))

let check_commitment commitment =
  if String.length commitment = key_commitment_size then Ok ()
  else Error (Invalid_key_commitment_length (String.length commitment))

let verify_signature bootstrap =
  let* signing_bytes = signing_bytes bootstrap in
  match Mirage_crypto_ec.Ed25519.pub_of_octets bootstrap.signer_public_key with
  | Error error ->
      Error
        (Cryptographic_failure
           (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))
  | Ok public_key ->
      if
        Mirage_crypto_ec.Ed25519.verify ~key:public_key ~msg:signing_bytes
          bootstrap.signature
      then Ok ()
      else Error Signature_verification_failed

let make ~repository_id ~device_id ~key_handle ~capability ~mandatory_features =
  let* () = check_mandatory_features mandatory_features in
  let unsigned =
    {
      repository_id;
      device_id;
      key_handle;
      signer_key_id = capability.cap_signer_key_id;
      signer_public_key = capability.cap_signer_public_key;
      encryption_key_commitment = capability.cap_encryption_key_commitment;
      address_key_commitment = capability.cap_address_key_commitment;
      mandatory_features;
      signature = "";
    }
  in
  let* signing_bytes = signing_bytes unsigned in
  let signature =
    Mirage_crypto_ec.Ed25519.sign ~key:capability.cap_signing_key signing_bytes
  in
  Ok { unsigned with signature }

let decode input =
  if String.length input > max_bootstrap_bytes then
    Error (Invalid_payload "bootstrap exceeds its byte limit")
  else
    let* value =
      Encoding.decode input
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "local bootstrap" 10 value in
    match values with
    | [
     version;
     repository_value;
     device_value;
     key_handle_value;
     signer_key_id_value;
     public_key_value;
     encryption_commitment_value;
     address_commitment_value;
     mandatory_features_value;
     signature_value;
    ] ->
        let* version = integer "bootstrap schema version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_schema_version version)
        else
          let* repository_bytes =
            bytes "bootstrap repository ID" repository_value
          in
          let* repository_id =
            Model.Repository_id.of_bytes repository_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* device_bytes = bytes "bootstrap device ID" device_value in
          let* device_id =
            Model.Device_id.of_bytes device_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* key_handle_bytes =
            bytes "bootstrap local key handle" key_handle_value
          in
          let* key_handle =
            Key_handle.of_bytes key_handle_bytes
            |> Result.map_error (fun _ ->
                Invalid_key_handle_length (String.length key_handle_bytes))
          in
          let* signer_key_id_bytes =
            bytes "bootstrap signer-key ID" signer_key_id_value
          in
          let* signer_key_id =
            Ledger.Signer_key_id.of_bytes signer_key_id_bytes
            |> Result.map_error (fun error ->
                Invalid_payload (Model.identity_error_to_string error))
          in
          let* signer_public_key =
            bytes "bootstrap signer public key" public_key_value
          in
          let* () = check_public_key signer_public_key in
          let* expected_signer_key_id =
            Ledger.signer_key_id_of_public_key signer_public_key
            |> Result.map_error (fun error -> Ledger_error error)
          in
          if
            not
              (Ledger.Signer_key_id.equal signer_key_id expected_signer_key_id)
          then Error Invalid_signer_key_id
          else
            let* encryption_key_commitment =
              bytes "bootstrap envelope-key commitment"
                encryption_commitment_value
            in
            let* () = check_commitment encryption_key_commitment in
            let* address_key_commitment =
              bytes "bootstrap address-key commitment" address_commitment_value
            in
            let* () = check_commitment address_key_commitment in
            let* mandatory_features =
              integer "bootstrap mandatory features" mandatory_features_value
            in
            let* () = check_mandatory_features mandatory_features in
            let* signature = bytes "bootstrap signature" signature_value in
            if String.length signature <> signature_size then
              Error (Invalid_signature_length (String.length signature))
            else
              let bootstrap =
                {
                  repository_id;
                  device_id;
                  key_handle;
                  signer_key_id;
                  signer_public_key;
                  encryption_key_commitment;
                  address_key_commitment;
                  mandatory_features;
                  signature;
                }
              in
              if not (String.equal input (encode bootstrap)) then
                Error Noncanonical_bootstrap
              else
                let* () = verify_signature bootstrap in
                Ok bootstrap
    | _ -> assert false

let repository_id bootstrap = bootstrap.repository_id
let device_id bootstrap = bootstrap.device_id
let key_handle bootstrap = bootstrap.key_handle
let signer_key_id bootstrap = bootstrap.signer_key_id
let signer_public_key bootstrap = bootstrap.signer_public_key
let mandatory_features bootstrap = bootstrap.mandatory_features

let validate_capability ~capability bootstrap =
  if
    not
      (String.equal capability.cap_signer_public_key bootstrap.signer_public_key)
  then Error Capability_signer_mismatch
  else if
    not
      (Ledger.Signer_key_id.equal capability.cap_signer_key_id
         bootstrap.signer_key_id)
  then Error Capability_signer_mismatch
  else if
    not
      (String.equal capability.cap_encryption_key_commitment
         bootstrap.encryption_key_commitment)
  then Error Capability_encryption_key_mismatch
  else if
    not
      (String.equal capability.cap_address_key_commitment
         bootstrap.address_key_commitment)
  then Error Capability_address_key_mismatch
  else Ok ()
