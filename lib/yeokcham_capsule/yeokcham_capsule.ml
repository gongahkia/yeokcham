module Encoding = Yeokcham_encoding
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot

type path = Scratch.path
type entry = Scratch.entry

type dependency =
  | Requires_capsule of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t option;
    }
  | Requires_release of Id.Release_id.t
  | Conflicts_with_capsule of Id.Capsule_id.t
  | Ordered_after of Id.Capsule_id.t

type exact_file_transition = {
  transition_path : path;
  expected_entry : entry option;
  replacement_entry : entry option;
}

type text_anchor = {
  before_context : string;
  selected : string;
  after_context : string;
}

type text_edit = {
  edit_path : path;
  anchor : text_anchor;
  replacement : string;
  fallback_transition : exact_file_transition;
}

type operation =
  | Exact_file_transition of exact_file_transition
  | Text_edit of text_edit
  | Move of { source : path; destination : path; prior : entry }
  | Mode_change of {
      path : path;
      expected : Snapshot.file_mode;
      replacement : Snapshot.file_mode;
    }

type validation_status = Passed | Failed of int | Timed_out | Not_run

type validation_evidence = {
  command : string list;
  environment_fingerprint : string option;
  snapshot : Snapshot.Snapshot.id;
  status : validation_status;
  stdout_digest : Snapshot.Content.id option;
  stderr_digest : Snapshot.Content.id option;
  started_at : int64;
  duration_ms : int64;
}

type construction_error =
  | Invalid_capsule_id_length of int
  | Invalid_revision_id_length of int
  | Empty_title
  | Invalid_title_utf8 of int
  | Invalid_description_utf8 of int
  | Revision_cannot_parent_itself

let construction_error_to_string = function
  | Invalid_capsule_id_length length ->
      Printf.sprintf "capsule ID must be 32 bytes, got %d" length
  | Invalid_revision_id_length length ->
      Printf.sprintf "capsule revision ID must be 32 bytes, got %d" length
  | Empty_title -> "capsule title must not be empty"
  | Invalid_title_utf8 offset ->
      Printf.sprintf "capsule title is not valid UTF-8 at byte %d" offset
  | Invalid_description_utf8 offset ->
      Printf.sprintf "capsule description is not valid UTF-8 at byte %d" offset
  | Revision_cannot_parent_itself -> "a revision cannot parent itself"

type capsule = {
  capsule_id : Id.Capsule_id.t;
  capsule_title : string;
  capsule_description : string;
  capsule_dependencies : dependency list;
}

type revision = {
  id : Id.Capsule_revision_id.t;
  capsule : Id.Capsule_id.t;
  parent : Id.Capsule_revision_id.t option;
  declared_base : Snapshot.Snapshot.id;
  operations : operation list;
  expected_result : Snapshot.Snapshot.id option;
  evidence : validation_evidence list;
  created_at : int64;
}

let ( let* ) = Result.bind

let valid_utf8 value error =
  match Encoding.text value with
  | Ok _ -> Ok ()
  | Error (Encoding.Invalid_text_utf8 offset) -> Error (error offset)
  | Error
      ( Encoding.Negative_map_key _ | Encoding.Duplicate_map_key _
      | Encoding.Nesting_limit_exceeded _ ) ->
      assert false

let create ~id ~title ~description ~dependencies =
  let id_length = String.length (Id.Capsule_id.to_bytes id) in
  if id_length <> 32 then Error (Invalid_capsule_id_length id_length)
  else if String.is_empty title then Error Empty_title
  else
    let* () = valid_utf8 title (fun offset -> Invalid_title_utf8 offset) in
    let* () =
      valid_utf8 description (fun offset -> Invalid_description_utf8 offset)
    in
    Ok
      {
        capsule_id = id;
        capsule_title = title;
        capsule_description = description;
        capsule_dependencies = dependencies;
      }

let id capsule = capsule.capsule_id
let title capsule = capsule.capsule_title
let description capsule = capsule.capsule_description
let dependencies capsule = capsule.capsule_dependencies

