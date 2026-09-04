module Health = Yeokcham_v4_health
module Health_repository = Yeokcham_v4_health_repository
module Health_store = Yeokcham_v4_health_store
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

type error =
  | Health_error of Health.refusal
  | Health_store_error of Health_store.error
  | Store_error of Store.error
  | V4_store_error of V4_store.error
  | Missing_state_head
  | Invalid_backup of { path : string; detail : string }

type apply_result =
  | Applied of Health.repair_candidate
  | Refused of Health.refusal

let ( let* ) = Result.bind

let error_to_string = function
  | Health_error error -> Health.refusal_to_string error
  | Health_store_error error -> Health_store.error_to_string error
  | Store_error error -> Store.error_to_string error
  | V4_store_error error -> V4_store.error_to_string error
  | Missing_state_head -> "V4 repair target has no state head"
  | Invalid_backup { path; detail } ->
      Printf.sprintf "invalid V4 repair backup %s: %s" path detail

let store_of_target ~root =
  V4_store.open_repository ~root
  |> Result.map V4_store.underlying_store
  |> Result.map_error (fun error -> V4_store_error error)

let state_head store =
  let* reference =
    Store.read_ref store ~name:V4_store.state_head_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match reference with
  | None -> Error Missing_state_head
  | Some reference -> (
      match Store.Mutable_ref.target reference with
      | None -> Error Missing_state_head
      | Some object_id -> Ok (Store.Stored_object_id.to_hex object_id))

let backup_store ~backup =
  Store.open_repository ~root:backup
  |> Result.map_error (fun error ->
      Invalid_backup { path = backup; detail = Store.error_to_string error })

let backup_candidate ~backup ~object_id =
  let* object_id =
    Store.Stored_object_id.of_hex object_id
    |> Result.map_error (fun _ ->
        Health_error (Health.Invalid_identifier object_id))
  in
  let* store = backup_store ~backup in
  let path = Store.object_path store object_id in
  if not (Sys.file_exists path) then Ok None
  else
    let* envelope =
      Store.get store object_id
      |> Result.map_error (fun error ->
          Invalid_backup { path; detail = Store.error_to_string error })
    in
    let source = Health.Backup backup in
    let canonical_bytes_id =
      Store.id_of_envelope envelope |> Store.Stored_object_id.to_hex
    in
    let* candidate =
      Health.make_candidate ~source
        ~object_id:(Store.Stored_object_id.to_hex object_id)
        ~canonical_bytes_id
      |> Result.map_error (fun error -> Health_error error)
    in
    Ok (Some (candidate, envelope))

let[@warning "-4"] missing_object_ids report =
  Health.report_damages report
  |> List.filter_map (fun damage ->
      match (Health.damage_code damage, Health.damage_affected damage) with
      | Health.Missing_object, Health.Object object_id -> Some object_id
      | _ -> None)

let candidates_from_backup ~backup report =
  missing_object_ids report
  |> List.fold_left
       (fun result object_id ->
         let* candidates = result in
         let* candidate = backup_candidate ~backup ~object_id in
         match candidate with
         | None -> Ok candidates
         | Some (candidate, _) -> Ok (candidate :: candidates))
       (Ok [])
  |> Result.map List.rev

let plan_from_backup ~root ~backup ~created_at ~expires_at =
  let* target = store_of_target ~root in
  let* state_head = state_head target in
  let report = Health_repository.verify ~root in
  let* candidates = candidates_from_backup ~backup report in
  let* plan =
    Health.make_plan ~repository:state_head ~state_head
      ~source:(Health.Backup backup)
      ~damages:(Health.report_damages report)
      ~candidates ~created_at ~expires_at
    |> Result.map_error (fun error -> Health_error error)
  in
  let* () =
    Health_store.append ~root plan
    |> Result.map_error (fun error -> Health_store_error error)
  in
  Ok plan

let[@warning "-4"] apply_from_backup ~root ~plan_id ~selection ~now =
  let* target = store_of_target ~root in
  Store.with_lock target ~name:V4_store.state_head_name
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* plan =
        Health_store.find ~root ~id:plan_id
        |> Result.map_error (fun error -> Health_store_error error)
      in
      match Health.plan_source plan with
      | Health.Backup backup -> (
          let* current_state_head = state_head target in
          let report = Health_repository.verify ~root in
          let reread_candidate, envelope =
            match
              backup_candidate ~backup
                ~object_id:
                  (match Health.plan_candidates plan with
                  | [] -> String.make 64 '0'
                  | candidates -> (
                      match
                        List.find_opt
                          (fun candidate ->
                            String.equal
                              (Health.candidate_id candidate)
                              selection.Health.selection_candidate_id)
                          candidates
                      with
                      | None -> String.make 64 '0'
                      | Some candidate -> Health.candidate_object_id candidate))
            with
            | Ok (Some (candidate, envelope)) -> (Some candidate, Some envelope)
            | Ok None | Error _ -> (None, None)
          in
          match
            Health.apply_eligibility ~plan ~selection ~now ~current_state_head
              ~current:report ~reread_candidate
          with
          | Health.Refused refusal -> Ok (Refused refusal)
          | Health.Eligible candidate -> (
              match envelope with
              | None -> Ok (Refused Health.Candidate_changed)
              | Some envelope ->
                  let* published =
                    Store.put target envelope
                    |> Result.map_error (fun error -> Store_error error)
                  in
                  if
                    String.equal
                      (Store.Stored_object_id.to_hex published)
                      (Health.candidate_object_id candidate)
                  then Ok (Applied candidate)
                  else Ok (Refused Health.Candidate_changed)))
      | _ -> Ok (Refused Health.Candidate_changed))
