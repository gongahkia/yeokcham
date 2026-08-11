module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace

type workspace = {
  workspace_id_ : V2_model.Workspace_id.t;
  workspace_title_ : string;
  workspace_description_ : string;
  workspace_created_at_ : int64;
}

type workspace_revision_link = {
  linked_workspace_id : V2_model.Workspace_id.t;
  linked_workspace_revision_id : V2_model.Workspace_revision_id.t;
  linked_workspace_revision_ref : V2_model.Opaque_object_ref.t;
}

type conflict_link = {
  linked_conflict_id : V2_model.Conflict_id.t;
  linked_conflict_ref : V2_model.Opaque_object_ref.t;
}

type resolution_link = {
  linked_resolution_id : V2_model.Resolution_id.t;
  linked_resolution_ref : V2_model.Opaque_object_ref.t;
}

type resolution_binding = {
  binding_conflict : conflict_link;
  binding_resolution : resolution_link;
}

type workspace_revision = {
  workspace_revision_id_ : V2_model.Workspace_revision_id.t;
  workspace_revision_workspace_id_ : V2_model.Workspace_id.t;
  workspace_revision_workspace_ref_ : V2_model.Opaque_object_ref.t;
  workspace_revision_parent_ : workspace_revision_link option;
  workspace_revision_base_ : Capsule.snapshot_link;
  workspace_revision_selected_ : Capsule.revision_link list;
  workspace_revision_precedence_ : Workspace.precedence list;
  workspace_revision_resolved_order_ : Capsule.revision_link list;
  workspace_revision_resolutions_ : resolution_binding list;
  workspace_revision_created_at_ : int64;
}

type conflict = {
  conflict_id_ : V2_model.Conflict_id.t;
  conflict_workspace_link_ : workspace_revision_link;
  conflict_attempt_id_ : V2_model.Workspace_attempt_id.t;
  conflict_revision_link_ : Capsule.revision_link;
  conflict_operation_index_ : int;
  conflict_paths_ : Model.Path.t list;
  conflict_cause_ : Model.transition_error;
  conflict_created_at_ : int64;
}

type resolution_action =
  | Skip_operation of {
      revision : Capsule.revision_link;
      operation_index : int;
    }

type resolution = {
  resolution_id_ : V2_model.Resolution_id.t;
  resolution_conflict_link_ : conflict_link;
  resolution_workspace_link_ : workspace_revision_link;
  resolution_action_ : resolution_action;
  resolution_created_at_ : int64;
}

type attempt_outcome =
  | Attempt_applied_exactly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Attempt_skipped_explicitly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Attempt_conflict of conflict_link
  | Attempt_blocked_by_conflict of {
      revision : Capsule.revision_link;
      operation_index : int;
      blocked_by : conflict_link;
    }

type workspace_attempt = {
  attempt_id_ : V2_model.Workspace_attempt_id.t;
  attempt_workspace_link_ : workspace_revision_link;
  attempt_base_ : Capsule.snapshot_link;
  attempt_ordered_ : Capsule.revision_link list;
  attempt_resulting_snapshot_ : Capsule.snapshot_link;
  attempt_outcomes_ : attempt_outcome list;
  attempt_conflicts_ : conflict_link list;
  attempt_created_at_ : int64;
}

type error =
  | Invalid_title of Encoding.construction_error
  | Invalid_description of Encoding.construction_error
  | Invalid_payload of string
  | Invalid_identity of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_record
  | Invalid_resolution_target

let current_schema_version = 1L
let supported_mandatory_features = 0L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_title error ->
      "invalid workspace title: " ^ Encoding.construction_error_to_string error
  | Invalid_description error ->
      "invalid workspace description: "
      ^ Encoding.construction_error_to_string error
  | Invalid_payload detail -> "invalid V2 workspace record: " ^ detail
  | Invalid_identity detail -> "invalid V2 workspace record identity: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 workspace record version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 workspace mandatory features: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 workspace mandatory features: %Ld" features
  | Noncanonical_record -> "V2 workspace record is not canonical"
  | Invalid_resolution_target ->
      "skip resolution does not name the exact conflict operation"

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text field value =
  Encoding.text value
  |> Result.map_error (fun error ->
      match field with
      | "title" -> Invalid_title error
      | "description" -> Invalid_description error
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

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let decode_value encoded =
  Encoding.decode encoded
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.decode_error_to_string error))

let workspace_id_value identity =
  Encoding.bytes (V2_model.Workspace_id.to_bytes identity)

let workspace_revision_id_value identity =
  Encoding.bytes (V2_model.Workspace_revision_id.to_bytes identity)

let workspace_attempt_id_value identity =
  Encoding.bytes (V2_model.Workspace_attempt_id.to_bytes identity)

let conflict_id_value identity =
  Encoding.bytes (V2_model.Conflict_id.to_bytes identity)

let resolution_id_value identity =
  Encoding.bytes (V2_model.Resolution_id.to_bytes identity)

let opaque_value identity =
  Encoding.bytes (V2_model.Opaque_object_ref.to_bytes identity)

let capsule_id_value identity =
  Encoding.bytes (V2_model.Capsule_id.to_bytes identity)

let capsule_revision_id_value identity =
  Encoding.bytes (V2_model.Capsule_revision_id.to_bytes identity)

let snapshot_id_value identity =
  Encoding.bytes (Yeokcham_id.Snapshot_id.to_bytes identity)

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