let create_revision ~id ~capsule ~parent ~declared_base ~operations
    ~expected_result ~evidence ~created_at =
  let id_length = String.length (Id.Capsule_revision_id.to_bytes id) in
  if id_length <> 32 then Error (Invalid_revision_id_length id_length)
  else if Option.exists (Id.Capsule_revision_id.equal id) parent then
    Error Revision_cannot_parent_itself
  else
    Ok
      {
        id;
        capsule = capsule.capsule_id;
        parent;
        declared_base;
        operations;
        expected_result;
        evidence;
        created_at;
      }

let revision_id revision = revision.id
let revision_capsule revision = revision.capsule
let revision_parent revision = revision.parent
let revision_declared_base revision = revision.declared_base
let revision_operations revision = revision.operations
let revision_expected_result revision = revision.expected_result
let revision_evidence revision = revision.evidence
let revision_created_at revision = revision.created_at

type application_conflict =
  | Declared_base_mismatch of {
      expected : Snapshot.Snapshot.id;
      actual : Snapshot.Snapshot.id;
    }
  | Exact_transition_rejected of {
      operation_index : int;
      path : path;
      detail : string;
    }
  | Text_fallback_required of { operation_index : int; edit : text_edit }
  | Move_rejected of {
      operation_index : int;
      source : path;
      destination : path;
      detail : string;
    }
  | Mode_change_rejected of {
      operation_index : int;
      path : path;
      detail : string;
    }

type operation_outcome =
  | Applied_exactly of int
  | Application_conflict of application_conflict

type application_result = {
  state : Scratch.State.t;
  outcomes : operation_outcome list;
  conflicts : application_conflict list;
}

let path_to_string path = String.concat "/" path

let application_conflict_to_string = function
  | Declared_base_mismatch _ -> "declared base snapshot does not match"
  | Exact_transition_rejected { operation_index; path; detail } ->
      Printf.sprintf "operation %d exact transition rejected at %s: %s"
        operation_index (path_to_string path) detail
  | Text_fallback_required { operation_index; edit } ->
      Printf.sprintf "operation %d text fallback required at %s" operation_index
        (path_to_string edit.edit_path)
  | Move_rejected { operation_index; source; destination; detail } ->
      Printf.sprintf "operation %d move %s -> %s rejected: %s" operation_index
        (path_to_string source)
        (path_to_string destination)
        detail
  | Mode_change_rejected { operation_index; path; detail } ->
      Printf.sprintf "operation %d mode change rejected at %s: %s"
        operation_index (path_to_string path) detail

let entry_equal left right =
  match (left, right) with
  | Scratch.Directory, Scratch.Directory -> true
  | Scratch.File left, Scratch.File right ->
      left.mode = right.mode
      && Snapshot.Content.equal_id left.content right.content
  | Scratch.Directory, Scratch.File _ | Scratch.File _, Scratch.Directory ->
      false

let option_entry_equal left right = Option.equal entry_equal left right

let exact_operations transition =
  match (transition.expected_entry, transition.replacement_entry) with
  | None, None -> Ok []
  | None, Some entry ->
      Ok [ Scratch.Create { path = transition.transition_path; entry } ]
  | Some prior, None ->
      Ok [ Scratch.Delete { path = transition.transition_path; prior } ]
  | Some prior, Some replacement ->
      if entry_equal prior replacement then Ok []
      else
        Ok
          [
            Scratch.Delete { path = transition.transition_path; prior };
            Scratch.Create
              { path = transition.transition_path; entry = replacement };
          ]

let apply_exact_transition state transition =
  if
    not
      (option_entry_equal
         (Scratch.State.find state transition.transition_path)
         transition.expected_entry)
  then Error "entry precondition failed"
  else
    let* operations = exact_operations transition in
    Scratch.State.apply state operations
    |> Result.map_error Scratch.error_to_string

let apply_text_fallback state edit =
  apply_exact_transition state edit.fallback_transition

