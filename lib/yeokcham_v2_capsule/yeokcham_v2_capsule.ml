module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

module Path_map = Map.Make (struct
  type t = Model.Path.t

  let compare = Model.Path.compare
end)

type snapshot_link = {
  snapshot_id : Yeokcham_id.Snapshot_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
}

type source_boundary = {
  source_snapshot : snapshot_link;
  target_snapshot : snapshot_link;
}

type revision_link = {
  linked_capsule_id : V2_model.Capsule_id.t;
  linked_revision_id : V2_model.Capsule_revision_id.t;
  linked_revision_ref : V2_model.Opaque_object_ref.t;
}

type provenance =
  | Created
  | Folded of revision_link
  | Split_from of revision_link list
  | Combined_from of revision_link list

type proposal = {
  from_snapshot : Model.Snapshot.t;
  to_snapshot : Model.Snapshot.t;
  proposal_operations_ : Model.scratch_operation list;
}

type selection = {
  proposal : proposal;
  indices : int list;
  selection_operations : Model.scratch_operation list;
  result : Model.Snapshot.t;
}

type capsule = {
  capsule_identity : V2_model.Capsule_id.t;
  title : string;
  description : string;
  created_at : int64;
}

type revision = {
  revision_schema_version : int64;
  revision_identity : V2_model.Capsule_revision_id.t;
  revision_capsule_id_ : V2_model.Capsule_id.t;
  capsule_ref : V2_model.Opaque_object_ref.t;
  parent : revision_link option;
  declared_base : snapshot_link;
  expected_result : snapshot_link;
  revision_operations_ : Model.scratch_operation list;
  source_boundaries : source_boundary list;
  provenance : provenance;
  revision_created_at : int64 option;
}

type split_plan = {
  left_indices : int list;
  left_operations : Model.scratch_operation list;
  left_result : Model.Snapshot.t;
  right_operations : Model.scratch_operation list;
}

type proposal_error = Derived_replay_mismatch

type selection_error =
  | Empty_selection
  | Unsorted_selection of { previous : int; current : int }
  | Selection_index_out_of_bounds of { index : int; operation_count : int }
  | Selected_operation_rejected of {
      proposal_index : int;
    cause : Model.transition_error;
  }

type split_error =
  | Split_selection_error of selection_error
  | Split_derivation_error of proposal_error

type error =
  | Invalid_title of Encoding.construction_error
  | Invalid_description of Encoding.construction_error
  | Declared_base_identity_mismatch
  | Expected_result_identity_mismatch
  | Boundary_base_mismatch
  | Boundary_target_mismatch
  | Selection_base_mismatch
  | Parent_capsule_mismatch
  | Empty_source_boundaries
  | Invalid_provenance of string
  | Revision_replay_rejected of Model.replay_error
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_mandatory_features of int64
  | Invalid_mandatory_features of int64
  | Noncanonical_record

let current_schema_version = 1L
let evolved_revision_schema_version = 2L
let supported_mandatory_features = 0L
let ( let* ) = Result.bind

let proposal_error_to_string = function
  | Derived_replay_mismatch -> "derived exact capsule proposal did not replay"

let selection_error_to_string = function
  | Empty_selection -> "capsule selection contains no operations"
  | Unsorted_selection { previous; current } ->
      Printf.sprintf "capsule selection index %d is not after %d" current
        previous
  | Selection_index_out_of_bounds { index; operation_count } ->
      Printf.sprintf "capsule selection index %d is outside 0..%d" index
        (operation_count - 1)
  | Selected_operation_rejected { proposal_index; cause } ->
      Printf.sprintf "selected capsule operation %d was rejected: %s"
        proposal_index
        (Model.transition_error_to_string cause)

let split_error_to_string = function
  | Split_selection_error error -> selection_error_to_string error
  | Split_derivation_error error -> proposal_error_to_string error

