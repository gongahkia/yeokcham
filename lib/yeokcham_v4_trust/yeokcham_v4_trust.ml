module Model = Yeokcham_v4_model
module Record = Yeokcham_v4_record
module Encoding = Yeokcham_encoding

let ( let* ) = Result.bind
let algorithm = "ed25519"
let certificate_id_domain = "yeokcham:v4:certificate-id:1\000"
let certificate_signature_domain = "yeokcham:v4:certificate-signature:1\000"
let revision_signature_domain = "yeokcham:v4:revision-signature:1\000"
let authority_epoch_id_domain = "yeokcham:v4:authority-epoch-id:1\000"

let authority_epoch_signature_domain =
  "yeokcham:v4:authority-epoch-signature:1\000"

let authorization_signature_domain = "yeokcham:v4:authorization:1\000"
let adoption_signature_domain = "yeokcham:v4:adoption:1\000"
let recovery_issuer_prefix = "recovery:"

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

(* A capability is an opaque local signing operation.  In particular, an
   external token or agent never needs to reveal private material to the V4
   process. *)
type signing_capability = {
  signing_public_key_value : string;
  signing_private_key_value : string option;
  signing_operation : domain:string -> string -> (string, string) result;
}

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
  signed_epoch_value : string option;
  signed_resolution_decision_value : Model.Decision_id.t option;
  signed_revision_value : Model.change_revision;
  signed_signature : string;
}

type epoch = {
  epoch_id_value : string;
  epoch_repository_value : Repository_id.t;
  epoch_parents_value : string list;
  epoch_certificate_ids : string list;
  epoch_revoked_value : Model.Device_id.t list;
  epoch_frontier_value : Model.Revision_id.t list;
  epoch_recovery_device_value : device;
  epoch_issuer_value : string;
  epoch_signature : string;
}

type authority = {
  authority_membership_value : membership;
  authority_epochs_value : epoch list;
  authority_heads_value : string list;
}

type authorization = {
  authorization_repository : Repository_id.t;
  authorization_epoch : string;
  authorization_issuer : string;
  authorization_device : device;
  authorization_revision_value : Model.Revision_id.t;
  authorization_change : Model.Change_id.t;
  authorization_signature : string;
}

type adoption = {
  adoption_repository : Repository_id.t;
  adoption_epoch : string;
  adoption_issuer : string;
  adoption_revision_value : Model.Revision_id.t;
  adoption_signed_digest : string;
  adoption_signature : string;
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
  | Unknown_epoch
  | Invalid_epoch of string
  | Duplicate_epoch
  | Authority_fork
  | Revoked_device
  | Unauthorized_epoch_issuer
  | Invalid_recovery_authority
  | Unknown_authorization
  | Authorization_mismatch
  | Duplicate_authorization
  | Signing_failed of string
  | Private_key_unavailable
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
  | Unknown_epoch -> "V4 authority epoch is unknown"
  | Invalid_epoch detail -> "invalid V4 authority epoch: " ^ detail
  | Duplicate_epoch -> "duplicate V4 authority epoch"
  | Authority_fork ->
      "V4 authority fork requires an explicit authority selection or \
       reconciliation"
  | Revoked_device -> "V4 device is revoked in this authority epoch"
  | Unauthorized_epoch_issuer ->
      "V4 authority epoch issuer is not an active administrator in every parent"
  | Invalid_recovery_authority -> "invalid V4 recovery authority"
  | Unknown_authorization -> "V4 one-time authorization is unknown"
  | Authorization_mismatch -> "V4 authorization does not match this revision"
  | Duplicate_authorization -> "V4 authorization was already consumed"
  | Signing_failed detail -> "V4 signer failed: " ^ detail
  | Private_key_unavailable ->
      "V4 signer is non-exportable and cannot provide private key bytes"
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

let device_of_public_key = make_device

let signing_capability_of_private_key bytes =
  match Mirage_crypto_ec.Ed25519.priv_of_octets bytes with
  | Error _ -> Error Invalid_private_key
  | Ok private_key ->
      let public_key =
        private_key |> Mirage_crypto_ec.Ed25519.pub_of_priv
        |> Mirage_crypto_ec.Ed25519.pub_to_octets
      in
      Ok
        {
          signing_public_key_value = public_key;
          signing_private_key_value = Some bytes;
          signing_operation =
            (fun ~domain bytes ->
              Ok
                (Mirage_crypto_ec.Ed25519.sign ~key:private_key
                   (domain ^ bytes)));
        }

let signing_capability_of_external_signer ~public_key ~sign =
  let* _ = make_device public_key in
  Ok
    {
      signing_public_key_value = public_key;
      signing_private_key_value = None;
      signing_operation = sign;
    }

let generate_device () =
  try
    Mirage_crypto_rng_unix.use_default ();
    let private_key, _ = Mirage_crypto_ec.Ed25519.generate () in
    let bytes = Mirage_crypto_ec.Ed25519.priv_to_octets private_key in
    let* generated_signing_capability = signing_capability_of_private_key bytes in
    let* generated_identity =
      make_device generated_signing_capability.signing_public_key_value
    in
    Ok { generated_identity; generated_signing_capability }
  with _ -> Error Entropy_failure

let generated_identity generated = generated.generated_identity

let generated_signing_capability generated =
  generated.generated_signing_capability

let device_id device = device.device_id_value
let device_public_key device = device.public_key

let recovery_issuer device =
  recovery_issuer_prefix ^ Model.Device_id.to_string (device_id device)

let recovery_issuer_device issuer =
  let prefix_length = String.length recovery_issuer_prefix in
  if
    String.length issuer > prefix_length
    && String.sub issuer 0 prefix_length = recovery_issuer_prefix
  then
    String.sub issuer prefix_length (String.length issuer - prefix_length)
    |> Model.Device_id.of_string
    |> Result.map_error (fun _ -> Invalid_recovery_authority)
    |> Result.map Option.some
  else Ok None

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
  | Encoding.Text value -> (
      let* recovery = recovery_issuer_device value in
      match recovery with
      | Some _ -> Ok (Some value)
      | None when String.length value = 64 -> Ok (Some value)
      | None -> Error (Invalid_record "issuer certificate ID has wrong length"))
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
  signing_capability.signing_public_key_value

let signing_private_key_bytes signing_capability =
  match signing_capability.signing_private_key_value with
  | Some bytes -> Ok bytes
  | None -> Error Private_key_unavailable

let sign_detached signing_capability ~domain bytes =
  signing_capability.signing_operation ~domain bytes
  |> Result.map_error (fun detail -> Signing_failed detail)

let verify_detached ~device ~domain ~signature bytes =
  if String.length signature <> 64 then
    Error (Invalid_signature (String.length signature))
  else
    match Mirage_crypto_ec.Ed25519.pub_of_octets (device_public_key device) with
    | Error _ ->
        Error (Invalid_public_key (String.length (device_public_key device)))
    | Ok public_key ->
        if
          Mirage_crypto_ec.Ed25519.verify ~key:public_key signature
            ~msg:(domain ^ bytes)
        then Ok ()
        else Error Signature_verification_failed

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
    let* signature =
      sign_detached signing_capability ~domain:certificate_signature_domain id
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
              let* recovery_issuer = recovery_issuer_device issuer_id in
              match recovery_issuer with
              | Some recovery_issuer ->
                  if
                    not
                      (Model.Device_id.equal recovery_issuer
                         certificate.certificate_issuer_device)
                  then Error Invalid_recovery_authority
                  else
                    (* This record becomes authorized only when an authority
                       epoch proves this recovery key was current. Membership
                       verification can check its derived identity now, but
                       intentionally cannot treat it as ordinary authority. *)
                    let* () = validate_certificate certificate in
                    verify (certificate :: verified) rest roots 0
              | None -> (
                  match certificate_by_id verified issuer_id with
                  | None ->
                      if
                        List.exists
                          (fun candidate ->
                            String.equal candidate.certificate_id_value
                              issuer_id)
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
                                issuer.certificate_subject_device
                                  .device_id_value)
                      then Error Unauthorized_issuer
                      else
                        let* () =
                          verify_certificate_crypto
                            ~issuer_public_key:
                              issuer.certificate_subject_device.public_key
                            certificate
                        in
                        verify (certificate :: verified) rest roots 0)))
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