let apply ~actual_base ~state revision =
  if not (Snapshot.Snapshot.equal_id actual_base revision.declared_base) then
    let conflict =
      Declared_base_mismatch
        { expected = revision.declared_base; actual = actual_base }
    in
    {
      state;
      outcomes = [ Application_conflict conflict ];
      conflicts = [ conflict ];
    }
  else
    let step (state, outcomes, conflicts) index operation =
      let accepted state =
        (state, Applied_exactly index :: outcomes, conflicts)
      in
      let rejected conflict =
        (state, Application_conflict conflict :: outcomes, conflict :: conflicts)
      in
      match operation with
      | Exact_file_transition transition -> (
          match apply_exact_transition state transition with
          | Ok state -> accepted state
          | Error detail ->
              rejected
                (Exact_transition_rejected
                   {
                     operation_index = index;
                     path = transition.transition_path;
                     detail;
                   }))
      | Text_edit edit ->
          rejected (Text_fallback_required { operation_index = index; edit })
      | Move { source; destination; prior } -> (
          match
            Scratch.State.apply state
              [ Scratch.Move { source; destination; prior } ]
          with
          | Ok state -> accepted state
          | Error error ->
              rejected
                (Move_rejected
                   {
                     operation_index = index;
                     source;
                     destination;
                     detail = Scratch.error_to_string error;
                   }))
      | Mode_change { path; expected; replacement } -> (
          match
            Scratch.State.apply state
              [ Scratch.Change_mode { path; expected; replacement } ]
          with
          | Ok state -> accepted state
          | Error error ->
              rejected
                (Mode_change_rejected
                   {
                     operation_index = index;
                     path;
                     detail = Scratch.error_to_string error;
                   }))
    in
    let rec apply_all state outcomes conflicts index = function
      | [] -> (state, outcomes, conflicts)
      | operation :: rest ->
          let state, outcomes, conflicts =
            step (state, outcomes, conflicts) index operation
          in
          apply_all state outcomes conflicts (index + 1) rest
    in
    let state, outcomes, conflicts =
      apply_all state [] [] 0 revision.operations
    in
    { state; outcomes = List.rev outcomes; conflicts = List.rev conflicts }

