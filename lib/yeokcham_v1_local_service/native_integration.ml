module Core = Yeokcham_v1_model.Core
module Model = Yeokcham_v1_model
module Plan = Yeokcham_v1_integration
module Store = Yeokcham_v1_store
module Local = Store.Local
module Operation = Local.Operation
module Raw = Yeokcham_store
module History = Yeokcham_v1_undo
module Snapshot = Yeokcham_snapshot
module Composition = Yeokcham_v1_composition
module Trust = Yeokcham_v1_trust
module Journal = Yeokcham_v1_restore_journal
module Proof = Yeokcham_v1_restore_proof

[@@@warning "-42"]

type error =
  | Plan_error of Plan.error
  | Application_error of Safe_apply.error
  | Metadata of string

let error_to_string = function
  | Plan_error e -> Plan.error_to_string e
  | Application_error e -> Safe_apply.error_to_string e
  | Metadata s -> s

let ( let* ) = Result.bind
let metadata r = Result.map_error (fun s -> Metadata s) r
let plan_error r = Result.map_error (fun e -> Plan_error e) r

let store_error r =
  Result.map_error (fun e -> Metadata (Store.error_to_string e)) r

let physical r = Result.map_error (fun e -> Application_error e) r
let model r = Result.map_error (fun e -> Metadata (Core.error_to_string e)) r

type outcome = {
  plan : Core.Plan_id.t;
  operation : Operation.t option;
  no_op : bool;
  resumed : bool;
}

type boundary =
  | Prepared_root
  | Applying_root
  | Materialized_root
  | Committed_root
  | Completed_root
  | Before_root
  | After_root
  | Mutation of Safe_apply.boundary * string list

let with_writer ~root action =
  let* repository = Store.open_repository ~root |> store_error in
  let path =
    Filename.concat (Filename.concat root ".yeokcham") "local-worktree.lock"
  in
  try
    let descriptor =
      Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC; Unix.O_CREAT ] 0o600
    in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.lockf descriptor Unix.F_TLOCK 0;
        action repository)
  with Unix.Unix_error (e, _, _) ->
    Error (Metadata ("integration writer unavailable: " ^ Unix.error_message e))

let no_restore root =
  let* pending =
    Journal.latest_pending ~root
    |> Result.map_error (fun e -> Metadata (Journal.error_to_string e))
  in
  match pending with
  | None -> Ok ()
  | Some journal ->
      Error
        (Metadata
           ("resume the pending restore before integration: "
           ^ Journal.operation_id journal))

let context loaded =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:(Metadata "integration needs authenticated local branch state")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:(Metadata "integration needs verified collaboration")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result ~none:(Metadata "integration needs verified authority")
  in
  Ok (local, collaboration, authority)

let snapshot identity =
  let* raw =
    Raw.Stored_object_id.of_raw_bytes (Core.Object_id.to_raw identity)
    |> Option.to_result ~none:(Metadata "invalid integration snapshot identity")
  in
  Ok (Snapshot.Snapshot.of_stored_object_id raw)

let model_snapshot identity =
  Model.Snapshot_id.of_string (Core.Object_id.to_hex identity)
  |> Result.map_error (fun e -> Metadata (Model.error_to_string e))

let physical_operation token =
  let raw =
    Yeokcham_hash.Sha256.digest_string
      ("yeokcham/integration-application/v1\000"
      ^ Core.Operation_id.to_raw token)
    |> Yeokcham_hash.Sha256.to_raw_string
  in
  let digits = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun i ->
      let byte = Char.code raw.[i / 2] in
      digits.[if i mod 2 = 0 then byte lsr 4 else byte land 15])

let observe_tree root store =
  let* identity, _, observation =
    Snapshot.Observation.scan ~root ~store
    |> Result.map_error (fun e -> Metadata (Snapshot.error_to_string e))
  in
  let* observed =
    Model.Snapshot_id.of_string
      (Raw.Stored_object_id.to_hex
         (Snapshot.Snapshot.stored_object_id identity))
    |> Result.map_error (fun e -> Metadata (Model.error_to_string e))
  in
  Ok (identity, observed, observation)

let prepare ~root ~selected_revisions ~reconcile_heads =
  with_writer ~root (fun repository ->
      let* () = no_restore root in
      let* loaded = Store.load repository |> store_error in
      let* local, _, _ = context loaded in
      let* () =
        match Local.pending_operation local with
        | None -> Ok ()
        | Some operation ->
            Error
              (Metadata
                 ("integration is incomplete; resume "
                 ^ Core.Operation_id.to_hex operation.Operation.token))
      in
      let store = Store.underlying_store repository in
      let* safety, observed, observation = observe_tree root store in
      let* plan =
        Plan.prepare ~store ~loaded ~observed ~observation ~selected_revisions
          ~reconcile_heads
        |> plan_error
      in
      let* () =
        match Plan.readiness plan with
        | Plan.Ready outputs ->
            let* target = snapshot outputs.Core.workspace_snapshot in
            Safe_apply.check ~root ~store ~safety ~target observation
            |> physical
        | Plan.Conflicted _ | Plan.Decision _ -> Ok ()
      in
      let* () = Plan.retain ~store plan |> plan_error in
      Ok plan)

