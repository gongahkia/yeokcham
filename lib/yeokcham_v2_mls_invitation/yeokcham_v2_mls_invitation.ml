module Authority = Yeokcham_v2_authority
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type member_invitation = {
  invitation_record_id : Model.Mls_invitation_id.t;
  invitation_repository_id : Model.Repository_id.t;
  invitation_group_id : Model.Mls_group_id.t;
  invitation_issuer_key_id : Model.Root_key_id.t;
  invitation_recipient_device_id : Model.Device_id.t;
  invitation_issued_at : int64;
  invitation_expires_at : int64;
  invitation_join_state : Envelope.t;
  invitation_mandatory_features : int64;
  invitation_signature : string;
}

type event_kind = Event_issued | Event_revoked | Event_accepted

type membership_event = {
  membership_event_record_id : Model.Mls_invitation_id.t;
  membership_event_invitation_id : Model.Mls_invitation_id.t;
  membership_event_repository_id : Model.Repository_id.t;
  membership_event_group_id : Model.Mls_group_id.t;
  membership_event_issuer_key_id : Model.Root_key_id.t;
  membership_event_recipient_device_id : Model.Device_id.t;
  membership_event_kind : event_kind;
  membership_event_occurred_at : int64;
  membership_event_payload : Envelope.t;
  membership_event_mandatory_features : int64;
  membership_event_signature : string;
}

type lifecycle = Open | Revoked | Accepted

type issue = {
  invitation : member_invitation;
  issued_event : membership_event;
  issuer_state : Group.t;
}

type acceptance = {
  recipient_state : Group.t;
  accepted_event : membership_event;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Invalid_time_range
  | Invitation_expired of { now : int64; expires_at : int64 }
  | Unauthorized_issuer
  | Authority_error of Authority.error
  | Group_error of Group.error
  | Envelope_error of Envelope.error
  | Signature_verification_failed
  | Identity_mismatch of string
  | Noncanonical_record
  | Missing_issued_event
  | Duplicate_issued_event
  | Replayed_invitation
  | Revoked_invitation
  | Entropy_failure

let current_schema_version = 1L
let supported_mandatory_features = 0L
let invitation_id_domain = "yeokcham:v2:mls-invitation:1\000"
let invitation_signature_domain = "yeokcham:v2:mls-invitation-signature:1\000"
let event_id_domain = "yeokcham:v2:mls-membership-event:1\000"
let event_signature_domain = "yeokcham:v2:mls-membership-event-signature:1\000"
let invitation_key_bytes = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_payload detail -> "invalid MLS invitation record: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported MLS invitation schema version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid MLS invitation mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported MLS invitation mandatory feature bits: %Ld"
        features
  | Invalid_time_range -> "MLS invitation expiry must be later than issuance"
  | Invitation_expired { now; expires_at } ->
      Printf.sprintf "MLS invitation expired at %Ld (now %Ld)" expires_at now
  | Unauthorized_issuer ->
      "MLS invitations require the repository authority root policy role"
  | Authority_error error -> Authority.error_to_string error
  | Group_error error -> Group.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Signature_verification_failed -> "MLS invitation root signature is invalid"
  | Identity_mismatch detail -> "MLS invitation identity mismatch: " ^ detail
  | Noncanonical_record -> "MLS invitation record bytes are noncanonical"
  | Missing_issued_event -> "MLS invitation history omits its issued event"
  | Duplicate_issued_event -> "MLS invitation history has duplicate issued events"
  | Replayed_invitation -> "MLS invitation was already accepted"
  | Revoked_invitation -> "MLS invitation was revoked"
  | Entropy_failure -> "OS CSPRNG unavailable while creating an invitation key"

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let check_features features =
  if Int64.compare features 0L < 0 then Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ -> Error (Invalid_payload (name ^ " has wrong field count"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload (name ^ " must be bytes"))

let text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload (name ^ " must be text"))

let repository_id name value =
  let* value = bytes name value in
  Model.Repository_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let group_id name value =
  let* value = bytes name value in
  Model.Mls_group_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let invitation_id_value name value =
  let* value = bytes name value in
  Model.Mls_invitation_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let root_key_id name value =
  let* value = bytes name value in
  Model.Root_key_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let device_id name value =
  let* value = bytes name value in
  Model.Device_id.of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let event_kind_code = function
  | Event_issued -> 1L
  | Event_revoked -> 2L
  | Event_accepted -> 3L

let event_kind_of_code = function
  | 1L -> Ok Event_issued
  | 2L -> Ok Event_revoked
  | 3L -> Ok Event_accepted
  | _ -> Error (Invalid_payload "MLS membership event kind is unsupported")

let ensure_authority ~authority ~repository_id ~issuer_key_id =
  if
    not
      (Model.Repository_id.equal repository_id
         (Authority.repository_authority_repository_id authority))
  then Error (Identity_mismatch "repository authority")
  else if
    not
      (Model.Root_key_id.equal issuer_key_id
         (Authority.repository_authority_root_key_id authority))
  then Error Unauthorized_issuer
  else Ok ()

let ensure_root ~authority root =
  if
    Model.Root_key_id.equal (Authority.root_key_id root)
      (Authority.repository_authority_root_key_id authority)
    && String.equal (Authority.root_public_key root)
         (Authority.repository_authority_root_public_key authority)
  then Ok ()
  else Error Unauthorized_issuer

let invitation_unsigned_value ~repository_id ~group_id ~issuer_key_id
    ~recipient_device_id ~issued_at ~expires_at ~join_state ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
      Encoding.bytes (Model.Root_key_id.to_bytes issuer_key_id);
      Encoding.bytes (Model.Device_id.to_bytes recipient_device_id);
      Encoding.integer issued_at;
      Encoding.integer expires_at;
      Encoding.bytes (Envelope.encode join_state);
      Encoding.integer mandatory_features;
    ]

