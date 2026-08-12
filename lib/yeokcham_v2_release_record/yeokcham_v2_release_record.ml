module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Capsule = Yeokcham_v2_capsule
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record

type validation_status = Passed | Failed

type validation_evidence = {
  validation_evidence_id_ : V2_model.Validation_id.t;
  validation_evidence_snapshot_ : Capsule.snapshot_link;
  validation_evidence_check_name_ : string;
  validation_evidence_status_ : validation_status;
  validation_evidence_observed_at_ : int64;
}

type validation_evidence_link = {
  linked_validation_id : V2_model.Validation_id.t;
  linked_validation_ref : V2_model.Opaque_object_ref.t;
}

type workspace_attempt_link = {
  linked_workspace_attempt_id : V2_model.Workspace_attempt_id.t;
  linked_workspace_attempt_ref : V2_model.Opaque_object_ref.t;
}

type release_link = {
  linked_release_id : V2_model.Release_id.t;
  linked_release_ref : V2_model.Opaque_object_ref.t;
}

type release = {
  release_id_ : V2_model.Release_id.t;
  release_parents_ : release_link list;
  release_workspace_ : Workspace_record.workspace_revision_link;
  release_attempt_ : workspace_attempt_link;
  release_base_ : Capsule.snapshot_link;
  release_capsules_ : Capsule.revision_link list;
  release_resolutions_ : Workspace_record.resolution_binding list;
  release_final_snapshot_ : Capsule.snapshot_link;
  release_evidence_ : validation_evidence_link list;
  release_message_ : string option;
  release_created_at_ : int64;
}

type error =
  | Invalid_check_name of Encoding.construction_error
  | Invalid_message of Encoding.construction_error
  | Invalid_payload of string
  | Invalid_identity of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_record

let current_schema_version = 1L
let supported_mandatory_features = 0L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_check_name error ->
      "invalid V2 validation check name: "
      ^ Encoding.construction_error_to_string error
  | Invalid_message error ->
      "invalid V2 release message: "
      ^ Encoding.construction_error_to_string error
  | Invalid_payload detail -> "invalid V2 release record: " ^ detail
  | Invalid_identity detail -> "invalid V2 release identity: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 release record version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 release mandatory features: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 release mandatory features: %Ld" features
  | Noncanonical_record -> "V2 release record is not canonical"

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text field value =
  Encoding.text value
  |> Result.map_error (fun error ->
      match field with
      | "check name" -> Invalid_check_name error
      | "message" -> Invalid_message error
      | _ ->
          Invalid_payload
            (field ^ ": " ^ Encoding.construction_error_to_string error))

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      Error (Invalid_payload (name ^ " has the wrong field count"))
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

let text_value name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let decode_value encoded =
  Encoding.decode encoded
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.decode_error_to_string error))

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let validation_id_value identity =
  Encoding.bytes (V2_model.Validation_id.to_bytes identity)

let release_id_value identity =
  Encoding.bytes (V2_model.Release_id.to_bytes identity)

let workspace_id_value identity =
  Encoding.bytes (V2_model.Workspace_id.to_bytes identity)

let workspace_revision_id_value identity =
  Encoding.bytes (V2_model.Workspace_revision_id.to_bytes identity)

let workspace_attempt_id_value identity =
  Encoding.bytes (V2_model.Workspace_attempt_id.to_bytes identity)

let capsule_id_value identity =
  Encoding.bytes (V2_model.Capsule_id.to_bytes identity)

let capsule_revision_id_value identity =
  Encoding.bytes (V2_model.Capsule_revision_id.to_bytes identity)

let conflict_id_value identity =
  Encoding.bytes (V2_model.Conflict_id.to_bytes identity)

let resolution_id_value identity =
  Encoding.bytes (V2_model.Resolution_id.to_bytes identity)

let snapshot_id_value identity =
  Encoding.bytes (Yeokcham_id.Snapshot_id.to_bytes identity)

