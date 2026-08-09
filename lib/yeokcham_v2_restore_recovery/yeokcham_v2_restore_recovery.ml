module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Materializer = Yeokcham_v2_restore_materializer
module Model = Yeokcham_model
module Restore_plan = Yeokcham_v2_restore_plan
module Scanner = Yeokcham_v2_scanner
module Scratch_store = Yeokcham_v2_scratch_store
module V2_model = Yeokcham_v2_model

type outcome = { journal : Journal.t; checkpoint : Scratch_store.checkpoint }

type error =
  | Journal_store_error of Journal_store.error
  | Journal_error of Journal.error
  | Scratch_store_error of Scratch_store.error
  | Scanner_error of Scanner.error
  | Materializer_error of Materializer.error
  | Operation_missing of V2_model.Transaction_id.t
  | Safety_reference_mismatch
  | Target_reference_mismatch
  | Journal_plan_mismatch of { journal : int; plan : int }
  | Unexpected_scratch_state of Scratch_store.inspection
  | Final_worktree_mismatch
  | Published_checkpoint_mismatch

type resolved = {
  scratch : Scratch_store.repository;
  journal_store : Journal_store.repository;
  record : Journal.t;
  safety : Scratch_store.checkpoint;
  target : Scratch_store.checkpoint;
  plan : Restore_plan.t;
}

let ( let* ) = Result.bind

let inspection_to_string = function
  | Scratch_store.No_checkpoint -> "no scratch checkpoint"
  | Scratch_store.Checkpoint checkpoint ->
      "scratch checkpoint "
      ^ Scratch_store.Ledger.Event_id.to_hex checkpoint.Scratch_store.event_id
  | Scratch_store.Divergent_checkpoints events ->
      "divergent scratch checkpoints "
      ^ String.concat "," (List.map Scratch_store.Ledger.Event_id.to_hex events)

let error_to_string = function
  | Journal_store_error error -> Journal_store.error_to_string error
  | Journal_error error -> Journal.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error
  | Scanner_error error -> Scanner.error_to_string error
  | Materializer_error error -> Materializer.error_to_string error
  | Operation_missing operation_id ->
      "V2 restore journal operation is missing: "
      ^ V2_model.Transaction_id.to_hex operation_id
  | Safety_reference_mismatch ->
      "V2 restore journal safety event does not retain its named snapshot"
  | Target_reference_mismatch ->
      "V2 restore journal target event does not retain its named snapshot"
  | Journal_plan_mismatch { journal; plan } ->
      Printf.sprintf
        "V2 restore journal action count %d does not match re-derived plan %d"
        journal plan
  | Unexpected_scratch_state inspection ->
      "V2 restore scratch state is not the expected safety or published \
       target: "
      ^ inspection_to_string inspection
  | Final_worktree_mismatch ->
      "V2 restore root no longer matches the materialized target snapshot"
  | Published_checkpoint_mismatch ->
      "V2 restore post-publication checkpoint does not match its target \
       snapshot"

let journal (outcome : outcome) = outcome.journal
let checkpoint (outcome : outcome) = outcome.checkpoint

let append journal_store record =
  match Journal_store.append journal_store record with
  | Ok Journal_store.Appended | Ok Journal_store.Already_appended -> Ok ()
  | Error error -> Error (Journal_store_error error)

let checkpoint_of_publication = function
  | Scratch_store.Published checkpoint | Scratch_store.Unchanged checkpoint ->
      checkpoint

let resolve ~root ~bootstrap_repository ~operation_id =
  let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
  let* journal_store =
    Journal_store.open_repository ~root
      ~repository_id:(Bootstrap.repository_id bootstrap)
    |> Result.map_error (fun error -> Journal_store_error error)
  in
  let* journal =
    Journal_store.latest journal_store ~operation_id
    |> Result.map_error (fun error -> Journal_store_error error)
  in
  let* journal =
    match journal with
    | Some journal -> Ok journal
    | None -> Error (Operation_missing operation_id)
  in
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* safety =
    Scratch_store.checkpoint_for_event scratch
      ~event_id:(Journal.safety_event_id journal)
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* target =
    Scratch_store.checkpoint_for_event scratch
      ~event_id:(Journal.target_event_id journal)
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  if
    not
      (V2_model.Opaque_object_ref.equal safety.Scratch_store.snapshot_ref
         (Journal.safety_snapshot journal))
  then Error Safety_reference_mismatch
  else if
    not
      (V2_model.Opaque_object_ref.equal target.Scratch_store.snapshot_ref
         (Journal.target_snapshot journal))
  then Error Target_reference_mismatch
  else
    let plan =
      Restore_plan.build ~observed:safety.Scratch_store.snapshot
        ~target:target.Scratch_store.snapshot
    in
    let action_count = List.length (Restore_plan.actions plan) in
    if Restore_plan.is_noop plan || Journal.action_count journal <> action_count
    then
      Error
        (Journal_plan_mismatch
           { journal = Journal.action_count journal; plan = action_count })
    else Ok { scratch; journal_store; record = journal; safety; target; plan }