let derive_invitation_id ~repository_id ~group_id ~issuer_key_id
    ~recipient_device_id ~issued_at ~expires_at ~join_state ~mandatory_features =
  let* value =
    invitation_unsigned_value ~repository_id ~group_id ~issuer_key_id
      ~recipient_device_id ~issued_at ~expires_at ~join_state ~mandatory_features
  in
  Model.Mls_invitation_id.of_bytes
    (digest invitation_id_domain (Encoding.encode value))
  |> Result.map_error (fun _ -> assert false)

let invitation_value invitation =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Mls_invitation_id.to_bytes invitation.invitation_record_id);
      Encoding.bytes (Model.Repository_id.to_bytes invitation.invitation_repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes invitation.invitation_group_id);
      Encoding.bytes (Model.Root_key_id.to_bytes invitation.invitation_issuer_key_id);
      Encoding.bytes
        (Model.Device_id.to_bytes invitation.invitation_recipient_device_id);
      Encoding.integer invitation.invitation_issued_at;
      Encoding.integer invitation.invitation_expires_at;
      Encoding.bytes (Envelope.encode invitation.invitation_join_state);
      Encoding.integer invitation.invitation_mandatory_features;
      Encoding.text Authority.algorithm |> Result.get_ok;
      Encoding.bytes invitation.invitation_signature;
    ]

let encode_invitation invitation = invitation_value invitation |> Result.get_ok |> Encoding.encode

let event_unsigned_value ~invitation_id ~repository_id ~group_id ~issuer_key_id
    ~recipient_device_id ~kind ~occurred_at ~payload ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Mls_invitation_id.to_bytes invitation_id);
      Encoding.bytes (Model.Repository_id.to_bytes repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
      Encoding.bytes (Model.Root_key_id.to_bytes issuer_key_id);
      Encoding.bytes (Model.Device_id.to_bytes recipient_device_id);
      Encoding.integer (event_kind_code kind);
      Encoding.integer occurred_at;
      Encoding.bytes (Envelope.encode payload);
      Encoding.integer mandatory_features;
    ]

let derive_event_id ~invitation_id ~repository_id ~group_id ~issuer_key_id
    ~recipient_device_id ~kind ~occurred_at ~payload ~mandatory_features =
  let* value =
    event_unsigned_value ~invitation_id ~repository_id ~group_id ~issuer_key_id
      ~recipient_device_id ~kind ~occurred_at ~payload ~mandatory_features
  in
  Model.Mls_invitation_id.of_bytes (digest event_id_domain (Encoding.encode value))
  |> Result.map_error (fun _ -> assert false)

