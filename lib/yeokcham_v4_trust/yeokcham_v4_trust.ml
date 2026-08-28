module Model = Yeokcham_v4_model
module Record = Yeokcham_v4_record
module Encoding = Yeokcham_encoding

let ( let* ) = Result.bind
let algorithm = "ed25519"
let certificate_id_domain = "yeokcham:v4:certificate-id:1\000"
let certificate_signature_domain = "yeokcham:v4:certificate-signature:1\000"
let revision_signature_domain = "yeokcham:v4:revision-signature:1\000"

type role = Member | Administrator

module Repository_id = struct
  type t = string

  let is_lowercase_hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false

  let of_string value =
    if String.length value <> 64 then
      Error "repository ID must be 64 lowercase hexadecimal characters"
    else if String.for_all is_lowercase_hex value then Ok value
    else Error "repository ID must be lowercase hexadecimal"

  let to_string value = value
  let equal = String.equal
  let compare = String.compare

  let hex bytes =
    let result = Bytes.create (String.length bytes * 2) in
    String.iteri
      (fun index byte ->
        Bytes.set result (index * 2) "0123456789abcdef".[Char.code byte lsr 4];
        Bytes.set result
          ((index * 2) + 1)
          "0123456789abcdef".[Char.code byte land 15])
      bytes;
    Bytes.unsafe_to_string result

  let generate () =
    try
      Mirage_crypto_rng_unix.use_default ();
      Ok (hex (Mirage_crypto_rng.generate 32))
    with _ -> Error "OS CSPRNG unavailable"
end

type device = { device_id_value : Model.Device_id.t; public_key : string }
type signing_capability = Mirage_crypto_ec.Ed25519.priv

type generated_device = {
  generated_identity : device;
  generated_signing_capability : signing_capability;
}

type certificate = {
  certificate_id_value : string;
  certificate_repository_value : Repository_id.t;
  certificate_subject_device : device;
  certificate_role_value : role;
  certificate_issuer_id : string option;
  certificate_issuer_device : Model.Device_id.t;
  certificate_mandatory_features : int64;
  certificate_signature : string;
}

type membership = {
  membership_repository : Repository_id.t;
  membership_certificates : certificate list;
}

type signed_revision = {
  signed_repository : Repository_id.t;
  signed_certificate : string;
  signed_revision_value : Model.change_revision;
  signed_signature : string;
}

type error =
  | Invalid_public_key of int
  | Invalid_signature of int
  | Invalid_private_key
  | Entropy_failure
  | Unsupported_algorithm of string
  | Unsupported_features of int64
  | Invalid_record of string
  | Noncanonical_record
  | Identity_mismatch of string
  | Signature_verification_failed
  | Duplicate_certificate
  | Unknown_issuer_certificate
  | Unauthorized_issuer
  | Invalid_root_certificate
  | Cross_repository_certificate
  | Duplicate_device
  | Unknown_author_certificate
  | Revision_author_mismatch
  | Record_error of Record.error

let error_to_string = function
  | Invalid_public_key length ->
      Printf.sprintf "V4 Ed25519 public key must contain 32 bytes, got %d"
        length
  | Invalid_signature length ->
      Printf.sprintf "V4 Ed25519 signature must contain 64 bytes, got %d" length
  | Invalid_private_key -> "V4 signing capability does not match its device"
  | Entropy_failure -> "V4 OS CSPRNG is unavailable"
  | Unsupported_algorithm value ->
      "unsupported V4 signature algorithm: " ^ value
  | Unsupported_features features ->
      Printf.sprintf "unsupported V4 mandatory features: %Ld" features
  | Invalid_record detail -> "invalid V4 signed record: " ^ detail
  | Noncanonical_record -> "V4 signed record is not canonically encoded"
  | Identity_mismatch detail -> "V4 signed identity mismatch: " ^ detail
  | Signature_verification_failed -> "V4 Ed25519 signature is invalid"
  | Duplicate_certificate -> "duplicate V4 device certificate"
  | Unknown_issuer_certificate -> "V4 certificate issuer is unknown"
  | Unauthorized_issuer -> "V4 certificate issuer is not an administrator"
  | Invalid_root_certificate -> "V4 root certificate must be self-signed admin"
  | Cross_repository_certificate ->
      "V4 certificate belongs to another repository"
  | Duplicate_device -> "V4 device has more than one certificate"
  | Unknown_author_certificate -> "V4 revision author certificate is unknown"
  | Revision_author_mismatch ->
      "V4 revision author does not match its author certificate"
  | Record_error error -> Record.error_to_string error