let certificate_is_recovery_issued certificate =
  match certificate.certificate_issuer_id with
  | None -> false
  | Some issuer ->
      String.length issuer >= String.length recovery_issuer_prefix
      && String.sub issuer 0 (String.length recovery_issuer_prefix)
         = recovery_issuer_prefix

let is_authorized membership device =
  match certificate_for_device membership device with
  | Some certificate -> not (certificate_is_recovery_issued certificate)
  | None -> false

let is_administrator membership device =
  match certificate_for_device membership device with
  | Some certificate ->
      certificate.certificate_role_value = Administrator
      && not (certificate_is_recovery_issued certificate)
  | None -> false

let enroll membership ~issuer signing_capability ~subject ~role =
  match certificate_by_id membership.membership_certificates issuer with
  | None -> Error Unknown_issuer_certificate
  | Some issuer_certificate ->
      if
        issuer_certificate.certificate_role_value <> Administrator
        || certificate_is_recovery_issued issuer_certificate
      then Error Unauthorized_issuer
      else if Option.is_some (certificate_for_device membership subject) then
        Error Duplicate_device
      else
        sign_certificate ~repository:membership.membership_repository ~subject
          ~role
          ~issuer_certificate:(Some issuer_certificate.certificate_id_value)
          ~issuer_device:
            issuer_certificate.certificate_subject_device.device_id_value
          signing_capability

let revision_unsigned_bytes ~repository ~certificate ~epoch ~resolution revision
    =
  let* repository = encode_repository repository in
  let* certificate = text certificate in
  let* epoch = text epoch in
  let* revision =
    Record.encode_change_revision revision
    |> Result.map_error (fun error -> Record_error error)
  in
  let* decision =
    match resolution with
    | None -> Ok Encoding.null
    | Some decision -> Model.Decision_id.to_string decision |> text
  in
  array
    [
      Encoding.integer 1L;
      repository;
      certificate;
      epoch;
      decision;
      Encoding.bytes revision;
    ]
  |> Result.map Encoding.encode

let sign_revision _ ~certificate:_ _ _ =
  Error (Invalid_epoch "V4 signed revisions require an authority epoch")

let sign_resolution _ ~certificate:_ _ ~decision:_ _ =
  Error (Invalid_epoch "V4 signed resolutions require an authority epoch")

let signed_revision_id signed = signed.signed_revision_value.Model.revision
let signed_revision_certificate signed = signed.signed_certificate
let signed_revision_value signed = signed.signed_revision_value
let signed_revision_epoch signed = signed.signed_epoch_value
let signed_revision_resolution signed = signed.signed_resolution_decision_value

let encode_signed_revision signed =
  let epoch =
    match signed.signed_epoch_value with
    | Some epoch -> epoch
    | None -> invalid_arg "V4 signed revisions require an authority epoch"
  in
  let unsigned =
    revision_unsigned_bytes ~repository:signed.signed_repository
      ~certificate:signed.signed_certificate ~epoch
      ~resolution:signed.signed_resolution_decision_value
      signed.signed_revision_value
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
      let* fields =
        match unsigned_value with
        | Encoding.Array ([ _; _; _; _ ] as fields) -> Ok fields
        | Encoding.Array ([ _; _; _; _; _ ] as fields) -> Ok fields
        | Encoding.Array ([ _; _; _; _; _; _ ] as fields) -> Ok fields
        | Encoding.Array _ ->
            Error
              (Invalid_record
                 "V4 revision unsigned body has the wrong field count")
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
            Error (Invalid_record "V4 revision unsigned body must be an array")
      in
      match fields with
      | [ version; repository; certificate; revision ] ->
          let _ = (version, repository, certificate, revision, signature) in
          Error
            (Invalid_record
               "authority-less signed revision encoding was retired before V4 \
                release")
      | [ version; repository; certificate; epoch; revision ] ->
          let _ =
            (version, repository, certificate, epoch, revision, signature)
          in
          Error
            (Invalid_record
               "pre-release signed revision encoding was retired before V4 \
                release")
      | [ version; repository; certificate; epoch; decision; revision ] ->
          let* version = integer_field "revision version" version in
          let* repository = decode_repository repository in
          let* certificate = text_field "revision certificate ID" certificate in
          let* epoch =
            match epoch with
            | Encoding.Text epoch -> Ok epoch
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                Error (Invalid_record "revision authority epoch must be text")
          in
          let* decision =
            match decision with
            | Encoding.Null -> Ok None
            | Encoding.Text decision ->
                Model.Decision_id.of_string decision
                |> Result.map_error (fun error ->
                    Invalid_record (Model.error_to_string error))
                |> Result.map Option.some
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _
            | Encoding.Map _ | Encoding.Bool _ ->
                Error
                  (Invalid_record "resolution decision must be text or null")
          in
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
                signed_epoch_value = Some epoch;
                signed_resolution_decision_value = decision;
                signed_revision_value = revision;
                signed_signature = signature;
              }
            in
            if String.equal encoded (encode_signed_revision signed) then
              Ok signed
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let verify_signed_revision_crypto membership signed =
  if
    not
      (Repository_id.equal membership.membership_repository
         signed.signed_repository)
  then Error Cross_repository_certificate
  else if String.length signed.signed_signature <> 64 then
    Error (Invalid_signature (String.length signed.signed_signature))
  else
    let* epoch =
      match signed.signed_epoch_value with
      | Some epoch -> Ok epoch
      | None ->
          Error (Invalid_epoch "V4 signed revision has no authority epoch")
    in
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
              ~certificate:signed.signed_certificate ~epoch
              ~resolution:signed.signed_resolution_decision_value
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

