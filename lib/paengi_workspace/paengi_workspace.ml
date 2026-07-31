module Capsule = Paengi_capsule
module Id = Paengi_id

[@@@warning "-4"]

type selected_revision = {
  capsule : Id.Capsule_id.t;
  revision : Id.Capsule_revision_id.t;
  dependencies : Capsule.dependency list;
}

type edge_kind = Required_dependency | Declared_order | Explicit_precedence

type edge = {
  before : Id.Capsule_revision_id.t;
  after : Id.Capsule_revision_id.t;
  reasons : edge_kind list;
}

type order = {
  ordered_revisions : selected_revision list;
  order_edges : edge list;
}

type error =
  | Duplicate_capsule of Id.Capsule_id.t
  | Duplicate_revision of Id.Capsule_revision_id.t
  | Required_capsule_missing of {
      requiring : Id.Capsule_revision_id.t;
      required_capsule : Id.Capsule_id.t;
    }
  | Required_revision_missing of {
      requiring : Id.Capsule_revision_id.t;
      required_capsule : Id.Capsule_id.t;
      required_revision : Id.Capsule_revision_id.t;
    }
  | Required_release_unavailable of {
      requiring : Id.Capsule_revision_id.t;
      required_release : Id.Release_id.t;
    }
  | Conflicting_capsules of {
      declared_by : Id.Capsule_id.t;
      conflicts_with : Id.Capsule_id.t;
    }
  | Explicit_order_duplicate of Id.Capsule_revision_id.t
  | Explicit_order_unknown of Id.Capsule_revision_id.t
  | Explicit_order_missing of Id.Capsule_revision_id.t
  | Dependency_cycle of Id.Capsule_revision_id.t list

let edge_kind_to_string = function
  | Required_dependency -> "requires"
  | Declared_order -> "ordered-after"
  | Explicit_precedence -> "explicit"

let error_to_string = function
  | Duplicate_capsule capsule ->
      "workspace selects capsule more than once: "
      ^ Id.Capsule_id.to_hex capsule
  | Duplicate_revision revision ->
      "workspace selects revision more than once: "
      ^ Id.Capsule_revision_id.to_hex revision
  | Required_capsule_missing { requiring; required_capsule } ->
      Printf.sprintf "revision %s requires unselected capsule %s"
        (Id.Capsule_revision_id.to_hex requiring)
        (Id.Capsule_id.to_hex required_capsule)
  | Required_revision_missing { requiring; required_capsule; required_revision }
    ->
      Printf.sprintf "revision %s requires %s at revision %s"
        (Id.Capsule_revision_id.to_hex requiring)
        (Id.Capsule_id.to_hex required_capsule)
        (Id.Capsule_revision_id.to_hex required_revision)
  | Required_release_unavailable { requiring; required_release } ->
      Printf.sprintf "revision %s requires unavailable release %s"
        (Id.Capsule_revision_id.to_hex requiring)
        (Id.Release_id.to_hex required_release)
  | Conflicting_capsules { declared_by; conflicts_with } ->
      Printf.sprintf "selected capsule %s conflicts with selected capsule %s"
        (Id.Capsule_id.to_hex declared_by)
        (Id.Capsule_id.to_hex conflicts_with)
  | Explicit_order_duplicate revision ->
      "explicit order repeats revision "
      ^ Id.Capsule_revision_id.to_hex revision
  | Explicit_order_unknown revision ->
      "explicit order names an unselected revision "
      ^ Id.Capsule_revision_id.to_hex revision
  | Explicit_order_missing revision ->
      "explicit order omits selected revision "
      ^ Id.Capsule_revision_id.to_hex revision
  | Dependency_cycle revisions ->
      "workspace dependency cycle: "
      ^ String.concat "," (List.map Id.Capsule_revision_id.to_hex revisions)

let ( let* ) = Result.bind

let compare_selection left right =
  let compared = Id.Capsule_revision_id.compare left.revision right.revision in
  if compared <> 0 then compared
  else Id.Capsule_id.compare left.capsule right.capsule

