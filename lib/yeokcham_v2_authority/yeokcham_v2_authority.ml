module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model
module Ledger = Yeokcham_v2_ledger
module Repository_id = Model.Repository_id
module User_id = Model.User_id
module Root_key_id = Model.Root_key_id
module Device_id = Model.Device_id
module Device_certificate_id = Model.Device_certificate_id
module Device_revocation_id = Model.Device_revocation_id
module Repository_authority_id = Model.Repository_authority_id
module Signer_key_id = Model.Signer_key_id

type root_signing_capability = {
  root_cap_private_key : Mirage_crypto_ec.Ed25519.priv;
  root_cap_public_key : string;
  root_cap_key_id : Root_key_id.t;
  root_cap_user_id : User_id.t;
}

type repository_authority = {
  authority_record_id : Repository_authority_id.t;
  authority_repository_id : Repository_id.t;
  authority_user_id : User_id.t;
  authority_root_key_id : Root_key_id.t;
  authority_root_public_key : string;
  authority_mandatory_features : int64;
  authority_signature : string;
}

type device_certificate = {
  certificate_record_id : Device_certificate_id.t;
  certificate_repository_id : Repository_id.t;
  certificate_user_id : User_id.t;
  certificate_device_id : Device_id.t;
  certificate_signer_key_id : Signer_key_id.t;
  certificate_signer_public_key : string;
  certificate_envelope_key_commitment : string;
  certificate_address_key_commitment : string;
  certificate_key_handle : string;
  certificate_mandatory_features : int64;
  certificate_signature : string;
}

type device_revocation = {
  revocation_record_id : Device_revocation_id.t;
  revocation_repository_id : Repository_id.t;
  revocation_user_id : User_id.t;
  revocation_certificate_id : Device_certificate_id.t;
  revocation_mandatory_features : int64;
  revocation_signature : string;
}

type authority_state = {
  authority : repository_authority;
  certificates : device_certificate list;
  revocations : device_revocation list;
}

type device_status = Active | Revoked of device_revocation

type error =
  | Invalid_root_private_key of string
  | Invalid_root_public_key of string
  | Invalid_device_signer_public_key of int
  | Invalid_signature_length of int
  | Invalid_key_commitment_length of { field : string; actual : int }
  | Invalid_key_handle_length of int
  | Reused_root_as_device_signer
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_payload of string
  | Invalid_identity of string
  | Authority_mismatch of string
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Noncanonical_record
  | Duplicate_device_certificate of Device_certificate_id.t
  | Duplicate_device of Device_id.t
  | Duplicate_device_revocation of Device_revocation_id.t
  | Multiple_revocations of Device_certificate_id.t
  | Unknown_revocation_certificate of Device_certificate_id.t

let current_schema_version = 1L
let supported_mandatory_features = 0L
let algorithm = "ed25519"
let public_key_size = 32
let signature_size = 64
let key_commitment_size = 32
let key_handle_size = 32
let user_id_domain = "yeokcham:v2:user-root:1\000"
let root_key_id_domain = "yeokcham:v2:root-signing-key:1\000"
let repository_authority_id_domain = "yeokcham:v2:repository-authority:1\000"

let repository_authority_signature_domain =
  "yeokcham:v2:repository-authority-signature:1\000"

let device_certificate_id_domain = "yeokcham:v2:device-certificate:1\000"

let device_certificate_signature_domain =
  "yeokcham:v2:device-certificate-signature:1\000"

let device_revocation_id_domain = "yeokcham:v2:device-revocation:1\000"

let device_revocation_signature_domain =
  "yeokcham:v2:device-revocation-signature:1\000"