let verify_signed_revision membership signed =
  let _ = membership in
  let _ = signed in
  Error (Invalid_epoch "V4 signed revisions require authority verification")

(* Authority epochs ------------------------------------------------------- *)

let map_result f values =
  let rec go reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* mapped = f value in
        go (mapped :: reversed) rest
  in
  go [] values

let compare_device_id left right = Model.Device_id.compare left right
let compare_revision_id left right = Model.Revision_id.compare left right

let sorted_unique compare values =
  let rec go previous = function
    | [] -> true
    | value :: rest -> (
        match previous with
        | None -> go (Some value) rest
        | Some previous -> compare previous value < 0 && go (Some value) rest)
  in
  go None values

let decode_text_array name value =
  match value with
  | Encoding.Array values -> map_result (text_field name) values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be an array"))

let encode_text_array values =
  let* values = map_result text values in
  array values

let decode_device_id_array name value =
  match value with
  | Encoding.Array values -> map_result decode_device_id values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be an array"))

let encode_device_id_array values =
  let* values = map_result encode_device_id values in
  array values

let decode_revision_id value =
  let* value = text_field "revision ID" value in
  Model.Revision_id.of_string value
  |> Result.map_error (fun error ->
      Invalid_record (Model.error_to_string error))

let encode_revision_id value = text (Model.Revision_id.to_string value)

let decode_revision_id_array name value =
  match value with
  | Encoding.Array values -> map_result decode_revision_id values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_record (name ^ " must be an array"))

let encode_revision_id_array values =
  let* values = map_result encode_revision_id values in
  array values

let validate_hex_id name value =
  Repository_id.of_string value
  |> Result.map_error (fun _ -> Invalid_epoch (name ^ " must be lowercase hex"))

let validate_epoch_issuer issuer =
  let* recovery_device = recovery_issuer_device issuer in
  match recovery_device with
  | Some _ -> Ok ()
  | None ->
      let* _ = validate_hex_id "authority issuer" issuer in
      Ok ()

let epoch_unsigned_value ~repository ~parents ~certificate_ids ~revoked
    ~frontier ~recovery_device ~issuer =
  let* repository = encode_repository repository in
  let* parents = encode_text_array parents in
  let* certificate_ids = encode_text_array certificate_ids in
  let* revoked = encode_device_id_array revoked in
  let* frontier = encode_revision_id_array frontier in
  let* recovery_device = encode_device recovery_device in
  let* issuer = text issuer in
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer 1L;
      repository;
      parents;
      certificate_ids;
      revoked;
      frontier;
      recovery_device;
      issuer;
      algorithm;
    ]

let epoch_unsigned_bytes ~repository ~parents ~certificate_ids ~revoked
    ~frontier ~recovery_device ~issuer =
  epoch_unsigned_value ~repository ~parents ~certificate_ids ~revoked ~frontier
    ~recovery_device ~issuer
  |> Result.map Encoding.encode

let epoch_id_for ~repository ~parents ~certificate_ids ~revoked ~frontier
    ~recovery_device ~issuer =
  let* unsigned =
    epoch_unsigned_bytes ~repository ~parents ~certificate_ids ~revoked
      ~frontier ~recovery_device ~issuer
  in
  Ok (Repository_id.hex (digest authority_epoch_id_domain unsigned))

let make_epoch ~repository ~parents ~certificate_ids ~revoked ~frontier
    ~recovery_device ~issuer signing_capability =
  let* id =
    epoch_id_for ~repository ~parents ~certificate_ids ~revoked ~frontier
      ~recovery_device ~issuer
  in
  let* signature =
    sign_detached signing_capability ~domain:authority_epoch_signature_domain id
  in
  Ok
    {
      epoch_id_value = id;
      epoch_repository_value = repository;
      epoch_parents_value = parents;
      epoch_certificate_ids = certificate_ids;
      epoch_revoked_value = revoked;
      epoch_frontier_value = frontier;
      epoch_recovery_device_value = recovery_device;
      epoch_issuer_value = issuer;
      epoch_signature = signature;
    }

let epoch_id epoch = epoch.epoch_id_value
let epoch_parents epoch = epoch.epoch_parents_value
let epoch_revoked epoch = epoch.epoch_revoked_value
let epoch_frontier epoch = epoch.epoch_frontier_value
let epoch_recovery_device epoch = epoch.epoch_recovery_device_value

let validate_epoch_shape epoch =
  let* expected =
    epoch_id_for ~repository:epoch.epoch_repository_value
      ~parents:epoch.epoch_parents_value
      ~certificate_ids:epoch.epoch_certificate_ids
      ~revoked:epoch.epoch_revoked_value ~frontier:epoch.epoch_frontier_value
      ~recovery_device:epoch.epoch_recovery_device_value
      ~issuer:epoch.epoch_issuer_value
  in
  if not (String.equal expected epoch.epoch_id_value) then
    Error (Identity_mismatch "authority epoch ID")
  else if String.length epoch.epoch_signature <> 64 then
    Error (Invalid_signature (String.length epoch.epoch_signature))
  else if not (sorted_unique String.compare epoch.epoch_parents_value) then
    Error (Invalid_epoch "parents are not strictly sorted")
  else if not (sorted_unique String.compare epoch.epoch_certificate_ids) then
    Error (Invalid_epoch "certificates are not strictly sorted")
  else if not (sorted_unique compare_device_id epoch.epoch_revoked_value) then
    Error (Invalid_epoch "revocations are not strictly sorted")
  else if not (sorted_unique compare_revision_id epoch.epoch_frontier_value)
  then Error (Invalid_epoch "frontier is not strictly sorted")
  else
    let* _ =
      map_result (validate_hex_id "authority parent") epoch.epoch_parents_value
    in
    let* _ =
      map_result
        (validate_hex_id "authority certificate")
        epoch.epoch_certificate_ids
    in
    validate_epoch_issuer epoch.epoch_issuer_value