let compare_capsule_selection left right =
  let compared = Id.Capsule_id.compare left.capsule right.capsule in
  if compared <> 0 then compared
  else Id.Capsule_revision_id.compare left.revision right.revision

let rec duplicate_by equal = function
  | left :: (right :: _ as rest) ->
      if equal left right then Some left else duplicate_by equal rest
  | _ -> None

let find_by_capsule selected capsule =
  List.find_opt
    (fun candidate -> Id.Capsule_id.equal candidate.capsule capsule)
    selected

let find_by_revision selected revision =
  List.find_opt
    (fun candidate -> Id.Capsule_revision_id.equal candidate.revision revision)
    selected

let dependency_key = function
  | Capsule.Requires_capsule { capsule; revision } -> (
      "0:"
      ^ Id.Capsule_id.to_hex capsule
      ^ ":"
      ^
      match revision with
      | None -> ""
      | Some revision -> Id.Capsule_revision_id.to_hex revision)
  | Capsule.Requires_release release -> "1:" ^ Id.Release_id.to_hex release
  | Capsule.Conflicts_with_capsule capsule ->
      "2:" ^ Id.Capsule_id.to_hex capsule
  | Capsule.Ordered_after capsule -> "3:" ^ Id.Capsule_id.to_hex capsule

let sorted_dependencies dependencies =
  List.sort
    (fun left right ->
      String.compare (dependency_key left) (dependency_key right))
    dependencies

let reason_rank = function
  | Required_dependency -> 0
  | Declared_order -> 1
  | Explicit_precedence -> 2

let insert_reason reason reasons =
  if List.exists (( = ) reason) reasons then reasons
  else
    List.sort
      (fun left right -> Int.compare (reason_rank left) (reason_rank right))
      (reason :: reasons)

let add_edge edges ~before ~after ~reason =
  let rec loop reversed = function
    | [] -> List.rev ({ before; after; reasons = [ reason ] } :: reversed)
    | edge :: rest
      when Id.Capsule_revision_id.equal edge.before before
           && Id.Capsule_revision_id.equal edge.after after ->
        List.rev_append reversed
          ({ edge with reasons = insert_reason reason edge.reasons } :: rest)
    | edge :: rest -> loop (edge :: reversed) rest
  in
  loop [] edges

let compare_edge left right =
  let compared = Id.Capsule_revision_id.compare left.before right.before in
  if compared <> 0 then compared
  else Id.Capsule_revision_id.compare left.after right.after

let validate_selection selected =
  let by_capsule = List.sort compare_capsule_selection selected in
  match
    duplicate_by
      (fun left right -> Id.Capsule_id.equal left.capsule right.capsule)
      by_capsule
  with
  | Some duplicate -> Error (Duplicate_capsule duplicate.capsule)
  | None -> (
      let by_revision = List.sort compare_selection selected in
      match
        duplicate_by
          (fun left right ->
            Id.Capsule_revision_id.equal left.revision right.revision)
          by_revision
      with
      | Some duplicate -> Error (Duplicate_revision duplicate.revision)
      | None -> Ok by_revision)

let validate_conflicts selected =
  let rec dependencies_for selection = function
    | [] -> Ok ()
    | Capsule.Conflicts_with_capsule conflicts_with :: rest ->
        if Option.is_some (find_by_capsule selected conflicts_with) then
          Error
            (Conflicting_capsules
               { declared_by = selection.capsule; conflicts_with })
        else dependencies_for selection rest
    | _ :: rest -> dependencies_for selection rest
  in
  let rec selections = function
    | [] -> Ok ()
    | selection :: rest ->
        let* () =
          dependencies_for selection
            (sorted_dependencies selection.dependencies)
        in
        selections rest
  in
  selections selected

