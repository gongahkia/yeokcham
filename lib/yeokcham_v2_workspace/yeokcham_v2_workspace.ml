module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

type selected_revision = {
  link : Capsule.revision_link;
  capsule_revision : Capsule.revision;
}

type precedence = {
  before : V2_model.Capsule_revision_id.t;
  after : V2_model.Capsule_revision_id.t;
}

type order = { selected : selected_revision list; precedence : precedence list }

type error =
  | Duplicate_capsule of V2_model.Capsule_id.t
  | Duplicate_revision of V2_model.Capsule_revision_id.t
  | Selection_link_mismatch of V2_model.Capsule_revision_id.t
  | Precedence_duplicate of precedence
  | Precedence_unknown of V2_model.Capsule_revision_id.t
  | Precedence_cycle of V2_model.Capsule_revision_id.t list

let error_to_string = function
  | Duplicate_capsule capsule ->
      "workspace selects capsule more than once: "
      ^ V2_model.Capsule_id.to_hex capsule
  | Duplicate_revision revision ->
      "workspace selects revision more than once: "
      ^ V2_model.Capsule_revision_id.to_hex revision
  | Selection_link_mismatch revision ->
      "workspace selection link does not match revision: "
      ^ V2_model.Capsule_revision_id.to_hex revision
  | Precedence_duplicate { before; after } ->
      "workspace precedence repeats edge "
      ^ V2_model.Capsule_revision_id.to_hex before
      ^ " -> "
      ^ V2_model.Capsule_revision_id.to_hex after
  | Precedence_unknown revision ->
      "workspace precedence names an unselected revision: "
      ^ V2_model.Capsule_revision_id.to_hex revision
  | Precedence_cycle revisions ->
      "workspace precedence cycle: "
      ^ String.concat ","
          (List.map V2_model.Capsule_revision_id.to_hex revisions)

let ( let* ) = Result.bind
let revision_id selected = Capsule.revision_link_revision_id selected.link
let capsule_id selected = Capsule.revision_link_capsule_id selected.link

let compare_selected left right =
  let compared =
    V2_model.Capsule_revision_id.compare (revision_id left) (revision_id right)
  in
  if Int.equal compared 0 then
    V2_model.Capsule_id.compare (capsule_id left) (capsule_id right)
  else compared

let compare_by_capsule left right =
  let compared =
    V2_model.Capsule_id.compare (capsule_id left) (capsule_id right)
  in
  if Int.equal compared 0 then
    V2_model.Capsule_revision_id.compare (revision_id left) (revision_id right)
  else compared

let compare_precedence left right =
  let compared =
    V2_model.Capsule_revision_id.compare left.before right.before
  in
  if Int.equal compared 0 then
    V2_model.Capsule_revision_id.compare left.after right.after
  else compared

let revision_link_matches selected =
  V2_model.Capsule_id.equal (capsule_id selected)
    (Capsule.revision_capsule_id selected.capsule_revision)
  && V2_model.Capsule_revision_id.equal (revision_id selected)
       (Capsule.revision_id selected.capsule_revision)

let rec first_duplicate equal = function
  | left :: (right :: _ as rest) ->
      if equal left right then Some left else first_duplicate equal rest
  | [] | [ _ ] -> None

let validate_selection selected =
  match
    List.find_opt
      (fun selected -> not (revision_link_matches selected))
      selected
  with
  | Some selected -> Error (Selection_link_mismatch (revision_id selected))
  | None -> (
      let sorted_by_capsule = List.sort compare_by_capsule selected in
      match
        first_duplicate
          (fun left right ->
            V2_model.Capsule_id.equal (capsule_id left) (capsule_id right))
          sorted_by_capsule
      with
      | Some selected -> Error (Duplicate_capsule (capsule_id selected))
      | None -> (
          let sorted = List.sort compare_selected selected in
          match
            first_duplicate
              (fun left right ->
                V2_model.Capsule_revision_id.equal (revision_id left)
                  (revision_id right))
              sorted
          with
          | Some selected -> Error (Duplicate_revision (revision_id selected))
          | None -> Ok sorted))

let selected_revision selected revision =
  List.exists
    (fun candidate ->
      V2_model.Capsule_revision_id.equal (revision_id candidate) revision)
    selected

let validate_precedence selected precedence =
  let precedence = List.sort compare_precedence precedence in
  match
    first_duplicate
      (fun left right ->
        V2_model.Capsule_revision_id.equal left.before right.before
        && V2_model.Capsule_revision_id.equal left.after right.after)
      precedence
  with
  | Some duplicate -> Error (Precedence_duplicate duplicate)
  | None ->
      let rec validate = function
        | [] -> Ok precedence
        | edge :: rest ->
            if not (selected_revision selected edge.before) then
              Error (Precedence_unknown edge.before)
            else if not (selected_revision selected edge.after) then
              Error (Precedence_unknown edge.after)
            else validate rest
      in
      validate precedence