let opaque_value identity =
  Encoding.bytes (V2_model.Opaque_object_ref.to_bytes identity)

let validation_id_of_value value =
  let* value = bytes "validation ID" value in
  V2_model.Validation_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let release_id_of_value value =
  let* value = bytes "release ID" value in
  V2_model.Release_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let workspace_id_of_value value =
  let* value = bytes "workspace ID" value in
  V2_model.Workspace_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let workspace_revision_id_of_value value =
  let* value = bytes "workspace revision ID" value in
  V2_model.Workspace_revision_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let workspace_attempt_id_of_value value =
  let* value = bytes "workspace attempt ID" value in
  V2_model.Workspace_attempt_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let capsule_id_of_value value =
  let* value = bytes "capsule ID" value in
  V2_model.Capsule_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let capsule_revision_id_of_value value =
  let* value = bytes "capsule revision ID" value in
  V2_model.Capsule_revision_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let conflict_id_of_value value =
  let* value = bytes "conflict ID" value in
  V2_model.Conflict_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let resolution_id_of_value value =
  let* value = bytes "resolution ID" value in
  V2_model.Resolution_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let snapshot_id_of_value value =
  let* value = bytes "snapshot ID" value in
  Yeokcham_id.Snapshot_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (Yeokcham_id.parse_error_to_string error))

let opaque_of_value value =
  let* value = bytes "opaque object reference" value in
  V2_model.Opaque_object_ref.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (V2_model.identity_error_to_string error))

let snapshot_link_value (link : Capsule.snapshot_link) =
  array
    [
      snapshot_id_value link.Capsule.snapshot_id;
      opaque_value link.Capsule.snapshot_ref;
    ]
  |> Result.get_ok

let snapshot_link_identity_value (link : Capsule.snapshot_link) =
  snapshot_id_value link.Capsule.snapshot_id

let snapshot_link_of_value value =
  let* values = fields "release snapshot link" 2 value in
  match values with
  | [ snapshot_id; snapshot_ref ] ->
      let* snapshot_id = snapshot_id_of_value snapshot_id in
      let* snapshot_ref = opaque_of_value snapshot_ref in
      Ok { Capsule.snapshot_id; snapshot_ref }
  | _ -> assert false

let revision_link_value link =
  array
    [
      capsule_id_value (Capsule.revision_link_capsule_id link);
      capsule_revision_id_value (Capsule.revision_link_revision_id link);
      opaque_value (Capsule.revision_link_ref link);
    ]
  |> Result.get_ok

let revision_link_identity_value link =
  array
    [
      capsule_id_value (Capsule.revision_link_capsule_id link);
      capsule_revision_id_value (Capsule.revision_link_revision_id link);
    ]
  |> Result.get_ok

let revision_link_of_value value =
  let* values = fields "release capsule revision link" 3 value in
  match values with
  | [ capsule_id; revision_id; revision_ref ] ->
      let* capsule_id = capsule_id_of_value capsule_id in
      let* revision_id = capsule_revision_id_of_value revision_id in
      let* revision_ref = opaque_of_value revision_ref in
      Ok (Capsule.make_revision_link ~capsule_id ~revision_id ~revision_ref)
  | _ -> assert false

let workspace_revision_link_value link =
  array
    [
      workspace_id_value
        (Workspace_record.workspace_revision_link_workspace_id link);
      workspace_revision_id_value
        (Workspace_record.workspace_revision_link_revision_id link);
      opaque_value (Workspace_record.workspace_revision_link_ref link);
    ]
  |> Result.get_ok

let workspace_revision_link_identity_value link =
  array
    [
      workspace_id_value
        (Workspace_record.workspace_revision_link_workspace_id link);
      workspace_revision_id_value
        (Workspace_record.workspace_revision_link_revision_id link);
    ]
  |> Result.get_ok