let encode_epoch epoch =
  let unsigned =
    epoch_unsigned_value ~repository:epoch.epoch_repository_value
      ~parents:epoch.epoch_parents_value
      ~certificate_ids:epoch.epoch_certificate_ids
      ~revoked:epoch.epoch_revoked_value ~frontier:epoch.epoch_frontier_value
      ~recovery_device:epoch.epoch_recovery_device_value
      ~issuer:epoch.epoch_issuer_value
    |> Result.get_ok
  in
  Encoding.array [ unsigned; Encoding.bytes epoch.epoch_signature ]
  |> Result.get_ok |> Encoding.encode

let decode_epoch encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_record (Encoding.decode_error_to_string error))
  in
  let* values = exact_array "V4 authority epoch" 2 value in
  match values with
  | [ unsigned; signature ] -> (
      let* signature = bytes_field "authority epoch signature" signature in
      let* fields = exact_array "V4 authority epoch unsigned body" 9 unsigned in
      match fields with
      | [
       version;
       repository;
       parents;
       certificates;
       revoked;
       frontier;
       recovery;
       issuer;
       algorithm_value;
      ] ->
          let* version = integer_field "authority epoch version" version in
          let* repository = decode_repository repository in
          let* parents = decode_text_array "authority parents" parents in
          let* certificate_ids =
            decode_text_array "authority certificates" certificates
          in
          let* revoked =
            decode_device_id_array "authority revocations" revoked
          in
          let* frontier =
            decode_revision_id_array "authority frontier" frontier
          in
          let* recovery_device = decode_device recovery in
          let* issuer = text_field "authority issuer" issuer in
          let* algorithm_value =
            text_field "authority algorithm" algorithm_value
          in
          if not (Int64.equal version 1L) then
            Error (Invalid_record "unsupported authority epoch version")
          else if not (String.equal algorithm_value algorithm) then
            Error (Unsupported_algorithm algorithm_value)
          else
            let* id =
              epoch_id_for ~repository ~parents ~certificate_ids ~revoked
                ~frontier ~recovery_device ~issuer
            in
            let epoch =
              {
                epoch_id_value = id;
                epoch_repository_value = repository;
                epoch_parents_value = parents;
                epoch_certificate_ids = certificate_ids;
                epoch_revoked_value = revoked;
                epoch_frontier_value = frontier;
                epoch_recovery_device_value = recovery_device;
                epoch_issuer_value = issuer;
                epoch_signature = signature;
              }
            in
            let* () = validate_epoch_shape epoch in
            if String.equal encoded (encode_epoch epoch) then Ok epoch
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let certificate_in_epoch epoch certificate =
  List.exists
    (String.equal (certificate_id certificate))
    epoch.epoch_certificate_ids

let device_revoked epoch device =
  List.exists
    (Model.Device_id.equal (device_id device))
    epoch.epoch_revoked_value

let certificate_active membership epoch certificate =
  certificate_in_epoch epoch certificate
  && (not (device_revoked epoch (certificate_subject certificate)))
  && Option.is_some
       (certificate_by_id membership.membership_certificates
          (certificate_id certificate))

let administrator_active membership epoch certificate =
  certificate_role certificate = Administrator
  && certificate_active membership epoch certificate

let verify_epoch_signature_device device epoch =
  match Mirage_crypto_ec.Ed25519.pub_of_octets (device_public_key device) with
  | Error _ ->
      Error (Invalid_public_key (String.length (device_public_key device)))
  | Ok public_key ->
      if
        Mirage_crypto_ec.Ed25519.verify ~key:public_key epoch.epoch_signature
          ~msg:(authority_epoch_signature_domain ^ epoch.epoch_id_value)
      then Ok ()
      else Error Signature_verification_failed

let union_sorted compare values = List.sort_uniq compare (List.concat values)

let contains_all compare required actual =
  List.for_all
    (fun value ->
      List.exists (fun candidate -> compare value candidate = 0) actual)
    required

let verify_authority ~membership epochs =
  let* membership =
    verify_membership ~repository:membership.membership_repository
      membership.membership_certificates
  in
  let rec unique seen = function
    | [] -> Ok ()
    | epoch :: rest ->
        if List.exists (fun id -> String.equal id epoch.epoch_id_value) seen
        then Error Duplicate_epoch
        else unique (epoch.epoch_id_value :: seen) rest
  in
  let* () = unique [] epochs in
  let epoch_by_id id =
    List.find_opt (fun epoch -> String.equal epoch.epoch_id_value id) epochs
  in
  let rec check visiting checked epoch =
    if List.exists (String.equal epoch.epoch_id_value) checked then Ok checked
    else if List.exists (String.equal epoch.epoch_id_value) visiting then
      Error (Invalid_epoch "parent graph contains a cycle")
    else if
      not
        (Repository_id.equal epoch.epoch_repository_value
           membership.membership_repository)
    then Error Cross_repository_certificate
    else
      let* () = validate_epoch_shape epoch in
      let parent_epochs =
        map_result
          (fun parent ->
            match epoch_by_id parent with
            | Some parent -> Ok parent
            | None -> Error Unknown_epoch)
          epoch.epoch_parents_value
      in
      let* parent_epochs = parent_epochs in
      let* checked =
        List.fold_left
          (fun result parent ->
            let* checked = result in
            check (epoch.epoch_id_value :: visiting) checked parent)
          (Ok checked) parent_epochs
      in
      let issuer_certificate =
        certificate_by_id membership.membership_certificates
          epoch.epoch_issuer_value
      in
      let* signer_device =
        match parent_epochs with
        | [] -> (
            match issuer_certificate with
            | Some issuer
              when certificate_issuer issuer = None
                   && certificate_role issuer = Administrator
                   && epoch.epoch_certificate_ids = [ certificate_id issuer ]
                   && epoch.epoch_revoked_value = [] ->
                Ok (certificate_subject issuer)
            | Some _ | None -> Error Invalid_root_certificate)
        | first_parent :: other_parents -> (
            match issuer_certificate with
            | Some issuer ->
                if
                  List.for_all
                    (fun parent ->
                      administrator_active membership parent issuer)
                    parent_epochs
                then Ok (certificate_subject issuer)
                else Error Unauthorized_epoch_issuer
            | None -> (
                let* recovery_issuer =
                  recovery_issuer_device epoch.epoch_issuer_value
                in
                match recovery_issuer with
                | None -> Error Unknown_issuer_certificate
                | Some recovery_issuer ->
                    let recovery_matches parent =
                      Model.Device_id.equal recovery_issuer
                        (device_id parent.epoch_recovery_device_value)
                    in
                    if
                      recovery_matches first_parent
                      && List.for_all recovery_matches other_parents
                    then Ok first_parent.epoch_recovery_device_value
                    else Error Invalid_recovery_authority))
      in
      let* () = verify_epoch_signature_device signer_device epoch in
      let inherited_certificates =
        union_sorted String.compare
          (List.map (fun parent -> parent.epoch_certificate_ids) parent_epochs)
      in
      let inherited_revocations =
        union_sorted compare_device_id
          (List.map (fun parent -> parent.epoch_revoked_value) parent_epochs)
      in
      let* () =
        if
          contains_all String.compare inherited_certificates
            epoch.epoch_certificate_ids
          && contains_all compare_device_id inherited_revocations
               epoch.epoch_revoked_value
        then Ok ()
        else Error (Invalid_epoch "a successor cannot remove authority history")
      in
      let* _ =
        map_result
          (fun certificate_id ->
            match
              certificate_by_id membership.membership_certificates
                certificate_id
            with
            | None -> Error Unknown_issuer_certificate
            | Some certificate -> (
                if parent_epochs = [] then Ok ()
                else if
                  List.exists
                    (fun parent -> certificate_in_epoch parent certificate)
                    parent_epochs
                then Ok ()
                else
                  match certificate_issuer certificate with
                  | Some issuer_id -> (
                      let* recovery_issuer = recovery_issuer_device issuer_id in
                      match recovery_issuer with
                      | Some recovery_issuer ->
                          if
                            (not
                               (Model.Device_id.equal recovery_issuer
                                  certificate.certificate_issuer_device))
                            || not
                                 (List.for_all
                                    (fun parent ->
                                      Model.Device_id.equal recovery_issuer
                                        (device_id
                                           parent.epoch_recovery_device_value))
                                    parent_epochs)
                          then Error Invalid_recovery_authority
                          else
                            verify_certificate_crypto
                              ~issuer_public_key:
                                (device_public_key
                                   (List.hd parent_epochs)
                                     .epoch_recovery_device_value)
                              certificate
                      | None -> (
                          match
                            certificate_by_id membership.membership_certificates
                              issuer_id
                          with
                          | Some enrollment_issuer
                            when List.for_all
                                   (fun parent ->
                                     administrator_active membership parent
                                       enrollment_issuer)
                                   parent_epochs ->
                              Ok ()
                          | Some _ -> Error Unauthorized_epoch_issuer
                          | None -> Error Unknown_issuer_certificate))
                  | None -> Error Invalid_root_certificate))
          epoch.epoch_certificate_ids
      in
      let* _ =
        map_result
          (fun revoked ->
            match
              List.find_opt
                (fun certificate ->
                  Model.Device_id.equal revoked
                    (device_id (certificate_subject certificate)))
                membership.membership_certificates
            with
            | Some certificate when certificate_in_epoch epoch certificate ->
                Ok ()
            | Some _ ->
                Error (Invalid_epoch "revocation names an excluded device")
            | None -> Error (Invalid_epoch "revocation names an unknown device"))
          epoch.epoch_revoked_value
      in
      Ok (epoch.epoch_id_value :: checked)
  in
  let* checked =
    List.fold_left
      (fun result epoch ->
        let* checked = result in
        check [] checked epoch)
      (Ok []) epochs
  in
  let roots =
    List.filter (fun epoch -> epoch.epoch_parents_value = []) epochs
  in
  if List.length roots <> 1 || List.length checked <> List.length epochs then
    Error (Invalid_epoch "authority graph must have one complete root")
  else
    let parents =
      List.concat_map (fun epoch -> epoch.epoch_parents_value) epochs
    in
    let heads =
      epochs
      |> List.filter (fun epoch ->
          not (List.exists (String.equal epoch.epoch_id_value) parents))
      |> List.map epoch_id |> List.sort String.compare
    in
    Ok
      {
        authority_membership_value = membership;
        authority_epochs_value =
          List.sort
            (fun left right -> String.compare (epoch_id left) (epoch_id right))
            epochs;
        authority_heads_value = heads;
      }

let root_epoch ~membership ~root_certificate ~recovery_device signing_capability
    =
  let* membership =
    verify_membership ~repository:membership.membership_repository
      membership.membership_certificates
  in
  let* certificate =
    match
      certificate_by_id membership.membership_certificates root_certificate
    with
    | Some certificate -> Ok certificate
    | None -> Error Unknown_issuer_certificate
  in
  if
    certificate_issuer certificate <> None
    || certificate_role certificate <> Administrator
  then Error Invalid_root_certificate
  else if
    not
      (String.equal
         (signing_public_key signing_capability)
         (device_public_key (certificate_subject certificate)))
  then Error Invalid_private_key
  else
    let* epoch =
      make_epoch ~repository:membership.membership_repository ~parents:[]
        ~certificate_ids:[ root_certificate ] ~revoked:[] ~frontier:[]
        ~recovery_device ~issuer:root_certificate signing_capability
    in
    let* _ = verify_authority ~membership [ epoch ] in
    Ok epoch

let authority_membership authority = authority.authority_membership_value
let authority_epochs authority = authority.authority_epochs_value
let authority_heads authority = authority.authority_heads_value

let authority_epoch authority id =
  match
    List.find_opt
      (fun epoch -> String.equal (epoch_id epoch) id)
      authority.authority_epochs_value
  with
  | Some epoch -> Ok epoch
  | None -> Error Unknown_epoch

let authority_device_active authority ~epoch device =
  match authority_epoch authority epoch with
  | Error _ -> false
  | Ok epoch -> (
      match
        certificate_for_device authority.authority_membership_value device
      with
      | Some certificate ->
          certificate_active authority.authority_membership_value epoch
            certificate
      | None -> false)

let authority_device_administrator authority ~epoch device =
  match authority_epoch authority epoch with
  | Error _ -> false
  | Ok epoch -> (
      match
        certificate_for_device authority.authority_membership_value device
      with
      | Some certificate ->
          administrator_active authority.authority_membership_value epoch
            certificate
      | None -> false)

let authority_epoch_is_head authority epoch =
  List.exists (String.equal epoch) authority.authority_heads_value

let rec epoch_descends_from authority ~ancestor epoch =
  if String.equal ancestor epoch.epoch_id_value then true
  else
    List.exists
      (fun parent ->
        match authority_epoch authority parent with
        | Error _ -> false
        | Ok parent -> epoch_descends_from authority ~ancestor parent)
      epoch.epoch_parents_value

let requires_late_review authority signed =
  let* signed_epoch =
    match signed.signed_epoch_value with
    | Some epoch -> authority_epoch authority epoch
    | None -> Error (Invalid_epoch "legacy revision has no authority epoch")
  in
  let* certificate =
    match
      certificate_by_id
        authority.authority_membership_value.membership_certificates
        signed.signed_certificate
    with
    | Some certificate -> Ok certificate
    | None -> Error Unknown_author_certificate
  in
  let signer = certificate_subject certificate in
  Ok
    (List.exists
       (fun head_id ->
         match authority_epoch authority head_id with
         | Error _ -> false
         | Ok head ->
             epoch_descends_from authority ~ancestor:signed_epoch.epoch_id_value
               head
             && device_revoked head signer)
       authority.authority_heads_value)

let extend_authority authority additional =
  let rec add seen = function
    | [] -> Ok seen
    | epoch :: rest -> (
        match
          List.find_opt
            (fun existing -> String.equal (epoch_id existing) (epoch_id epoch))
            seen
        with
        | None -> add (epoch :: seen) rest
        | Some existing ->
            if existing = epoch then add seen rest else Error Duplicate_epoch)
  in
  let* epochs = add authority.authority_epochs_value additional in
  verify_authority ~membership:authority.authority_membership_value epochs

let successor_epoch authority ~parents ~certificates ~revoked ~frontier
    ~recovery_device ~issuer signing_capability =
  if parents = [] then
    Error (Invalid_epoch "a successor needs at least one parent")
  else if not (sorted_unique String.compare parents) then
    Error (Invalid_epoch "parents are not strictly sorted")
  else if
    not
      (List.for_all
         (fun parent -> List.mem parent authority.authority_heads_value)
         parents)
  then
    Error (Invalid_epoch "a successor may only advance current authority heads")
  else
    let* parent_epochs = map_result (authority_epoch authority) parents in
    let* issuer_certificate =
      match
        certificate_by_id
          authority.authority_membership_value.membership_certificates issuer
      with
      | Some certificate -> Ok certificate
      | None -> Error Unknown_issuer_certificate
    in
    if
      not
        (List.for_all
           (fun parent ->
             administrator_active authority.authority_membership_value parent
               issuer_certificate)
           parent_epochs)
    then Error Unauthorized_epoch_issuer
    else if
      not
        (String.equal
           (signing_public_key signing_capability)
           (device_public_key (certificate_subject issuer_certificate)))
    then Error Invalid_private_key
    else
      let certificate_ids =
        certificates |> List.map certificate_id |> List.sort String.compare
      in
      let revoked = List.sort compare_device_id revoked in
      let frontier = List.sort compare_revision_id frontier in
      let* epoch =
        make_epoch
          ~repository:authority.authority_membership_value.membership_repository
          ~parents ~certificate_ids ~revoked ~frontier ~recovery_device ~issuer
          signing_capability
      in
      let* _ = extend_authority authority [ epoch ] in
      Ok epoch

let recover_epoch authority ~parents ~certificates ~revoked ~frontier
    ~recovery_device signing_capability =
  if parents = [] then
    Error (Invalid_epoch "recovery needs at least one parent")
  else if not (sorted_unique String.compare parents) then
    Error (Invalid_epoch "parents are not strictly sorted")
  else if
    not
      (List.for_all
         (fun parent -> List.mem parent authority.authority_heads_value)
         parents)
  then Error (Invalid_epoch "recovery may only advance current authority heads")
  else
    let* parent_epochs = map_result (authority_epoch authority) parents in
    match parent_epochs with
    | [] -> assert false
    | first_parent :: other_parents ->
        let consumed_recovery = first_parent.epoch_recovery_device_value in
        if
          not
            (List.for_all
               (fun parent ->
                 device_equal consumed_recovery
                   parent.epoch_recovery_device_value)
               other_parents)
        then Error Invalid_recovery_authority
        else if device_equal consumed_recovery recovery_device then
          Error (Invalid_epoch "recovery must rotate the consumed authority")
        else if
          not
            (String.equal
               (signing_public_key signing_capability)
               (device_public_key consumed_recovery))
        then Error Invalid_private_key
        else
          let certificate_ids =
            certificates |> List.map certificate_id |> List.sort String.compare
          in
          let revoked = List.sort compare_device_id revoked in
          let frontier = List.sort compare_revision_id frontier in
          let* epoch =
            make_epoch
              ~repository:
                authority.authority_membership_value.membership_repository
              ~parents ~certificate_ids ~revoked ~frontier ~recovery_device
              ~issuer:(recovery_issuer consumed_recovery)
              signing_capability
          in
          let* _ = extend_authority authority [ epoch ] in
          Ok epoch

let recover_enroll authority ~parents ~subject ~role signing_capability =
  if parents = [] then
    Error (Invalid_epoch "recovery enrollment needs a parent")
  else if not (sorted_unique String.compare parents) then
    Error (Invalid_epoch "parents are not strictly sorted")
  else if
    not
      (List.for_all
         (fun parent -> List.mem parent authority.authority_heads_value)
         parents)
  then
    Error
      (Invalid_epoch "recovery enrollment may only use current authority heads")
  else
    let* parent_epochs = map_result (authority_epoch authority) parents in
    match parent_epochs with
    | [] -> assert false
    | first_parent :: other_parents ->
        let recovery_device = first_parent.epoch_recovery_device_value in
        if
          not
            (List.for_all
               (fun parent ->
                 device_equal recovery_device parent.epoch_recovery_device_value)
               other_parents)
        then Error Invalid_recovery_authority
        else if
          not
            (String.equal
               (signing_public_key signing_capability)
               (device_public_key recovery_device))
        then Error Invalid_private_key
        else if
          Option.is_some
            (certificate_for_device authority.authority_membership_value subject)
        then Error Duplicate_device
        else
          sign_certificate
            ~repository:
              authority.authority_membership_value.membership_repository
            ~subject ~role
            ~issuer_certificate:(Some (recovery_issuer recovery_device))
            ~issuer_device:(device_id recovery_device)
            signing_capability

let sign_revision_at_with authority ~epoch ~certificate signing_capability
    ~resolution revision =
  let* authority_epoch = authority_epoch authority epoch in
  let* author_certificate =
    match
      certificate_by_id
        authority.authority_membership_value.membership_certificates certificate
    with
    | Some certificate -> Ok certificate
    | None -> Error Unknown_author_certificate
  in
  if
    not
      (certificate_active authority.authority_membership_value authority_epoch
         author_certificate)
  then Error Revoked_device
  else if
    not
      (Model.Device_id.equal
         (device_id (certificate_subject author_certificate))
         revision.Model.revision_author)
  then Error Revision_author_mismatch
  else if
    not
      (String.equal
         (signing_public_key signing_capability)
         (device_public_key (certificate_subject author_certificate)))
  then Error Invalid_private_key
  else
    let* bytes =
      revision_unsigned_bytes
        ~repository:authority.authority_membership_value.membership_repository
        ~certificate ~epoch ~resolution revision
    in
    let* signature =
      sign_detached signing_capability ~domain:revision_signature_domain bytes
    in
    Ok
      {
        signed_repository =
          authority.authority_membership_value.membership_repository;
        signed_certificate = certificate;
        signed_epoch_value = Some epoch;
        signed_resolution_decision_value = resolution;
        signed_revision_value = revision;
        signed_signature = signature;
      }

let sign_revision_at authority ~epoch ~certificate signing_capability revision =
  sign_revision_at_with authority ~epoch ~certificate signing_capability
    ~resolution:None revision

let sign_resolution_at authority ~epoch ~certificate signing_capability
    ~decision revision =
  sign_revision_at_with authority ~epoch ~certificate signing_capability
    ~resolution:(Some decision) revision

let verify_signed_revision_at authority signed =
  let* epoch =
    match signed.signed_epoch_value with
    | Some epoch -> authority_epoch authority epoch
    | None -> Error (Invalid_epoch "legacy revision has no authority epoch")
  in
  let* () =
    verify_signed_revision_crypto authority.authority_membership_value signed
  in
  let* certificate =
    match
      certificate_by_id
        authority.authority_membership_value.membership_certificates
        signed.signed_certificate
    with
    | Some certificate -> Ok certificate
    | None -> Error Unknown_author_certificate
  in
  if certificate_active authority.authority_membership_value epoch certificate
  then Ok ()
  else Error Revoked_device

(* Exact, signed exceptions for late records.  They cannot grant a broad
   membership capability: each record names one device, revision, and change. *)

let authorization_unsigned_value ~repository ~epoch ~issuer ~device ~revision
    ~change =
  let* repository = encode_repository repository in
  let* epoch = text epoch in
  let* issuer = text issuer in
  let* device = encode_device device in
  let* revision = encode_revision_id revision in
  let* change = text (Model.Change_id.to_string change) in
  array
    [ Encoding.integer 1L; repository; epoch; issuer; device; revision; change ]

let authorization_unsigned_bytes ~repository ~epoch ~issuer ~device ~revision
    ~change =
  authorization_unsigned_value ~repository ~epoch ~issuer ~device ~revision
    ~change
  |> Result.map Encoding.encode

let authorization_signing_certificate authority ~epoch ~issuer
    signing_capability =
  let* epoch = authority_epoch authority epoch in
  let* certificate =
    match
      certificate_by_id
        authority.authority_membership_value.membership_certificates issuer
    with
    | Some certificate -> Ok certificate
    | None -> Error Unknown_issuer_certificate
  in
  if
    not
      (administrator_active authority.authority_membership_value epoch
         certificate)
  then Error Unauthorized_epoch_issuer
  else if
    not
      (String.equal
         (signing_public_key signing_capability)
         (device_public_key (certificate_subject certificate)))
  then Error Invalid_private_key
  else Ok certificate

let make_authorization authority ~epoch ~issuer signing_capability ~device
    ~revision ~change =
  let* _ =
    authorization_signing_certificate authority ~epoch ~issuer
      signing_capability
  in
  let* unsigned =
    authorization_unsigned_bytes
      ~repository:authority.authority_membership_value.membership_repository
      ~epoch ~issuer ~device ~revision ~change
  in
  let* signature =
    sign_detached signing_capability ~domain:authorization_signature_domain
      unsigned
  in
  Ok
    {
      authorization_repository =
        authority.authority_membership_value.membership_repository;
      authorization_epoch = epoch;
      authorization_issuer = issuer;
      authorization_device = device;
      authorization_revision_value = revision;
      authorization_change = change;
      authorization_signature = signature;
    }

let authorization_revision authorization =
  authorization.authorization_revision_value

let authorization_epoch authorization = authorization.authorization_epoch

let encode_authorization authorization =
  let unsigned =
    authorization_unsigned_value
      ~repository:authorization.authorization_repository
      ~epoch:authorization.authorization_epoch
      ~issuer:authorization.authorization_issuer
      ~device:authorization.authorization_device
      ~revision:authorization.authorization_revision_value
      ~change:authorization.authorization_change
    |> Result.get_ok
  in
  Encoding.array
    [ unsigned; Encoding.bytes authorization.authorization_signature ]
  |> Result.get_ok |> Encoding.encode

let decode_authorization encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_record (Encoding.decode_error_to_string error))
  in
  let* values = exact_array "V4 authorization" 2 value in
  match values with
  | [ unsigned; signature ] -> (
      let* signature = bytes_field "authorization signature" signature in
      let* fields = exact_array "V4 authorization unsigned body" 7 unsigned in
      match fields with
      | [ version; repository; epoch; issuer; device; revision; change ] ->
          let* version = integer_field "authorization version" version in
          let* repository = decode_repository repository in
          let* epoch = text_field "authorization epoch" epoch in
          let* issuer = text_field "authorization issuer" issuer in
          let* device = decode_device device in
          let* revision = decode_revision_id revision in
          let* change = text_field "authorization change" change in
          let* change =
            Model.Change_id.of_string change
            |> Result.map_error (fun error ->
                Invalid_record (Model.error_to_string error))
          in
          if not (Int64.equal version 1L) then
            Error (Invalid_record "unsupported authorization version")
          else
            let authorization =
              {
                authorization_repository = repository;
                authorization_epoch = epoch;
                authorization_issuer = issuer;
                authorization_device = device;
                authorization_revision_value = revision;
                authorization_change = change;
                authorization_signature = signature;
              }
            in
            if String.equal encoded (encode_authorization authorization) then
              Ok authorization
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let verify_authorization authority authorization =
  if
    not
      (Repository_id.equal authorization.authorization_repository
         authority.authority_membership_value.membership_repository)
  then Error Cross_repository_certificate
  else if String.length authorization.authorization_signature <> 64 then
    Error
      (Invalid_signature (String.length authorization.authorization_signature))
  else
    let* epoch = authority_epoch authority authorization.authorization_epoch in
    let* certificate =
      match
        certificate_by_id
          authority.authority_membership_value.membership_certificates
          authorization.authorization_issuer
      with
      | Some certificate -> Ok certificate
      | None -> Error Unknown_issuer_certificate
    in
    if
      not
        (administrator_active authority.authority_membership_value epoch
           certificate)
    then Error Unauthorized_epoch_issuer
    else
      let* bytes =
        authorization_unsigned_bytes
          ~repository:authorization.authorization_repository
          ~epoch:authorization.authorization_epoch
          ~issuer:authorization.authorization_issuer
          ~device:authorization.authorization_device
          ~revision:authorization.authorization_revision_value
          ~change:authorization.authorization_change
      in
      match
        Mirage_crypto_ec.Ed25519.pub_of_octets
          (device_public_key (certificate_subject certificate))
      with
      | Error _ ->
          Error
            (Invalid_public_key
               (String.length
                  (device_public_key (certificate_subject certificate))))
      | Ok public_key ->
          if
            Mirage_crypto_ec.Ed25519.verify ~key:public_key
              authorization.authorization_signature
              ~msg:(authorization_signature_domain ^ bytes)
          then Ok ()
          else Error Signature_verification_failed

let authorization_matches_signed_revision authorization signed =
  Model.Revision_id.equal authorization.authorization_revision_value
    (signed_revision_id signed)
  && Model.Change_id.equal authorization.authorization_change
       signed.signed_revision_value.Model.change
  && Model.Device_id.equal
       (device_id authorization.authorization_device)
       signed.signed_revision_value.Model.revision_author

let signed_revision_digest signed =
  Repository_id.hex
    (digest "yeokcham:v4:signed-revision-digest:1\000"
       (encode_signed_revision signed))

let adoption_unsigned_value ~repository ~epoch ~issuer ~revision ~signed_digest
    =
  let* repository = encode_repository repository in
  let* epoch = text epoch in
  let* issuer = text issuer in
  let* revision = encode_revision_id revision in
  let* signed_digest = text signed_digest in
  array
    [ Encoding.integer 1L; repository; epoch; issuer; revision; signed_digest ]

let adoption_unsigned_bytes ~repository ~epoch ~issuer ~revision ~signed_digest
    =
  adoption_unsigned_value ~repository ~epoch ~issuer ~revision ~signed_digest
  |> Result.map Encoding.encode

let make_adoption authority ~epoch ~issuer signing_capability ~signed_revision =
  let* _ =
    authorization_signing_certificate authority ~epoch ~issuer
      signing_capability
  in
  let* () = verify_signed_revision_at authority signed_revision in
  let* unsigned =
    adoption_unsigned_bytes
      ~repository:authority.authority_membership_value.membership_repository
      ~epoch ~issuer
      ~revision:(signed_revision_id signed_revision)
      ~signed_digest:(signed_revision_digest signed_revision)
  in
  let* signature =
    sign_detached signing_capability ~domain:adoption_signature_domain unsigned
  in
  Ok
    {
      adoption_repository =
        authority.authority_membership_value.membership_repository;
      adoption_epoch = epoch;
      adoption_issuer = issuer;
      adoption_revision_value = signed_revision_id signed_revision;
      adoption_signed_digest = signed_revision_digest signed_revision;
      adoption_signature = signature;
    }

let adoption_revision adoption = adoption.adoption_revision_value
let adoption_epoch adoption = adoption.adoption_epoch

let encode_adoption adoption =
  let unsigned =
    adoption_unsigned_value ~repository:adoption.adoption_repository
      ~epoch:adoption.adoption_epoch ~issuer:adoption.adoption_issuer
      ~revision:adoption.adoption_revision_value
      ~signed_digest:adoption.adoption_signed_digest
    |> Result.get_ok
  in
  Encoding.array [ unsigned; Encoding.bytes adoption.adoption_signature ]
  |> Result.get_ok |> Encoding.encode

let decode_adoption encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_record (Encoding.decode_error_to_string error))
  in
  let* values = exact_array "V4 adoption" 2 value in
  match values with
  | [ unsigned; signature ] -> (
      let* signature = bytes_field "adoption signature" signature in
      let* fields = exact_array "V4 adoption unsigned body" 6 unsigned in
      match fields with
      | [ version; repository; epoch; issuer; revision; signed_digest ] ->
          let* version = integer_field "adoption version" version in
          let* repository = decode_repository repository in
          let* epoch = text_field "adoption epoch" epoch in
          let* issuer = text_field "adoption issuer" issuer in
          let* revision = decode_revision_id revision in
          let* signed_digest =
            text_field "adoption signed revision digest" signed_digest
          in
          if not (Int64.equal version 1L) then
            Error (Invalid_record "unsupported adoption version")
          else
            let adoption =
              {
                adoption_repository = repository;
                adoption_epoch = epoch;
                adoption_issuer = issuer;
                adoption_revision_value = revision;
                adoption_signed_digest = signed_digest;
                adoption_signature = signature;
              }
            in
            if String.equal encoded (encode_adoption adoption) then Ok adoption
            else Error Noncanonical_record
      | _ -> assert false)
  | _ -> assert false

