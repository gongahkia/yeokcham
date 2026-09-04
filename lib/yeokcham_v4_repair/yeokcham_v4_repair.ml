module Health = Yeokcham_v4_health
module Health_repository = Yeokcham_v4_health_repository
module Health_store = Yeokcham_v4_health_store
module Gc = Yeokcham_v4_gc
module Package = Yeokcham_v4_package
module Bootstrap = Yeokcham_v4_bootstrap
module Transport_config = Yeokcham_v4_transport_config
module Transport_credential = Yeokcham_v4_transport_credential
module Transport_http = Yeokcham_v4_transport_http
module Trust = Yeokcham_v4_trust
module Transport = Yeokcham_v4_transport
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

type error =
  | Health_error of Health.refusal
  | Health_store_error of Health_store.error
  | Store_error of Store.error
  | V4_store_error of V4_store.error
  | Gc_error of Gc.error
  | Package_error of Package.error
  | Transport_config_error of Transport_config.error
  | Transport_credential_error of Transport_credential.error
  | Transport_http_error of Transport_http.error
  | No_configured_relay_repository
  | Bootstrap_error of Bootstrap.error
  | Invalid_bootstrap_artifact of { path : string; detail : string }
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
  | Gc_error error -> Gc.error_to_string error
  | Package_error error -> Package.error_to_string error
  | Transport_config_error error -> Transport_config.error_to_string error
  | Transport_credential_error error ->
      Transport_credential.error_to_string error
  | Transport_http_error error -> Transport_http.error_to_string error
  | No_configured_relay_repository ->
      "V4 repair relay source requires a collaborative repository identity"
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Invalid_bootstrap_artifact { path; detail } ->
      Printf.sprintf "invalid V4 repair bootstrap artifact %s: %s" path detail
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

let candidate_of_envelope ~source ~object_id envelope =
  let canonical_bytes_id =
    Store.id_of_envelope envelope |> Store.Stored_object_id.to_hex
  in
  Health.make_candidate ~source ~object_id ~canonical_bytes_id
  |> Result.map_error (fun error -> Health_error error)

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
    let* candidate =
      candidate_of_envelope ~source:(Health.Backup backup)
        ~object_id:(Store.Stored_object_id.to_hex object_id)
        envelope
    in
    Ok (Some (candidate, envelope))

let quarantine_candidate ~root ~transaction_id ~object_id =
  let* object_id =
    Store.Stored_object_id.of_hex object_id
    |> Result.map_error (fun _ ->
        Health_error (Health.Invalid_identifier object_id))
  in
  let* envelope =
    Gc.quarantined_object ~root ~transaction_id ~object_id
    |> Result.map_error (fun error -> Gc_error error)
  in
  match envelope with
  | None -> Ok None
  | Some envelope ->
      let* candidate =
        candidate_of_envelope ~source:(Health.Gc_quarantine transaction_id)
          ~object_id:(Store.Stored_object_id.to_hex object_id)
          envelope
      in
      Ok (Some (candidate, envelope))

let package_candidate ~package ~object_id =
  let* object_id =
    Store.Stored_object_id.of_hex object_id
    |> Result.map_error (fun _ ->
        Health_error (Health.Invalid_identifier object_id))
  in
  let* artifact =
    Package.read_artifact ~package
    |> Result.map_error (fun error -> Package_error error)
  in
  match
    List.find_opt
      (fun (candidate_id, _) ->
        Store.Stored_object_id.equal candidate_id object_id)
      (Package.artifact_objects artifact)
  with
  | None -> Ok None
  | Some (_, bytes) ->
      let* envelope =
        Yeokcham_envelope.decode bytes
        |> Result.map_error (fun error ->
            Package_error (Package.Envelope_error error))
      in
      if not (String.equal bytes (Yeokcham_envelope.encode envelope)) then
        Error
          (Package_error
             (Package.Invalid_package "noncanonical artifact object"))
      else
        let* candidate =
          candidate_of_envelope ~source:(Health.Offline_package package)
            ~object_id:(Store.Stored_object_id.to_hex object_id)
            envelope
        in
        Ok (Some (candidate, envelope))

let collaborative_repository ~root =
  let* repository =
    V4_store.open_repository ~root
    |> Result.map_error (fun error -> V4_store_error error)
  in
  let* loaded =
    V4_store.load repository
    |> Result.map_error (fun error -> V4_store_error error)
  in
  match loaded.V4_store.collaboration with
  | None -> Error No_configured_relay_repository
  | Some collaboration ->
      let repository = V4_store.membership collaboration |> Trust.repository in
      Ok repository

let relay_project ~root =
  let* repository = collaborative_repository ~root in
  Ok (Trust.Repository_id.to_string repository)

