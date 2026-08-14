module Authority = Yeokcham_v2_authority
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type change = Member_added | Member_removed

type transition = {
  epoch_record_id : Model.Mls_epoch_id.t;
  epoch_repository_id : Model.Repository_id.t;
  epoch_group_id : Model.Mls_group_id.t;
  epoch_issuer_key_id : Model.Root_key_id.t;
  epoch_parent_id : Model.Mls_epoch_id.t option;
  epoch_change : change;
  epoch_changed_device_id : Model.Device_id.t;
  epoch_previous : int64;
  epoch_next : int64;
  epoch_predecessor_state_commitment : string;
  epoch_successor_state_commitment : string;
  epoch_commit_commitment : string;
  epoch_successor_envelope : Envelope.t;
  epoch_mandatory_features : int64;
  epoch_signature : string;
}

type transition_result = {
  transition_result_record : transition;
  transition_result_successor_state : Group.t;
  transition_result_commit : string;
  transition_result_previous_epoch : int64;
  transition_result_next_epoch : int64;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Invalid_epoch of string
  | Unauthorized_root
  | Authority_error of Authority.error
  | Group_error of Group.error
  | Envelope_error of Envelope.error
  | Signature_verification_failed
  | Identity_mismatch of string
  | Noncanonical_record
  | Divergent_epoch of Model.Mls_epoch_id.t option
  | Disconnected_epoch of Model.Mls_epoch_id.t

let current_schema_version = 1L
let supported_mandatory_features = 0L
let id_domain = "yeokcham:v2:mls-epoch:1\000"
let signature_domain = "yeokcham:v2:mls-epoch-signature:1\000"
let state_commitment_domain = "yeokcham:v2:mls-epoch-state:1\000"
let commit_commitment_domain = "yeokcham:v2:mls-epoch-commit:1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_payload detail -> "invalid MLS epoch transition: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported MLS epoch schema version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid MLS epoch mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported MLS epoch mandatory feature bits: %Ld"
        features
  | Invalid_epoch detail -> "invalid MLS epoch transition: " ^ detail
  | Unauthorized_root -> "MLS epoch transitions require the repository root"
  | Authority_error error -> Authority.error_to_string error
  | Group_error error -> Group.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Signature_verification_failed ->
      "MLS epoch transition root signature is invalid"
  | Identity_mismatch detail ->
      "MLS epoch transition identity mismatch: " ^ detail
  | Noncanonical_record -> "MLS epoch transition bytes are noncanonical"
  | Divergent_epoch None -> "MLS epoch history has multiple root transitions"
  | Divergent_epoch (Some id) ->
      "MLS epoch history has competing successors after "
      ^ Model.Mls_epoch_id.short_hex id
  | Disconnected_epoch id ->
      "MLS epoch history contains a disconnected transition "
      ^ Model.Mls_epoch_id.short_hex id

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
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
  | Encoding.Array _ ->
      Error (Invalid_payload (name ^ " has wrong field count"))
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

let identity name of_bytes value =
  let* value = bytes name value in
  of_bytes value
  |> Result.map_error (fun _ -> Invalid_payload (name ^ " has invalid length"))

let parent_id = function
  | Encoding.Null -> Ok None
  | Encoding.Bytes value ->
      Model.Mls_epoch_id.of_bytes value
      |> Result.map Option.some
      |> Result.map_error (fun _ ->
          Invalid_payload "MLS epoch parent ID has invalid length")
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_payload "MLS epoch parent ID must be bytes or null")

let change_code = function Member_added -> 1L | Member_removed -> 2L

let change_of_code = function
  | 1L -> Ok Member_added
  | 2L -> Ok Member_removed
  | _ -> Error (Invalid_payload "MLS epoch change kind is unsupported")

let check_epoch ~previous ~next =
  if Int64.compare previous 0L < 0 || Int64.compare next 0L < 0 then
    Error (Invalid_epoch "values must be nonnegative")
  else if not (Int64.equal next (Int64.succ previous)) then
    Error (Invalid_epoch "successor must advance exactly one MLS epoch")
  else Ok ()

let check_commitment name value =
  if String.length value = 32 then Ok ()
  else Error (Invalid_payload (name ^ " must contain 32 bytes"))

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
  then Error Unauthorized_root
  else Ok ()

let ensure_root ~authority root =
  if
    Model.Root_key_id.equal
      (Authority.root_key_id root)
      (Authority.repository_authority_root_key_id authority)
    && String.equal
         (Authority.root_public_key root)
         (Authority.repository_authority_root_public_key authority)
  then Ok ()
  else Error Unauthorized_root

let state_commitment state = digest state_commitment_domain (Group.encode state)
let commit_commitment commit = digest commit_commitment_domain commit