let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_root_private_key detail ->
      "invalid V2 authority root private key: " ^ detail
  | Invalid_root_public_key detail ->
      "invalid V2 authority root public key: " ^ detail
  | Invalid_device_signer_public_key actual ->
      Printf.sprintf
        "device signer Ed25519 public key must contain 32 bytes, got %d" actual
  | Invalid_signature_length actual ->
      Printf.sprintf "authority Ed25519 signature must contain 64 bytes, got %d"
        actual
  | Invalid_key_commitment_length { field; actual } ->
      Printf.sprintf "%s key commitment must contain 32 bytes, got %d" field
        actual
  | Invalid_key_handle_length actual ->
      Printf.sprintf "authority local key handle must contain 32 bytes, got %d"
        actual
  | Reused_root_as_device_signer ->
      "the root signing public key must not be a device ledger signer"
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid authority mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported authority mandatory feature bits: %Ld"
        features
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported authority record schema version: %Ld" version
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported authority signature algorithm: %s" value
  | Invalid_payload detail -> "invalid authority record: " ^ detail
  | Invalid_identity detail -> "authority record identity mismatch: " ^ detail
  | Authority_mismatch detail ->
      "authority record does not match its anchor: " ^ detail
  | Signature_verification_failed -> "authority root signature is invalid"
  | Cryptographic_failure detail -> "authority cryptographic failure: " ^ detail
  | Noncanonical_record -> "authority record bytes are noncanonical"
  | Duplicate_device_certificate certificate ->
      Printf.sprintf "duplicate device certificate: %s"
        (Device_certificate_id.to_hex certificate)
  | Duplicate_device device ->
      Printf.sprintf "multiple authority certificates bind device: %s"
        (Device_id.to_hex device)
  | Duplicate_device_revocation revocation ->
      Printf.sprintf "duplicate device revocation: %s"
        (Device_revocation_id.to_hex revocation)
  | Multiple_revocations certificate ->
      Printf.sprintf "multiple revocations bind certificate: %s"
        (Device_certificate_id.to_hex certificate)
  | Unknown_revocation_certificate certificate ->
      Printf.sprintf "revocation targets unknown certificate: %s"
        (Device_certificate_id.to_hex certificate)

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

let text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let valid_root_public_key public_key =
  if String.length public_key <> public_key_size then
    Error
      (Invalid_root_public_key
         (Printf.sprintf "must contain 32 bytes, got %d"
            (String.length public_key)))
  else
    Mirage_crypto_ec.Ed25519.pub_of_octets public_key
    |> Result.map_error (fun error ->
        Invalid_root_public_key
          (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))

let user_id_of_root_public_key public_key =
  let* _ = valid_root_public_key public_key in
  match User_id.of_bytes (digest user_id_domain public_key) with
  | Ok identity -> Ok identity
  | Error _ -> assert false

let root_key_id_of_public_key public_key =
  let* _ = valid_root_public_key public_key in
  match Root_key_id.of_bytes (digest root_key_id_domain public_key) with
  | Ok identity -> Ok identity
  | Error _ -> assert false

let root_signing_capability_of_private_key private_key =
  let* root_private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets private_key
    |> Result.map_error (fun error ->
        Invalid_root_private_key
          (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))
  in
  let public_key =
    root_private_key |> Mirage_crypto_ec.Ed25519.pub_of_priv
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let* root_id = root_key_id_of_public_key public_key in
  let* user_identity = user_id_of_root_public_key public_key in
  Ok
    ({
       root_cap_private_key = root_private_key;
       root_cap_public_key = public_key;
       root_cap_key_id = root_id;
       root_cap_user_id = user_identity;
     }
      : root_signing_capability)

let root_public_key (root : root_signing_capability) = root.root_cap_public_key
let root_key_id (root : root_signing_capability) = root.root_cap_key_id
let user_id (root : root_signing_capability) = root.root_cap_user_id

let repository_authority_unsigned_value ~repository_id ~user_id ~root_key_id
    ~root_public_key ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Repository_id.to_bytes repository_id);
      Encoding.bytes (User_id.to_bytes user_id);
      Encoding.bytes (Root_key_id.to_bytes root_key_id);
      Encoding.bytes root_public_key;
      Encoding.integer mandatory_features;
    ]

let repository_authority_unsigned_bytes ~repository_id ~user_id ~root_key_id
    ~root_public_key ~mandatory_features =
  repository_authority_unsigned_value ~repository_id ~user_id ~root_key_id
    ~root_public_key ~mandatory_features
  |> Result.map Encoding.encode