let opaque_of_value value =
  let* value = bytes "opaque object reference" value in
  V2_model.Opaque_object_ref.of_bytes value
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

let snapshot_id_of_value value =
  let* value = bytes "snapshot ID" value in
  Yeokcham_id.Snapshot_id.of_bytes value
  |> Result.map_error (fun error ->
      Invalid_identity (Yeokcham_id.parse_error_to_string error))

let snapshot_link_value (link : Capsule.snapshot_link) =
  array
    [
      snapshot_id_value link.Capsule.snapshot_id;
      opaque_value link.Capsule.snapshot_ref;
    ]
  |> Result.get_ok

let snapshot_link_of_value value =
  let* values = fields "workspace snapshot link" 2 value in
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
  let* values = fields "workspace capsule revision link" 3 value in
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
      workspace_id_value link.linked_workspace_id;
      workspace_revision_id_value link.linked_workspace_revision_id;
      opaque_value link.linked_workspace_revision_ref;
    ]
  |> Result.get_ok

let workspace_revision_link_identity_value link =
  array
    [
      workspace_id_value link.linked_workspace_id;
      workspace_revision_id_value link.linked_workspace_revision_id;
    ]
  |> Result.get_ok

let workspace_revision_link_of_value value =
  let* values = fields "workspace revision link" 3 value in
  match values with
  | [ workspace_id; revision_id; revision_ref ] ->
      let* linked_workspace_id = workspace_id_of_value workspace_id in
      let* linked_workspace_revision_id =
        workspace_revision_id_of_value revision_id
      in
      let* linked_workspace_revision_ref = opaque_of_value revision_ref in
      Ok
        {
          linked_workspace_id;
          linked_workspace_revision_id;
          linked_workspace_revision_ref;
        }
  | _ -> assert false

let conflict_link_value link =
  array
    [
      conflict_id_value link.linked_conflict_id;
      opaque_value link.linked_conflict_ref;
    ]
  |> Result.get_ok

let conflict_link_identity_value link =
  conflict_id_value link.linked_conflict_id

let conflict_link_of_value value =
  let* values = fields "workspace conflict link" 2 value in
  match values with
  | [ conflict_id; conflict_ref ] ->
      let* linked_conflict_id = conflict_id_of_value conflict_id in
      let* linked_conflict_ref = opaque_of_value conflict_ref in
      Ok { linked_conflict_id; linked_conflict_ref }
  | _ -> assert false

let resolution_link_value link =
  array
    [
      resolution_id_value link.linked_resolution_id;
      opaque_value link.linked_resolution_ref;
    ]
  |> Result.get_ok

let resolution_link_identity_value link =
  resolution_id_value link.linked_resolution_id

let resolution_link_of_value value =
  let* values = fields "workspace resolution link" 2 value in
  match values with
  | [ resolution_id; resolution_ref ] ->
      let* linked_resolution_id = resolution_id_of_value resolution_id in
      let* linked_resolution_ref = opaque_of_value resolution_ref in
      Ok { linked_resolution_id; linked_resolution_ref }
  | _ -> assert false

let make_workspace_revision_link ~workspace_id ~revision_id ~revision_ref =
  {
    linked_workspace_id = workspace_id;
    linked_workspace_revision_id = revision_id;
    linked_workspace_revision_ref = revision_ref;
  }

let workspace_revision_link_workspace_id link = link.linked_workspace_id
let workspace_revision_link_revision_id link = link.linked_workspace_revision_id
let workspace_revision_link_ref link = link.linked_workspace_revision_ref

let make_conflict_link ~id ~object_ref =
  { linked_conflict_id = id; linked_conflict_ref = object_ref }

let conflict_link_id link = link.linked_conflict_id
let conflict_link_ref link = link.linked_conflict_ref

let make_resolution_link ~id ~object_ref =
  { linked_resolution_id = id; linked_resolution_ref = object_ref }

let resolution_link_id link = link.linked_resolution_id
let resolution_link_ref link = link.linked_resolution_ref

let make_resolution_binding ~conflict ~resolution =
  { binding_conflict = conflict; binding_resolution = resolution }

let resolution_binding_conflict binding = binding.binding_conflict
let resolution_binding_resolution binding = binding.binding_resolution

let make_workspace ~id ~title ~description ~created_at =
  let* _ = text "title" title in
  let* _ = text "description" description in
  Ok
    {
      workspace_id_ = id;
      workspace_title_ = title;
      workspace_description_ = description;
      workspace_created_at_ = created_at;
    }

let workspace_id (workspace : workspace) = workspace.workspace_id_
let workspace_title (workspace : workspace) = workspace.workspace_title_

let workspace_description (workspace : workspace) =
  workspace.workspace_description_

let workspace_created_at (workspace : workspace) =
  workspace.workspace_created_at_