let relay_candidate ~root ~remote ~object_id =
  let* object_id =
    Store.Stored_object_id.of_hex object_id
    |> Result.map_error (fun _ ->
        Health_error (Health.Invalid_identifier object_id))
  in
  let* configured =
    Transport_config.find ~root ~name:remote
    |> Result.map_error (fun error -> Transport_config_error error)
  in
  let* token =
    Transport_credential.load ~remote
    |> Result.map_error (fun error -> Transport_credential_error error)
  in
  let* client =
    Transport_http.create ~url:configured.Transport_config.url ~token
    |> Result.map_error (fun error -> Transport_http_error error)
  in
  let* project = relay_project ~root in
  let* bytes =
    Transport_http.get client ~project ~kind:Transport_http.Object
      ~id:(Store.Stored_object_id.to_hex object_id)
    |> Result.map_error (fun error -> Transport_http_error error)
  in
  let* envelope =
    Yeokcham_envelope.decode bytes
    |> Result.map_error (fun error ->
        Transport_http_error
          (Transport_http.Invalid_response
             (Yeokcham_envelope.decode_error_to_string error)))
  in
  if not (String.equal bytes (Yeokcham_envelope.encode envelope)) then
    Error
      (Transport_http_error
         (Transport_http.Invalid_response "relay returned noncanonical object"))
  else
    let* candidate =
      candidate_of_envelope ~source:(Health.Configured_relay remote)
        ~object_id:(Store.Stored_object_id.to_hex object_id)
        envelope
    in
    Ok (Some (candidate, envelope))

let bootstrap_basis_path artifact =
  Filename.concat artifact "bootstrap-basis-v1.cbor"

let read_bootstrap_basis artifact =
  let path = bootstrap_basis_path artifact in
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then
      Error
        (Invalid_bootstrap_artifact
           { path; detail = "basis must be a regular file" })
    else if stat.Unix.st_size < 0 || stat.Unix.st_size > 1024 * 1024 then
      Error
        (Invalid_bootstrap_artifact
           { path; detail = "basis exceeds the 1 MiB repair-reader bound" })
    else Ok (In_channel.with_open_bin path In_channel.input_all)
  with
  | Unix.Unix_error (error, _, _) ->
      Error
        (Invalid_bootstrap_artifact { path; detail = Unix.error_message error })
  | Sys_error detail -> Error (Invalid_bootstrap_artifact { path; detail })

let candidate_from_artifact ~source ~object_id artifact =
  match
    List.find_opt
      (fun (candidate_id, _) ->
        Store.Stored_object_id.equal candidate_id object_id)
      (Package.artifact_objects artifact)
  with
  | None -> Ok None
  | Some (_, bytes) ->
      let* envelope =
        Yeokcham_envelope.decode bytes
        |> Result.map_error (fun error ->
            Package_error (Package.Envelope_error error))
      in
      if not (String.equal bytes (Yeokcham_envelope.encode envelope)) then
        Error
          (Package_error
             (Package.Invalid_package "noncanonical artifact object"))
      else
        let* candidate =
          candidate_of_envelope ~source
            ~object_id:(Store.Stored_object_id.to_hex object_id)
            envelope
        in
        Ok (Some (candidate, envelope))

let bootstrap_candidate ~root ~artifact ~object_id =
  let* object_id =
    Store.Stored_object_id.of_hex object_id
    |> Result.map_error (fun _ ->
        Health_error (Health.Invalid_identifier object_id))
  in
  let* repository = collaborative_repository ~root in
  let* bytes = read_bootstrap_basis artifact in
  let* basis =
    Bootstrap.decode bytes
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* _ =
    Bootstrap.verify ~repository ~package:artifact ~bytes
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* package =
    Package.read_artifact ~package:artifact
    |> Result.map_error (fun error -> Package_error error)
  in
  if
    not
      (String.equal (Bootstrap.manifest basis)
         (Transport.sha256 (Package.artifact_manifest package)))
  then
    Error
      (Invalid_bootstrap_artifact
         {
           path = artifact;
           detail = "basis manifest does not name the reread package artifact";
         })
  else
    candidate_from_artifact ~source:(Health.Bootstrap_artifact artifact)
      ~object_id package

let[@warning "-4"] missing_object_ids report =
  Health.report_damages report
  |> List.filter_map (fun damage ->
      match (Health.damage_code damage, Health.damage_affected damage) with
      | Health.Missing_object, Health.Object object_id -> Some object_id
      | _ -> None)

let candidates_from ~read_candidate report =
  missing_object_ids report
  |> List.fold_left
       (fun result object_id ->
         let* candidates = result in
         let* candidate = read_candidate ~object_id in
         match candidate with
         | None -> Ok candidates
         | Some (candidate, _) -> Ok (candidate :: candidates))
       (Ok [])
  |> Result.map List.rev

let plan_from_source ~root ~source ~read_candidate ~created_at ~expires_at =
  let* target = store_of_target ~root in
  let* state_head = state_head target in
  let report = Health_repository.verify ~root in
  let* candidates = candidates_from ~read_candidate report in
  let* plan =
    Health.make_plan ~repository:state_head ~state_head ~source
      ~damages:(Health.report_damages report)
      ~candidates ~created_at ~expires_at
    |> Result.map_error (fun error -> Health_error error)
  in
  let* () =
    Health_store.append ~root plan
    |> Result.map_error (fun error -> Health_store_error error)
  in
  Ok plan