let derive_repository_authority_id ~repository_id ~user_id ~root_key_id
    ~root_public_key ~mandatory_features =
  let* bytes =
    repository_authority_unsigned_bytes ~repository_id ~user_id ~root_key_id
      ~root_public_key ~mandatory_features
  in
  match
    Repository_authority_id.of_bytes
      (digest repository_authority_id_domain bytes)
  with
  | Ok identity -> Ok identity
  | Error _ -> assert false

let repository_authority_signing_bytes authority_id =
  repository_authority_signature_domain
  ^ Repository_authority_id.to_bytes authority_id

let check_signature_length signature =
  if String.length signature = signature_size then Ok ()
  else Error (Invalid_signature_length (String.length signature))

let verify_signature ~public_key ~message ~signature =
  let* root_public_key = valid_root_public_key public_key in
  let* () = check_signature_length signature in
  try
    if
      Mirage_crypto_ec.Ed25519.verify ~key:root_public_key signature
        ~msg:message
    then Ok ()
    else Error Signature_verification_failed
  with Mirage_crypto_ec.Message_too_long ->
    Error (Cryptographic_failure "authority signing message is too long")

let make_repository_authority ~repository_id ~(root : root_signing_capability)
    ~mandatory_features =
  let* () = check_mandatory_features mandatory_features in
  let* authority_id =
    derive_repository_authority_id ~repository_id ~user_id:root.root_cap_user_id
      ~root_key_id:root.root_cap_key_id
      ~root_public_key:root.root_cap_public_key ~mandatory_features
  in
  let signature =
    Mirage_crypto_ec.Ed25519.sign ~key:root.root_cap_private_key
      (repository_authority_signing_bytes authority_id)
  in
  Ok
    {
      authority_record_id = authority_id;
      authority_repository_id = repository_id;
      authority_user_id = root.root_cap_user_id;
      authority_root_key_id = root.root_cap_key_id;
      authority_root_public_key = root.root_cap_public_key;
      authority_mandatory_features = mandatory_features;
      authority_signature = signature;
    }

let repository_authority_id authority = authority.authority_record_id

let repository_authority_repository_id authority =
  authority.authority_repository_id

let repository_authority_user_id authority = authority.authority_user_id
let repository_authority_root_key_id authority = authority.authority_root_key_id

let repository_authority_root_public_key authority =
  authority.authority_root_public_key

let repository_authority_mandatory_features authority =
  authority.authority_mandatory_features

let repository_authority_value authority =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes
        (Repository_authority_id.to_bytes authority.authority_record_id);
      Encoding.bytes (Repository_id.to_bytes authority.authority_repository_id);
      Encoding.bytes (User_id.to_bytes authority.authority_user_id);
      Encoding.bytes (Root_key_id.to_bytes authority.authority_root_key_id);
      Encoding.bytes authority.authority_root_public_key;
      Encoding.integer authority.authority_mandatory_features;
      Encoding.text algorithm |> Result.get_ok;
      Encoding.bytes authority.authority_signature;
    ]

let encode_repository_authority authority =
  repository_authority_value authority |> Result.get_ok |> Encoding.encode