let error_to_string = function
  | Invalid_title error ->
      "invalid capsule title: " ^ Encoding.construction_error_to_string error
  | Invalid_description error ->
      "invalid capsule description: "
      ^ Encoding.construction_error_to_string error
  | Declared_base_identity_mismatch ->
      "capsule declared base does not match its exact snapshot"
  | Expected_result_identity_mismatch ->
      "capsule expected result does not match exact selected replay"
  | Boundary_base_mismatch ->
      "capsule source boundary does not begin at the declared base"
  | Boundary_target_mismatch ->
      "capsule source boundary does not end at the proposed target snapshot"
  | Selection_base_mismatch ->
      "capsule selection was not derived from the declared base snapshot"
  | Parent_capsule_mismatch ->
      "capsule revision parent belongs to a different capsule"
  | Empty_source_boundaries -> "capsule revision has no source boundaries"
  | Invalid_provenance detail ->
      "invalid capsule revision provenance: " ^ detail
  | Revision_replay_rejected error ->
      "capsule revision replay rejected: " ^ Model.replay_error_to_string error
  | Invalid_payload detail -> "invalid V2 capsule record: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 capsule record version: %Ld" version
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 capsule mandatory features: %Ld" features
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 capsule mandatory features: %Ld" features
  | Noncanonical_record -> "V2 capsule record is not canonical"

type entry = Directory | File of Model.file_entry

let entry_of_initial = function
  | Model.Directory_path path -> (path, Directory)
  | Model.File_path (path, file) -> (path, File file)

let entries snapshot =
  Model.Snapshot.entries snapshot
  |> List.fold_left
       (fun map initial ->
         let path, entry = entry_of_initial initial in
         Path_map.add path entry map)
       Path_map.empty

let path_components path = Model.Path.to_components path

let is_ancestor ancestor child =
  let rec prefix left right =
    match (left, right) with
    | [], _ -> true
    | _, [] -> false
    | first :: rest, candidate :: candidates ->
        String.equal first candidate && prefix rest candidates
  in
  prefix (path_components ancestor) (path_components child)

let entry_at snapshot path =
  match Model.Snapshot.find snapshot path with
  | Some entry -> entry
  | None -> assert false

let path_depth path = List.length (path_components path)

let compare_shallow_path left right =
  match Int.compare (path_depth left) (path_depth right) with
  | 0 -> Model.Path.compare left right
  | comparison -> comparison

let changed_source_entry target path source_entry =
  match Path_map.find_opt path target with
  | None -> true
  | Some Directory -> (
      match source_entry with Directory -> false | File _ -> true)
  | Some (File _) -> (
      match source_entry with Directory -> true | File _ -> false)

let deletion_roots source target =
  let candidates =
    Path_map.bindings source
    |> List.filter_map (fun (path, entry) ->
        if changed_source_entry target path entry then Some path else None)
    |> List.sort Model.Path.compare
  in
  List.fold_left
    (fun roots path ->
      if List.exists (fun root -> is_ancestor root path) roots then roots
      else roots @ [ path ])
    [] candidates

let added_target_directory source path =
  match Path_map.find_opt path source with
  | Some Directory -> false
  | None | Some (File _) -> true

let added_target_file source path =
  match Path_map.find_opt path source with
  | Some (File _) -> false
  | None | Some Directory -> true

let derive_operations ~from ~to_ =
  let source = entries from in
  let target = entries to_ in
  let deletions =
    deletion_roots source target
    |> List.map (fun path ->
        Model.Delete_path { path; prior = entry_at from path })
  in
  let directories =
    Path_map.bindings target
    |> List.filter_map (fun (path, entry) ->
        match entry with
        | Directory when added_target_directory source path -> Some path
        | Directory | File _ -> None)
    |> List.sort compare_shallow_path
    |> List.map (fun path -> Model.Create_directory { path })
  in
  let modifications =
    Path_map.bindings target
    |> List.concat_map (fun (path, target_entry) ->
        match (Path_map.find_opt path source, target_entry) with
        | ( Some (File { Model.mode = source_mode; content = source_content }),
            File { Model.mode = target_mode; content = target_content } ) ->
            let content =
              if String.equal source_content target_content then []
              else
                [
                  Model.Modify_file
                    {
                      path;
                      expected_content = source_content;
                      replacement_content = target_content;
                    };
                ]
            in
            let mode =
              if source_mode = target_mode then []
              else
                [
                  Model.Change_mode
                    {
                      path;
                      expected_mode = source_mode;
                      replacement_mode = target_mode;
                    };
                ]
            in
            content @ mode
        | Some Directory, Directory
        | None, Directory
        | None, File _
        | Some Directory, File _
        | Some (File _), Directory ->
            [])
  in
  let creations =
    Path_map.bindings target
    |> List.filter_map (fun (path, entry) ->
        match entry with
        | Directory -> None
        | File file when added_target_file source path -> Some (path, file)
        | File _ -> None)
    |> List.map (fun (path, { Model.mode; content }) ->
        Model.Create_file { path; content; mode })
  in
  deletions @ directories @ modifications @ creations