let encode_workspace (workspace : workspace) =
  array
    [
      Encoding.integer current_schema_version;
      workspace_id_value workspace.workspace_id_;
      text "title" workspace.workspace_title_ |> Result.get_ok;
      text "description" workspace.workspace_description_ |> Result.get_ok;
      Encoding.integer workspace.workspace_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_workspace encoded =
  let* value = decode_value encoded in
  let* values = fields "workspace" 6 value in
  match values with
  | [ version; id; title; description; created_at; features ] ->
      let* version = integer "workspace schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = workspace_id_of_value id in
        let* title = text_value "workspace title" title in
        let* description = text_value "workspace description" description in
        let* created_at = integer "workspace creation time" created_at in
        let* features = integer "workspace mandatory features" features in
        let* () = check_features features in
        let* workspace = make_workspace ~id ~title ~description ~created_at in
        if String.equal encoded (encode_workspace workspace) then Ok workspace
        else Error Noncanonical_record
  | _ -> assert false

let compare_revision_link left right =
  let compared =
    V2_model.Capsule_revision_id.compare
      (Capsule.revision_link_revision_id left)
      (Capsule.revision_link_revision_id right)
  in
  if Int.equal compared 0 then
    V2_model.Capsule_id.compare
      (Capsule.revision_link_capsule_id left)
      (Capsule.revision_link_capsule_id right)
  else compared

let compare_precedence left right =
  let compared =
    V2_model.Capsule_revision_id.compare left.Workspace.before
      right.Workspace.before
  in
  if Int.equal compared 0 then
    V2_model.Capsule_revision_id.compare left.Workspace.after
      right.Workspace.after
  else compared

let compare_binding left right =
  V2_model.Conflict_id.compare left.binding_conflict.linked_conflict_id
    right.binding_conflict.linked_conflict_id

let strict_sorted compare values =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) -> compare left right < 0 && loop rest
  in
  loop values

let revision_link_list_value links =
  Encoding.array (List.map revision_link_value links) |> Result.get_ok

let revision_link_identity_list_value links =
  Encoding.array (List.map revision_link_identity_value links) |> Result.get_ok