let save ~observe repository loaded ~local ~project ~history =
  let* _, collaboration, _ = context loaded in
  Store.For_test.save_collaborative
    ~before_publish:(fun () -> observe Before_root)
    ~after_publish:(fun () -> observe After_root)
    ~local ~history repository ~expected:loaded.Store.head ~project
    ~collaboration
  |> store_error

let find_token local token =
  List.find_opt
    (fun operation -> Core.Operation_id.equal token operation.Operation.token)
    (Local.operations local)
  |> Option.to_result ~none:(Metadata "unknown integration operation")

let fresh_token ~random_bytes local =
  let rec loop remaining =
    let* token = Core.Operation_id.generate ~random_bytes () |> model in
    if
      List.exists
        (fun operation ->
          Core.Operation_id.equal token operation.Operation.token)
        (Local.operations local)
      || List.exists
           (fun publication ->
             Core.Operation_id.equal token publication.Local.operation)
           (Local.publications local)
    then
      if remaining = 1 then
        Error (Metadata "integration token collision after three attempts")
      else loop (remaining - 1)
    else Ok token
  in
  loop 3

let sign_records ~store ~loaded plan signing_capability =
  let* local, collaboration, authority = context loaded in
  if Plan.no_op plan then Ok None
  else
    let* outputs =
      match Plan.readiness plan with
      | Plan.Ready outputs -> Ok outputs
      | Plan.Conflicted _ ->
          Error (Metadata "integration has unresolved conflicts")
      | Plan.Decision detail -> Error (Metadata detail)
    in
    let request = Plan.request plan in
    let* represented =
      Composition.Graph.represented (Local.pool local)
        request.Core.accepted_heads
      |> Result.map_error (fun e ->
          Metadata (Composition.Graph.error_to_string e))
    in
    let* staged_local, accepted =
      match request.Core.accepted_heads with
      | [ accepted ]
        when List.length (Plan.event_heads plan) = 1
             && List.for_all
                  (fun id -> List.exists (Core.Record_id.equal id) represented)
                  request.Core.selected_revisions ->
          Ok (local, accepted)
      | _ ->
          let* signing_capability =
            signing_capability
            |> Option.to_result
                 ~none:
                   (Metadata
                      "starting acceptance requires the enrolled signing \
                       capability")
          in
          Local.prepare_acceptance ~store ~authority
            ~certificate:(Store.local_certificate collaboration)
            ~signing_capability ~parents:request.Core.accepted_heads
            ~chosen_revisions:request.Core.selected_revisions
            ~result_snapshot:outputs.Core.accepted_snapshot
            ~cursor:(Local.selected local).Local.cursor local
          |> metadata
    in
    let staged =
      Local.record_objects staged_local
      |> List.filter (fun (id, _) -> Core.find (Local.pool local) id = None)
    in
    Ok (Some (accepted, staged))

let begin_operation ~random_bytes ~observe ~root repository loaded plan signed =
  let store = Store.underlying_store repository in
  let* local, _, _ = context loaded in
  let* safety_id, observed, observation = observe_tree root store in
  let* plan =
    Plan.revalidate ~store ~loaded ~observed ~observation plan |> plan_error
  in
  if Plan.no_op plan then Ok None
  else
    let* outputs =
      match Plan.readiness plan with
      | Plan.Ready outputs -> Ok outputs
      | Plan.Conflicted _ ->
          Error (Metadata "integration has unresolved conflicts")
      | Plan.Decision detail -> Error (Metadata detail)
    in
    let* accepted, staged =
      signed
      |> Option.to_result ~none:(Metadata "integration signing inputs changed")
    in
    let request = Plan.request plan in
    let created_at = Int64.of_float (Unix.gettimeofday ()) in
    let draft = (Model.active_draft loaded.Store.project).Model.draft_id in
    let* history =
      History.record loaded.Store.history ~snapshot:observed ~draft ~created_at
      |> metadata
    in
    let* source =
      History.identity history (History.current history) |> metadata
    in
    let* target_sequence =
      History.next_sequence history
      |> Option.to_result ~none:(Metadata "local history IDs exhausted")
    in
    let* target_snapshot = model_snapshot outputs.Core.workspace_snapshot in
    let* _ =
      History.record_exact history ~expected:target_sequence
        ~snapshot:target_snapshot ~draft ~created_at
      |> metadata
    in
    let* token = fresh_token ~random_bytes local in
    let* target_id = snapshot outputs.Core.workspace_snapshot in
    let* application =
      Safe_apply.prepare ~root ~store ~operation:(physical_operation token)
        ~safety:safety_id ~target:target_id observation
      |> physical
    in
    let* physical_digest =
      Core.Digest.of_raw (Safe_apply.digest application) |> model
    in
    let* operation =
      Operation.make ~store ~repository:request.Core.repository ~token
        ~plan:(Plan.id plan) ~plan_object:(Plan.stored_id plan) ~source
        ~target_sequence ~accepted ~staged ~physical_digest
        ~expected:loaded.Store.head ~created_at
      |> metadata
    in
    let* local = Local.put_operation ~store operation local |> metadata in
    let project = Model.checkpoint loaded.Store.project ~snapshot:observed in
    let* _ = save ~observe repository loaded ~local ~project ~history in
    observe Prepared_root;
    Ok (Some operation)