let repository_id_of_value name value =
  let* value = bytes name value in
  Repository_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let user_id_of_value name value =
  let* value = bytes name value in
  User_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let root_key_id_of_value name value =
  let* value = bytes name value in
  Root_key_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let repository_authority_id_of_value name value =
  let* value = bytes name value in
  Repository_authority_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let decode_repository_authority encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "repository authority" 9 value in
  match values with
  | [
   version;
   id;
   repository_id;
   user_id;
   root_key_id;
   root_public_key;
   features;
   algorithm_value;
   signature;
  ] ->
      let* version = integer "repository authority schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id =
          repository_authority_id_of_value "repository authority ID" id
        in
        let* repository_id =
          repository_id_of_value "repository authority repository ID"
            repository_id
        in
        let* user_id =
          user_id_of_value "repository authority user ID" user_id
        in
        let* root_key_id =
          root_key_id_of_value "repository authority root key ID" root_key_id
        in
        let* root_public_key =
          bytes "repository authority root public key" root_public_key
        in
        let* features =
          integer "repository authority mandatory features" features
        in
        let* () = check_mandatory_features features in
        let* algorithm_value =
          text "repository authority signature algorithm" algorithm_value
        in
        if not (String.equal algorithm_value algorithm) then
          Error (Unsupported_algorithm algorithm_value)
        else
          let* signature = bytes "repository authority signature" signature in
          let* derived_user_id = user_id_of_root_public_key root_public_key in
          if not (User_id.equal user_id derived_user_id) then
            Error (Invalid_identity "repository authority user ID")
          else
            let* derived_root_key_id =
              root_key_id_of_public_key root_public_key
            in
            if not (Root_key_id.equal root_key_id derived_root_key_id) then
              Error (Invalid_identity "repository authority root key ID")
            else
              let* derived_id =
                derive_repository_authority_id ~repository_id ~user_id
                  ~root_key_id ~root_public_key ~mandatory_features:features
              in
              if not (Repository_authority_id.equal id derived_id) then
                Error (Invalid_identity "repository authority ID")
              else
                let* () =
                  verify_signature ~public_key:root_public_key
                    ~message:(repository_authority_signing_bytes id)
                    ~signature
                in
                let authority =
                  {
                    authority_record_id = id;
                    authority_repository_id = repository_id;
                    authority_user_id = user_id;
                    authority_root_key_id = root_key_id;
                    authority_root_public_key = root_public_key;
                    authority_mandatory_features = features;
                    authority_signature = signature;
                  }
                in
                if String.equal encoded (encode_repository_authority authority)
                then Ok authority
                else Error Noncanonical_record
  | _ -> assert false

let ensure_root_matches_authority ~(authority : repository_authority)
    ~(root : root_signing_capability) =
  if
    not
      (String.equal root.root_cap_public_key authority.authority_root_public_key
      && Root_key_id.equal root.root_cap_key_id authority.authority_root_key_id
      && User_id.equal root.root_cap_user_id authority.authority_user_id)
  then Error (Authority_mismatch "root capability")
  else Ok ()

let check_device_signer_public_key public_key =
  if String.length public_key <> public_key_size then
    Error (Invalid_device_signer_public_key (String.length public_key))
  else
    let* _ =
      Mirage_crypto_ec.Ed25519.pub_of_octets public_key
      |> Result.map_error (fun error ->
          Cryptographic_failure
            (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))
    in
    Ledger.signer_key_id_of_public_key public_key
    |> Result.map_error (fun _ -> assert false)

let check_commitment field value =
  if String.length value = key_commitment_size then Ok ()
  else
    Error
      (Invalid_key_commitment_length { field; actual = String.length value })

let check_key_handle value =
  if String.length value = key_handle_size then Ok ()
  else Error (Invalid_key_handle_length (String.length value))

let device_certificate_unsigned_value ~repository_id ~user_id ~device_id
    ~signer_key_id ~signer_public_key ~envelope_key_commitment
    ~address_key_commitment ~key_handle ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Repository_id.to_bytes repository_id);
      Encoding.bytes (User_id.to_bytes user_id);
      Encoding.bytes (Device_id.to_bytes device_id);
      Encoding.bytes (Signer_key_id.to_bytes signer_key_id);
      Encoding.bytes signer_public_key;
      Encoding.bytes envelope_key_commitment;
      Encoding.bytes address_key_commitment;
      Encoding.bytes key_handle;
      Encoding.integer mandatory_features;
    ]

let derive_device_certificate_id ~repository_id ~user_id ~device_id
    ~signer_key_id ~signer_public_key ~envelope_key_commitment
    ~address_key_commitment ~key_handle ~mandatory_features =
  let* unsigned =
    device_certificate_unsigned_value ~repository_id ~user_id ~device_id
      ~signer_key_id ~signer_public_key ~envelope_key_commitment
      ~address_key_commitment ~key_handle ~mandatory_features
  in
  match
    Device_certificate_id.of_bytes
      (digest device_certificate_id_domain (Encoding.encode unsigned))
  with
  | Ok identity -> Ok identity
  | Error _ -> assert false

let device_certificate_signing_bytes certificate_id =
  device_certificate_signature_domain
  ^ Device_certificate_id.to_bytes certificate_id