module Draft = struct
  type error =
    | Scratch_error of Scratch.error
    | Snapshot_error of Snapshot.error
    | Construction_error of construction_error
    | Source_not_ancestor of {
        source : Scratch.Checkpoint_id.t;
        target : Scratch.Checkpoint_id.t;
      }
    | Derived_replay_mismatch

  type t = {
    source_checkpoint : Scratch.Checkpoint_id.t;
    target_checkpoint : Scratch.Checkpoint_id.t;
    source_snapshot : Snapshot.Snapshot.id;
    target_snapshot : Snapshot.Snapshot.id;
    revision : revision;
  }

  let error_to_string = function
    | Scratch_error error -> Scratch.error_to_string error
    | Snapshot_error error -> Snapshot.error_to_string error
    | Construction_error error -> construction_error_to_string error
    | Source_not_ancestor _ ->
        "source checkpoint is not an ancestor of the target checkpoint"
    | Derived_replay_mismatch ->
        "derived exact operations do not replay to the target state"

  let operation_from_scratch state operation =
    match operation with
    | Scratch.Create { path; _ }
    | Scratch.Delete { path; _ }
    | Scratch.Modify_content { path; _ } ->
        let* next =
          Scratch.State.apply state [ operation ]
          |> Result.map_error (fun error -> Scratch_error error)
        in
        Ok
          ( Exact_file_transition
              {
                transition_path = path;
                expected_entry = Scratch.State.find state path;
                replacement_entry = Scratch.State.find next path;
              },
            next )
    | Scratch.Change_mode { path; expected; replacement } ->
        let* next =
          Scratch.State.apply state [ operation ]
          |> Result.map_error (fun error -> Scratch_error error)
        in
        Ok (Mode_change { path; expected; replacement }, next)
    | Scratch.Move { source; destination; prior } ->
        let* next =
          Scratch.State.apply state [ operation ]
          |> Result.map_error (fun error -> Scratch_error error)
        in
        Ok (Move { source; destination; prior }, next)

  let operations_between ~from ~to_ =
    let scratch_operations = Scratch.State.diff ~from ~to_ in
    let rec derive state reversed = function
      | [] ->
          if Scratch.State.equal state to_ then Ok (List.rev reversed)
          else Error Derived_replay_mismatch
      | operation :: rest ->
          let* capsule_operation, state =
            operation_from_scratch state operation
          in
          derive state (capsule_operation :: reversed) rest
    in
    derive from [] scratch_operations

  let is_ancestor scratch ~source ~target =
    let* timeline =
      Scratch.timeline scratch ~start:target ~limit:max_int ()
      |> Result.map_error (fun error -> Scratch_error error)
    in
    if
      List.exists
        (fun entry ->
          Scratch.Checkpoint_id.equal source entry.Scratch.logical_id)
        timeline
    then Ok ()
    else Error (Source_not_ancestor { source; target })

  let checkpoint_state store scratch identity =
    let* resolved =
      Scratch.resolve_checkpoint scratch identity
      |> Result.map_error (fun error -> Scratch_error error)
    in
    let checkpoint = Scratch.resolved_checkpoint resolved in
    let snapshot_id = Scratch.Checkpoint.snapshot checkpoint in
    let* snapshot =
      Snapshot.Snapshot.load store snapshot_id
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* state =
      Scratch.State.of_snapshot store snapshot
      |> Result.map_error (fun error -> Scratch_error error)
    in
    Ok (snapshot_id, state)

  let from_checkpoints ~store ~scratch ~capsule ~revision_id ~from ~target
      ~evidence ~created_at =
    let* () = is_ancestor scratch ~source:from ~target in
    let* source_snapshot, source_state = checkpoint_state store scratch from in
    let* target_snapshot, target_state =
      checkpoint_state store scratch target
    in
    let* operations = operations_between ~from:source_state ~to_:target_state in
    let* revision =
      create_revision ~id:revision_id ~capsule ~parent:None
        ~declared_base:source_snapshot ~operations
        ~expected_result:(Some target_snapshot) ~evidence ~created_at
      |> Result.map_error (fun error -> Construction_error error)
    in
    Ok
      {
        source_checkpoint = from;
        target_checkpoint = target;
        source_snapshot;
        target_snapshot;
        revision;
      }

  let source_checkpoint draft = draft.source_checkpoint
  let target_checkpoint draft = draft.target_checkpoint
  let source_snapshot draft = draft.source_snapshot
  let target_snapshot draft = draft.target_snapshot
  let revision draft = draft.revision

  let pin_boundaries scratch draft ~changed_at =
    let capsule = revision_capsule draft.revision in
    let* () =
      Scratch.pin_capsule_boundary scratch draft.source_checkpoint ~capsule
        ~changed_at
      |> Result.map_error (fun error -> Scratch_error error)
    in
    if
      Scratch.Checkpoint_id.equal draft.source_checkpoint
        draft.target_checkpoint
    then Ok ()
    else
      Scratch.pin_capsule_boundary scratch draft.target_checkpoint ~capsule
        ~changed_at
      |> Result.map_error (fun error -> Scratch_error error)
end