let declared_edges selected =
  let add_dependencies selection edges =
    let rec loop edges = function
      | [] -> Ok edges
      | Capsule.Requires_capsule { capsule; revision } :: rest -> (
          match find_by_capsule selected capsule with
          | None ->
              Error
                (Required_capsule_missing
                   {
                     requiring = selection.revision;
                     required_capsule = capsule;
                   })
          | Some required -> (
              match revision with
              | Some expected
                when not
                       (Id.Capsule_revision_id.equal expected required.revision)
                ->
                  Error
                    (Required_revision_missing
                       {
                         requiring = selection.revision;
                         required_capsule = capsule;
                         required_revision = expected;
                       })
              | None | Some _ ->
                  loop
                    (add_edge edges ~before:required.revision
                       ~after:selection.revision ~reason:Required_dependency)
                    rest))
      | Capsule.Requires_release required_release :: _ ->
          Error
            (Required_release_unavailable
               { requiring = selection.revision; required_release })
      | Capsule.Ordered_after capsule :: rest ->
          let edges =
            match find_by_capsule selected capsule with
            | None -> edges
            | Some prior ->
                add_edge edges ~before:prior.revision ~after:selection.revision
                  ~reason:Declared_order
          in
          loop edges rest
      | Capsule.Conflicts_with_capsule _ :: rest -> loop edges rest
    in
    loop edges (sorted_dependencies selection.dependencies)
  in
  let rec selections edges = function
    | [] -> Ok edges
    | selection :: rest ->
        let* edges = add_dependencies selection edges in
        selections edges rest
  in
  selections [] selected

let explicit_edges selected explicit_order edges =
  match explicit_order with
  | None -> Ok edges
  | Some revisions ->
      let rec validate seen = function
        | [] -> Ok ()
        | revision :: rest ->
            if List.exists (Id.Capsule_revision_id.equal revision) seen then
              Error (Explicit_order_duplicate revision)
            else if Option.is_none (find_by_revision selected revision) then
              Error (Explicit_order_unknown revision)
            else validate (revision :: seen) rest
      in
      let* () = validate [] revisions in
      let rec complete = function
        | [] -> Ok ()
        | selection :: rest ->
            if
              List.exists
                (Id.Capsule_revision_id.equal selection.revision)
                revisions
            then complete rest
            else Error (Explicit_order_missing selection.revision)
      in
      let* () = complete selected in
      let rec add_pairs edges = function
        | before :: (after :: _ as rest) ->
            add_pairs
              (add_edge edges ~before ~after ~reason:Explicit_precedence)
              rest
        | _ -> edges
      in
      Ok (add_pairs edges revisions)

let has_incoming edges remaining revision =
  List.exists
    (fun edge ->
      Id.Capsule_revision_id.equal edge.after revision
      && Option.is_some (find_by_revision remaining edge.before))
    edges

let derive_order ~selected ~explicit_order =
  let* selected = validate_selection selected in
  let* () = validate_conflicts selected in
  let* edges = declared_edges selected in
  let* edges = explicit_edges selected explicit_order edges in
  let edges = List.sort compare_edge edges in
  let rec sort remaining reversed =
    match remaining with
    | [] -> Ok { ordered_revisions = List.rev reversed; order_edges = edges }
    | _ -> (
        match
          List.find_opt
            (fun selection ->
              not (has_incoming edges remaining selection.revision))
            remaining
        with
        | Some next ->
            let remaining =
              List.filter
                (fun selection ->
                  not
                    (Id.Capsule_revision_id.equal selection.revision
                       next.revision))
                remaining
            in
            sort remaining (next :: reversed)
        | None ->
            Error
              (Dependency_cycle
                 (List.map (fun selection -> selection.revision) remaining)))
  in
  sort selected []

let revisions order = order.ordered_revisions
let edges order = order.order_edges

type application_revision = {
  selected : selected_revision;
  operations : Capsule.operation list;
}

type conflict_kind =
  | Missing_or_ambiguous_precondition
  | Competing_edits
  | Delete_modify
  | Move_modify
  | Binary_conflict
  | Dependency_failure
  | Unsupported_or_uncertain_operation