let make_device_certificate ~(authority : repository_authority)
    ~(root : root_signing_capability) ~device_id ~signer_public_key
    ~envelope_key_commitment ~address_key_commitment ~key_handle
    ~mandatory_features =
  let* () = ensure_root_matches_authority ~authority ~root in
  let* () = check_mandatory_features mandatory_features in
  let* signer_key_id = check_device_signer_public_key signer_public_key in
  if String.equal signer_public_key authority.authority_root_public_key then
    Error Reused_root_as_device_signer
  else
    let* () = check_commitment "envelope" envelope_key_commitment in
    let* () = check_commitment "address" address_key_commitment in
    let* () = check_key_handle key_handle in
    let* certificate_id =
      derive_device_certificate_id
        ~repository_id:authority.authority_repository_id
        ~user_id:authority.authority_user_id ~device_id ~signer_key_id
        ~signer_public_key ~envelope_key_commitment ~address_key_commitment
        ~key_handle ~mandatory_features
    in
    let signature =
      Mirage_crypto_ec.Ed25519.sign ~key:root.root_cap_private_key
        (device_certificate_signing_bytes certificate_id)
    in
    Ok
      {
        certificate_record_id = certificate_id;
        certificate_repository_id = authority.authority_repository_id;
        certificate_user_id = authority.authority_user_id;
        certificate_device_id = device_id;
        certificate_signer_key_id = signer_key_id;
        certificate_signer_public_key = signer_public_key;
        certificate_envelope_key_commitment = envelope_key_commitment;
        certificate_address_key_commitment = address_key_commitment;
        certificate_key_handle = key_handle;
        certificate_mandatory_features = mandatory_features;
        certificate_signature = signature;
      }

let device_certificate_id certificate = certificate.certificate_record_id

let device_certificate_repository_id certificate =
  certificate.certificate_repository_id

let device_certificate_user_id certificate = certificate.certificate_user_id
let device_certificate_device_id certificate = certificate.certificate_device_id

let device_certificate_signer_key_id certificate =
  certificate.certificate_signer_key_id

let device_certificate_signer_public_key certificate =
  certificate.certificate_signer_public_key

let device_certificate_envelope_key_commitment certificate =
  certificate.certificate_envelope_key_commitment

let device_certificate_address_key_commitment certificate =
  certificate.certificate_address_key_commitment

let device_certificate_key_handle certificate =
  certificate.certificate_key_handle

let device_certificate_mandatory_features certificate =
  certificate.certificate_mandatory_features

let device_certificate_value certificate =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes
        (Device_certificate_id.to_bytes certificate.certificate_record_id);
      Encoding.bytes
        (Repository_id.to_bytes certificate.certificate_repository_id);
      Encoding.bytes (User_id.to_bytes certificate.certificate_user_id);
      Encoding.bytes (Device_id.to_bytes certificate.certificate_device_id);
      Encoding.bytes
        (Signer_key_id.to_bytes certificate.certificate_signer_key_id);
      Encoding.bytes certificate.certificate_signer_public_key;
      Encoding.bytes certificate.certificate_envelope_key_commitment;
      Encoding.bytes certificate.certificate_address_key_commitment;
      Encoding.bytes certificate.certificate_key_handle;
      Encoding.integer certificate.certificate_mandatory_features;
      Encoding.text algorithm |> Result.get_ok;
      Encoding.bytes certificate.certificate_signature;
    ]

let encode_device_certificate certificate =
  device_certificate_value certificate |> Result.get_ok |> Encoding.encode

let device_id_of_value name value =
  let* value = bytes name value in
  Device_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let signer_key_id_of_value name value =
  let* value = bytes name value in
  Signer_key_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let certificate_id_of_value name value =
  let* value = bytes name value in
  Device_certificate_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let ensure_certificate_matches_authority ~authority certificate =
  if
    not
      (Repository_id.equal certificate.certificate_repository_id
         authority.authority_repository_id)
  then Error (Authority_mismatch "certificate repository ID")
  else if
    not
      (User_id.equal certificate.certificate_user_id authority.authority_user_id)
  then Error (Authority_mismatch "certificate user ID")
  else Ok ()

