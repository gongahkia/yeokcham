module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation

type policy = Pin_all_exact_snapshot_checkpoints

type decision =
  | Evidence_not_passed
  | No_matching_checkpoint
  | Retain of Scratch.Checkpoint_id.t list

type outcome = {
  evidence : Paengi_id.Validation_id.t;
  decision : decision;
  newly_retained : int;
  already_retained : int;
}

type error =
  | Validation_error of Validation.error
  | Scratch_error of Scratch.error

let error_to_string = function
  | Validation_error error -> Validation.error_to_string error
  | Scratch_error error -> Scratch.error_to_string error

let ( let* ) = Result.bind

let compare_checkpoint left right =
  Store.Stored_object_id.compare
    (Scratch.Checkpoint_id.stored_object_id left)
    (Scratch.Checkpoint_id.stored_object_id right)

let decide Pin_all_exact_snapshot_checkpoints ~evidence ~candidates =
  if not (Validation.evidence_passed evidence) then Evidence_not_passed
  else
    let target = Validation.evidence_snapshot evidence in
    let matching =
      candidates
      |> List.filter_map (fun (checkpoint, snapshot) ->
             if Snapshot.Snapshot.equal_id target snapshot then Some checkpoint
             else None)
      |> List.sort_uniq compare_checkpoint
    in
    match matching with [] -> No_matching_checkpoint | _ -> Retain matching

let apply policy ~store ~scratch ~evidence_object ~changed_at =
  let* evidence =
    Validation.load_evidence store evidence_object
    |> Result.map_error (fun error -> Validation_error error)
  in
  let* timeline =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let candidates =
    List.map
      (fun entry ->
        ( entry.Scratch.logical_id,
          Scratch.Checkpoint.snapshot entry.Scratch.checkpoint ))
      timeline
  in
  let decision = decide policy ~evidence ~candidates in
  let* newly_retained, already_retained =
    match decision with
    | Evidence_not_passed | No_matching_checkpoint -> Ok (0, 0)
    | Retain checkpoints ->
        List.fold_left
          (fun result checkpoint ->
            let* newly_retained, already_retained = result in
            let* added =
              Scratch.retain_validation_passed scratch checkpoint
                ~validation:(Validation.evidence_id evidence) ~changed_at
              |> Result.map_error (fun error -> Scratch_error error)
            in
            Ok
              ( if added then (newly_retained + 1, already_retained)
                else (newly_retained, already_retained + 1) ))
          (Ok (0, 0)) checkpoints
  in
  Ok
    {
      evidence = Validation.evidence_id evidence;
      decision;
      newly_retained;
      already_retained;
    }