let workspace_revision_link_of_value value =
  let* values = fields "release workspace revision link" 3 value in
  match values with
  | [ workspace_id; revision_id; revision_ref ] ->
      let* workspace_id = workspace_id_of_value workspace_id in
      let* revision_id = workspace_revision_id_of_value revision_id in
      let* revision_ref = opaque_of_value revision_ref in
      Ok
        (Workspace_record.make_workspace_revision_link ~workspace_id
           ~revision_id ~revision_ref)
  | _ -> assert false

let conflict_link_value link =
  array
    [
      conflict_id_value (Workspace_record.conflict_link_id link);
      opaque_value (Workspace_record.conflict_link_ref link);
    ]
  |> Result.get_ok

let conflict_link_identity_value link =
  conflict_id_value (Workspace_record.conflict_link_id link)

let conflict_link_of_value value =
  let* values = fields "release conflict link" 2 value in
  match values with
  | [ id; object_ref ] ->
      let* id = conflict_id_of_value id in
      let* object_ref = opaque_of_value object_ref in
      Ok (Workspace_record.make_conflict_link ~id ~object_ref)
  | _ -> assert false

let resolution_link_value link =
  array
    [
      resolution_id_value (Workspace_record.resolution_link_id link);
      opaque_value (Workspace_record.resolution_link_ref link);
    ]
  |> Result.get_ok

let resolution_link_identity_value link =
  resolution_id_value (Workspace_record.resolution_link_id link)

let resolution_link_of_value value =
  let* values = fields "release resolution link" 2 value in
  match values with
  | [ id; object_ref ] ->
      let* id = resolution_id_of_value id in
      let* object_ref = opaque_of_value object_ref in
      Ok (Workspace_record.make_resolution_link ~id ~object_ref)
  | _ -> assert false

let resolution_binding_value binding =
  array
    [
      conflict_link_value (Workspace_record.resolution_binding_conflict binding);
      resolution_link_value
        (Workspace_record.resolution_binding_resolution binding);
    ]
  |> Result.get_ok

let resolution_binding_identity_value binding =
  array
    [
      conflict_link_identity_value
        (Workspace_record.resolution_binding_conflict binding);
      resolution_link_identity_value
        (Workspace_record.resolution_binding_resolution binding);
    ]
  |> Result.get_ok

let resolution_binding_of_value value =
  let* values = fields "release resolution binding" 2 value in
  match values with
  | [ conflict; resolution ] ->
      let* conflict = conflict_link_of_value conflict in
      let* resolution = resolution_link_of_value resolution in
      Ok (Workspace_record.make_resolution_binding ~conflict ~resolution)
  | _ -> assert false

let make_validation_evidence_link ~id ~object_ref =
  { linked_validation_id = id; linked_validation_ref = object_ref }

let validation_evidence_link_id link = link.linked_validation_id
let validation_evidence_link_ref link = link.linked_validation_ref

let validation_evidence_link_value link =
  array
    [
      validation_id_value link.linked_validation_id;
      opaque_value link.linked_validation_ref;
    ]
  |> Result.get_ok

let validation_evidence_link_of_value value =
  let* values = fields "validation evidence link" 2 value in
  match values with
  | [ id; object_ref ] ->
      let* id = validation_id_of_value id in
      let* object_ref = opaque_of_value object_ref in
      Ok (make_validation_evidence_link ~id ~object_ref)
  | _ -> assert false

let make_workspace_attempt_link ~id ~object_ref =
  {
    linked_workspace_attempt_id = id;
    linked_workspace_attempt_ref = object_ref;
  }

let workspace_attempt_link_id link = link.linked_workspace_attempt_id
let workspace_attempt_link_ref link = link.linked_workspace_attempt_ref

let workspace_attempt_link_value link =
  array
    [
      workspace_attempt_id_value link.linked_workspace_attempt_id;
      opaque_value link.linked_workspace_attempt_ref;
    ]
  |> Result.get_ok

let workspace_attempt_link_identity_value link =
  workspace_attempt_id_value link.linked_workspace_attempt_id