let decode_device_certificate_payload encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "device certificate" 13 value in
  match values with
  | [
   version;
   id;
   repository_id;
   user_id;
   device_id;
   signer_key_id;
   signer_public_key;
   envelope_key_commitment;
   address_key_commitment;
   key_handle;
   features;
   algorithm_value;
   signature;
  ] ->
      let* version = integer "device certificate schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = certificate_id_of_value "device certificate ID" id in
        let* repository_id =
          repository_id_of_value "device certificate repository ID"
            repository_id
        in
        let* user_id = user_id_of_value "device certificate user ID" user_id in
        let* device_id =
          device_id_of_value "device certificate device ID" device_id
        in
        let* signer_key_id =
          signer_key_id_of_value "device certificate signer key ID"
            signer_key_id
        in
        let* signer_public_key =
          bytes "device certificate signer public key" signer_public_key
        in
        let* actual_signer_key_id =
          check_device_signer_public_key signer_public_key
        in
        if not (Signer_key_id.equal signer_key_id actual_signer_key_id) then
          Error (Invalid_identity "device certificate signer key ID")
        else
          let* envelope_key_commitment =
            bytes "device certificate envelope key commitment"
              envelope_key_commitment
          in
          let* () = check_commitment "envelope" envelope_key_commitment in
          let* address_key_commitment =
            bytes "device certificate address key commitment"
              address_key_commitment
          in
          let* () = check_commitment "address" address_key_commitment in
          let* key_handle =
            bytes "device certificate local key handle" key_handle
          in
          let* () = check_key_handle key_handle in
          let* features =
            integer "device certificate mandatory features" features
          in
          let* () = check_mandatory_features features in
          let* algorithm_value =
            text "device certificate signature algorithm" algorithm_value
          in
          if not (String.equal algorithm_value algorithm) then
            Error (Unsupported_algorithm algorithm_value)
          else
            let* signature = bytes "device certificate signature" signature in
            let* () = check_signature_length signature in
            let* derived_id =
              derive_device_certificate_id ~repository_id ~user_id ~device_id
                ~signer_key_id ~signer_public_key ~envelope_key_commitment
                ~address_key_commitment ~key_handle ~mandatory_features:features
            in
            if not (Device_certificate_id.equal id derived_id) then
              Error (Invalid_identity "device certificate ID")
            else
              let certificate =
                {
                  certificate_record_id = id;
                  certificate_repository_id = repository_id;
                  certificate_user_id = user_id;
                  certificate_device_id = device_id;
                  certificate_signer_key_id = signer_key_id;
                  certificate_signer_public_key = signer_public_key;
                  certificate_envelope_key_commitment = envelope_key_commitment;
                  certificate_address_key_commitment = address_key_commitment;
                  certificate_key_handle = key_handle;
                  certificate_mandatory_features = features;
                  certificate_signature = signature;
                }
              in
              if String.equal encoded (encode_device_certificate certificate)
              then Ok certificate
              else Error Noncanonical_record
  | _ -> assert false

let verify_device_certificate ~authority certificate =
  let* () = ensure_certificate_matches_authority ~authority certificate in
  if
    String.equal certificate.certificate_signer_public_key
      authority.authority_root_public_key
  then Error Reused_root_as_device_signer
  else
    let* () =
      verify_signature ~public_key:authority.authority_root_public_key
        ~message:
          (device_certificate_signing_bytes certificate.certificate_record_id)
        ~signature:certificate.certificate_signature
    in
    Ok certificate

let validate_device_certificate_payload encoded =
  decode_device_certificate_payload encoded |> Result.map (fun _ -> ())

let decode_device_certificate ~authority encoded =
  let* certificate = decode_device_certificate_payload encoded in
  verify_device_certificate ~authority certificate

let device_revocation_unsigned_value ~repository_id ~user_id ~certificate_id
    ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Repository_id.to_bytes repository_id);
      Encoding.bytes (User_id.to_bytes user_id);
      Encoding.bytes (Device_certificate_id.to_bytes certificate_id);
      Encoding.integer mandatory_features;
    ]

let derive_device_revocation_id ~repository_id ~user_id ~certificate_id
    ~mandatory_features =
  let* unsigned =
    device_revocation_unsigned_value ~repository_id ~user_id ~certificate_id
      ~mandatory_features
  in
  match
    Device_revocation_id.of_bytes
      (digest device_revocation_id_domain (Encoding.encode unsigned))
  with
  | Ok identity -> Ok identity
  | Error _ -> assert false