let has_incoming precedence remaining selected =
  List.exists
    (fun edge ->
      V2_model.Capsule_revision_id.equal edge.after (revision_id selected)
      && selected_revision remaining edge.before)
    precedence

let derive_order ~selected ~precedence =
  let* selected = validate_selection selected in
  let* precedence = validate_precedence selected precedence in
  let rec sort remaining reversed =
    match remaining with
    | [] -> Ok { selected = List.rev reversed; precedence }
    | _ -> (
        match
          List.find_opt
            (fun selected -> not (has_incoming precedence remaining selected))
            remaining
        with
        | Some next ->
            let remaining =
              List.filter
                (fun candidate ->
                  not
                    (V2_model.Capsule_revision_id.equal (revision_id candidate)
                       (revision_id next)))
                remaining
            in
            sort remaining (next :: reversed)
        | None -> Error (Precedence_cycle (List.map revision_id remaining)))
  in
  sort selected []

let ordered_revisions order = order.selected
let precedence_edges order = order.precedence

type conflict = {
  revision : Capsule.revision_link;
  operation_index : int;
  paths : Model.Path.t list;
  cause : Model.transition_error;
}

type operation_outcome =
  | Applied_exactly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Skipped_explicitly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Conflict of conflict
  | Blocked_by_conflict of {
      revision : Capsule.revision_link;
      operation_index : int;
      blocked_by : conflict;
    }

type resolution_action =
  | Skip_operation of {
      revision : Capsule.revision_link;
      operation_index : int;
    }

type application = {
  resulting_snapshot : Model.Snapshot.t;
  outcomes : operation_outcome list;
  conflicts : conflict list;
}

let operation_paths = function
  | Model.Create_file { path; _ }
  | Model.Create_directory { path }
  | Model.Modify_file { path; _ }
  | Model.Delete_path { path; _ }
  | Model.Change_mode { path; _ } ->
      [ path ]
  | Model.Move_path { source; destination; _ } -> [ source; destination ]

let same_link left right =
  V2_model.Capsule_id.equal
    (Capsule.revision_link_capsule_id left)
    (Capsule.revision_link_capsule_id right)
  && V2_model.Capsule_revision_id.equal
       (Capsule.revision_link_revision_id left)
       (Capsule.revision_link_revision_id right)
  && V2_model.Opaque_object_ref.equal
       (Capsule.revision_link_ref left)
       (Capsule.revision_link_ref right)

let is_skipped resolutions ~revision ~operation_index =
  List.exists
    (function
      | Skip_operation selected ->
          same_link selected.revision revision
          && Int.equal selected.operation_index operation_index)
    resolutions

let paths_intersect left right =
  List.exists
    (fun left_path -> List.exists (Model.Path.equal left_path) right)
    left

let apply_operation snapshot operation =
  match Model.Snapshot.apply_operations snapshot [ operation ] with
  | Ok snapshot -> Ok snapshot
  | Error { Model.cause; _ } -> Error cause

let apply ~base ~order ~resolutions =
  let apply_revision (snapshot, outcomes, conflicts) selected =
    Capsule.revision_operations selected.capsule_revision
    |> List.mapi (fun operation_index operation -> (operation_index, operation))
    |> List.fold_left
         (fun (snapshot, outcomes, conflicts) (operation_index, operation) ->
           let revision = selected.link in
           if is_skipped resolutions ~revision ~operation_index then
             ( snapshot,
               Skipped_explicitly { revision; operation_index } :: outcomes,
               conflicts )
           else
             let paths = operation_paths operation in
             match
               List.find_opt
                 (fun conflict -> paths_intersect paths conflict.paths)
                 conflicts
             with
             | Some blocked_by ->
                 ( snapshot,
                   Blocked_by_conflict { revision; operation_index; blocked_by }
                   :: outcomes,
                   conflicts )
             | None -> (
                 match apply_operation snapshot operation with
                 | Ok snapshot ->
                     ( snapshot,
                       Applied_exactly { revision; operation_index } :: outcomes,
                       conflicts )
                 | Error cause ->
                     let conflict =
                       { revision; operation_index; paths; cause }
                     in
                     ( snapshot,
                       Conflict conflict :: outcomes,
                       conflict :: conflicts )))
         (snapshot, outcomes, conflicts)
  in
  let snapshot, outcomes, conflicts =
    List.fold_left apply_revision (base, [], []) (ordered_revisions order)
  in
  {
    resulting_snapshot = snapshot;
    outcomes = List.rev outcomes;
    conflicts = List.rev conflicts;
  }