let workspace_attempt_link_of_value value =
  let* values = fields "workspace attempt link" 2 value in
  match values with
  | [ id; object_ref ] ->
      let* id = workspace_attempt_id_of_value id in
      let* object_ref = opaque_of_value object_ref in
      Ok (make_workspace_attempt_link ~id ~object_ref)
  | _ -> assert false

let make_release_link ~id ~object_ref =
  { linked_release_id = id; linked_release_ref = object_ref }

let release_link_id link = link.linked_release_id
let release_link_ref link = link.linked_release_ref

let release_link_value link =
  array
    [
      release_id_value link.linked_release_id;
      opaque_value link.linked_release_ref;
    ]
  |> Result.get_ok

let release_link_identity_value link = release_id_value link.linked_release_id

let release_link_of_value value =
  let* values = fields "release parent link" 2 value in
  match values with
  | [ id; object_ref ] ->
      let* id = release_id_of_value id in
      let* object_ref = opaque_of_value object_ref in
      Ok (make_release_link ~id ~object_ref)
  | _ -> assert false

let validation_status_value = function
  | Passed -> Encoding.integer 0L
  | Failed -> Encoding.integer 1L

let validation_status_of_value = function
  | Encoding.Integer 0L -> Ok Passed
  | Encoding.Integer 1L -> Ok Failed
  | Encoding.Integer _ -> Error (Invalid_payload "unknown validation status")
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "validation status must be an integer")

let check_name_value check_name =
  if String.length check_name = 0 then
    Error (Invalid_payload "validation check name must not be empty")
  else text "check name" check_name

