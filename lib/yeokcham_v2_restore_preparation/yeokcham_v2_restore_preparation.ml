module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Restore_plan = Yeokcham_v2_restore_plan
module Scanner = Yeokcham_v2_scanner
module Scratch_store = Yeokcham_v2_scratch_store
module V2_model = Yeokcham_v2_model

type prepared = {
  target : Scratch_store.checkpoint;
  safety : Scratch_store.checkpoint;
  plan : Restore_plan.t;
  journal : Journal.t;
}

type outcome = Noop of Scratch_store.checkpoint | Prepared of prepared

type error =
  | Scanner_error of Scanner.error
  | Scratch_store_error of Scratch_store.error
  | Journal_error of Journal.error
  | Journal_store_error of Journal_store.error
  | Safety_checkpoint_mismatch
  | Operation_already_exists of Journal.t

let ( let* ) = Result.bind

let journal_phase_to_string = function
  | Journal.Prepared -> "prepared"
  | Journal.Applying completed -> Printf.sprintf "applying(%d)" completed
  | Journal.Materialized -> "materialized"
  | Journal.Published -> "published"

let error_to_string = function
  | Scanner_error error -> Scanner.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error
  | Journal_error error -> Journal.error_to_string error
  | Journal_store_error error -> Journal_store.error_to_string error
  | Safety_checkpoint_mismatch ->
      "V2 restore safety publication does not retain the exact observed \
       snapshot"
  | Operation_already_exists record ->
      Printf.sprintf
        "V2 restore operation already has journal generation %Ld in phase %s"
        (Journal.generation record)
        (journal_phase_to_string (Journal.phase record))

let target_checkpoint prepared = prepared.target
let safety_checkpoint prepared = prepared.safety
let plan prepared = prepared.plan
let journal prepared = prepared.journal

let checkpoint_of_publication = function
  | Scratch_store.Published checkpoint | Scratch_store.Unchanged checkpoint ->
      checkpoint

let append_new journal_store record =
  match Journal_store.append journal_store record with
  | Ok Journal_store.Appended -> Ok ()
  | Ok Journal_store.Already_appended -> Error (Operation_already_exists record)
  | Error error -> Error (Journal_store_error error)

let prepare ~root ~bootstrap_repository ~target_event_id ~operation_id
    ~safety_snapshot_nonce ~safety_ledger_nonce =
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* target =
    Scratch_store.checkpoint_for_event scratch ~event_id:target_event_id
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* observed =
    Scanner.scan ~root |> Result.map_error (fun error -> Scanner_error error)
  in
  let plan =
    Restore_plan.build ~observed ~target:target.Scratch_store.snapshot
  in
  if Restore_plan.is_noop plan then Ok (Noop target)
  else
    let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
    let* journal_store =
      Journal_store.open_repository ~root
        ~repository_id:(Bootstrap.repository_id bootstrap)
      |> Result.map_error (fun error -> Journal_store_error error)
    in
    let* existing =
      Journal_store.latest journal_store ~operation_id
      |> Result.map_error (fun error -> Journal_store_error error)
    in
    match existing with
    | Some record -> Error (Operation_already_exists record)
    | None ->
        let* safety =
          Scratch_store.publish scratch ~snapshot:observed
            ~snapshot_nonce:safety_snapshot_nonce
            ~ledger_nonce:safety_ledger_nonce
          |> Result.map checkpoint_of_publication
          |> Result.map_error (fun error -> Scratch_store_error error)
        in
        if
          not
            (Yeokcham_model.Snapshot.equal observed
               safety.Scratch_store.snapshot)
        then Error Safety_checkpoint_mismatch
        else
          let* prepared =
            Journal.make_prepared
              ~repository_id:(Bootstrap.repository_id bootstrap)
              ~operation_id ~safety_event_id:safety.Scratch_store.event_id
              ~safety_snapshot:safety.Scratch_store.snapshot_ref
              ~target_snapshot:target.Scratch_store.snapshot_ref
              ~action_count:(List.length (Restore_plan.actions plan))
              ~mandatory_features:0L
            |> Result.map_error (fun error -> Journal_error error)
          in
          let* () = append_new journal_store prepared in
          let* started =
            Journal.advance prepared (Journal.Applying 0)
            |> Result.map_error (fun error -> Journal_error error)
          in
          let* () = append_new journal_store started in
          Ok (Prepared { target; safety; plan; journal = started })
