module Encoding = Paengi_encoding
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot

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
  | Error (Encoding.Negative_map_key _ | Encoding.Duplicate_map_key _
          | Encoding.Nesting_limit_exceeded _) ->
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
      Printf.sprintf "operation %d text fallback required at %s"
        operation_index (path_to_string edit.edit_path)
  | Move_rejected { operation_index; source; destination; detail } ->
      Printf.sprintf "operation %d move %s -> %s rejected: %s" operation_index
        (path_to_string source) (path_to_string destination) detail
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

let option_entry_equal left right =
  Option.equal entry_equal left right

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
    Scratch.State.apply state operations |> Result.map_error Scratch.error_to_string

let apply_text_fallback state edit =
  apply_exact_transition state edit.fallback_transition

let apply ~actual_base ~state revision =
  if not (Snapshot.Snapshot.equal_id actual_base revision.declared_base) then
    let conflict =
      Declared_base_mismatch
        { expected = revision.declared_base; actual = actual_base }
    in
    { state; outcomes = [ Application_conflict conflict ]; conflicts = [ conflict ] }
  else
    let step (state, outcomes, conflicts) index operation =
      let accepted state = (state, Applied_exactly index :: outcomes, conflicts) in
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
          match Scratch.State.apply state [ Scratch.Move { source; destination; prior } ] with
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
          let state, outcomes, conflicts = step (state, outcomes, conflicts) index operation in
          apply_all state outcomes conflicts (index + 1) rest
    in
    let state, outcomes, conflicts =
      apply_all state [] [] 0 revision.operations
    in
    { state; outcomes = List.rev outcomes; conflicts = List.rev conflicts }