let event_value event =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Mls_invitation_id.to_bytes event.membership_event_record_id);
      Encoding.bytes
        (Model.Mls_invitation_id.to_bytes event.membership_event_invitation_id);
      Encoding.bytes
        (Model.Repository_id.to_bytes event.membership_event_repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes event.membership_event_group_id);
      Encoding.bytes
        (Model.Root_key_id.to_bytes event.membership_event_issuer_key_id);
      Encoding.bytes
        (Model.Device_id.to_bytes event.membership_event_recipient_device_id);
      Encoding.integer (event_kind_code event.membership_event_kind);
      Encoding.integer event.membership_event_occurred_at;
      Encoding.bytes (Envelope.encode event.membership_event_payload);
      Encoding.integer event.membership_event_mandatory_features;
      Encoding.text Authority.algorithm |> Result.get_ok;
      Encoding.bytes event.membership_event_signature;
    ]

let encode_membership_event event = event_value event |> Result.get_ok |> Encoding.encode

let make_event ~root ~invitation ~kind ~occurred_at ~payload =
  let mandatory_features = invitation.invitation_mandatory_features in
  let* id =
    derive_event_id ~invitation_id:invitation.invitation_record_id
      ~repository_id:invitation.invitation_repository_id
      ~group_id:invitation.invitation_group_id
      ~issuer_key_id:invitation.invitation_issuer_key_id
      ~recipient_device_id:invitation.invitation_recipient_device_id ~kind
      ~occurred_at ~payload ~mandatory_features
  in
  let* signature =
    Authority.sign_root_message root ~domain:event_signature_domain
      (Model.Mls_invitation_id.to_bytes id)
    |> Result.map_error (fun error -> Authority_error error)
  in
  Ok
    {
      membership_event_record_id = id;
      membership_event_invitation_id = invitation.invitation_record_id;
      membership_event_repository_id = invitation.invitation_repository_id;
      membership_event_group_id = invitation.invitation_group_id;
      membership_event_issuer_key_id = invitation.invitation_issuer_key_id;
      membership_event_recipient_device_id = invitation.invitation_recipient_device_id;
      membership_event_kind = kind;
      membership_event_occurred_at = occurred_at;
      membership_event_payload = payload;
      membership_event_mandatory_features = mandatory_features;
      membership_event_signature = signature;
    }

let event_payload ~kind ~first ~second =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.integer (event_kind_code kind);
      Encoding.bytes first;
      Encoding.bytes second;
    ]
  |> Result.map Encoding.encode

let seal_event_payload ~key ~nonce ~kind ~first ~second =
  let* plaintext = event_payload ~kind ~first ~second in
  Envelope.seal ~key ~nonce ~mandatory_features:0L plaintext
  |> Result.map_error (fun error -> Envelope_error error)

let invitation_key () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate invitation_key_bytes |> Envelope.key_of_bytes
    |> Result.map_error (fun _ -> Entropy_failure)
  with _ -> Error Entropy_failure