let construction =
  Result.map_error (fun error ->
      Invalid_record (Encoding.construction_error_to_string error))

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_record (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be bytes"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be an integer"))

let digest domain bytes =
  Yeokcham_hash.Sha256.digest_string (domain ^ bytes)
  |> Yeokcham_hash.Sha256.to_raw_string

let device_id_of_public_key public_key =
  if String.length public_key <> 32 then
    Error (Invalid_public_key (String.length public_key))
  else
    Repository_id.hex (digest "yeokcham:v4:device-id:1\000" public_key)
    |> Model.Device_id.of_string
    |> Result.map_error (fun error ->
        Identity_mismatch (Model.error_to_string error))

let make_device public_key =
  let* id = device_id_of_public_key public_key in
  Ok { device_id_value = id; public_key }

let generate_device () =
  try
    Mirage_crypto_rng_unix.use_default ();
    let private_key, _ = Mirage_crypto_ec.Ed25519.generate () in
    let public_key =
      private_key |> Mirage_crypto_ec.Ed25519.pub_of_priv
      |> Mirage_crypto_ec.Ed25519.pub_to_octets
    in
    let* generated_identity = make_device public_key in
    Ok { generated_identity; generated_signing_capability = private_key }
  with _ -> Error Entropy_failure

let device_of_public_key = make_device

let signing_capability_of_private_key bytes =
  match Mirage_crypto_ec.Ed25519.priv_of_octets bytes with
  | Ok capability -> Ok capability
  | Error _ -> Error Invalid_private_key

let generated_identity generated = generated.generated_identity

let generated_signing_capability generated =
  generated.generated_signing_capability

let device_id device = device.device_id_value
let device_public_key device = device.public_key

let device_equal left right =
  Model.Device_id.equal left.device_id_value right.device_id_value
  && String.equal left.public_key right.public_key

let role_code = function Member -> 0L | Administrator -> 1L

let role_of_code = function
  | value when Int64.equal value 0L -> Ok Member
  | value when Int64.equal value 1L -> Ok Administrator
  | _ -> Error (Invalid_record "unknown V4 certificate role")

let encode_repository repository = text (Repository_id.to_string repository)
let encode_device_id device = text (Model.Device_id.to_string device)

let encode_device device =
  let* id = encode_device_id device.device_id_value in
  array [ id; Encoding.bytes device.public_key ]

let decode_repository value =
  let* value = text_field "repository ID" value in
  Repository_id.of_string value
  |> Result.map_error (fun detail -> Invalid_record detail)

let decode_device_id value =
  let* value = text_field "device ID" value in
  Model.Device_id.of_string value
  |> Result.map_error (fun error ->
      Invalid_record (Model.error_to_string error))

let decode_device value =
  let* values = exact_array "device identity" 2 value in
  match values with
  | [ id; public_key ] ->
      let* id = decode_device_id id in
      let* public_key = bytes_field "device public key" public_key in
      let* device = make_device public_key in
      if Model.Device_id.equal id device.device_id_value then Ok device
      else Error (Identity_mismatch "device ID is not derived from public key")
  | _ -> assert false

let encode_issuer = function None -> Ok Encoding.null | Some id -> text id