let unsigned_value ~repository_id ~group_id ~issuer_key_id ~parent ~change
    ~changed_device_id ~previous ~next ~predecessor_state ~successor_state
    ~commit ~successor_envelope ~mandatory_features =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
      Encoding.bytes (Model.Root_key_id.to_bytes issuer_key_id);
      (match parent with
      | None -> Encoding.null
      | Some id -> Encoding.bytes (Model.Mls_epoch_id.to_bytes id));
      Encoding.integer (change_code change);
      Encoding.bytes (Model.Device_id.to_bytes changed_device_id);
      Encoding.integer previous;
      Encoding.integer next;
      Encoding.bytes predecessor_state;
      Encoding.bytes successor_state;
      Encoding.bytes commit;
      Encoding.bytes (Envelope.encode successor_envelope);
      Encoding.integer mandatory_features;
    ]

let derive_id ~repository_id ~group_id ~issuer_key_id ~parent ~change
    ~changed_device_id ~previous ~next ~predecessor_state ~successor_state
    ~commit ~successor_envelope ~mandatory_features =
  let* value =
    unsigned_value ~repository_id ~group_id ~issuer_key_id ~parent ~change
      ~changed_device_id ~previous ~next ~predecessor_state ~successor_state
      ~commit ~successor_envelope ~mandatory_features
  in
  Model.Mls_epoch_id.of_bytes (digest id_domain (Encoding.encode value))
  |> Result.map_error (fun _ -> assert false)

let value transition =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Mls_epoch_id.to_bytes transition.epoch_record_id);
      Encoding.bytes
        (Model.Repository_id.to_bytes transition.epoch_repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes transition.epoch_group_id);
      Encoding.bytes (Model.Root_key_id.to_bytes transition.epoch_issuer_key_id);
      (match transition.epoch_parent_id with
      | None -> Encoding.null
      | Some id -> Encoding.bytes (Model.Mls_epoch_id.to_bytes id));
      Encoding.integer (change_code transition.epoch_change);
      Encoding.bytes
        (Model.Device_id.to_bytes transition.epoch_changed_device_id);
      Encoding.integer transition.epoch_previous;
      Encoding.integer transition.epoch_next;
      Encoding.bytes transition.epoch_predecessor_state_commitment;
      Encoding.bytes transition.epoch_successor_state_commitment;
      Encoding.bytes transition.epoch_commit_commitment;
      Encoding.bytes (Envelope.encode transition.epoch_successor_envelope);
      Encoding.integer transition.epoch_mandatory_features;
      Encoding.text Authority.algorithm |> Result.get_ok;
      Encoding.bytes transition.epoch_signature;
    ]

let encode transition = value transition |> Result.get_ok |> Encoding.encode