let propose ~from ~to_ =
  let operations = derive_operations ~from ~to_ in
  match Model.Snapshot.apply_operations from operations with
  | Ok actual when Model.Snapshot.equal actual to_ ->
      Ok
        ({
           from_snapshot = from;
           to_snapshot = to_;
           proposal_operations_ = operations;
         }
          : proposal)
  | Ok _ | Error _ -> Error Derived_replay_mismatch

let proposal_operations (proposal : proposal) = proposal.proposal_operations_
let proposal_from_snapshot (proposal : proposal) = proposal.from_snapshot
let proposal_to_snapshot (proposal : proposal) = proposal.to_snapshot

let select (proposal : proposal) ~indices =
  let operation_count = List.length proposal.proposal_operations_ in
  let rec validate previous = function
    | [] -> Ok ()
    | index :: rest -> (
        if index < 0 || index >= operation_count then
          Error (Selection_index_out_of_bounds { index; operation_count })
        else
          match previous with
          | Some previous when index <= previous ->
              Error (Unsorted_selection { previous; current = index })
          | None | Some _ -> validate (Some index) rest)
  in
  match indices with
  | [] -> Error Empty_selection
  | _ ->
      let* () = validate None indices in
      let selected =
        List.map
          (fun index -> List.nth proposal.proposal_operations_ index)
          indices
      in
      let rec apply state = function
        | [] -> Ok state
        | (proposal_index, operation) :: rest -> (
            match Model.Snapshot.apply_operation state operation with
            | Ok state -> apply state rest
            | Error cause ->
                Error (Selected_operation_rejected { proposal_index; cause }))
      in
      let* result =
        apply proposal.from_snapshot (List.combine indices selected)
      in
      Ok { proposal; indices; selection_operations = selected; result }

let selected_indices (selection : selection) = selection.indices
let selected_operations (selection : selection) = selection.selection_operations
let selected_result (selection : selection) = selection.result

let make_capsule ~id ~title ~description ~created_at =
  let* _ =
    Encoding.text title |> Result.map_error (fun error -> Invalid_title error)
  in
  let* _ =
    Encoding.text description
    |> Result.map_error (fun error -> Invalid_description error)
  in
  Ok { capsule_identity = id; title; description; created_at }

let snapshot_link_value link =
  Encoding.array
    [
      Encoding.bytes (Yeokcham_id.Snapshot_id.to_bytes link.snapshot_id);
      Encoding.bytes (V2_model.Opaque_object_ref.to_bytes link.snapshot_ref);
    ]
  |> Result.get_ok

let source_boundary_value boundary =
  Encoding.array
    [
      snapshot_link_value boundary.source_snapshot;
      snapshot_link_value boundary.target_snapshot;
    ]
  |> Result.get_ok

let revision_link_value (link : revision_link) =
  Encoding.array
    [
      Encoding.bytes (V2_model.Capsule_id.to_bytes link.linked_capsule_id);
      Encoding.bytes
        (V2_model.Capsule_revision_id.to_bytes link.linked_revision_id);
      Encoding.bytes
        (V2_model.Opaque_object_ref.to_bytes link.linked_revision_ref);
    ]
  |> Result.get_ok

let revision_link_identity_value (link : revision_link) =
  Encoding.array
    [
      Encoding.bytes (V2_model.Capsule_id.to_bytes link.linked_capsule_id);
      Encoding.bytes
        (V2_model.Capsule_revision_id.to_bytes link.linked_revision_id);
    ]
  |> Result.get_ok

let revision_link_list_value links =
  Encoding.array (List.map revision_link_value links) |> Result.get_ok

let revision_link_identity_list_value links =
  Encoding.array (List.map revision_link_identity_value links) |> Result.get_ok

let provenance_value = function
  | Created -> Encoding.array [ Encoding.integer 0L ] |> Result.get_ok
  | Folded link ->
      Encoding.array [ Encoding.integer 1L; revision_link_value link ]
      |> Result.get_ok
  | Split_from links ->
      Encoding.array [ Encoding.integer 2L; revision_link_list_value links ]
      |> Result.get_ok
  | Combined_from links ->
      Encoding.array [ Encoding.integer 3L; revision_link_list_value links ]
      |> Result.get_ok