let decode_issuer = function
  | Encoding.Null -> Ok None
  | Encoding.Text value when String.length value = 64 -> Ok (Some value)
  | Encoding.Text _ ->
      Error (Invalid_record "issuer certificate ID has wrong length")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_record "issuer certificate ID must be null or text")

let certificate_unsigned_value ~repository ~subject ~role ~issuer_certificate
    ~issuer_device ~mandatory_features =
  let* repository = encode_repository repository in
  let* subject = encode_device subject in
  let* issuer_certificate = encode_issuer issuer_certificate in
  let* issuer_device = encode_device_id issuer_device in
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer 1L;
      repository;
      subject;
      Encoding.integer (role_code role);
      issuer_certificate;
      issuer_device;
      Encoding.integer mandatory_features;
      algorithm;
    ]

let certificate_unsigned_bytes ~repository ~subject ~role ~issuer_certificate
    ~issuer_device ~mandatory_features =
  certificate_unsigned_value ~repository ~subject ~role ~issuer_certificate
    ~issuer_device ~mandatory_features
  |> Result.map Encoding.encode

let certificate_id_for ~repository ~subject ~role ~issuer_certificate
    ~issuer_device ~mandatory_features =
  let* unsigned =
    certificate_unsigned_bytes ~repository ~subject ~role ~issuer_certificate
      ~issuer_device ~mandatory_features
  in
  Ok (Repository_id.hex (digest certificate_id_domain unsigned))

let signing_public_key signing_capability =
  signing_capability |> Mirage_crypto_ec.Ed25519.pub_of_priv
  |> Mirage_crypto_ec.Ed25519.pub_to_octets

let signing_private_key_bytes = Mirage_crypto_ec.Ed25519.priv_to_octets

let sign_certificate ~repository ~subject ~role ~issuer_certificate
    ~issuer_device signing_capability =
  let* id =
    certificate_id_for ~repository ~subject ~role ~issuer_certificate
      ~issuer_device ~mandatory_features:0L
  in
  let issuer_public_key = signing_public_key signing_capability in
  let* issuer = make_device issuer_public_key in
  if not (Model.Device_id.equal issuer.device_id_value issuer_device) then
    Error Invalid_private_key
  else
    let signature =
      Mirage_crypto_ec.Ed25519.sign ~key:signing_capability
        (certificate_signature_domain ^ id)
    in
    Ok
      {
        certificate_id_value = id;
        certificate_repository_value = repository;
        certificate_subject_device = subject;
        certificate_role_value = role;
        certificate_issuer_id = issuer_certificate;
        certificate_issuer_device = issuer_device;
        certificate_mandatory_features = 0L;
        certificate_signature = signature;
      }

let root_certificate ~repository ~device signing_capability =
  sign_certificate ~repository ~subject:device ~role:Administrator
    ~issuer_certificate:None ~issuer_device:device.device_id_value
    signing_capability

let certificate_id certificate = certificate.certificate_id_value

let certificate_repository certificate =
  certificate.certificate_repository_value

let certificate_subject certificate = certificate.certificate_subject_device
let certificate_role certificate = certificate.certificate_role_value
let certificate_issuer certificate = certificate.certificate_issuer_id

let validate_certificate certificate =
  if not (Int64.equal certificate.certificate_mandatory_features 0L) then
    Error (Unsupported_features certificate.certificate_mandatory_features)
  else if String.length certificate.certificate_signature <> 64 then
    Error (Invalid_signature (String.length certificate.certificate_signature))
  else
    let* expected =
      certificate_id_for ~repository:certificate.certificate_repository_value
        ~subject:certificate.certificate_subject_device
        ~role:certificate.certificate_role_value
        ~issuer_certificate:certificate.certificate_issuer_id
        ~issuer_device:certificate.certificate_issuer_device
        ~mandatory_features:certificate.certificate_mandatory_features
    in
    if not (String.equal expected certificate.certificate_id_value) then
      Error (Identity_mismatch "certificate ID")
    else Ok ()