let scratch_inspection scratch =
  Scratch_store.inspect scratch
  |> Result.map_error (fun error -> Scratch_store_error error)

let safety_is_current resolved =
  let* inspection = scratch_inspection resolved.scratch in
  (match inspection with
  | Scratch_store.Checkpoint checkpoint
    when Scratch_store.Ledger.Event_id.equal checkpoint.Scratch_store.event_id
           resolved.safety.Scratch_store.event_id ->
      Ok ()
  | inspection -> Error (Unexpected_scratch_state inspection))
  [@warning "-4"]

let target_is_current resolved =
  let* inspection = scratch_inspection resolved.scratch in
  (match inspection with
  | Scratch_store.Checkpoint checkpoint
    when Model.Snapshot.equal checkpoint.Scratch_store.snapshot
           resolved.target.Scratch_store.snapshot ->
      Ok checkpoint
  | inspection -> Error (Unexpected_scratch_state inspection))
  [@warning "-4"]

let scan_target ~root target =
  let* actual =
    Scanner.scan ~root |> Result.map_error (fun error -> Scanner_error error)
  in
  if Model.Snapshot.equal actual target.Scratch_store.snapshot then Ok ()
  else Error Final_worktree_mismatch

let mark_published resolved checkpoint journal =
  if
    not
      (Model.Snapshot.equal checkpoint.Scratch_store.snapshot
         resolved.target.Scratch_store.snapshot)
  then Error Published_checkpoint_mismatch
  else
    let* published =
      Journal.advance journal Journal.Published
      |> Result.map_error (fun error -> Journal_error error)
    in
    let* () = append resolved.journal_store published in
    Ok { journal = published; checkpoint }

let publish_materialized ~root ~post_snapshot_nonce ~post_ledger_nonce resolved
    journal =
  let* () = scan_target ~root resolved.target in
  let* inspection = scratch_inspection resolved.scratch in
  (match inspection with
  | Scratch_store.Checkpoint checkpoint
    when Model.Snapshot.equal checkpoint.Scratch_store.snapshot
           resolved.target.Scratch_store.snapshot ->
      mark_published resolved checkpoint journal
  | Scratch_store.Checkpoint checkpoint
    when Scratch_store.Ledger.Event_id.equal checkpoint.Scratch_store.event_id
           resolved.safety.Scratch_store.event_id ->
      let* checkpoint =
        Scratch_store.publish resolved.scratch
          ~snapshot:resolved.target.Scratch_store.snapshot
          ~snapshot_nonce:post_snapshot_nonce ~ledger_nonce:post_ledger_nonce
        |> Result.map checkpoint_of_publication
        |> Result.map_error (fun error -> Scratch_store_error error)
      in
      mark_published resolved checkpoint journal
  | inspection -> Error (Unexpected_scratch_state inspection))
  [@warning "-4"]

let materialize resolved journal ~root =
  Materializer.materialize ~root ~journal_store:resolved.journal_store
    ~plan:resolved.plan ~journal ()
  |> Result.map_error (fun error -> Materializer_error error)

let resume ~root ~bootstrap_repository ~operation_id ~post_snapshot_nonce
    ~post_ledger_nonce =
  let* resolved = resolve ~root ~bootstrap_repository ~operation_id in
  match Journal.phase resolved.record with
  | Journal.Prepared ->
      let* () = safety_is_current resolved in
      let* applying =
        Journal.advance resolved.record (Journal.Applying 0)
        |> Result.map_error (fun error -> Journal_error error)
      in
      let* () = append resolved.journal_store applying in
      let* materialized = materialize resolved applying ~root in
      publish_materialized ~root ~post_snapshot_nonce ~post_ledger_nonce
        resolved materialized.Materializer.journal
  | Journal.Applying _ ->
      let* () = safety_is_current resolved in
      let* materialized = materialize resolved resolved.record ~root in
      publish_materialized ~root ~post_snapshot_nonce ~post_ledger_nonce
        resolved materialized.Materializer.journal
  | Journal.Materialized ->
      publish_materialized ~root ~post_snapshot_nonce ~post_ledger_nonce
        resolved resolved.record
  | Journal.Published ->
      let* checkpoint = target_is_current resolved in
      (Ok { journal = resolved.record; checkpoint } [@warning "-4"])