let decode_invitation ~authority encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "MLS invitation" 12 value in
  match values with
  | [
   version;
   id;
   repository;
   group;
   issuer;
   recipient;
   issued_at;
   expires_at;
   join_state;
   features;
   algorithm;
   signature;
  ] ->
      let* version = integer "MLS invitation version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = invitation_id_value "MLS invitation ID" id in
        let* repository_id = repository_id "MLS invitation repository ID" repository in
        let* group_id = group_id "MLS invitation group ID" group in
        let* issuer_key_id = root_key_id "MLS invitation issuer key ID" issuer in
        let* recipient_device_id = device_id "MLS invitation recipient" recipient in
        let* issued_at = integer "MLS invitation issued-at" issued_at in
        let* expires_at = integer "MLS invitation expires-at" expires_at in
        let* join_state = bytes "MLS invitation encrypted join state" join_state in
        let* join_state =
          Envelope.decode join_state |> Result.map_error (fun error -> Envelope_error error)
        in
        let* mandatory_features = integer "MLS invitation mandatory features" features in
        let* () = check_features mandatory_features in
        let* algorithm = text "MLS invitation signature algorithm" algorithm in
        if not (String.equal algorithm Authority.algorithm) then
          Error (Invalid_payload "MLS invitation signature algorithm is unsupported")
        else
          let* signature = bytes "MLS invitation signature" signature in
          let* () = ensure_authority ~authority ~repository_id ~issuer_key_id in
          if Int64.compare expires_at issued_at <= 0 then Error Invalid_time_range
          else if
            not
              (Model.Mls_group_id.equal group_id
                 (Group.group_id_for_repository repository_id))
          then Error (Identity_mismatch "repository-derived MLS group ID")
          else
            let* derived_id =
              derive_invitation_id ~repository_id ~group_id ~issuer_key_id
                ~recipient_device_id ~issued_at ~expires_at ~join_state
                ~mandatory_features
            in
            if not (Model.Mls_invitation_id.equal id derived_id) then
              Error (Identity_mismatch "MLS invitation ID")
            else
              let* () =
                Authority.verify_root_message
                  ~public_key:(Authority.repository_authority_root_public_key authority)
                  ~domain:invitation_signature_domain
                  (Model.Mls_invitation_id.to_bytes id) ~signature
                |> Result.map_error (fun _ -> Signature_verification_failed)
              in
              let invitation =
                {
                  invitation_record_id = id;
                  invitation_repository_id = repository_id;
                  invitation_group_id = group_id;
                  invitation_issuer_key_id = issuer_key_id;
                  invitation_recipient_device_id = recipient_device_id;
                  invitation_issued_at = issued_at;
                  invitation_expires_at = expires_at;
                  invitation_join_state = join_state;
                  invitation_mandatory_features = mandatory_features;
                  invitation_signature = signature;
                }
              in
              if String.equal encoded (encode_invitation invitation) then Ok invitation
              else Error Noncanonical_record
  | _ -> assert false

let decode_membership_event ~authority encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "MLS membership event" 13 value in
  match values with
  | [
   version;
   id;
   invitation_id;
   repository;
   group;
   issuer;
   recipient;
   kind;
   occurred_at;
   payload;
   features;
   algorithm;
   signature;
  ] ->
      let* version = integer "MLS membership event version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = invitation_id_value "MLS membership event ID" id in
        let* invitation_id =
          invitation_id_value "MLS membership event invitation ID" invitation_id
        in
        let* repository_id = repository_id "MLS membership event repository ID" repository in
        let* group_id = group_id "MLS membership event group ID" group in
        let* issuer_key_id = root_key_id "MLS membership event issuer key ID" issuer in
        let* recipient_device_id = device_id "MLS membership event recipient" recipient in
        let* kind_code = integer "MLS membership event kind" kind in
        let* kind = event_kind_of_code kind_code in
        let* occurred_at = integer "MLS membership event occurred-at" occurred_at in
        let* payload = bytes "MLS membership event encrypted payload" payload in
        let* payload =
          Envelope.decode payload |> Result.map_error (fun error -> Envelope_error error)
        in
        let* mandatory_features = integer "MLS membership event mandatory features" features in
        let* () = check_features mandatory_features in
        let* algorithm = text "MLS membership event signature algorithm" algorithm in
        if not (String.equal algorithm Authority.algorithm) then
          Error (Invalid_payload "MLS membership event signature algorithm is unsupported")
        else
          let* signature = bytes "MLS membership event signature" signature in
          let* () = ensure_authority ~authority ~repository_id ~issuer_key_id in
          if
            not
              (Model.Mls_group_id.equal group_id
                 (Group.group_id_for_repository repository_id))
          then Error (Identity_mismatch "repository-derived MLS group ID")
          else
            let* derived_id =
              derive_event_id ~invitation_id ~repository_id ~group_id ~issuer_key_id
                ~recipient_device_id ~kind ~occurred_at ~payload ~mandatory_features
            in
            if not (Model.Mls_invitation_id.equal id derived_id) then
              Error (Identity_mismatch "MLS membership event ID")
            else
              let* () =
                Authority.verify_root_message
                  ~public_key:(Authority.repository_authority_root_public_key authority)
                  ~domain:event_signature_domain
                  (Model.Mls_invitation_id.to_bytes id) ~signature
                |> Result.map_error (fun _ -> Signature_verification_failed)
              in
              let event =
                {
                  membership_event_record_id = id;
                  membership_event_invitation_id = invitation_id;
                  membership_event_repository_id = repository_id;
                  membership_event_group_id = group_id;
                  membership_event_issuer_key_id = issuer_key_id;
                  membership_event_recipient_device_id = recipient_device_id;
                  membership_event_kind = kind;
                  membership_event_occurred_at = occurred_at;
                  membership_event_payload = payload;
                  membership_event_mandatory_features = mandatory_features;
                  membership_event_signature = signature;
                }
              in
              if String.equal encoded (encode_membership_event event) then Ok event
              else Error Noncanonical_record
  | _ -> assert false