let device_revocation_signing_bytes revocation_id =
  device_revocation_signature_domain
  ^ Device_revocation_id.to_bytes revocation_id

let make_device_revocation ~(authority : repository_authority)
    ~(root : root_signing_capability) ~certificate ~mandatory_features =
  let* () = ensure_root_matches_authority ~authority ~root in
  let* () = ensure_certificate_matches_authority ~authority certificate in
  let* () = check_mandatory_features mandatory_features in
  let* revocation_id =
    derive_device_revocation_id ~repository_id:authority.authority_repository_id
      ~user_id:authority.authority_user_id
      ~certificate_id:certificate.certificate_record_id ~mandatory_features
  in
  let signature =
    Mirage_crypto_ec.Ed25519.sign ~key:root.root_cap_private_key
      (device_revocation_signing_bytes revocation_id)
  in
  Ok
    {
      revocation_record_id = revocation_id;
      revocation_repository_id = authority.authority_repository_id;
      revocation_user_id = authority.authority_user_id;
      revocation_certificate_id = certificate.certificate_record_id;
      revocation_mandatory_features = mandatory_features;
      revocation_signature = signature;
    }

let device_revocation_id revocation = revocation.revocation_record_id

let device_revocation_repository_id revocation =
  revocation.revocation_repository_id

let device_revocation_user_id revocation = revocation.revocation_user_id

let device_revocation_certificate_id revocation =
  revocation.revocation_certificate_id

let device_revocation_mandatory_features revocation =
  revocation.revocation_mandatory_features

let device_revocation_value revocation =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes
        (Device_revocation_id.to_bytes revocation.revocation_record_id);
      Encoding.bytes
        (Repository_id.to_bytes revocation.revocation_repository_id);
      Encoding.bytes (User_id.to_bytes revocation.revocation_user_id);
      Encoding.bytes
        (Device_certificate_id.to_bytes revocation.revocation_certificate_id);
      Encoding.integer revocation.revocation_mandatory_features;
      Encoding.text algorithm |> Result.get_ok;
      Encoding.bytes revocation.revocation_signature;
    ]

let encode_device_revocation revocation =
  device_revocation_value revocation |> Result.get_ok |> Encoding.encode

let revocation_id_of_value name value =
  let* value = bytes name value in
  Device_revocation_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let ensure_revocation_matches_authority ~authority revocation =
  if
    not
      (Repository_id.equal revocation.revocation_repository_id
         authority.authority_repository_id)
  then Error (Authority_mismatch "revocation repository ID")
  else if
    not
      (User_id.equal revocation.revocation_user_id authority.authority_user_id)
  then Error (Authority_mismatch "revocation user ID")
  else Ok ()

let decode_device_revocation_payload encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "device revocation" 8 value in
  match values with
  | [
   version;
   id;
   repository_id;
   user_id;
   certificate_id;
   features;
   algorithm_value;
   signature;
  ] ->
      let* version = integer "device revocation schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = revocation_id_of_value "device revocation ID" id in
        let* repository_id =
          repository_id_of_value "device revocation repository ID" repository_id
        in
        let* user_id = user_id_of_value "device revocation user ID" user_id in
        let* certificate_id =
          certificate_id_of_value "device revocation certificate ID"
            certificate_id
        in
        let* features =
          integer "device revocation mandatory features" features
        in
        let* () = check_mandatory_features features in
        let* algorithm_value =
          text "device revocation signature algorithm" algorithm_value
        in
        if not (String.equal algorithm_value algorithm) then
          Error (Unsupported_algorithm algorithm_value)
        else
          let* signature = bytes "device revocation signature" signature in
          let* () = check_signature_length signature in
          let* derived_id =
            derive_device_revocation_id ~repository_id ~user_id ~certificate_id
              ~mandatory_features:features
          in
          if not (Device_revocation_id.equal id derived_id) then
            Error (Invalid_identity "device revocation ID")
          else
            let revocation =
              {
                revocation_record_id = id;
                revocation_repository_id = repository_id;
                revocation_user_id = user_id;
                revocation_certificate_id = certificate_id;
                revocation_mandatory_features = features;
                revocation_signature = signature;
              }
            in
            if String.equal encoded (encode_device_revocation revocation) then
              Ok revocation
            else Error Noncanonical_record
  | _ -> assert false