module Parent_resolver = struct
  type node = {
    revision : Id.Capsule_revision_id.t;
    capsule : Id.Capsule_id.t;
    parent : Id.Capsule_revision_id.t option;
  }

  type error =
    | Duplicate_revision of Id.Capsule_revision_id.t
    | Unknown_revision of Id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Id.Capsule_revision_id.t;
        expected_capsule : Id.Capsule_id.t;
        actual_capsule : Id.Capsule_id.t;
      }
    | Cycle of Id.Capsule_revision_id.t

  let error_to_string = function
    | Duplicate_revision revision ->
        "duplicate synthetic revision: "
        ^ Id.Capsule_revision_id.to_hex revision
    | Unknown_revision revision ->
        "unknown synthetic revision: " ^ Id.Capsule_revision_id.to_hex revision
    | Parent_capsule_mismatch { parent; expected_capsule; actual_capsule } ->
        Printf.sprintf "synthetic parent %s belongs to capsule %s, not %s"
          (Id.Capsule_revision_id.to_hex parent)
          (Id.Capsule_id.to_hex actual_capsule)
          (Id.Capsule_id.to_hex expected_capsule)
    | Cycle revision ->
        "synthetic revision parent cycle: "
        ^ Id.Capsule_revision_id.to_hex revision

  let history ~nodes ~capsule ~current =
    let rec add index = function
      | [] -> Ok index
      | node :: rest ->
          if
            List.exists
              (fun existing ->
                Id.Capsule_revision_id.equal existing.revision node.revision)
              index
          then Error (Duplicate_revision node.revision)
          else add (node :: index) rest
    in
    let* index = add [] nodes in
    let find revision =
      List.find_opt
        (fun node -> Id.Capsule_revision_id.equal revision node.revision)
        index
    in
    let rec walk seen reversed revision =
      if List.exists (Id.Capsule_revision_id.equal revision) seen then
        Error (Cycle revision)
      else
        match find revision with
        | None -> Error (Unknown_revision revision)
        | Some node when not (Id.Capsule_id.equal capsule node.capsule) ->
            Error
              (Parent_capsule_mismatch
                 {
                   parent = revision;
                   expected_capsule = capsule;
                   actual_capsule = node.capsule;
                 })
        | Some node -> (
            match node.parent with
            | None -> Ok (List.rev (node :: reversed))
            | Some parent -> (
                match find parent with
                | None -> Error (Unknown_revision parent)
                | Some parent_node ->
                    if Id.Capsule_id.equal capsule parent_node.capsule then
                      walk (revision :: seen) (node :: reversed) parent
                    else
                      Error
                        (Parent_capsule_mismatch
                           {
                             parent;
                             expected_capsule = capsule;
                             actual_capsule = parent_node.capsule;
                           })))
    in
    walk [] [] current
end