let provenance_identity_value = function
  | Created -> Encoding.array [ Encoding.integer 0L ] |> Result.get_ok
  | Folded link ->
      Encoding.array [ Encoding.integer 1L; revision_link_identity_value link ]
      |> Result.get_ok
  | Split_from links ->
      Encoding.array
        [ Encoding.integer 2L; revision_link_identity_list_value links ]
      |> Result.get_ok
  | Combined_from links ->
      Encoding.array
        [ Encoding.integer 3L; revision_link_identity_list_value links ]
      |> Result.get_ok

let operation_values operations =
  List.map
    (fun operation ->
      Model.Scratch_operation.canonical_bytes operation |> Encoding.bytes)
    operations

let revision_identity_bytes ~capsule_id ~declared_base ~expected_result
    ~operations ~source_boundary =
  Encoding.array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (V2_model.Capsule_id.to_bytes capsule_id);
      Encoding.bytes
        (Yeokcham_id.Snapshot_id.to_bytes declared_base.snapshot_id);
      Encoding.bytes
        (Yeokcham_id.Snapshot_id.to_bytes expected_result.snapshot_id);
      Encoding.array (operation_values operations) |> Result.get_ok;
      source_boundary_value source_boundary;
    ]
  |> Result.get_ok |> Encoding.encode

let derive_revision_id ~capsule_id ~declared_base ~expected_result ~operations
    ~source_boundary =
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:capsule-revision:v1\000"
  in
  let context =
    Hash.feed_string context
      (revision_identity_bytes ~capsule_id ~declared_base ~expected_result
         ~operations ~source_boundary)
  in
  let digest = Hash.get context |> Hash.to_raw_string in
  V2_model.Capsule_revision_id.of_bytes digest |> Result.get_ok

let derive_evolved_revision_id ~capsule_id ~parent ~declared_base
    ~expected_result ~operations ~source_boundaries ~provenance =
  let parent =
    match parent with
    | None -> Encoding.null
    | Some link -> revision_link_identity_value link
  in
  let identity =
    Encoding.array
      [
        Encoding.integer evolved_revision_schema_version;
        Encoding.bytes (V2_model.Capsule_id.to_bytes capsule_id);
        parent;
        Encoding.bytes
          (Yeokcham_id.Snapshot_id.to_bytes declared_base.snapshot_id);
        Encoding.bytes
          (Yeokcham_id.Snapshot_id.to_bytes expected_result.snapshot_id);
        Encoding.array (operation_values operations) |> Result.get_ok;
        Encoding.array (List.map source_boundary_value source_boundaries)
        |> Result.get_ok;
        provenance_identity_value provenance;
      ]
    |> Result.get_ok |> Encoding.encode
  in
  let context =
    Hash.feed_string Hash.empty "yeokcham:v2:capsule-revision:v2\000"
  in
  let context = Hash.feed_string context identity in
  let digest = Hash.get context |> Hash.to_raw_string in
  V2_model.Capsule_revision_id.of_bytes digest |> Result.get_ok

let same_snapshot_id left right =
  Yeokcham_id.Snapshot_id.equal left.snapshot_id right.snapshot_id

let same_snapshot_link left right =
  same_snapshot_id left right
  && V2_model.Opaque_object_ref.equal left.snapshot_ref right.snapshot_ref

let make_initial_revision ~capsule ~capsule_ref ~declared_base
    ~declared_base_snapshot ~expected_result ~selected ~source_boundary =
  if
    not
      (Yeokcham_id.Snapshot_id.equal declared_base.snapshot_id
         (Model.Snapshot.id declared_base_snapshot))
  then Error Declared_base_identity_mismatch
  else if
    not
      (Model.Snapshot.equal declared_base_snapshot
         selected.proposal.from_snapshot)
  then Error Selection_base_mismatch
  else if not (same_snapshot_link declared_base source_boundary.source_snapshot)
  then Error Boundary_base_mismatch
  else if
    not
      (Yeokcham_id.Snapshot_id.equal source_boundary.target_snapshot.snapshot_id
         (Model.Snapshot.id selected.proposal.to_snapshot))
  then Error Boundary_target_mismatch
  else
    match
      Model.Snapshot.apply_operations declared_base_snapshot
        selected.selection_operations
    with
    | Error error -> Error (Revision_replay_rejected error)
    | Ok actual ->
        if
          not
            (Yeokcham_id.Snapshot_id.equal expected_result.snapshot_id
               (Model.Snapshot.id actual))
        then Error Expected_result_identity_mismatch
        else
          let id =
            derive_revision_id ~capsule_id:capsule.capsule_identity
              ~declared_base ~expected_result
              ~operations:selected.selection_operations ~source_boundary
          in
          Ok
            {
              revision_schema_version = current_schema_version;
              revision_identity = id;
              revision_capsule_id_ = capsule.capsule_identity;
              capsule_ref;
              parent = None;
              declared_base;
              expected_result;
              revision_operations_ = selected.selection_operations;
              source_boundaries = [ source_boundary ];
              provenance = Created;
              revision_created_at = None;
            }