let validation_identity_bytes ~snapshot ~check_name ~status =
  array
    [
      Encoding.integer current_schema_version;
      snapshot_link_identity_value snapshot;
      check_name_value check_name |> Result.get_ok;
      validation_status_value status;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_validation_id ~snapshot ~check_name ~status =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:validation-evidence:v1\000"
  in
  let context =
    Hash.feed_string context
      (validation_identity_bytes ~snapshot ~check_name ~status)
  in
  Hash.get context |> Hash.to_raw_string |> V2_model.Validation_id.of_bytes
  |> Result.get_ok

let make_validation_evidence ~snapshot ~check_name ~status ~observed_at =
  let* _ = check_name_value check_name in
  let validation_evidence_id_ =
    derive_validation_id ~snapshot ~check_name ~status
  in
  Ok
    {
      validation_evidence_id_;
      validation_evidence_snapshot_ = snapshot;
      validation_evidence_check_name_ = check_name;
      validation_evidence_status_ = status;
      validation_evidence_observed_at_ = observed_at;
    }

let validation_evidence_id evidence = evidence.validation_evidence_id_

let validation_evidence_snapshot evidence =
  evidence.validation_evidence_snapshot_

let validation_evidence_check_name evidence =
  evidence.validation_evidence_check_name_

let validation_evidence_status evidence = evidence.validation_evidence_status_

let validation_evidence_observed_at evidence =
  evidence.validation_evidence_observed_at_

let encode_validation_evidence evidence =
  array
    [
      Encoding.integer current_schema_version;
      validation_id_value evidence.validation_evidence_id_;
      snapshot_link_value evidence.validation_evidence_snapshot_;
      check_name_value evidence.validation_evidence_check_name_ |> Result.get_ok;
      validation_status_value evidence.validation_evidence_status_;
      Encoding.integer evidence.validation_evidence_observed_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_validation_evidence encoded =
  let* value = decode_value encoded in
  let* values = fields "validation evidence" 7 value in
  match values with
  | [ version; id; snapshot; check_name; status; observed_at; features ] ->
      let* version = integer "validation evidence schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = validation_id_of_value id in
        let* snapshot = snapshot_link_of_value snapshot in
        let* check_name = text_value "validation check name" check_name in
        let* status = validation_status_of_value status in
        let* observed_at = integer "validation observation time" observed_at in
        let* features = integer "validation mandatory features" features in
        let* () = check_features features in
        let* evidence =
          make_validation_evidence ~snapshot ~check_name ~status ~observed_at
        in
        if
          not
            (V2_model.Validation_id.equal id (validation_evidence_id evidence))
        then Error (Invalid_identity "validation logical identity mismatch")
        else if String.equal encoded (encode_validation_evidence evidence) then
          Ok evidence
        else Error Noncanonical_record
  | _ -> assert false

let compare_validation_evidence_link left right =
  V2_model.Validation_id.compare left.linked_validation_id
    right.linked_validation_id

let compare_resolution_binding left right =
  V2_model.Conflict_id.compare
    (Workspace_record.conflict_link_id
       (Workspace_record.resolution_binding_conflict left))
    (Workspace_record.conflict_link_id
       (Workspace_record.resolution_binding_conflict right))

let strict_sorted compare values =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) -> compare left right < 0 && loop rest
  in
  loop values

let unique compare values =
  let rec loop = function
    | [] -> true
    | value :: rest ->
        (not (List.exists (fun other -> compare value other = 0) rest))
        && loop rest
  in
  loop values

let compare_release_link left right =
  V2_model.Release_id.compare left.linked_release_id right.linked_release_id

let compare_capsule_revision left right =
  let compared =
    V2_model.Capsule_id.compare
      (Capsule.revision_link_capsule_id left)
      (Capsule.revision_link_capsule_id right)
  in
  if Int.equal compared 0 then
    V2_model.Capsule_revision_id.compare
      (Capsule.revision_link_revision_id left)
      (Capsule.revision_link_revision_id right)
  else compared

let release_identity_bytes ~parents ~workspace ~attempt ~base ~capsules
    ~resolutions ~final_snapshot ~message =
  let message =
    match message with
    | None -> Encoding.null
    | Some value -> text "message" value |> Result.get_ok
  in
  array
    [
      Encoding.integer current_schema_version;
      Encoding.array (List.map release_link_identity_value parents)
      |> Result.get_ok;
      workspace_revision_link_identity_value workspace;
      workspace_attempt_link_identity_value attempt;
      snapshot_link_identity_value base;
      Encoding.array (List.map revision_link_identity_value capsules)
      |> Result.get_ok;
      Encoding.array (List.map resolution_binding_identity_value resolutions)
      |> Result.get_ok;
      snapshot_link_identity_value final_snapshot;
      message;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_release_id ~parents ~workspace ~attempt ~base ~capsules ~resolutions
    ~final_snapshot ~message =
  let context = Hash.feed_string Hash.empty "yeokcham:v2:release:v1\000" in
  let context =
    Hash.feed_string context
      (release_identity_bytes ~parents ~workspace ~attempt ~base ~capsules
         ~resolutions ~final_snapshot ~message)
  in
  Hash.get context |> Hash.to_raw_string |> V2_model.Release_id.of_bytes
  |> Result.get_ok

let valid_release_content ~parents ~capsules ~resolutions ~evidence ~id =
  evidence <> []
  && unique compare_release_link parents
  && unique compare_capsule_revision capsules
  && strict_sorted compare_resolution_binding resolutions
  && strict_sorted compare_validation_evidence_link evidence
  && not
       (List.exists
          (fun parent -> V2_model.Release_id.equal parent.linked_release_id id)
          parents)

let make_release ~parents ~workspace ~attempt ~base ~capsules ~resolutions
    ~final_snapshot ~evidence ~message ~created_at =
  let* () =
    match message with
    | None -> Ok ()
    | Some value -> text "message" value |> Result.map (fun _ -> ())
  in
  let resolutions = List.sort compare_resolution_binding resolutions in
  let evidence = List.sort compare_validation_evidence_link evidence in
  let id =
    derive_release_id ~parents ~workspace ~attempt ~base ~capsules ~resolutions
      ~final_snapshot ~message
  in
  if not (valid_release_content ~parents ~capsules ~resolutions ~evidence ~id)
  then
    Error
      (Invalid_payload
         "release evidence is missing or release links are duplicate or \
          noncanonical")
  else
    Ok
      {
        release_id_ = id;
        release_parents_ = parents;
        release_workspace_ = workspace;
        release_attempt_ = attempt;
        release_base_ = base;
        release_capsules_ = capsules;
        release_resolutions_ = resolutions;
        release_final_snapshot_ = final_snapshot;
        release_evidence_ = evidence;
        release_message_ = message;
        release_created_at_ = created_at;
      }

let release_id release = release.release_id_
let release_parents release = release.release_parents_
let release_workspace release = release.release_workspace_
let release_attempt release = release.release_attempt_
let release_base release = release.release_base_
let release_capsules release = release.release_capsules_
let release_resolutions release = release.release_resolutions_
let release_final_snapshot release = release.release_final_snapshot_
let release_evidence release = release.release_evidence_
let release_message release = release.release_message_
let release_created_at release = release.release_created_at_

let encode_release release =
  let message =
    match release.release_message_ with
    | None -> Encoding.null
    | Some value -> text "message" value |> Result.get_ok
  in
  array
    [
      Encoding.integer current_schema_version;
      release_id_value release.release_id_;
      Encoding.array (List.map release_link_value release.release_parents_)
      |> Result.get_ok;
      workspace_revision_link_value release.release_workspace_;
      workspace_attempt_link_value release.release_attempt_;
      snapshot_link_value release.release_base_;
      Encoding.array (List.map revision_link_value release.release_capsules_)
      |> Result.get_ok;
      Encoding.array
        (List.map resolution_binding_value release.release_resolutions_)
      |> Result.get_ok;
      snapshot_link_value release.release_final_snapshot_;
      Encoding.array
        (List.map validation_evidence_link_value release.release_evidence_)
      |> Result.get_ok;
      message;
      Encoding.integer release.release_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let list_of_value name decode = function
  | Encoding.Array values ->
      let rec collect reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* decoded = decode value in
            collect (decoded :: reversed) rest
      in
      collect [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let optional_message = function
  | Encoding.Null -> Ok None
  | Encoding.Text value -> Ok (Some value)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_payload "release message must be text or null")

let decode_release encoded =
  let* value = decode_value encoded in
  let* values = fields "release" 13 value in
  match values with
  | [
   version;
   id;
   parents;
   workspace;
   attempt;
   base;
   capsules;
   resolutions;
   final_snapshot;
   evidence;
   message;
   created_at;
   features;
  ] ->
      let* version = integer "release schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = release_id_of_value id in
        let* parents =
          list_of_value "release parents" release_link_of_value parents
        in
        let* workspace = workspace_revision_link_of_value workspace in
        let* attempt = workspace_attempt_link_of_value attempt in
        let* base = snapshot_link_of_value base in
        let* capsules =
          list_of_value "release capsules" revision_link_of_value capsules
        in
        let* resolutions =
          list_of_value "release resolutions" resolution_binding_of_value
            resolutions
        in
        let* final_snapshot = snapshot_link_of_value final_snapshot in
        let* evidence =
          list_of_value "release evidence" validation_evidence_link_of_value
            evidence
        in
        let* message = optional_message message in
        let* created_at = integer "release creation time" created_at in
        let* features = integer "release mandatory features" features in
        let* () = check_features features in
        let* release =
          make_release ~parents ~workspace ~attempt ~base ~capsules ~resolutions
            ~final_snapshot ~evidence ~message ~created_at
        in
        if not (V2_model.Release_id.equal id (release_id release)) then
          Error (Invalid_identity "release logical identity mismatch")
        else if String.equal encoded (encode_release release) then Ok release
        else Error Noncanonical_record
  | _ -> assert false