let selected_object_id plan selection =
  Health.plan_candidates plan
  |> List.find_opt (fun candidate ->
      String.equal
        (Health.candidate_id candidate)
        selection.Health.selection_candidate_id)
  |> Option.map Health.candidate_object_id

let apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate =
  let* target = store_of_target ~root in
  Store.with_lock target ~name:V4_store.state_head_name
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* plan =
        Health_store.find ~root ~id:plan_id
        |> Result.map_error (fun error -> Health_store_error error)
      in
      if matches_source (Health.plan_source plan) then
        let* current_state_head = state_head target in
        let report = Health_repository.verify ~root in
        let reread_candidate, envelope =
          match selected_object_id plan selection with
          | None -> (None, None)
          | Some object_id -> (
              match read_candidate ~object_id with
              | Ok (Some (candidate, envelope)) ->
                  (Some candidate, Some envelope)
              | Ok None | Error _ -> (None, None))
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
                else Ok (Refused Health.Candidate_changed))
      else Ok (Refused Health.Candidate_changed))

let[@warning "-4"] plan_from_backup ~root ~backup ~created_at ~expires_at =
  plan_from_source ~root ~source:(Health.Backup backup)
    ~read_candidate:(backup_candidate ~backup) ~created_at ~expires_at

let[@warning "-4"] plan_from_gc_quarantine ~root ~transaction_id ~created_at
    ~expires_at =
  plan_from_source ~root ~source:(Health.Gc_quarantine transaction_id)
    ~read_candidate:(quarantine_candidate ~root ~transaction_id)
    ~created_at ~expires_at

let[@warning "-4"] plan_from_offline_package ~root ~package ~created_at
    ~expires_at =
  plan_from_source ~root ~source:(Health.Offline_package package)
    ~read_candidate:(package_candidate ~package)
    ~created_at ~expires_at

let[@warning "-4"] plan_from_configured_relay ~root ~remote ~created_at
    ~expires_at =
  plan_from_source ~root ~source:(Health.Configured_relay remote)
    ~read_candidate:(relay_candidate ~root ~remote)
    ~created_at ~expires_at

let[@warning "-4"] plan_from_bootstrap_artifact ~root ~artifact ~created_at
    ~expires_at =
  plan_from_source ~root ~source:(Health.Bootstrap_artifact artifact)
    ~read_candidate:(bootstrap_candidate ~root ~artifact)
    ~created_at ~expires_at

let[@warning "-4"] apply_from_backup ~root ~plan_id ~selection ~now =
  let matches_source = function Health.Backup _ -> true | _ -> false in
  let read_candidate = function
    | Health.Backup backup -> backup_candidate ~backup
    | _ -> fun ~object_id:_ -> Ok None
  in
  let* plan =
    Health_store.find ~root ~id:plan_id
    |> Result.map_error (fun error -> Health_store_error error)
  in
  apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate:(read_candidate (Health.plan_source plan))

let[@warning "-4"] apply_from_gc_quarantine ~root ~plan_id ~selection ~now =
  let matches_source = function Health.Gc_quarantine _ -> true | _ -> false in
  let read_candidate = function
    | Health.Gc_quarantine transaction_id ->
        quarantine_candidate ~root ~transaction_id
    | _ -> fun ~object_id:_ -> Ok None
  in
  let* plan =
    Health_store.find ~root ~id:plan_id
    |> Result.map_error (fun error -> Health_store_error error)
  in
  apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate:(read_candidate (Health.plan_source plan))

let[@warning "-4"] apply_from_offline_package ~root ~plan_id ~selection ~now =
  let matches_source = function
    | Health.Offline_package _ -> true
    | _ -> false
  in
  let read_candidate = function
    | Health.Offline_package package -> package_candidate ~package
    | _ -> fun ~object_id:_ -> Ok None
  in
  let* plan =
    Health_store.find ~root ~id:plan_id
    |> Result.map_error (fun error -> Health_store_error error)
  in
  apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate:(read_candidate (Health.plan_source plan))

let[@warning "-4"] apply_from_configured_relay ~root ~plan_id ~selection ~now =
  let matches_source = function
    | Health.Configured_relay _ -> true
    | _ -> false
  in
  let read_candidate = function
    | Health.Configured_relay remote -> relay_candidate ~root ~remote
    | _ -> fun ~object_id:_ -> Ok None
  in
  let* plan =
    Health_store.find ~root ~id:plan_id
    |> Result.map_error (fun error -> Health_store_error error)
  in
  apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate:(read_candidate (Health.plan_source plan))

let[@warning "-4"] apply_from_bootstrap_artifact ~root ~plan_id ~selection ~now
    =
  let matches_source = function
    | Health.Bootstrap_artifact _ -> true
    | _ -> false
  in
  let read_candidate = function
    | Health.Bootstrap_artifact artifact -> bootstrap_candidate ~root ~artifact
    | _ -> fun ~object_id:_ -> Ok None
  in
  let* plan =
    Health_store.find ~root ~id:plan_id
    |> Result.map_error (fun error -> Health_store_error error)
  in
  apply_from_source ~root ~plan_id ~selection ~now ~matches_source
    ~read_candidate:(read_candidate (Health.plan_source plan))