let validate_provenance capsule_id = function
  | Created -> Error (Invalid_provenance "created is reserved for revision v1")
  | Folded (link : revision_link) ->
      if V2_model.Capsule_id.equal capsule_id link.linked_capsule_id then Ok ()
      else Error (Invalid_provenance "fold source belongs to another capsule")
  | Split_from [] -> Error (Invalid_provenance "split sources are empty")
  | Split_from _ -> Ok ()
  | Combined_from [] -> Error (Invalid_provenance "combine sources are empty")
  | Combined_from _ -> Ok ()

let make_revision ~capsule ~capsule_ref ~(parent : revision_link option)
    ~declared_base ~declared_base_snapshot ~expected_result ~operations
    ~source_boundaries ~provenance ~created_at =
  if
    not
      (Yeokcham_id.Snapshot_id.equal declared_base.snapshot_id
         (Model.Snapshot.id declared_base_snapshot))
  then Error Declared_base_identity_mismatch
  else
    match source_boundaries with
    | [] -> Error Empty_source_boundaries
    | first_boundary :: _ -> (
        if not (same_snapshot_link declared_base first_boundary.source_snapshot)
        then Error Boundary_base_mismatch
        else
          let* () =
            match parent with
            | None -> Ok ()
            | Some link ->
                if
                  V2_model.Capsule_id.equal capsule.capsule_identity
                    link.linked_capsule_id
                then Ok ()
                else Error Parent_capsule_mismatch
          in
          let* () = validate_provenance capsule.capsule_identity provenance in
          match
            Model.Snapshot.apply_operations declared_base_snapshot operations
          with
          | Error error -> Error (Revision_replay_rejected error)
          | Ok actual ->
              if
                not
                  (Yeokcham_id.Snapshot_id.equal expected_result.snapshot_id
                     (Model.Snapshot.id actual))
              then Error Expected_result_identity_mismatch
              else
                let id =
                  derive_evolved_revision_id
                    ~capsule_id:capsule.capsule_identity ~parent ~declared_base
                    ~expected_result ~operations ~source_boundaries ~provenance
                in
                Ok
                  {
                    revision_schema_version = evolved_revision_schema_version;
                    revision_identity = id;
                    revision_capsule_id_ = capsule.capsule_identity;
                    capsule_ref;
                    parent;
                    declared_base;
                    expected_result;
                    revision_operations_ = operations;
                    source_boundaries;
                    provenance;
                    revision_created_at = Some created_at;
                  })

let capsule_id capsule = capsule.capsule_identity
let capsule_title capsule = capsule.title
let capsule_description capsule = capsule.description
let capsule_created_at capsule = capsule.created_at
let revision_id revision = revision.revision_identity
let revision_capsule_id revision = revision.revision_capsule_id_
let revision_capsule_ref revision = revision.capsule_ref
let revision_declared_base revision = revision.declared_base
let revision_expected_result revision = revision.expected_result
let revision_operations revision = revision.revision_operations_
let revision_source_boundary revision = List.hd revision.source_boundaries
let revision_source_boundaries revision = revision.source_boundaries
let revision_parent revision = revision.parent
let revision_provenance revision = revision.provenance
let revision_created_at revision = revision.revision_created_at

let make_revision_link ~capsule_id ~revision_id ~revision_ref =
  {
    linked_capsule_id = capsule_id;
    linked_revision_id = revision_id;
    linked_revision_ref = revision_ref;
  }

let revision_link_capsule_id link = link.linked_capsule_id
let revision_link_revision_id link = link.linked_revision_id
let revision_link_ref link = link.linked_revision_ref