let update_phase ~observe repository loaded operation phase =
  let* local, _, _ = context loaded in
  let* operation = Operation.advance operation phase |> metadata in
  let* local =
    Local.put_operation
      ~store:(Store.underlying_store repository)
      operation local
    |> metadata
  in
  let* loaded =
    save ~observe repository loaded ~local ~project:loaded.Store.project
      ~history:loaded.Store.history
  in
  Ok (loaded, operation)

let pause ~observe repository loaded operation error =
  let stage =
    match operation.Operation.phase with
    | Operation.Prepared -> Some Operation.Before_apply
    | Operation.Applying -> Some Operation.During_apply
    | Operation.Materialized -> Some Operation.Before_commit
    | Operation.Paused (stage, _) -> Some stage
    | Operation.Committed | Operation.Completed -> None
  in
  let* () =
    match stage with
    | None -> Ok ()
    | Some stage ->
        let detail = error_to_string error in
        let detail =
          if String.length detail > 4096 then String.sub detail 0 4096
          else detail
        in
        update_phase ~observe repository loaded operation
          (Operation.Paused (stage, detail))
        |> Result.map (fun _ -> ())
  in
  Error error

let ensure_proof ~root store operation =
  if Core.Object_id.equal operation.Operation.safety operation.Operation.target
  then Ok ()
  else
    Raw.with_lock store ~name:"restore-retention"
      ~on_error:(fun e -> Metadata (Raw.error_to_string e))
      (fun () ->
        let* _ =
          Composition.load store operation.Operation.safety
          |> Result.map_error (fun e ->
              Metadata (Composition.error_to_string e))
        in
        let* _ =
          Composition.load store operation.Operation.target
          |> Result.map_error (fun e ->
              Metadata (Composition.error_to_string e))
        in
        let* safety = model_snapshot operation.Operation.safety in
        let* target = model_snapshot operation.Operation.target in
        let* proof =
          Proof.make
            ~operation_id:(physical_operation operation.Operation.token)
            ~safety ~target
          |> Result.map_error (fun e -> Metadata (Proof.error_to_string e))
        in
        Proof.append ~root proof
        |> Result.map_error (fun e -> Metadata (Proof.error_to_string e)))