type application_conflict = {
  conflict_capsule : Id.Capsule_id.t;
  conflict_revision : Id.Capsule_revision_id.t;
  operation_index : int;
  kind : conflict_kind;
  paths : Paengi_scratch.path list;
  current : Paengi_scratch.entry option;
}

type operation_outcome =
  | Applied_exactly of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Already_satisfied of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Persistent_conflict of application_conflict
  | Blocked_dependency of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
      blocked_by : application_conflict;
    }
  | Rejected_operation of application_conflict
  | Resolved_explicitly of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }

type resolution_action =
  | Skip_operation of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }

type application = {
  state : Paengi_scratch.State.t;
  outcomes : operation_outcome list;
  conflicts : application_conflict list;
}

let conflict_kind_to_string = function
  | Missing_or_ambiguous_precondition -> "missing-or-ambiguous-precondition"
  | Competing_edits -> "competing-edits"
  | Delete_modify -> "delete-modify"
  | Move_modify -> "move-modify"
  | Binary_conflict -> "binary-conflict"
  | Dependency_failure -> "dependency-failure"
  | Unsupported_or_uncertain_operation -> "unsupported-or-uncertain-operation"

let entry_equal left right =
  match (left, right) with
  | Paengi_scratch.Directory, Paengi_scratch.Directory -> true
  | Paengi_scratch.File left, Paengi_scratch.File right ->
      left.mode = right.mode
      && Paengi_snapshot.Content.equal_id left.content right.content
  | Paengi_scratch.Directory, Paengi_scratch.File _
  | Paengi_scratch.File _, Paengi_scratch.Directory ->
      false

let option_entry_equal left right = Option.equal entry_equal left right

let operation_paths (operation : Capsule.operation) =
  match operation with
  | Capsule.Exact_file_transition transition ->
      [ transition.Capsule.transition_path ]
  | Capsule.Text_edit edit -> [ edit.Capsule.edit_path ]
  | Capsule.Move { source; destination; _ } -> [ source; destination ]
  | Capsule.Mode_change { path; _ } -> [ path ]

let operation_current state (operation : Capsule.operation) =
  match operation with
  | Capsule.Exact_file_transition transition ->
      Paengi_scratch.State.find state transition.Capsule.transition_path
  | Capsule.Text_edit edit ->
      Paengi_scratch.State.find state edit.Capsule.edit_path
  | Capsule.Move { source; _ } -> Paengi_scratch.State.find state source
  | Capsule.Mode_change { path; _ } -> Paengi_scratch.State.find state path

let operation_already_satisfied state (operation : Capsule.operation) =
  match operation with
  | Capsule.Exact_file_transition transition ->
      option_entry_equal
        (Paengi_scratch.State.find state transition.Capsule.transition_path)
        transition.Capsule.replacement_entry
  | Capsule.Text_edit _ -> false
  | Capsule.Move { source; destination; prior } ->
      Option.is_none (Paengi_scratch.State.find state source)
      && Option.equal entry_equal
           (Paengi_scratch.State.find state destination)
           (Some prior)
  | Capsule.Mode_change { path; replacement; _ } -> (
      match Paengi_scratch.State.find state path with
      | Some (Paengi_scratch.File file) -> file.mode = replacement
      | Some Paengi_scratch.Directory | None -> false)

let apply_exact_transition state (transition : Capsule.exact_file_transition) =
  if
    not
      (option_entry_equal
         (Paengi_scratch.State.find state transition.Capsule.transition_path)
         transition.Capsule.expected_entry)
  then Error "entry precondition failed"
  else
    let operations =
      match
        (transition.Capsule.expected_entry, transition.Capsule.replacement_entry)
      with
      | None, None -> []
      | None, Some entry ->
          [
            Paengi_scratch.Create
              { path = transition.Capsule.transition_path; entry };
          ]
      | Some prior, None ->
          [
            Paengi_scratch.Delete
              { path = transition.Capsule.transition_path; prior };
          ]
      | Some prior, Some replacement when entry_equal prior replacement -> []
      | Some prior, Some replacement ->
          [
            Paengi_scratch.Delete
              { path = transition.Capsule.transition_path; prior };
            Paengi_scratch.Create
              { path = transition.Capsule.transition_path; entry = replacement };
          ]
    in
    Paengi_scratch.State.apply state operations
    |> Result.map_error Paengi_scratch.error_to_string