let apply_revision ~base revision =
  Model.Snapshot.apply_operations base revision.revision_operations_

let plan_split ~base revision ~left_indices =
  match apply_revision ~base revision with
  | Error _ -> assert false
  | Ok expected_result ->
      let proposal =
        {
          from_snapshot = base;
          to_snapshot = expected_result;
          proposal_operations_ = revision.revision_operations_;
        }
      in
      let* left =
        select proposal ~indices:left_indices
        |> Result.map_error (fun error -> Split_selection_error error)
      in
      let* right =
        propose ~from:left.result ~to_:expected_result
        |> Result.map_error (fun error -> Split_derivation_error error)
      in
      Ok
        {
          left_indices;
          left_operations = left.selection_operations;
          left_result = left.result;
          right_operations = right.proposal_operations_;
        }

let split_plan_left_indices plan = plan.left_indices
let split_plan_left_operations plan = plan.left_operations
let split_plan_left_result plan = plan.left_result
let split_plan_right_operations plan = plan.right_operations

let text field value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload
        (field ^ ": " ^ Encoding.construction_error_to_string error))

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let encode_capsule capsule =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (V2_model.Capsule_id.to_bytes capsule.capsule_identity);
      text "capsule title" capsule.title |> Result.get_ok;
      text "capsule description" capsule.description |> Result.get_ok;
      Encoding.integer capsule.created_at;
      Encoding.integer supported_mandatory_features;
    ]
  |> Result.get_ok |> Encoding.encode

let encode_revision revision =
  if Int64.equal revision.revision_schema_version current_schema_version then
    array
      [
        Encoding.integer current_schema_version;
        Encoding.bytes
          (V2_model.Capsule_id.to_bytes revision.revision_capsule_id_);
        Encoding.bytes
          (V2_model.Capsule_revision_id.to_bytes revision.revision_identity);
        Encoding.bytes
          (V2_model.Opaque_object_ref.to_bytes revision.capsule_ref);
        snapshot_link_value revision.declared_base;
        snapshot_link_value revision.expected_result;
        Encoding.array (operation_values revision.revision_operations_)
        |> Result.get_ok;
        source_boundary_value (revision_source_boundary revision);
        Encoding.integer supported_mandatory_features;
      ]
    |> Result.get_ok |> Encoding.encode
  else
    let parent =
      match revision.parent with
      | None -> Encoding.null
      | Some link -> revision_link_value link
    in
    array
      [
        Encoding.integer evolved_revision_schema_version;
        Encoding.bytes
          (V2_model.Capsule_id.to_bytes revision.revision_capsule_id_);
        Encoding.bytes
          (V2_model.Capsule_revision_id.to_bytes revision.revision_identity);
        Encoding.bytes
          (V2_model.Opaque_object_ref.to_bytes revision.capsule_ref);
        parent;
        snapshot_link_value revision.declared_base;
        snapshot_link_value revision.expected_result;
        Encoding.array (operation_values revision.revision_operations_)
        |> Result.get_ok;
        Encoding.array
          (List.map source_boundary_value revision.source_boundaries)
        |> Result.get_ok;
        provenance_value revision.provenance;
        Encoding.integer (Option.get revision.revision_created_at);
        Encoding.integer supported_mandatory_features;
      ]
    |> Result.get_ok |> Encoding.encode

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

let decode_snapshot_link value =
  let* fields = fields "snapshot link" 2 value in
  match fields with
  | [ snapshot_id; snapshot_ref ] ->
      let* snapshot_id = bytes "snapshot link logical identity" snapshot_id in
      let* snapshot_ref = bytes "snapshot link object reference" snapshot_ref in
      let* snapshot_id =
        Yeokcham_id.Snapshot_id.of_bytes snapshot_id
        |> Result.map_error (fun _ ->
            Invalid_payload "invalid snapshot link identity")
      in
      let* snapshot_ref =
        V2_model.Opaque_object_ref.of_bytes snapshot_ref
        |> Result.map_error (fun _ ->
            Invalid_payload "invalid snapshot link reference")
      in
      Ok { snapshot_id; snapshot_ref }
  | _ -> assert false

let decode_boundary value =
  let* fields = fields "source boundary" 2 value in
  match fields with
  | [ source_snapshot; target_snapshot ] ->
      let* source_snapshot = decode_snapshot_link source_snapshot in
      let* target_snapshot = decode_snapshot_link target_snapshot in
      Ok { source_snapshot; target_snapshot }
  | _ -> assert false