let decode ~authority encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "MLS epoch transition" 17 value in
  match values with
  | [
   version;
   id;
   repository;
   group;
   issuer;
   parent;
   kind;
   changed;
   previous;
   next;
   predecessor;
   successor;
   commit;
   envelope;
   features;
   algorithm;
   signature;
  ] ->
      let* version = integer "MLS epoch schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* record_id =
          identity "MLS epoch ID" Model.Mls_epoch_id.of_bytes id
        in
        let* repository_id =
          identity "MLS epoch repository ID" Model.Repository_id.of_bytes
            repository
        in
        let* group_id =
          identity "MLS epoch group ID" Model.Mls_group_id.of_bytes group
        in
        let* issuer_key_id =
          identity "MLS epoch issuer key ID" Model.Root_key_id.of_bytes issuer
        in
        let* parent_id = parent_id parent in
        let* kind = integer "MLS epoch change kind" kind in
        let* change = change_of_code kind in
        let* changed_device_id =
          identity "MLS epoch changed device ID" Model.Device_id.of_bytes
            changed
        in
        let* previous = integer "MLS epoch previous value" previous in
        let* next = integer "MLS epoch next value" next in
        let* () = check_epoch ~previous ~next in
        let* predecessor_state =
          bytes "MLS epoch predecessor commitment" predecessor
        in
        let* () =
          check_commitment "MLS epoch predecessor commitment" predecessor_state
        in
        let* successor_state =
          bytes "MLS epoch successor commitment" successor
        in
        let* () =
          check_commitment "MLS epoch successor commitment" successor_state
        in
        let* commit = bytes "MLS epoch commit commitment" commit in
        let* () = check_commitment "MLS epoch commit commitment" commit in
        let* envelope = bytes "MLS epoch successor envelope" envelope in
        let* successor_envelope =
          Envelope.decode envelope
          |> Result.map_error (fun error -> Envelope_error error)
        in
        let* features = integer "MLS epoch mandatory features" features in
        let* () = check_features features in
        let* () =
          if
            Int64.equal features
              (Envelope.mandatory_features successor_envelope)
          then Ok ()
          else Error (Identity_mismatch "successor envelope mandatory features")
        in
        let* algorithm = text "MLS epoch signature algorithm" algorithm in
        if not (String.equal algorithm Authority.algorithm) then
          Error (Invalid_payload "MLS epoch signature algorithm is unsupported")
        else
          let* signature = bytes "MLS epoch root signature" signature in
          let* () = ensure_authority ~authority ~repository_id ~issuer_key_id in
          let* expected_id =
            derive_id ~repository_id ~group_id ~issuer_key_id ~parent:parent_id
              ~change ~changed_device_id ~previous ~next ~predecessor_state
              ~successor_state ~commit ~successor_envelope
              ~mandatory_features:features
          in
          if not (Model.Mls_epoch_id.equal record_id expected_id) then
            Error (Identity_mismatch "derived record ID")
          else
            let* () =
              Authority.verify_root_message
                ~public_key:
                  (Authority.repository_authority_root_public_key authority)
                ~domain:signature_domain
                (Model.Mls_epoch_id.to_bytes record_id)
                ~signature
              |> Result.map_error (fun _ -> Signature_verification_failed)
            in
            let transition =
              {
                epoch_record_id = record_id;
                epoch_repository_id = repository_id;
                epoch_group_id = group_id;
                epoch_issuer_key_id = issuer_key_id;
                epoch_parent_id = parent_id;
                epoch_change = change;
                epoch_changed_device_id = changed_device_id;
                epoch_previous = previous;
                epoch_next = next;
                epoch_predecessor_state_commitment = predecessor_state;
                epoch_successor_state_commitment = successor_state;
                epoch_commit_commitment = commit;
                epoch_successor_envelope = successor_envelope;
                epoch_mandatory_features = features;
                epoch_signature = signature;
              }
            in
            if String.equal encoded (encode transition) then Ok transition
            else Error Noncanonical_record
  | _ -> assert false

let id transition = transition.epoch_record_id
let parent_id transition = transition.epoch_parent_id
let change transition = transition.epoch_change
let changed_device_id transition = transition.epoch_changed_device_id
let previous_epoch transition = transition.epoch_previous
let next_epoch transition = transition.epoch_next

let predecessor_state_commitment transition =
  transition.epoch_predecessor_state_commitment

let successor_state_commitment transition =
  transition.epoch_successor_state_commitment

let successor_envelope transition = transition.epoch_successor_envelope

let create ~authority ~root ~parent_id ~change ~changed_device_id
    ~predecessor_state ~successor_state ~commit ~previous_epoch ~next_epoch
    ~state_key ~state_nonce =
  let* () = ensure_root ~authority root in
  let repository_id = Group.repository_id predecessor_state in
  let group_id = Group.group_id predecessor_state in
  let* () =
    ensure_authority ~authority ~repository_id
      ~issuer_key_id:(Authority.root_key_id root)
  in
  let* () = check_epoch ~previous:previous_epoch ~next:next_epoch in
  if
    (not
       (Model.Repository_id.equal repository_id
          (Group.repository_id successor_state)))
    || not (Model.Mls_group_id.equal group_id (Group.group_id successor_state))
  then Error (Identity_mismatch "successor repository/group binding")
  else
    let predecessor_state = state_commitment predecessor_state in
    let successor_state_commitment = state_commitment successor_state in
    let commit = commit_commitment commit in
    let* successor_envelope =
      Group.seal_state ~key:state_key ~nonce:state_nonce successor_state
      |> Result.map_error (fun error -> Group_error error)
    in
    let mandatory_features = 0L in
    let issuer_key_id = Authority.root_key_id root in
    let* record_id =
      derive_id ~repository_id ~group_id ~issuer_key_id ~parent:parent_id
        ~change ~changed_device_id ~previous:previous_epoch ~next:next_epoch
        ~predecessor_state ~successor_state:successor_state_commitment ~commit
        ~successor_envelope ~mandatory_features
    in
    let* signature =
      Authority.sign_root_message root ~domain:signature_domain
        (Model.Mls_epoch_id.to_bytes record_id)
      |> Result.map_error (fun error -> Authority_error error)
    in
    Ok
      {
        epoch_record_id = record_id;
        epoch_repository_id = repository_id;
        epoch_group_id = group_id;
        epoch_issuer_key_id = issuer_key_id;
        epoch_parent_id = parent_id;
        epoch_change = change;
        epoch_changed_device_id = changed_device_id;
        epoch_previous = previous_epoch;
        epoch_next = next_epoch;
        epoch_predecessor_state_commitment = predecessor_state;
        epoch_successor_state_commitment = successor_state_commitment;
        epoch_commit_commitment = commit;
        epoch_successor_envelope = successor_envelope;
        epoch_mandatory_features = mandatory_features;
        epoch_signature = signature;
      }