let verify_certificate_crypto ~issuer_public_key certificate =
  let* () = validate_certificate certificate in
  match Mirage_crypto_ec.Ed25519.pub_of_octets issuer_public_key with
  | Error _ -> Error (Invalid_public_key (String.length issuer_public_key))
  | Ok public_key ->
      if
        Mirage_crypto_ec.Ed25519.verify ~key:public_key
          certificate.certificate_signature
          ~msg:(certificate_signature_domain ^ certificate.certificate_id_value)
      then Ok ()
      else Error Signature_verification_failed

let encode_certificate certificate =
  let unsigned =
    certificate_unsigned_value
      ~repository:certificate.certificate_repository_value
      ~subject:certificate.certificate_subject_device
      ~role:certificate.certificate_role_value
      ~issuer_certificate:certificate.certificate_issuer_id
      ~issuer_device:certificate.certificate_issuer_device
      ~mandatory_features:certificate.certificate_mandatory_features
    |> Result.get_ok
  in
  Encoding.array [ unsigned; Encoding.bytes certificate.certificate_signature ]
  |> Result.get_ok |> Encoding.encode

let decode_certificate encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_record (Encoding.decode_error_to_string error))
  in
  let* values = exact_array "V4 certificate" 2 value in
  match values with
  | [ unsigned; signature ] -> (
      let* fields = exact_array "V4 certificate unsigned body" 8 unsigned in
      let* signature = bytes_field "certificate signature" signature in
      match fields with
      | [
       version;
       repository;
       subject;
       role;
       issuer;
       issuer_device;
       features;
       algorithm_value;
      ] ->
          let* version = integer_field "certificate version" version in
          let* repository = decode_repository repository in
          let* subject = decode_device subject in
          let* role = integer_field "certificate role" role in
          let* role = role_of_code role in
          let* issuer_certificate = decode_issuer issuer in
          let* issuer_device = decode_device_id issuer_device in
          let* mandatory_features =
            integer_field "certificate features" features
          in
          let* algorithm_value =
            text_field "certificate algorithm" algorithm_value
          in
          if not (Int64.equal version 1L) then
            Error (Invalid_record "unsupported certificate version")
          else if not (String.equal algorithm_value algorithm) then
            Error (Unsupported_algorithm algorithm_value)
          else
            let* id =
              certificate_id_for ~repository ~subject ~role ~issuer_certificate
                ~issuer_device ~mandatory_features
            in
            let certificate =
              {
                certificate_id_value = id;
                certificate_repository_value = repository;
                certificate_subject_device = subject;
                certificate_role_value = role;
                certificate_issuer_id = issuer_certificate;
                certificate_issuer_device = issuer_device;
                certificate_mandatory_features = mandatory_features;
                certificate_signature = signature;
              }
            in
            if String.equal encoded (encode_certificate certificate) then
              validate_certificate certificate
              |> Result.map (fun () -> certificate)
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let certificate_by_id certificates id =
  List.find_opt
    (fun certificate -> String.equal certificate.certificate_id_value id)
    certificates

let verify_membership ~repository certificates =
  let rec verify verified pending roots deferred =
    match pending with
    | [] ->
        if List.length roots = 1 then
          Ok
            {
              membership_repository = repository;
              membership_certificates = verified;
            }
        else Error Invalid_root_certificate
    | certificate :: rest -> (
        if
          not
            (Repository_id.equal certificate.certificate_repository_value
               repository)
        then Error Cross_repository_certificate
        else if
          List.exists
            (fun seen ->
              String.equal seen.certificate_id_value
                certificate.certificate_id_value)
            verified
        then Error Duplicate_certificate
        else if
          List.exists
            (fun seen ->
              Model.Device_id.equal
                seen.certificate_subject_device.device_id_value
                certificate.certificate_subject_device.device_id_value)
            verified
        then Error Duplicate_device
        else
          match certificate.certificate_issuer_id with
          | None ->
              if
                certificate.certificate_role_value <> Administrator
                || not
                     (Model.Device_id.equal
                        certificate.certificate_issuer_device
                        certificate.certificate_subject_device.device_id_value)
              then Error Invalid_root_certificate
              else
                let* () =
                  verify_certificate_crypto
                    ~issuer_public_key:
                      certificate.certificate_subject_device.public_key
                    certificate
                in
                verify (certificate :: verified) rest (certificate :: roots) 0
          | Some issuer_id -> (
              match certificate_by_id verified issuer_id with
              | None ->
                  if
                    List.exists
                      (fun candidate ->
                        String.equal candidate.certificate_id_value issuer_id)
                      rest
                  then
                    if deferred + 1 >= List.length pending then
                      Error Unknown_issuer_certificate
                    else
                      verify verified (rest @ [ certificate ]) roots
                        (deferred + 1)
                  else Error Unknown_issuer_certificate
              | Some issuer ->
                  if
                    issuer.certificate_role_value <> Administrator
                    || not
                         (Model.Device_id.equal
                            certificate.certificate_issuer_device
                            issuer.certificate_subject_device.device_id_value)
                  then Error Unauthorized_issuer
                  else
                    let* () =
                      verify_certificate_crypto
                        ~issuer_public_key:
                          issuer.certificate_subject_device.public_key
                        certificate
                    in
                    verify (certificate :: verified) rest roots 0))
  in
  verify [] certificates [] 0

let extend_membership membership additional =
  let* _ =
    verify_membership ~repository:membership.membership_repository
      membership.membership_certificates
  in
  let rec add seen = function
    | [] -> Ok seen
    | certificate :: rest -> (
        match
          List.find_opt
            (fun existing ->
              String.equal existing.certificate_id_value
                certificate.certificate_id_value)
            seen
        with
        | None -> add (certificate :: seen) rest
        | Some existing ->
            if existing = certificate then add seen rest
            else Error Duplicate_certificate)
  in
  let* certificates = add membership.membership_certificates additional in
  verify_membership ~repository:membership.membership_repository certificates

let certificates membership =
  List.sort
    (fun left right ->
      String.compare left.certificate_id_value right.certificate_id_value)
    membership.membership_certificates

let repository membership = membership.membership_repository

let certificate_for_device membership device =
  List.find_opt
    (fun certificate ->
      device_equal certificate.certificate_subject_device device)
    membership.membership_certificates

let is_authorized membership device =
  Option.is_some (certificate_for_device membership device)

let is_administrator membership device =
  match certificate_for_device membership device with
  | Some { certificate_role_value = Administrator; _ } -> true
  | Some { certificate_role_value = Member; _ } | None -> false

let enroll membership ~issuer signing_capability ~subject ~role =
  match certificate_by_id membership.membership_certificates issuer with
  | None -> Error Unknown_issuer_certificate
  | Some issuer_certificate ->
      if issuer_certificate.certificate_role_value <> Administrator then
        Error Unauthorized_issuer
      else if Option.is_some (certificate_for_device membership subject) then
        Error Duplicate_device
      else
        sign_certificate ~repository:membership.membership_repository ~subject
          ~role
          ~issuer_certificate:(Some issuer_certificate.certificate_id_value)
          ~issuer_device:
            issuer_certificate.certificate_subject_device.device_id_value
          signing_capability

let revision_unsigned_bytes ~repository ~certificate revision =
  let* repository = encode_repository repository in
  let* certificate = text certificate in
  let* revision =
    Record.encode_change_revision revision
    |> Result.map_error (fun error -> Record_error error)
  in
  array
    [ Encoding.integer 1L; repository; certificate; Encoding.bytes revision ]
  |> Result.map Encoding.encode

let sign_revision membership ~certificate signing_capability revision =
  match certificate_by_id membership.membership_certificates certificate with
  | None -> Error Unknown_author_certificate
  | Some author_certificate ->
      if
        not
          (Model.Device_id.equal
             author_certificate.certificate_subject_device.device_id_value
             revision.Model.revision_author)
      then Error Revision_author_mismatch
      else
        let public_key = signing_public_key signing_capability in
        if
          not
            (String.equal public_key
               author_certificate.certificate_subject_device.public_key)
        then Error Invalid_private_key
        else
          let* bytes =
            revision_unsigned_bytes ~repository:membership.membership_repository
              ~certificate revision
          in
          let signature =
            Mirage_crypto_ec.Ed25519.sign ~key:signing_capability
              (revision_signature_domain ^ bytes)
          in
          Ok
            {
              signed_repository = membership.membership_repository;
              signed_certificate = certificate;
              signed_revision_value = revision;
              signed_signature = signature;
            }

let signed_revision_id signed = signed.signed_revision_value.Model.revision
let signed_revision_certificate signed = signed.signed_certificate
let signed_revision_value signed = signed.signed_revision_value

let encode_signed_revision signed =
  let unsigned =
    revision_unsigned_bytes ~repository:signed.signed_repository
      ~certificate:signed.signed_certificate signed.signed_revision_value
    |> Result.get_ok
  in
  Encoding.array
    [ Encoding.bytes unsigned; Encoding.bytes signed.signed_signature ]
  |> Result.get_ok |> Encoding.encode

let decode_signed_revision encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_record (Encoding.decode_error_to_string error))
  in
  let* values = exact_array "V4 signed revision" 2 value in
  match values with
  | [ unsigned; signature ] -> (
      let* unsigned = bytes_field "revision unsigned body" unsigned in
      let* signature = bytes_field "revision signature" signature in
      let* unsigned_value =
        Encoding.decode unsigned
        |> Result.map_error (fun error ->
            Invalid_record (Encoding.decode_error_to_string error))
      in
      let* fields = exact_array "V4 revision unsigned body" 4 unsigned_value in
      match fields with
      | [ version; repository; certificate; revision ] ->
          let* version = integer_field "revision version" version in
          let* repository = decode_repository repository in
          let* certificate = text_field "revision certificate ID" certificate in
          let* revision = bytes_field "revision body" revision in
          let* revision =
            Record.decode_change_revision revision
            |> Result.map_error (fun error -> Record_error error)
          in
          if not (Int64.equal version 1L) then
            Error (Invalid_record "unsupported signed revision version")
          else
            let signed =
              {
                signed_repository = repository;
                signed_certificate = certificate;
                signed_revision_value = revision;
                signed_signature = signature;
              }
            in
            if String.equal encoded (encode_signed_revision signed) then
              Ok signed
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let verify_signed_revision membership signed =
  if
    not
      (Repository_id.equal membership.membership_repository
         signed.signed_repository)
  then Error Cross_repository_certificate
  else if String.length signed.signed_signature <> 64 then
    Error (Invalid_signature (String.length signed.signed_signature))
  else
    match
      certificate_by_id membership.membership_certificates
        signed.signed_certificate
    with
    | None -> Error Unknown_author_certificate
    | Some certificate -> (
        if
          not
            (Model.Device_id.equal
               certificate.certificate_subject_device.device_id_value
               signed.signed_revision_value.Model.revision_author)
        then Error Revision_author_mismatch
        else
          let* bytes =
            revision_unsigned_bytes ~repository:signed.signed_repository
              ~certificate:signed.signed_certificate
              signed.signed_revision_value
          in
          match
            Mirage_crypto_ec.Ed25519.pub_of_octets
              certificate.certificate_subject_device.public_key
          with
          | Error _ ->
              Error
                (Invalid_public_key
                   (String.length
                      certificate.certificate_subject_device.public_key))
          | Ok public_key ->
              if
                Mirage_crypto_ec.Ed25519.verify ~key:public_key
                  signed.signed_signature
                  ~msg:(revision_signature_domain ^ bytes)
              then Ok ()
              else Error Signature_verification_failed)