let decode_revision_link value =
  let* fields = fields "capsule revision link" 3 value in
  match fields with
  | [ capsule_id; revision_id; revision_ref ] ->
      let* capsule_id = bytes "revision link capsule identity" capsule_id in
      let* revision_id = bytes "revision link revision identity" revision_id in
      let* revision_ref = bytes "revision link object reference" revision_ref in
      let* capsule_id =
        V2_model.Capsule_id.of_bytes capsule_id
        |> Result.map_error (fun _ ->
            Invalid_payload "invalid revision link capsule identity")
      in
      let* revision_id =
        V2_model.Capsule_revision_id.of_bytes revision_id
        |> Result.map_error (fun _ ->
            Invalid_payload "invalid revision link revision identity")
      in
      let* revision_ref =
        V2_model.Opaque_object_ref.of_bytes revision_ref
        |> Result.map_error (fun _ ->
            Invalid_payload "invalid revision link object reference")
      in
      Ok
        {
          linked_capsule_id = capsule_id;
          linked_revision_id = revision_id;
          linked_revision_ref = revision_ref;
        }
  | _ -> assert false

let decode_revision_link_list name = function
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* link = decode_revision_link value in
            decode (link :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let decode_provenance value =
  let* fields = fields "capsule revision provenance" 2 value in
  match fields with
  | [ tag; source ] ->
      let* tag = integer "capsule revision provenance tag" tag in
      if Int64.equal tag 1L then
        let* link = decode_revision_link source in
        Ok (Folded link)
      else if Int64.equal tag 2L then
        let* links =
          decode_revision_link_list "split provenance links" source
        in
        if links = [] then Error (Invalid_provenance "split sources are empty")
        else Ok (Split_from links)
      else if Int64.equal tag 3L then
        let* links =
          decode_revision_link_list "combine provenance links" source
        in
        if links = [] then
          Error (Invalid_provenance "combine sources are empty")
        else Ok (Combined_from links)
      else Error (Invalid_payload "unknown capsule revision provenance tag")
  | _ -> assert false

let decode_boundaries = function
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* boundary = decode_boundary value in
            decode (boundary :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "capsule revision boundaries must be an array")

let decode_operations = function
  | Encoding.Array values ->
      let rec decode reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* encoded_operation = bytes "capsule operation" value in
            let* operation =
              Model.Scratch_operation.decode_canonical_bytes encoded_operation
              |> Result.map_error (fun error ->
                  Invalid_payload
                    ("invalid capsule operation: "
                    ^ Model.canonical_decode_error_to_string error))
            in
            decode (operation :: reversed) rest
      in
      decode [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "capsule operations must be an array")

let decode_capsule encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* fields = fields "capsule" 6 value in
  match fields with
  | [ version; id; title; description; created_at; features ] ->
      let* version = integer "capsule version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* id = bytes "capsule identity" id in
        let* id =
          V2_model.Capsule_id.of_bytes id
          |> Result.map_error (fun _ ->
              Invalid_payload "invalid capsule identity")
        in
        let* title = text_value "capsule title" title in
        let* description = text_value "capsule description" description in
        let* created_at = integer "capsule creation time" created_at in
        let* features = integer "capsule mandatory features" features in
        let* () = check_features features in
        let* capsule = make_capsule ~id ~title ~description ~created_at in
        if String.equal encoded (encode_capsule capsule) then Ok capsule
        else Error Noncanonical_record
  | _ -> assert false

let decode_revision_common ~capsule_id ~id ~capsule_ref =
  let* capsule_id = bytes "capsule revision capsule identity" capsule_id in
  let* capsule_id =
    V2_model.Capsule_id.of_bytes capsule_id
    |> Result.map_error (fun _ ->
        Invalid_payload "invalid revision capsule identity")
  in
  let* id = bytes "capsule revision identity" id in
  let* id =
    V2_model.Capsule_revision_id.of_bytes id
    |> Result.map_error (fun _ -> Invalid_payload "invalid revision identity")
  in
  let* capsule_ref = bytes "capsule revision capsule reference" capsule_ref in
  let* capsule_ref =
    V2_model.Opaque_object_ref.of_bytes capsule_ref
    |> Result.map_error (fun _ ->
        Invalid_payload "invalid revision capsule reference")
  in
  Ok (capsule_id, id, capsule_ref)

let decode_initial_revision encoded fields =
  match fields with
  | [
   _version;
   capsule_id;
   id;
   capsule_ref;
   declared_base;
   expected_result;
   operations;
   boundary;
   features;
  ] ->
      let* capsule_id, id, capsule_ref =
        decode_revision_common ~capsule_id ~id ~capsule_ref
      in
      let* declared_base = decode_snapshot_link declared_base in
      let* expected_result = decode_snapshot_link expected_result in
      let* operations = decode_operations operations in
      let* source_boundary = decode_boundary boundary in
      let* features = integer "capsule revision mandatory features" features in
      let* () = check_features features in
      if not (same_snapshot_link declared_base source_boundary.source_snapshot)
      then Error Boundary_base_mismatch
      else
        let expected_id =
          derive_revision_id ~capsule_id ~declared_base ~expected_result
            ~operations ~source_boundary
        in
        if not (V2_model.Capsule_revision_id.equal id expected_id) then
          Error (Invalid_payload "capsule revision logical identity mismatch")
        else
          let revision =
            {
              revision_schema_version = current_schema_version;
              revision_identity = id;
              revision_capsule_id_ = capsule_id;
              capsule_ref;
              parent = None;
              declared_base;
              expected_result;
              revision_operations_ = operations;
              source_boundaries = [ source_boundary ];
              provenance = Created;
              revision_created_at = None;
            }
          in
          if String.equal encoded (encode_revision revision) then Ok revision
          else Error Noncanonical_record
  | _ -> assert false

let decode_evolved_revision encoded fields =
  match fields with
  | [
   _version;
   capsule_id;
   id;
   capsule_ref;
   parent;
   declared_base;
   expected_result;
   operations;
   boundaries;
   provenance;
   created_at;
   features;
  ] ->
      let* capsule_id, id, capsule_ref =
        decode_revision_common ~capsule_id ~id ~capsule_ref
      in
      let* parent =
        match parent with
        | Encoding.Null -> Ok None
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ ->
            decode_revision_link parent |> Result.map Option.some
      in
      let* declared_base = decode_snapshot_link declared_base in
      let* expected_result = decode_snapshot_link expected_result in
      let* operations = decode_operations operations in
      let* source_boundaries = decode_boundaries boundaries in
      let* provenance = decode_provenance provenance in
      let* created_at = integer "capsule revision creation time" created_at in
      let* features = integer "capsule revision mandatory features" features in
      let* () = check_features features in
      let* first_boundary =
        match source_boundaries with
        | first :: _ -> Ok first
        | [] -> Error Empty_source_boundaries
      in
      let* () =
        if same_snapshot_link declared_base first_boundary.source_snapshot then
          Ok ()
        else Error Boundary_base_mismatch
      in
      let* () =
        match parent with
        | None -> Ok ()
        | Some link ->
            if V2_model.Capsule_id.equal capsule_id link.linked_capsule_id then
              Ok ()
            else Error Parent_capsule_mismatch
      in
      let* () = validate_provenance capsule_id provenance in
      let expected_id =
        derive_evolved_revision_id ~capsule_id ~parent ~declared_base
          ~expected_result ~operations ~source_boundaries ~provenance
      in
      if not (V2_model.Capsule_revision_id.equal id expected_id) then
        Error (Invalid_payload "capsule revision logical identity mismatch")
      else
        let revision =
          {
            revision_schema_version = evolved_revision_schema_version;
            revision_identity = id;
            revision_capsule_id_ = capsule_id;
            capsule_ref;
            parent;
            declared_base;
            expected_result;
            revision_operations_ = operations;
            source_boundaries;
            provenance;
            revision_created_at = Some created_at;
          }
        in
        if String.equal encoded (encode_revision revision) then Ok revision
        else Error Noncanonical_record
  | _ -> assert false

let decode_revision encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  match value with
  | Encoding.Array (version :: _) ->
      let* version = integer "capsule revision version" version in
      if Int64.equal version current_schema_version then
        let* fields = fields "capsule revision" 9 value in
        decode_initial_revision encoded fields
      else if Int64.equal version evolved_revision_schema_version then
        let* fields = fields "capsule revision" 12 value in
        decode_evolved_revision encoded fields
      else Error (Unsupported_schema_version version)
  | Encoding.Array [] -> Error (Invalid_payload "capsule revision is empty")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "capsule revision must be an array")