let revision_link_list_of_value name value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* link = revision_link_of_value value in
            decode (link :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let precedence_value edge =
  array
    [
      capsule_revision_id_value edge.Workspace.before;
      capsule_revision_id_value edge.Workspace.after;
    ]
  |> Result.get_ok

let precedence_list_value edges =
  Encoding.array (List.map precedence_value edges) |> Result.get_ok

let precedence_of_value value =
  let* values = fields "workspace precedence edge" 2 value in
  match values with
  | [ before; after ] ->
      let* before = capsule_revision_id_of_value before in
      let* after = capsule_revision_id_of_value after in
      Ok { Workspace.before; after }
  | _ -> assert false

let precedence_list_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* edge = precedence_of_value value in
            decode (edge :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace precedence must be an array")

let binding_value binding =
  array
    [
      conflict_link_value binding.binding_conflict;
      resolution_link_value binding.binding_resolution;
    ]
  |> Result.get_ok

let binding_identity_value binding =
  array
    [
      conflict_link_identity_value binding.binding_conflict;
      resolution_link_identity_value binding.binding_resolution;
    ]
  |> Result.get_ok

let binding_of_value value =
  let* values = fields "workspace resolution binding" 2 value in
  match values with
  | [ conflict; resolution ] ->
      let* binding_conflict = conflict_link_of_value conflict in
      let* binding_resolution = resolution_link_of_value resolution in
      Ok { binding_conflict; binding_resolution }
  | _ -> assert false

let binding_list_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* binding = binding_of_value value in
            decode (binding :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace resolution bindings must be an array")

let workspace_revision_identity_bytes ~workspace ~parent ~base ~selected
    ~precedence ~resolved_order ~resolutions =
  let parent =
    match parent with
    | None -> Encoding.null
    | Some parent -> workspace_revision_link_identity_value parent
  in
  array
    [
      Encoding.integer current_schema_version;
      workspace_id_value workspace;
      parent;
      snapshot_id_value base.Capsule.snapshot_id;
      revision_link_identity_list_value selected;
      Encoding.array
        (List.map
           (fun edge ->
             array
               [
                 capsule_revision_id_value edge.Workspace.before;
                 capsule_revision_id_value edge.Workspace.after;
               ]
             |> Result.get_ok)
           precedence)
      |> Result.get_ok;
      revision_link_identity_list_value resolved_order;
      Encoding.array (List.map binding_identity_value resolutions)
      |> Result.get_ok;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_workspace_revision_id ~workspace ~parent ~base ~selected ~precedence
    ~resolved_order ~resolutions =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:workspace-revision:v1\000"
  in
  let context =
    Hash.feed_string context
      (workspace_revision_identity_bytes ~workspace ~parent ~base ~selected
         ~precedence ~resolved_order ~resolutions)
  in
  Hash.get context |> Hash.to_raw_string
  |> V2_model.Workspace_revision_id.of_bytes |> Result.get_ok

let validate_ordered_selection selected resolved_order =
  let same left right =
    V2_model.Capsule_id.equal
      (Capsule.revision_link_capsule_id left)
      (Capsule.revision_link_capsule_id right)
    && V2_model.Capsule_revision_id.equal
         (Capsule.revision_link_revision_id left)
         (Capsule.revision_link_revision_id right)
    && V2_model.Opaque_object_ref.equal
         (Capsule.revision_link_ref left)
         (Capsule.revision_link_ref right)
  in
  List.length selected = List.length resolved_order
  && List.for_all (fun link -> List.exists (same link) resolved_order) selected

let selected_revision_ids_are_unique selected =
  let ids =
    List.map Capsule.revision_link_revision_id selected
    |> List.sort_uniq V2_model.Capsule_revision_id.compare
  in
  Int.equal (List.length ids) (List.length selected)

let selected_revision_ids selected =
  List.map Capsule.revision_link_revision_id selected

let precedence_endpoints_are_selected selected precedence =
  let ids = selected_revision_ids selected in
  List.for_all
    (fun edge ->
      (not
         (V2_model.Capsule_revision_id.equal edge.Workspace.before
            edge.Workspace.after))
      && List.exists
           (V2_model.Capsule_revision_id.equal edge.Workspace.before)
           ids
      && List.exists
           (V2_model.Capsule_revision_id.equal edge.Workspace.after)
           ids)
    precedence

let precedence_is_acyclic selected precedence =
  let successors id =
    List.filter_map
      (fun edge ->
        if V2_model.Capsule_revision_id.equal edge.Workspace.before id then
          Some edge.Workspace.after
        else None)
      precedence
  in
  let rec visit visiting visited id =
    if List.exists (V2_model.Capsule_revision_id.equal id) visiting then false
    else if List.exists (V2_model.Capsule_revision_id.equal id) visited then
      true
    else
      let visiting = id :: visiting in
      List.for_all (visit visiting (id :: visited)) (successors id)
  in
  List.for_all (visit [] []) (selected_revision_ids selected)

let resolved_order_respects_precedence resolved_order precedence =
  let index id =
    List.find_index
      (fun link ->
        V2_model.Capsule_revision_id.equal
          (Capsule.revision_link_revision_id link)
          id)
      resolved_order
  in
  List.for_all
    (fun edge ->
      match (index edge.Workspace.before, index edge.Workspace.after) with
      | Some before, Some after -> before < after
      | None, _ | _, None -> false)
    precedence

let valid_workspace_revision_content selected precedence resolved_order =
  selected_revision_ids_are_unique selected
  && precedence_endpoints_are_selected selected precedence
  && precedence_is_acyclic selected precedence
  && validate_ordered_selection selected resolved_order
  && resolved_order_respects_precedence resolved_order precedence

let make_workspace_revision ~workspace ~workspace_ref ~parent ~base ~selected
    ~precedence ~resolved_order ~resolutions ~created_at =
  let selected = List.sort compare_revision_link selected in
  let precedence = List.sort compare_precedence precedence in
  let resolutions = List.sort compare_binding resolutions in
  if
    (not (strict_sorted compare_revision_link selected))
    || (not (strict_sorted compare_precedence precedence))
    || (not (strict_sorted compare_binding resolutions))
    || not (valid_workspace_revision_content selected precedence resolved_order)
  then
    Error
      (Invalid_payload "workspace revision has duplicate or mismatched links")
  else
    let id =
      derive_workspace_revision_id ~workspace:(workspace_id workspace) ~parent
        ~base ~selected ~precedence ~resolved_order ~resolutions
    in
    Ok
      {
        workspace_revision_id_ = id;
        workspace_revision_workspace_id_ = workspace_id workspace;
        workspace_revision_workspace_ref_ = workspace_ref;
        workspace_revision_parent_ = parent;
        workspace_revision_base_ = base;
        workspace_revision_selected_ = selected;
        workspace_revision_precedence_ = precedence;
        workspace_revision_resolved_order_ = resolved_order;
        workspace_revision_resolutions_ = resolutions;
        workspace_revision_created_at_ = created_at;
      }

let workspace_revision_id revision = revision.workspace_revision_id_

let workspace_revision_workspace_id revision =
  revision.workspace_revision_workspace_id_

let workspace_revision_workspace_ref revision =
  revision.workspace_revision_workspace_ref_

let workspace_revision_parent revision = revision.workspace_revision_parent_
let workspace_revision_base revision = revision.workspace_revision_base_
let workspace_revision_selected revision = revision.workspace_revision_selected_

let workspace_revision_precedence revision =
  revision.workspace_revision_precedence_

let workspace_revision_resolved_order revision =
  revision.workspace_revision_resolved_order_

let workspace_revision_resolutions revision =
  revision.workspace_revision_resolutions_

let workspace_revision_created_at revision =
  revision.workspace_revision_created_at_

let encode_workspace_revision revision =
  let parent =
    match revision.workspace_revision_parent_ with
    | None -> Encoding.null
    | Some parent -> workspace_revision_link_value parent
  in
  array
    [
      Encoding.integer current_schema_version;
      workspace_id_value revision.workspace_revision_workspace_id_;
      workspace_revision_id_value revision.workspace_revision_id_;
      opaque_value revision.workspace_revision_workspace_ref_;
      parent;
      snapshot_link_value revision.workspace_revision_base_;
      revision_link_list_value revision.workspace_revision_selected_;
      precedence_list_value revision.workspace_revision_precedence_;
      revision_link_list_value revision.workspace_revision_resolved_order_;
      Encoding.array
        (List.map binding_value revision.workspace_revision_resolutions_)
      |> Result.get_ok;
      Encoding.integer revision.workspace_revision_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_parent value =
  match value with
  | Encoding.Null -> Ok None
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ ->
      workspace_revision_link_of_value value |> Result.map Option.some

let decode_workspace_revision encoded =
  let* value = decode_value encoded in
  let* values = fields "workspace revision" 12 value in
  match values with
  | [
   version;
   workspace;
   id;
   workspace_ref;
   parent;
   base;
   selected;
   precedence;
   resolved_order;
   resolutions;
   created_at;
   features;
  ] ->
      let* version = integer "workspace revision schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* workspace_revision_workspace = workspace_id_of_value workspace in
        let* workspace_revision_id_ = workspace_revision_id_of_value id in
        let* workspace_ref = opaque_of_value workspace_ref in
        let* parent = decode_parent parent in
        let* base = snapshot_link_of_value base in
        let* selected =
          revision_link_list_of_value "workspace selected revisions" selected
        in
        let* precedence = precedence_list_of_value precedence in
        let* resolved_order =
          revision_link_list_of_value "workspace resolved order" resolved_order
        in
        let* resolutions = binding_list_of_value resolutions in
        let* created_at =
          integer "workspace revision creation time" created_at
        in
        let* features =
          integer "workspace revision mandatory features" features
        in
        let* () = check_features features in
        if
          (not (strict_sorted compare_revision_link selected))
          || (not (strict_sorted compare_precedence precedence))
          || (not (strict_sorted compare_binding resolutions))
          || not
               (valid_workspace_revision_content selected precedence
                  resolved_order)
        then
          Error (Invalid_payload "workspace revision links are not canonical")
        else
          let expected =
            derive_workspace_revision_id ~workspace:workspace_revision_workspace
              ~parent ~base ~selected ~precedence ~resolved_order ~resolutions
          in
          if
            not
              (V2_model.Workspace_revision_id.equal workspace_revision_id_
                 expected)
          then
            Error
              (Invalid_identity "workspace revision logical identity mismatch")
          else
            let revision =
              {
                workspace_revision_id_;
                workspace_revision_workspace_id_ = workspace_revision_workspace;
                workspace_revision_workspace_ref_ = workspace_ref;
                workspace_revision_parent_ = parent;
                workspace_revision_base_ = base;
                workspace_revision_selected_ = selected;
                workspace_revision_precedence_ = precedence;
                workspace_revision_resolved_order_ = resolved_order;
                workspace_revision_resolutions_ = resolutions;
                workspace_revision_created_at_ = created_at;
              }
            in
            if String.equal encoded (encode_workspace_revision revision) then
              Ok revision
            else Error Noncanonical_record
  | _ -> assert false

let path_value path =
  Model.Path.to_components path
  |> List.map (fun component -> Encoding.text component |> Result.get_ok)
  |> Encoding.array |> Result.get_ok

let path_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* component =
              text_value "workspace conflict path component" value
            in
            decode (component :: reversed) rest
      in
      let* components = decode [] values in
      Model.Path.of_components components
      |> Result.map_error (fun error ->
          Invalid_payload (Model.Path.error_to_string error))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace conflict path must be an array")

let paths_value paths =
  Encoding.array (List.map path_value paths) |> Result.get_ok

let paths_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* path = path_of_value value in
            decode (path :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace conflict paths must be an array")

let transition_error_value = function
  | Model.Path_not_found path ->
      array [ Encoding.integer 0L; path_value path ] |> Result.get_ok
  | Model.Path_already_exists path ->
      array [ Encoding.integer 1L; path_value path ] |> Result.get_ok
  | Model.Parent_not_found path ->
      array [ Encoding.integer 2L; path_value path ] |> Result.get_ok
  | Model.Parent_is_file path ->
      array [ Encoding.integer 3L; path_value path ] |> Result.get_ok
  | Model.Expected_entry_mismatch path ->
      array [ Encoding.integer 4L; path_value path ] |> Result.get_ok
  | Model.Expected_content_mismatch path ->
      array [ Encoding.integer 5L; path_value path ] |> Result.get_ok
  | Model.Expected_mode_mismatch path ->
      array [ Encoding.integer 6L; path_value path ] |> Result.get_ok
  | Model.Move_into_descendant { source; destination } ->
      array [ Encoding.integer 7L; path_value source; path_value destination ]
      |> Result.get_ok

let transition_error_of_value value =
  let* values =
    match value with
    | Encoding.Array (Encoding.Integer 7L :: _ as values) -> Ok values
    | Encoding.Array values when List.length values = 2 -> Ok values
    | Encoding.Array _ ->
        Error (Invalid_payload "workspace conflict cause has wrong fields")
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Invalid_payload "workspace conflict cause must be an array")
  in
  match values with
  | [ tag; path ] -> (
      let* tag = integer "workspace conflict cause tag" tag in
      let* path = path_of_value path in
      match tag with
      | 0L -> Ok (Model.Path_not_found path)
      | 1L -> Ok (Model.Path_already_exists path)
      | 2L -> Ok (Model.Parent_not_found path)
      | 3L -> Ok (Model.Parent_is_file path)
      | 4L -> Ok (Model.Expected_entry_mismatch path)
      | 5L -> Ok (Model.Expected_content_mismatch path)
      | 6L -> Ok (Model.Expected_mode_mismatch path)
      | _ -> Error (Invalid_payload "unknown workspace conflict cause tag"))
  | [ tag; source; destination ] ->
      let* tag = integer "workspace conflict cause tag" tag in
      if not (Int64.equal tag 7L) then
        Error (Invalid_payload "workspace conflict cause has wrong fields")
      else
        let* source = path_of_value source in
        let* destination = path_of_value destination in
        Ok (Model.Move_into_descendant { source; destination })
  | _ -> assert false

let conflict_identity_bytes ~workspace ~attempt ~revision ~operation_index
    ~paths ~cause =
  array
    [
      Encoding.integer current_schema_version;
      workspace_revision_link_identity_value workspace;
      workspace_attempt_id_value attempt;
      revision_link_identity_value revision;
      Encoding.integer (Int64.of_int operation_index);
      paths_value paths;
      transition_error_value cause;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_conflict_id ~workspace ~attempt ~revision ~operation_index ~paths
    ~cause =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:workspace-conflict:v1\000"
  in
  let context =
    Hash.feed_string context
      (conflict_identity_bytes ~workspace ~attempt ~revision ~operation_index
         ~paths ~cause)
  in
  Hash.get context |> Hash.to_raw_string |> V2_model.Conflict_id.of_bytes
  |> Result.get_ok

let make_conflict ~workspace ~attempt ~(source : Workspace.conflict) ~created_at
    =
  let id =
    derive_conflict_id ~workspace ~attempt ~revision:source.Workspace.revision
      ~operation_index:source.Workspace.operation_index
      ~paths:source.Workspace.paths ~cause:source.Workspace.cause
  in
  Ok
    {
      conflict_id_ = id;
      conflict_workspace_link_ = workspace;
      conflict_attempt_id_ = attempt;
      conflict_revision_link_ = source.Workspace.revision;
      conflict_operation_index_ = source.Workspace.operation_index;
      conflict_paths_ = source.Workspace.paths;
      conflict_cause_ = source.Workspace.cause;
      conflict_created_at_ = created_at;
    }

let conflict_id conflict = conflict.conflict_id_
let conflict_workspace conflict = conflict.conflict_workspace_link_
let conflict_attempt conflict = conflict.conflict_attempt_id_
let conflict_revision conflict = conflict.conflict_revision_link_
let conflict_operation_index conflict = conflict.conflict_operation_index_
let conflict_paths conflict = conflict.conflict_paths_
let conflict_cause conflict = conflict.conflict_cause_
let conflict_created_at conflict = conflict.conflict_created_at_

let encode_conflict conflict =
  array
    [
      Encoding.integer current_schema_version;
      conflict_id_value conflict.conflict_id_;
      workspace_revision_link_value conflict.conflict_workspace_link_;
      workspace_attempt_id_value conflict.conflict_attempt_id_;
      revision_link_value conflict.conflict_revision_link_;
      Encoding.integer (Int64.of_int conflict.conflict_operation_index_);
      paths_value conflict.conflict_paths_;
      transition_error_value conflict.conflict_cause_;
      Encoding.integer conflict.conflict_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_conflict encoded =
  let* value = decode_value encoded in
  let* values = fields "workspace conflict" 10 value in
  match values with
  | [
   version;
   id;
   workspace;
   attempt;
   revision;
   operation_index;
   paths;
   cause;
   created_at;
   features;
  ] ->
      let* version = integer "workspace conflict schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* conflict_id_ = conflict_id_of_value id in
        let* workspace = workspace_revision_link_of_value workspace in
        let* attempt = workspace_attempt_id_of_value attempt in
        let* revision = revision_link_of_value revision in
        let* operation_index =
          integer "workspace conflict operation index" operation_index
        in
        if
          Int64.compare operation_index 0L < 0
          || Int64.compare operation_index (Int64.of_int max_int) > 0
        then
          Error
            (Invalid_payload
               "workspace conflict operation index is outside OCaml int range")
        else
          let* paths = paths_of_value paths in
          let* cause = transition_error_of_value cause in
          let* created_at =
            integer "workspace conflict creation time" created_at
          in
          let* features =
            integer "workspace conflict mandatory features" features
          in
          let* () = check_features features in
          let operation_index = Int64.to_int operation_index in
          let expected =
            derive_conflict_id ~workspace ~attempt ~revision ~operation_index
              ~paths ~cause
          in
          if not (V2_model.Conflict_id.equal conflict_id_ expected) then
            Error
              (Invalid_identity "workspace conflict logical identity mismatch")
          else
            let conflict =
              {
                conflict_id_;
                conflict_workspace_link_ = workspace;
                conflict_attempt_id_ = attempt;
                conflict_revision_link_ = revision;
                conflict_operation_index_ = operation_index;
                conflict_paths_ = paths;
                conflict_cause_ = cause;
                conflict_created_at_ = created_at;
              }
            in
            if String.equal encoded (encode_conflict conflict) then Ok conflict
            else Error Noncanonical_record
  | _ -> assert false

let resolution_action_value = function
  | Skip_operation { revision; operation_index } ->
      array
        [
          Encoding.integer 0L;
          revision_link_value revision;
          Encoding.integer (Int64.of_int operation_index);
        ]
      |> Result.get_ok

let resolution_action_of_value value =
  let* values = fields "workspace resolution action" 3 value in
  match values with
  | [ tag; revision; operation_index ] ->
      let* tag = integer "workspace resolution action tag" tag in
      if not (Int64.equal tag 0L) then
        Error (Invalid_payload "unknown workspace resolution action tag")
      else
        let* revision = revision_link_of_value revision in
        let* operation_index =
          integer "workspace resolution operation index" operation_index
        in
        if
          Int64.compare operation_index 0L < 0
          || Int64.compare operation_index (Int64.of_int max_int) > 0
        then
          Error
            (Invalid_payload
               "workspace resolution operation index is outside OCaml int range")
        else
          Ok
            (Skip_operation
               { revision; operation_index = Int64.to_int operation_index })
  | _ -> assert false

let resolution_identity_bytes ~conflict ~workspace ~action =
  array
    [
      Encoding.integer current_schema_version;
      conflict_link_identity_value conflict;
      workspace_revision_link_identity_value workspace;
      resolution_action_value action;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_resolution_id ~conflict ~workspace ~action =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:workspace-resolution:v1\000"
  in
  let context =
    Hash.feed_string context
      (resolution_identity_bytes ~conflict ~workspace ~action)
  in
  Hash.get context |> Hash.to_raw_string |> V2_model.Resolution_id.of_bytes
  |> Result.get_ok

let same_revision_link left right =
  V2_model.Capsule_id.equal
    (Capsule.revision_link_capsule_id left)
    (Capsule.revision_link_capsule_id right)
  && V2_model.Capsule_revision_id.equal
       (Capsule.revision_link_revision_id left)
       (Capsule.revision_link_revision_id right)
  && V2_model.Opaque_object_ref.equal
       (Capsule.revision_link_ref left)
       (Capsule.revision_link_ref right)

let make_resolution ~conflict ~(source : conflict) ~workspace ~action
    ~created_at =
  let valid =
    match action with
    | Skip_operation { revision; operation_index } ->
        same_revision_link revision source.conflict_revision_link_
        && Int.equal operation_index source.conflict_operation_index_
  in
  if not valid then Error Invalid_resolution_target
  else
    let resolution_id_ = derive_resolution_id ~conflict ~workspace ~action in
    Ok
      {
        resolution_id_;
        resolution_conflict_link_ = conflict;
        resolution_workspace_link_ = workspace;
        resolution_action_ = action;
        resolution_created_at_ = created_at;
      }

let resolution_id resolution = resolution.resolution_id_
let resolution_conflict resolution = resolution.resolution_conflict_link_
let resolution_workspace resolution = resolution.resolution_workspace_link_
let resolution_action resolution = resolution.resolution_action_
let resolution_created_at resolution = resolution.resolution_created_at_

let encode_resolution resolution =
  array
    [
      Encoding.integer current_schema_version;
      resolution_id_value resolution.resolution_id_;
      conflict_link_value resolution.resolution_conflict_link_;
      workspace_revision_link_value resolution.resolution_workspace_link_;
      resolution_action_value resolution.resolution_action_;
      Encoding.integer resolution.resolution_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_resolution encoded =
  let* value = decode_value encoded in
  let* values = fields "workspace resolution" 7 value in
  match values with
  | [ version; id; conflict; workspace; action; created_at; features ] ->
      let* version = integer "workspace resolution schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* resolution_id_ = resolution_id_of_value id in
        let* conflict = conflict_link_of_value conflict in
        let* workspace = workspace_revision_link_of_value workspace in
        let* action = resolution_action_of_value action in
        let* created_at =
          integer "workspace resolution creation time" created_at
        in
        let* features =
          integer "workspace resolution mandatory features" features
        in
        let* () = check_features features in
        let expected = derive_resolution_id ~conflict ~workspace ~action in
        if not (V2_model.Resolution_id.equal resolution_id_ expected) then
          Error
            (Invalid_identity "workspace resolution logical identity mismatch")
        else
          let resolution =
            {
              resolution_id_;
              resolution_conflict_link_ = conflict;
              resolution_workspace_link_ = workspace;
              resolution_action_ = action;
              resolution_created_at_ = created_at;
            }
          in
          if String.equal encoded (encode_resolution resolution) then
            Ok resolution
          else Error Noncanonical_record
  | _ -> assert false

let conflict_link_list_value links =
  Encoding.array (List.map conflict_link_value links) |> Result.get_ok

let conflict_link_list_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* link = conflict_link_of_value value in
            decode (link :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace attempt conflicts must be an array")

let outcome_value = function
  | Attempt_applied_exactly { revision; operation_index } ->
      array
        [
          Encoding.integer 0L;
          revision_link_value revision;
          Encoding.integer (Int64.of_int operation_index);
        ]
      |> Result.get_ok
  | Attempt_skipped_explicitly { revision; operation_index } ->
      array
        [
          Encoding.integer 1L;
          revision_link_value revision;
          Encoding.integer (Int64.of_int operation_index);
        ]
      |> Result.get_ok
  | Attempt_conflict conflict ->
      array [ Encoding.integer 2L; conflict_link_value conflict ]
      |> Result.get_ok
  | Attempt_blocked_by_conflict { revision; operation_index; blocked_by } ->
      array
        [
          Encoding.integer 3L;
          revision_link_value revision;
          Encoding.integer (Int64.of_int operation_index);
          conflict_link_value blocked_by;
        ]
      |> Result.get_ok

let decode_operation_index name value =
  let* value = integer name value in
  if
    Int64.compare value 0L < 0 || Int64.compare value (Int64.of_int max_int) > 0
  then Error (Invalid_payload (name ^ " is outside OCaml int range"))
  else Ok (Int64.to_int value)

let outcome_of_value value =
  match value with
  | Encoding.Array [ tag; revision; operation_index ] ->
      let* tag = integer "workspace attempt outcome tag" tag in
      let* revision = revision_link_of_value revision in
      let* operation_index =
        decode_operation_index "workspace attempt operation index"
          operation_index
      in
      if Int64.equal tag 0L then
        Ok (Attempt_applied_exactly { revision; operation_index })
      else if Int64.equal tag 1L then
        Ok (Attempt_skipped_explicitly { revision; operation_index })
      else Error (Invalid_payload "workspace attempt outcome has wrong fields")
  | Encoding.Array [ tag; conflict ] ->
      let* tag = integer "workspace attempt outcome tag" tag in
      if not (Int64.equal tag 2L) then
        Error (Invalid_payload "workspace attempt outcome has wrong fields")
      else
        conflict_link_of_value conflict
        |> Result.map (fun conflict -> Attempt_conflict conflict)
  | Encoding.Array [ tag; revision; operation_index; blocked_by ] ->
      let* tag = integer "workspace attempt outcome tag" tag in
      if not (Int64.equal tag 3L) then
        Error (Invalid_payload "workspace attempt outcome has wrong fields")
      else
        let* revision = revision_link_of_value revision in
        let* operation_index =
          decode_operation_index "workspace attempt operation index"
            operation_index
        in
        let* blocked_by = conflict_link_of_value blocked_by in
        Ok
          (Attempt_blocked_by_conflict { revision; operation_index; blocked_by })
  | Encoding.Array _ ->
      Error (Invalid_payload "workspace attempt outcome has wrong fields")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace attempt outcome must be an array")

let outcomes_value outcomes =
  Encoding.array (List.map outcome_value outcomes) |> Result.get_ok

let outcomes_of_value value =
  match value with
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* outcome = outcome_of_value value in
            decode (outcome :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "workspace attempt outcomes must be an array")

let attempt_identity_bytes ~workspace ~base ~ordered =
  array
    [
      Encoding.integer current_schema_version;
      workspace_revision_link_identity_value workspace;
      snapshot_id_value base.Capsule.snapshot_id;
      revision_link_identity_list_value ordered;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_attempt_id ~workspace ~base ~ordered =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:workspace-attempt:v1\000"
  in
  let context =
    Hash.feed_string context (attempt_identity_bytes ~workspace ~base ~ordered)
  in
  Hash.get context |> Hash.to_raw_string
  |> V2_model.Workspace_attempt_id.of_bytes |> Result.get_ok

let make_workspace_attempt ~id ~workspace ~base ~ordered ~resulting_snapshot
    ~outcomes ~conflicts ~created_at =
  let expected = derive_attempt_id ~workspace ~base ~ordered in
  if not (V2_model.Workspace_attempt_id.equal id expected) then
    Error
      (Invalid_identity
         "workspace attempt ID does not match its immutable input")
  else
    Ok
      {
        attempt_id_ = id;
        attempt_workspace_link_ = workspace;
        attempt_base_ = base;
        attempt_ordered_ = ordered;
        attempt_resulting_snapshot_ = resulting_snapshot;
        attempt_outcomes_ = outcomes;
        attempt_conflicts_ = conflicts;
        attempt_created_at_ = created_at;
      }

let workspace_attempt_id attempt = attempt.attempt_id_
let workspace_attempt_workspace attempt = attempt.attempt_workspace_link_
let workspace_attempt_base attempt = attempt.attempt_base_
let workspace_attempt_ordered attempt = attempt.attempt_ordered_

let workspace_attempt_resulting_snapshot attempt =
  attempt.attempt_resulting_snapshot_

let workspace_attempt_outcomes attempt = attempt.attempt_outcomes_
let workspace_attempt_conflicts attempt = attempt.attempt_conflicts_
let workspace_attempt_created_at attempt = attempt.attempt_created_at_

let encode_workspace_attempt attempt =
  array
    [
      Encoding.integer current_schema_version;
      workspace_attempt_id_value attempt.attempt_id_;
      workspace_revision_link_value attempt.attempt_workspace_link_;
      snapshot_link_value attempt.attempt_base_;
      revision_link_list_value attempt.attempt_ordered_;
      snapshot_link_value attempt.attempt_resulting_snapshot_;
      outcomes_value attempt.attempt_outcomes_;
      conflict_link_list_value attempt.attempt_conflicts_;
      Encoding.integer attempt.attempt_created_at_;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let decode_workspace_attempt encoded =
  let* value = decode_value encoded in
  let* values = fields "workspace attempt" 10 value in
  match values with
  | [
   version;
   id;
   workspace;
   base;
   ordered;
   resulting_snapshot;
   outcomes;
   conflicts;
   created_at;
   features;
  ] ->
      let* version = integer "workspace attempt schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* attempt_id_ = workspace_attempt_id_of_value id in
        let* workspace = workspace_revision_link_of_value workspace in
        let* base = snapshot_link_of_value base in
        let* ordered =
          revision_link_list_of_value "workspace attempt order" ordered
        in
        let* resulting_snapshot = snapshot_link_of_value resulting_snapshot in
        let* outcomes = outcomes_of_value outcomes in
        let* conflicts = conflict_link_list_of_value conflicts in
        let* created_at =
          integer "workspace attempt creation time" created_at
        in
        let* features =
          integer "workspace attempt mandatory features" features
        in
        let* () = check_features features in
        let expected = derive_attempt_id ~workspace ~base ~ordered in
        if not (V2_model.Workspace_attempt_id.equal attempt_id_ expected) then
          Error (Invalid_identity "workspace attempt logical identity mismatch")
        else
          let attempt =
            {
              attempt_id_;
              attempt_workspace_link_ = workspace;
              attempt_base_ = base;
              attempt_ordered_ = ordered;
              attempt_resulting_snapshot_ = resulting_snapshot;
              attempt_outcomes_ = outcomes;
              attempt_conflicts_ = conflicts;
              attempt_created_at_ = created_at;
            }
          in
          if String.equal encoded (encode_workspace_attempt attempt) then
            Ok attempt
          else Error Noncanonical_record
  | _ -> assert false