module Catalog = struct
  module Capsule_map = Map.Make (struct
    type t = Id.Capsule_id.t

    let compare = Id.Capsule_id.compare
  end)

  module Revision_map = Map.Make (struct
    type t = Id.Capsule_revision_id.t

    let compare = Id.Capsule_revision_id.compare
  end)

  type t = {
    capsules : capsule Capsule_map.t;
    revisions : revision Revision_map.t;
    current : Id.Capsule_revision_id.t Capsule_map.t;
  }

  type error =
    | Capsule_id_collision of Id.Capsule_id.t
    | Unknown_capsule of Id.Capsule_id.t
    | Revision_id_collision of Id.Capsule_revision_id.t
    | Unknown_parent_revision of Id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Id.Capsule_revision_id.t;
        expected_capsule : Id.Capsule_id.t;
        actual_capsule : Id.Capsule_id.t;
      }
    | Unknown_revision of Id.Capsule_revision_id.t
    | Revision_capsule_mismatch of {
        revision : Id.Capsule_revision_id.t;
        expected_capsule : Id.Capsule_id.t;
        actual_capsule : Id.Capsule_id.t;
      }

  type revision_diff = {
    from_revision : Id.Capsule_revision_id.t;
    to_revision : Id.Capsule_revision_id.t;
    declared_base_changed : bool;
    expected_result_changed : bool;
    from_operations : operation list;
    to_operations : operation list;
  }

  let capsule_id_to_string identity = Id.Capsule_id.to_hex identity
  let revision_id_to_string identity = Id.Capsule_revision_id.to_hex identity

  let error_to_string = function
    | Capsule_id_collision identity ->
        "capsule ID already names different metadata: "
        ^ capsule_id_to_string identity
    | Unknown_capsule identity ->
        "unknown capsule: " ^ capsule_id_to_string identity
    | Revision_id_collision identity ->
        "revision ID already names different content: "
        ^ revision_id_to_string identity
    | Unknown_parent_revision identity ->
        "unknown parent revision: " ^ revision_id_to_string identity
    | Parent_capsule_mismatch { parent; expected_capsule; actual_capsule } ->
        Printf.sprintf "parent revision %s belongs to capsule %s, not %s"
          (revision_id_to_string parent)
          (capsule_id_to_string actual_capsule)
          (capsule_id_to_string expected_capsule)
    | Unknown_revision identity ->
        "unknown revision: " ^ revision_id_to_string identity
    | Revision_capsule_mismatch { revision; expected_capsule; actual_capsule }
      ->
        Printf.sprintf "revision %s belongs to capsule %s, not %s"
          (revision_id_to_string revision)
          (capsule_id_to_string actual_capsule)
          (capsule_id_to_string expected_capsule)

  let empty =
    {
      capsules = Capsule_map.empty;
      revisions = Revision_map.empty;
      current = Capsule_map.empty;
    }

  let dependency_equal left right =
    match (left, right) with
    | Requires_capsule left, Requires_capsule right ->
        Id.Capsule_id.equal left.capsule right.capsule
        && Option.equal Id.Capsule_revision_id.equal left.revision
             right.revision
    | Requires_release left, Requires_release right ->
        Id.Release_id.equal left right
    | Conflicts_with_capsule left, Conflicts_with_capsule right
    | Ordered_after left, Ordered_after right ->
        Id.Capsule_id.equal left right
    | ( Requires_capsule _,
        (Requires_release _ | Conflicts_with_capsule _ | Ordered_after _) )
    | ( Requires_release _,
        (Requires_capsule _ | Conflicts_with_capsule _ | Ordered_after _) )
    | ( Conflicts_with_capsule _,
        (Requires_capsule _ | Requires_release _ | Ordered_after _) )
    | ( Ordered_after _,
        (Requires_capsule _ | Requires_release _ | Conflicts_with_capsule _) )
      ->
        false

  let capsule_equal left right =
    Id.Capsule_id.equal left.capsule_id right.capsule_id
    && String.equal left.capsule_title right.capsule_title
    && String.equal left.capsule_description right.capsule_description
    && List.equal dependency_equal left.capsule_dependencies
         right.capsule_dependencies

  let path_equal = List.equal String.equal
  let entry_option_equal = Option.equal entry_equal

  let exact_transition_equal left right =
    path_equal left.transition_path right.transition_path
    && entry_option_equal left.expected_entry right.expected_entry
    && entry_option_equal left.replacement_entry right.replacement_entry

  let text_anchor_equal left right =
    String.equal left.before_context right.before_context
    && String.equal left.selected right.selected
    && String.equal left.after_context right.after_context

  let text_edit_equal left right =
    path_equal left.edit_path right.edit_path
    && text_anchor_equal left.anchor right.anchor
    && String.equal left.replacement right.replacement
    && exact_transition_equal left.fallback_transition right.fallback_transition

  let operation_equal left right =
    match (left, right) with
    | Exact_file_transition left, Exact_file_transition right ->
        exact_transition_equal left right
    | Text_edit left, Text_edit right -> text_edit_equal left right
    | Move left, Move right ->
        path_equal left.source right.source
        && path_equal left.destination right.destination
        && entry_equal left.prior right.prior
    | Mode_change left, Mode_change right ->
        path_equal left.path right.path
        && left.expected = right.expected
        && left.replacement = right.replacement
    | Exact_file_transition _, (Text_edit _ | Move _ | Mode_change _)
    | Text_edit _, (Exact_file_transition _ | Move _ | Mode_change _)
    | Move _, (Exact_file_transition _ | Text_edit _ | Mode_change _)
    | Mode_change _, (Exact_file_transition _ | Text_edit _ | Move _) ->
        false

  let validation_status_equal left right =
    match (left, right) with
    | Passed, Passed | Timed_out, Timed_out | Not_run, Not_run -> true
    | Failed left, Failed right -> left = right
    | Passed, (Failed _ | Timed_out | Not_run)
    | Failed _, (Passed | Timed_out | Not_run)
    | Timed_out, (Passed | Failed _ | Not_run)
    | Not_run, (Passed | Failed _ | Timed_out) ->
        false

  let validation_evidence_equal left right =
    List.equal String.equal left.command right.command
    && Option.equal String.equal left.environment_fingerprint
         right.environment_fingerprint
    && Snapshot.Snapshot.equal_id left.snapshot right.snapshot
    && validation_status_equal left.status right.status
    && Option.equal Snapshot.Content.equal_id left.stdout_digest
         right.stdout_digest
    && Option.equal Snapshot.Content.equal_id left.stderr_digest
         right.stderr_digest
    && Int64.equal left.started_at right.started_at
    && Int64.equal left.duration_ms right.duration_ms

  let revision_equal left right =
    Id.Capsule_revision_id.equal left.id right.id
    && Id.Capsule_id.equal left.capsule right.capsule
    && Option.equal Id.Capsule_revision_id.equal left.parent right.parent
    && Snapshot.Snapshot.equal_id left.declared_base right.declared_base
    && List.equal operation_equal left.operations right.operations
    && Option.equal Snapshot.Snapshot.equal_id left.expected_result
         right.expected_result
    && List.equal validation_evidence_equal left.evidence right.evidence
    && Int64.equal left.created_at right.created_at

  let add_capsule catalog capsule =
    match Capsule_map.find_opt capsule.capsule_id catalog.capsules with
    | None ->
        Ok
          {
            catalog with
            capsules =
              Capsule_map.add capsule.capsule_id capsule catalog.capsules;
          }
    | Some existing when capsule_equal existing capsule -> Ok catalog
    | Some _ -> Error (Capsule_id_collision capsule.capsule_id)

  let add_revision catalog revision =
    let* () =
      if Capsule_map.mem revision.capsule catalog.capsules then Ok ()
      else Error (Unknown_capsule revision.capsule)
    in
    let* () =
      match revision.parent with
      | None -> Ok ()
      | Some parent -> (
          match Revision_map.find_opt parent catalog.revisions with
          | None -> Error (Unknown_parent_revision parent)
          | Some parent_revision ->
              if Id.Capsule_id.equal revision.capsule parent_revision.capsule
              then Ok ()
              else
                Error
                  (Parent_capsule_mismatch
                     {
                       parent;
                       expected_capsule = revision.capsule;
                       actual_capsule = parent_revision.capsule;
                     }))
    in
    match Revision_map.find_opt revision.id catalog.revisions with
    | Some existing when revision_equal existing revision -> Ok catalog
    | Some _ -> Error (Revision_id_collision revision.id)
    | None ->
        Ok
          {
            catalog with
            revisions = Revision_map.add revision.id revision catalog.revisions;
            current =
              Capsule_map.add revision.capsule revision.id catalog.current;
          }

  let select_current catalog ~capsule ~revision =
    let* selected =
      match Revision_map.find_opt revision catalog.revisions with
      | Some revision -> Ok revision
      | None -> Error (Unknown_revision revision)
    in
    if Id.Capsule_id.equal capsule selected.capsule then
      Ok
        {
          catalog with
          current = Capsule_map.add capsule revision catalog.current;
        }
    else
      Error
        (Revision_capsule_mismatch
           {
             revision;
             expected_capsule = capsule;
             actual_capsule = selected.capsule;
           })

  let find_capsule catalog identity =
    Capsule_map.find_opt identity catalog.capsules

  let find_revision catalog identity =
    Revision_map.find_opt identity catalog.revisions

  let current_revision catalog capsule =
    Option.bind (Capsule_map.find_opt capsule catalog.current) (fun revision ->
        Revision_map.find_opt revision catalog.revisions)

  let history catalog capsule =
    let* current =
      match current_revision catalog capsule with
      | Some revision -> Ok revision
      | None -> Error (Unknown_capsule capsule)
    in
    let rec walk reversed revision =
      match revision.parent with
      | None -> Ok (List.rev (revision :: reversed))
      | Some parent -> (
          match Revision_map.find_opt parent catalog.revisions with
          | None -> Error (Unknown_parent_revision parent)
          | Some parent_revision -> walk (revision :: reversed) parent_revision)
    in
    walk [] current

  let diff catalog ~from ~to_ =
    let* from_revision =
      match find_revision catalog from with
      | Some revision -> Ok revision
      | None -> Error (Unknown_revision from)
    in
    let* to_revision =
      match find_revision catalog to_ with
      | Some revision -> Ok revision
      | None -> Error (Unknown_revision to_)
    in
    Ok
      {
        from_revision = from;
        to_revision = to_;
        declared_base_changed =
          not
            (Snapshot.Snapshot.equal_id from_revision.declared_base
               to_revision.declared_base);
        expected_result_changed =
          not
            (Option.equal Snapshot.Snapshot.equal_id
               from_revision.expected_result to_revision.expected_result);
        from_operations = from_revision.operations;
        to_operations = to_revision.operations;
      }
end