let invitation_id invitation = invitation.invitation_record_id
let invitation_repository_id invitation = invitation.invitation_repository_id
let invitation_group_id invitation = invitation.invitation_group_id
let invitation_recipient_device_id invitation = invitation.invitation_recipient_device_id
let invitation_expires_at invitation = invitation.invitation_expires_at
let membership_event_id event = event.membership_event_record_id
let membership_event_invitation_id event = event.membership_event_invitation_id

let issue ~runtime ~authority ~root ~issuer_state ~recipient_device_id ~issued_at
    ~expires_at ~invitation_key:join_key ~invitation_nonce ~event_nonce =
  let* () = ensure_root ~authority root in
  if Int64.compare expires_at issued_at <= 0 then Error Invalid_time_range
  else if
    not
      (Model.Repository_id.equal (Group.repository_id issuer_state)
         (Authority.repository_authority_repository_id authority))
  then Error (Identity_mismatch "issuer MLS state repository")
  else
    let* joined =
      Group.add_member ~runtime ~issuer_state ~recipient_device_id
      |> Result.map_error (fun error -> Group_error error)
    in
    let joined_recipient_state = joined.Group.recipient_state in
    let joined_issuer_state = joined.Group.issuer_state in
    let joined_commit = joined.Group.commit in
    let joined_welcome = joined.Group.welcome in
    let* join_state =
      Envelope.seal ~key:join_key ~nonce:invitation_nonce ~mandatory_features:0L
        (Group.encode joined_recipient_state)
      |> Result.map_error (fun error -> Envelope_error error)
    in
    let repository_id = Group.repository_id issuer_state in
    let group_id = Group.group_id issuer_state in
    let issuer_key_id = Authority.root_key_id root in
    let* invitation_id =
      derive_invitation_id ~repository_id ~group_id ~issuer_key_id
        ~recipient_device_id ~issued_at ~expires_at ~join_state
        ~mandatory_features:0L
    in
    let* invitation_signature =
      Authority.sign_root_message root ~domain:invitation_signature_domain
        (Model.Mls_invitation_id.to_bytes invitation_id)
      |> Result.map_error (fun error -> Authority_error error)
    in
    let invitation =
      {
        invitation_record_id = invitation_id;
        invitation_repository_id = repository_id;
        invitation_group_id = group_id;
        invitation_issuer_key_id = issuer_key_id;
        invitation_recipient_device_id = recipient_device_id;
        invitation_issued_at = issued_at;
        invitation_expires_at = expires_at;
        invitation_join_state = join_state;
        invitation_mandatory_features = 0L;
        invitation_signature;
      }
    in
    let* payload =
      seal_event_payload ~key:join_key ~nonce:event_nonce ~kind:Event_issued
        ~first:(digest "yeokcham:v2:mls-commit:1\000" joined_commit)
        ~second:(digest "yeokcham:v2:mls-welcome:1\000" joined_welcome)
    in
    let* issued_event =
      make_event ~root ~invitation ~kind:Event_issued ~occurred_at:issued_at ~payload
    in
    Ok { invitation; issued_event; issuer_state = joined_issuer_state }