let verify_device_revocation ~authority revocation =
  let* () = ensure_revocation_matches_authority ~authority revocation in
  let* () =
    verify_signature ~public_key:authority.authority_root_public_key
      ~message:(device_revocation_signing_bytes revocation.revocation_record_id)
      ~signature:revocation.revocation_signature
  in
  Ok revocation

let validate_device_revocation_payload encoded =
  decode_device_revocation_payload encoded |> Result.map (fun _ -> ())

let decode_device_revocation ~authority encoded =
  let* revocation = decode_device_revocation_payload encoded in
  verify_device_revocation ~authority revocation

let compare_certificate left right =
  Device_certificate_id.compare left.certificate_record_id
    right.certificate_record_id

let compare_revocation left right =
  Device_revocation_id.compare left.revocation_record_id
    right.revocation_record_id

let reject_duplicate_certificates certificates =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if
          Device_certificate_id.equal left.certificate_record_id
            right.certificate_record_id
        then Error (Duplicate_device_certificate right.certificate_record_id)
        else loop rest
  in
  loop certificates

let reject_duplicate_devices certificates =
  let sorted =
    List.sort
      (fun left right ->
        Device_id.compare left.certificate_device_id right.certificate_device_id)
      certificates
  in
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if
          Device_id.equal left.certificate_device_id right.certificate_device_id
        then Error (Duplicate_device right.certificate_device_id)
        else loop rest
  in
  loop sorted

let reject_duplicate_revocations revocations =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if
          Device_revocation_id.equal left.revocation_record_id
            right.revocation_record_id
        then Error (Duplicate_device_revocation right.revocation_record_id)
        else loop rest
  in
  loop revocations

let evaluate ~authority ~certificates ~revocations =
  let certificates = List.sort compare_certificate certificates in
  let revocations = List.sort compare_revocation revocations in
  let* () = reject_duplicate_certificates certificates in
  let* () = reject_duplicate_devices certificates in
  let* () = reject_duplicate_revocations revocations in
  let* () =
    List.fold_left
      (fun result certificate ->
        let* () = result in
        ensure_certificate_matches_authority ~authority certificate)
      (Ok ()) certificates
  in
  let* () =
    List.fold_left
      (fun result revocation ->
        let* () = result in
        ensure_revocation_matches_authority ~authority revocation)
      (Ok ()) revocations
  in
  let certificate_exists certificate_id =
    List.exists
      (fun certificate ->
        Device_certificate_id.equal certificate.certificate_record_id
          certificate_id)
      certificates
  in
  let rec validate_revocation_targets previous_certificate = function
    | [] -> Ok ()
    | revocation :: rest ->
        if not (certificate_exists revocation.revocation_certificate_id) then
          Error
            (Unknown_revocation_certificate revocation.revocation_certificate_id)
        else if
          match previous_certificate with
          | Some previous ->
              Device_certificate_id.equal previous
                revocation.revocation_certificate_id
          | None -> false
        then Error (Multiple_revocations revocation.revocation_certificate_id)
        else
          validate_revocation_targets
            (Some revocation.revocation_certificate_id) rest
  in
  let revocations_by_certificate =
    List.sort
      (fun left right ->
        Device_certificate_id.compare left.revocation_certificate_id
          right.revocation_certificate_id)
      revocations
  in
  let* () = validate_revocation_targets None revocations_by_certificate in
  Ok { authority; certificates; revocations }

let authority_state_authority state = state.authority
let authority_state_certificates state = state.certificates
let authority_state_revocations state = state.revocations

let device_status state device_id =
  match
    List.find_opt
      (fun certificate ->
        Device_id.equal certificate.certificate_device_id device_id)
      state.certificates
  with
  | None -> None
  | Some certificate ->
      let revocation =
        List.find_opt
          (fun revocation ->
            Device_certificate_id.equal revocation.revocation_certificate_id
              certificate.certificate_record_id)
          state.revocations
      in
      Some
        (match revocation with
        | None -> Active
        | Some revocation -> Revoked revocation)