let apply_operation state (operation : Capsule.operation) =
  match operation with
  | Capsule.Exact_file_transition transition ->
      apply_exact_transition state transition
  | Capsule.Text_edit _ -> Error "text fallback requires an explicit resolution"
  | Capsule.Move { source; destination; prior } ->
      Paengi_scratch.State.apply state
        [ Paengi_scratch.Move { source; destination; prior } ]
      |> Result.map_error Paengi_scratch.error_to_string
  | Capsule.Mode_change { path; expected; replacement } ->
      Paengi_scratch.State.apply state
        [ Paengi_scratch.Change_mode { path; expected; replacement } ]
      |> Result.map_error Paengi_scratch.error_to_string

let kind_of_operation (operation : Capsule.operation) =
  match operation with
  | Capsule.Exact_file_transition { Capsule.replacement_entry = None; _ } ->
      Delete_modify
  | Capsule.Exact_file_transition _ | Capsule.Mode_change _ -> Competing_edits
  | Capsule.Move _ -> Move_modify
  | Capsule.Text_edit _ -> Unsupported_or_uncertain_operation

let path_equal = List.equal String.equal

let intersects left right =
  List.exists (fun left -> List.exists (path_equal left) right) left

let is_skipped resolutions ~capsule ~revision ~operation_index =
  List.exists
    (function
      | Skip_operation selected ->
          Id.Capsule_id.equal selected.capsule capsule
          && Id.Capsule_revision_id.equal selected.revision revision
          && Int.equal selected.operation_index operation_index)
    resolutions

let apply ~state ~ordered ~resolutions =
  let rec apply_operations state outcomes conflicts selection index = function
    | [] -> (state, outcomes, conflicts)
    | operation :: rest ->
        let capsule = selection.selected.capsule in
        let revision = selection.selected.revision in
        let paths = operation_paths operation in
        let state, outcome, conflicts =
          if is_skipped resolutions ~capsule ~revision ~operation_index:index
          then
            ( state,
              Resolved_explicitly { capsule; revision; operation_index = index },
              conflicts )
          else
            match
              List.find_opt
                (fun conflict -> intersects paths conflict.paths)
                conflicts
            with
            | Some blocked_by ->
                ( state,
                  Blocked_dependency
                    { capsule; revision; operation_index = index; blocked_by },
                  conflicts )
            | None when operation_already_satisfied state operation ->
                ( state,
                  Already_satisfied
                    { capsule; revision; operation_index = index },
                  conflicts )
            | None -> (
                match apply_operation state operation with
                | Ok next ->
                    ( next,
                      Applied_exactly
                        { capsule; revision; operation_index = index },
                      conflicts )
                | Error _ ->
                    let conflict =
                      {
                        conflict_capsule = capsule;
                        conflict_revision = revision;
                        operation_index = index;
                        kind = kind_of_operation operation;
                        paths;
                        current = operation_current state operation;
                      }
                    in
                    (state, Persistent_conflict conflict, conflict :: conflicts)
                )
        in
        apply_operations state (outcome :: outcomes) conflicts selection
          (index + 1) rest
  in
  let rec apply_revisions state outcomes conflicts = function
    | [] ->
        { state; outcomes = List.rev outcomes; conflicts = List.rev conflicts }
    | revision :: rest ->
        let state, outcomes, conflicts =
          apply_operations state outcomes conflicts revision 0
            revision.operations
        in
        apply_revisions state outcomes conflicts rest
  in
  apply_revisions state [] [] ordered