let event_matches invitation event =
  Model.Mls_invitation_id.equal event.membership_event_invitation_id
    invitation.invitation_record_id
  && Model.Repository_id.equal event.membership_event_repository_id
       invitation.invitation_repository_id
  && Model.Mls_group_id.equal event.membership_event_group_id invitation.invitation_group_id
  && Model.Device_id.equal event.membership_event_recipient_device_id
       invitation.invitation_recipient_device_id

let lifecycle ~authority ~invitation history =
  let* _ = decode_invitation ~authority (encode_invitation invitation) in
  let rec collect seen issued revoked accepted = function
    | [] ->
        if issued = 0 then Error Missing_issued_event
        else if issued > 1 then Error Duplicate_issued_event
        else if accepted > 0 then Ok Accepted
        else if revoked > 0 then Ok Revoked
        else Ok Open
    | event :: rest ->
        let* event =
          decode_membership_event ~authority (encode_membership_event event)
        in
        if event_matches invitation event then
          let id = Model.Mls_invitation_id.to_bytes event.membership_event_record_id in
          if List.mem id seen then Error (Identity_mismatch "duplicate membership event")
          else
            let issued, revoked, accepted =
              match event.membership_event_kind with
              | Event_issued -> (issued + 1, revoked, accepted)
              | Event_revoked -> (issued, revoked + 1, accepted)
              | Event_accepted -> (issued, revoked, accepted + 1)
            in
            collect (id :: seen) issued revoked accepted rest
        else collect seen issued revoked accepted rest
  in
  collect [] 0 0 0 history

let revoke ~authority ~root ~invitation ~history ~revoked_at
    ~invitation_key:join_key ~event_nonce =
  let* () = ensure_root ~authority root in
  let* status = lifecycle ~authority ~invitation history in
  match status with
  | Revoked -> Error Revoked_invitation
  | Accepted -> Error Replayed_invitation
  | Open ->
      let* payload =
        seal_event_payload ~key:join_key ~nonce:event_nonce ~kind:Event_revoked
          ~first:(Model.Mls_invitation_id.to_bytes invitation.invitation_record_id)
          ~second:""
      in
      make_event ~root ~invitation ~kind:Event_revoked ~occurred_at:revoked_at ~payload

let accept ~runtime ~authority ~root ~invitation ~history ~now
    ~invitation_key:join_key ~event_nonce =
  let* checked = decode_invitation ~authority (encode_invitation invitation) in
  if Int64.compare now checked.invitation_expires_at >= 0 then
    Error
      (Invitation_expired
         { now; expires_at = checked.invitation_expires_at })
  else
    let* status = lifecycle ~authority ~invitation:checked history in
    match status with
    | Revoked -> Error Revoked_invitation
    | Accepted -> Error Replayed_invitation
    | Open ->
        let* plaintext =
          Envelope.open_envelope ~key:join_key checked.invitation_join_state
          |> Result.map_error (fun error -> Envelope_error error)
        in
        let* recipient_state =
          Group.decode plaintext |> Result.map_error (fun error -> Group_error error)
        in
        if
          not
            (Model.Repository_id.equal (Group.repository_id recipient_state)
               checked.invitation_repository_id)
        then Error (Identity_mismatch "accepted MLS state repository")
        else if
          not
            (Model.Mls_group_id.equal (Group.group_id recipient_state)
               checked.invitation_group_id)
        then Error (Identity_mismatch "accepted MLS state group")
        else if
          not
            (Model.Device_id.equal (Group.device_id recipient_state)
               checked.invitation_recipient_device_id)
        then Error (Identity_mismatch "accepted MLS state recipient")
        else
          let* () =
            Group.verify ~runtime recipient_state
            |> Result.map_error (fun error -> Group_error error)
          in
          let* payload =
            seal_event_payload ~key:join_key ~nonce:event_nonce ~kind:Event_accepted
              ~first:(digest "yeokcham:v2:mls-recipient-state:1\000"
                        (Group.encode recipient_state))
              ~second:""
          in
          let* () = ensure_root ~authority root in
          let* accepted_event =
            make_event ~root ~invitation:checked ~kind:Event_accepted ~occurred_at:now
              ~payload
          in
          Ok { recipient_state; accepted_event }