let perform ~observe ~root repository token ~resumed =
  let store = Store.underlying_store repository in
  let rec loop () =
    let* loaded = Store.load repository |> store_error in
    let* local, _, authority = context loaded in
    let* operation = find_token local token in
    let outcome operation =
      {
        plan = operation.Operation.plan;
        operation = Some operation;
        no_op = false;
        resumed;
      }
    in
    match operation.Operation.phase with
    | Operation.Completed ->
        let* () = Plan.forget ~store operation.Operation.plan |> plan_error in
        Ok (outcome operation)
    | Operation.Committed ->
        let* () = ensure_proof ~root store operation in
        let* _, operation =
          update_phase ~observe repository loaded operation Operation.Completed
        in
        observe Completed_root;
        let* () = Plan.forget ~store operation.Operation.plan |> plan_error in
        Ok (outcome operation)
    | Operation.Paused (stage, _) ->
        let phase =
          match stage with
          | Operation.Before_apply -> Operation.Prepared
          | Operation.During_apply -> Operation.Applying
          | Operation.Before_commit -> Operation.Materialized
        in
        let* _ = update_phase ~observe repository loaded operation phase in
        loop ()
    | Operation.Prepared | Operation.Applying | Operation.Materialized -> (
        let* envelope =
          Raw.get
            ~max_bytes:(8 * 1024 * 1024)
            store operation.Operation.plan_object
          |> Result.map_error (fun e -> Metadata (Raw.error_to_string e))
        in
        let* plan =
          Plan.decode ~store ~loaded (Yeokcham_envelope.encode envelope)
          |> plan_error
        in
        match
          Plan.revalidate_shared ~store ~loaded
            ~cursor:operation.Operation.source plan
        with
        | Error error ->
            pause ~observe repository loaded operation (Plan_error error)
        | Ok () -> (
            match operation.Operation.phase with
            | Operation.Prepared ->
                let* _ =
                  update_phase ~observe repository loaded operation
                    Operation.Applying
                in
                observe Applying_root;
                loop ()
            | Operation.Applying -> (
                let application =
                  let* safety = snapshot operation.Operation.safety in
                  let* target = snapshot operation.Operation.target in
                  let* application =
                    Safe_apply.load ~root ~operation:(physical_operation token)
                      ~digest:
                        (Core.Digest.to_raw operation.Operation.physical_digest)
                      ~safety ~target
                    |> physical
                  in
                  Safe_apply.For_test.apply
                    ~observe:(fun stage path ->
                      observe (Mutation (stage, path)))
                    ~root ~store application
                  |> physical
                in
                match application with
                | Error error ->
                    pause ~observe repository loaded operation error
                | Ok () ->
                    let* _ =
                      update_phase ~observe repository loaded operation
                        Operation.Materialized
                    in
                    observe Materialized_root;
                    loop ())
            | Operation.Materialized -> (
                let commit =
                  let* target = model_snapshot operation.Operation.target in
                  let draft =
                    (Model.active_draft loaded.Store.project).Model.draft_id
                  in
                  let* history =
                    History.record_exact loaded.Store.history
                      ~expected:operation.Operation.target_sequence
                      ~snapshot:target ~draft
                      ~created_at:operation.Operation.created_at
                    |> metadata
                  in
                  let* local =
                    Local.commit_operation ~store ~authority operation local
                    |> metadata
                  in
                  let project =
                    Model.checkpoint loaded.Store.project ~snapshot:target
                  in
                  save ~observe repository loaded ~local ~project ~history
                  |> Result.map (fun _ -> ())
                in
                match commit with
                | Error error ->
                    pause ~observe repository loaded operation error
                | Ok () ->
                    observe Committed_root;
                    loop ())
            | Operation.Committed | Operation.Completed | Operation.Paused _ ->
                assert false))
  in
  loop ()

let apply_with ~random_bytes ~observe ~root ~plan:identity ~signing_capability =
  let* inspection =
    with_writer ~root (fun repository ->
        let* () = no_restore root in
        let* loaded = Store.load repository |> store_error in
        let* local, _, _ = context loaded in
        match Local.find_operation local ~plan:identity with
        | Some operation -> Ok (`Existing operation.Operation.token)
        | None ->
            let* () =
              match Local.pending_operation local with
              | None -> Ok ()
              | Some operation ->
                  Error
                    (Metadata
                       ("another integration is incomplete: "
                       ^ Core.Operation_id.to_hex operation.Operation.token))
            in
            let store = Store.underlying_store repository in
            let* plan = Plan.load ~store ~loaded identity |> plan_error in
            let* _, observed, observation = observe_tree root store in
            let* plan =
              Plan.revalidate ~store ~loaded ~observed ~observation plan
              |> plan_error
            in
            Ok (`New (store, loaded, plan)))
  in
  match inspection with
  | `Existing token ->
      with_writer ~root (fun repository ->
          let* () = no_restore root in
          perform ~observe ~root repository token ~resumed:true)
  | `New (store, loaded, plan) ->
      (* providers may require a human decision; no writer lock crosses signing. *)
      let* signed = sign_records ~store ~loaded plan signing_capability in
      with_writer ~root (fun repository ->
          let* () = no_restore root in
          let* loaded = Store.load repository |> store_error in
          let* local, _, _ = context loaded in
          match Local.find_operation local ~plan:identity with
          | Some operation ->
              perform ~observe ~root repository operation.Operation.token
                ~resumed:true
          | None -> (
              let* () =
                match Local.pending_operation local with
                | None -> Ok ()
                | Some _ ->
                    Error
                      (Metadata
                         "another integration began while signing; resume it \
                          first")
              in
              let* operation =
                begin_operation ~random_bytes ~observe ~root repository loaded
                  plan signed
              in
              match operation with
              | None ->
                  let* () = Plan.forget ~store identity |> plan_error in
                  Ok
                    {
                      plan = identity;
                      operation = None;
                      no_op = true;
                      resumed = false;
                    }
              | Some operation ->
                  perform ~observe ~root repository operation.Operation.token
                    ~resumed:false))

let apply = apply_with ~random_bytes:Trust.random_bytes ~observe:(fun _ -> ())

let resume ~root ~operation =
  with_writer ~root (fun repository ->
      let* () = no_restore root in
      perform ~observe:(fun _ -> ()) ~root repository operation ~resumed:true)

module For_test = struct
  let apply = apply_with ~random_bytes:Trust.random_bytes
  let apply_with_entropy = apply_with
end