let result ~record ~successor_state ~commit ~previous_epoch ~next_epoch =
  {
    transition_result_record = record;
    transition_result_successor_state = successor_state;
    transition_result_commit = commit;
    transition_result_previous_epoch = previous_epoch;
    transition_result_next_epoch = next_epoch;
  }

let advance_add ~runtime ~authority ~root ~parent_id ~issuer_state
    ~recipient_device_id ~state_key ~state_nonce =
  let* joined =
    Group.add_member ~runtime ~issuer_state ~recipient_device_id
    |> Result.map_error (fun error -> Group_error error)
  in
  let* record =
    create ~authority ~root ~parent_id ~change:Member_added
      ~changed_device_id:recipient_device_id ~predecessor_state:issuer_state
      ~successor_state:joined.Group.added_issuer_state
      ~commit:joined.Group.add_commit
      ~previous_epoch:joined.Group.add_previous_epoch
      ~next_epoch:joined.Group.add_next_epoch ~state_key ~state_nonce
  in
  Ok
    (result ~record ~successor_state:joined.Group.added_issuer_state
       ~commit:joined.Group.add_commit
       ~previous_epoch:joined.Group.add_previous_epoch
       ~next_epoch:joined.Group.add_next_epoch)

let advance_removal ~runtime ~authority ~root ~parent_id ~issuer_state
    ~removed_device_id ~state_key ~state_nonce =
  let* removed =
    Group.remove_member ~runtime ~issuer_state ~removed_device_id
    |> Result.map_error (fun error -> Group_error error)
  in
  let* record =
    create ~authority ~root ~parent_id ~change:Member_removed
      ~changed_device_id:removed_device_id ~predecessor_state:issuer_state
      ~successor_state:removed.Group.removed_issuer_state
      ~commit:removed.Group.removal_commit
      ~previous_epoch:removed.Group.removal_previous_epoch
      ~next_epoch:removed.Group.removal_next_epoch ~state_key ~state_nonce
  in
  Ok
    (result ~record ~successor_state:removed.Group.removed_issuer_state
       ~commit:removed.Group.removal_commit
       ~previous_epoch:removed.Group.removal_previous_epoch
       ~next_epoch:removed.Group.removal_next_epoch)

let open_successor ~runtime ~state_key transition =
  let* state =
    Group.open_state ~key:state_key transition.epoch_successor_envelope
    |> Result.map_error (fun error -> Group_error error)
  in
  if
    not
      (String.equal (state_commitment state)
         transition.epoch_successor_state_commitment)
  then Error (Identity_mismatch "successor state commitment")
  else if
    (not
       (Model.Repository_id.equal
          (Group.repository_id state)
          transition.epoch_repository_id))
    || not
         (Model.Mls_group_id.equal (Group.group_id state)
            transition.epoch_group_id)
  then Error (Identity_mismatch "successor state binding")
  else
    Group.verify ~runtime state
    |> Result.map_error (fun error -> Group_error error)
    |> Result.map (fun () -> state)

let verify_chain ~runtime ~authority ~state_key ~initial_state transitions =
  let* () =
    Group.verify ~runtime initial_state
    |> Result.map_error (fun error -> Group_error error)
  in
  let repository_id = Group.repository_id initial_state in
  let group_id = Group.group_id initial_state in
  let rec walk parent epoch state remaining used =
    let candidates =
      List.filter
        (fun transition ->
          transition.epoch_parent_id = parent
          && Int64.equal transition.epoch_previous epoch
          && String.equal transition.epoch_predecessor_state_commitment
               (state_commitment state))
        remaining
    in
    match candidates with
    | [] ->
        if List.length used = List.length transitions then Ok state
        else
          let disconnected =
            List.find
              (fun transition -> not (List.memq transition used))
              transitions
          in
          Error (Disconnected_epoch disconnected.epoch_record_id)
    | [ transition ] ->
        let* checked = decode ~authority (encode transition) in
        if
          (not
             (Model.Repository_id.equal checked.epoch_repository_id
                repository_id))
          || not (Model.Mls_group_id.equal checked.epoch_group_id group_id)
        then Error (Identity_mismatch "epoch chain repository/group")
        else
          let* successor = open_successor ~runtime ~state_key checked in
          walk (Some checked.epoch_record_id) checked.epoch_next successor
            remaining (checked :: used)
    | _ -> Error (Divergent_epoch parent)
  in
  walk None 0L initial_state transitions []