let verify_adoption authority adoption =
  if
    not
      (Repository_id.equal adoption.adoption_repository
         authority.authority_membership_value.membership_repository)
  then Error Cross_repository_certificate
  else if String.length adoption.adoption_signature <> 64 then
    Error (Invalid_signature (String.length adoption.adoption_signature))
  else
    let* epoch = authority_epoch authority adoption.adoption_epoch in
    let* certificate =
      match
        certificate_by_id
          authority.authority_membership_value.membership_certificates
          adoption.adoption_issuer
      with
      | Some certificate -> Ok certificate
      | None -> Error Unknown_issuer_certificate
    in
    if
      not
        (administrator_active authority.authority_membership_value epoch
           certificate)
    then Error Unauthorized_epoch_issuer
    else
      let* bytes =
        adoption_unsigned_bytes ~repository:adoption.adoption_repository
          ~epoch:adoption.adoption_epoch ~issuer:adoption.adoption_issuer
          ~revision:adoption.adoption_revision_value
          ~signed_digest:adoption.adoption_signed_digest
      in
      match
        Mirage_crypto_ec.Ed25519.pub_of_octets
          (device_public_key (certificate_subject certificate))
      with
      | Error _ ->
          Error
            (Invalid_public_key
               (String.length
                  (device_public_key (certificate_subject certificate))))
      | Ok public_key ->
          if
            Mirage_crypto_ec.Ed25519.verify ~key:public_key
              adoption.adoption_signature
              ~msg:(adoption_signature_domain ^ bytes)
          then Ok ()
          else Error Signature_verification_failed

let adoption_matches_signed_revision adoption signed =
  Model.Revision_id.equal adoption.adoption_revision_value
    (signed_revision_id signed)
  && String.equal adoption.adoption_signed_digest
       (signed_revision_digest signed)
