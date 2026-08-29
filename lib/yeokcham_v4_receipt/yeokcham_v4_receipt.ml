module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Store = Yeokcham_v4_store
module Transport = Yeokcham_v4_transport
module Trust = Yeokcham_v4_trust

type error =
  | Store_error of Store.error
  | Model_error of Model.error
  | Trust_error of Trust.error
  | Package_error of Package.error
  | Transport_error of Transport.error
  | Unsigned_project

type status = {
  creator : Model.Device_id.t;
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_changes : Model.shared_change list;
  shared_change_count : int;
  open_decisions : Model.decision list;
  deliveries : Model.delivery list;
  delivery_count : int;
  checkpoints : Model.checkpoint list;
  usernames : Model.username_registration list;
  uncaptured : bool;
}

type transport_arrival = {
  publication : Transport.publication;
  package : string;
}

type transport_receive = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  transport_status : status;
}

let ( let* ) = Result.bind

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Trust_error error -> Trust.error_to_string error
  | Package_error error -> Package.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Unsigned_project ->
      "this V4 project has no signed collaboration state; initialize a signed \
       project"

let status_of_project project =
  let active_draft = Model.active_draft project in
  let projection = Model.projection project in
  let shared_changes = Model.shared_changes project in
  let deliveries = Model.deliveries project in
  {
    creator = Model.creator project;
    active_draft;
    checkpoint = active_draft.Model.latest_checkpoint;
    shared_changes;
    shared_change_count = List.length shared_changes;
    open_decisions = projection.Model.decisions;
    deliveries;
    delivery_count = List.length deliveries;
    checkpoints = Model.checkpoints project;
    usernames = Model.usernames project;
    uncaptured = false;
  }

let with_repository ~root f =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  f repository loaded

let require_collaboration loaded =
  match loaded.Store.collaboration with
  | Some collaboration -> Ok collaboration
  | None -> Error Unsigned_project

let persist_collaborative repository loaded project collaboration =
  Store.save_collaborative repository ~expected:loaded.Store.head ~project
    ~collaboration
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let merge_signed_revisions existing incoming =
  let rec add known = function
    | [] -> Ok known
    | signed :: rest -> (
        let revision = Trust.signed_revision_value signed in
        match
          List.find_opt
            (fun candidate ->
              Model.Revision_id.equal
                (Trust.signed_revision_id candidate)
                revision.Model.revision)
            known
        with
        | None -> add (signed :: known) rest
        | Some candidate ->
            if
              Trust.encode_signed_revision candidate
              = Trust.encode_signed_revision signed
            then add known rest
            else
              Error
                (Package_error
                   (Package.Invalid_package
                      "revision identity conflicts with a local signed record"))
        )
  in
  add existing incoming

let merge_public_records ~encode existing incoming =
  let rec add known = function
    | [] -> Ok known
    | record :: rest ->
        let bytes = encode record in
        if
          List.exists
            (fun existing -> String.equal bytes (encode existing))
            known
        then add known rest
        else add (record :: known) rest
  in
  add existing incoming

let receive_package ~root ~package =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      match Store.authority existing with
      | None ->
          let* received =
            Package.verify_and_import
              ~destination:(Store.underlying_store repository)
              ~package
              ~membership:(Store.membership existing)
              ~project:loaded.Store.project
            |> Result.map_error (fun error -> Package_error error)
          in
          let received, project = received in
          let* revisions =
            merge_signed_revisions
              (Store.signed_revisions existing)
              (Package.revisions received)
          in
          let* collaboration =
            Store.collaboration
              ~membership:(Package.membership received)
              ~revisions
              ~local_certificate:(Store.local_certificate existing)
            |> Result.map_error (fun error -> Store_error error)
          in
          persist_collaborative repository loaded project collaboration
      | Some authority ->
          let* received =
            Package.verify_and_import_with_authority
              ~destination:(Store.underlying_store repository)
              ~package ~authority ~known_adoptions:(Store.adoptions existing)
              ~project:loaded.Store.project
            |> Result.map_error (fun error -> Package_error error)
          in
          let received, project = received in
          let* authority =
            match Package.authority received with
            | Some authority -> Ok authority
            | None ->
                Error
                  (Package_error
                     (Package.Invalid_package
                        "authority-aware receive returned no authority"))
          in
          let* revisions =
            merge_signed_revisions
              (Store.signed_revisions existing)
              (Package.revisions received)
          in
          let* authorizations =
            merge_public_records ~encode:Trust.encode_authorization
              (Store.authorizations existing)
              (Package.authorizations received)
          in
          let* adoptions =
            merge_public_records ~encode:Trust.encode_adoption
              (Store.adoptions existing)
              (Package.adoptions received)
          in
          let* collaboration =
            Store.collaboration_with_authority ~authority ~revisions
              ~local_certificate:(Store.local_certificate existing)
              ~authorizations ~adoptions
            |> Result.map_error (fun error -> Store_error error)
          in
          persist_collaborative repository loaded project collaboration)

let receive_transport_batch ~root ~remote ~cursor arrivals =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* initial_authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Store_error
                 (Store.Invalid_collaboration_state
                    "relay transport requires authority-aware collaboration"))
      in
      let transport = Store.transport existing in
      let prior_remote = Transport.find_remote transport ~name:remote in
      let known =
        match prior_remote with
        | None -> []
        | Some state -> Transport.remote_known_publications state
      in
      let known_ids = List.map Transport.reference_id known in
      let review_inbox =
        match prior_remote with
        | None -> []
        | Some state -> Transport.remote_review_inbox state
      in
      let arrivals =
        List.filter
          (fun arrival ->
            let id = Transport.publication_id arrival.publication in
            (not (List.mem id known_ids)) || List.mem id review_inbox)
          arrivals
      in
      let rec inspect authority reversed = function
        | [] -> Ok (List.rev reversed, authority)
        | arrival :: rest ->
            let* artifact =
              Package.read_artifact ~package:arrival.package
              |> Result.map_error (fun error -> Package_error error)
            in
            if
              not
                (String.equal
                   (Transport.sha256 (Package.artifact_manifest artifact))
                   (Transport.publication_manifest arrival.publication))
            then
              Error
                (Transport_error
                   (Transport.Invalid_publication
                      "publication manifest does not match staged package"))
            else
              let* inspected =
                Package.inspect_with_authority ~package:arrival.package
                  ~authority
                |> Result.map_error (fun error -> Package_error error)
              in
              let* package_authority =
                match Package.authority inspected with
                | Some authority -> Ok authority
                | None ->
                    Error
                      (Package_error
                         (Package.Invalid_package
                            "transport package lacks authority closure"))
              in
              let* () =
                Transport.verify_publication ~authority:package_authority
                  arrival.publication
                |> Result.map_error (fun error -> Transport_error error)
              in
              inspect package_authority ((arrival, inspected) :: reversed) rest
      in
      let* inspected_arrivals, inspected_authority =
        inspect initial_authority [] arrivals
      in
      let* () =
        Transport.validate_feed ~known
          (List.map
             (fun (arrival, _) -> arrival.publication)
             inspected_arrivals)
        |> Result.map_error (fun error -> Transport_error error)
      in
      let existing_signed_purpose signed =
        let revision = Trust.signed_revision_value signed in
        match Trust.signed_revision_resolution signed with
        | None ->
            Model.shared_changes loaded.Store.project
            |> List.concat_map (fun change -> change.Model.revisions)
            |> List.exists (fun existing -> existing = revision)
        | Some decision ->
            Model.resolutions loaded.Store.project
            |> List.exists (fun resolution ->
                Model.Decision_id.equal resolution.Model.resolved_decision
                  decision
                && resolution.Model.replacement_revision = revision)
      in
      let needs_late_review inspected =
        let* authority =
          match Package.authority inspected with
          | Some authority -> Ok authority
          | None ->
              Error
                (Package_error
                   (Package.Invalid_package
                      "transport package lacks authority closure"))
        in
        let rec loop = function
          | [] -> Ok false
          | signed :: rest ->
              if existing_signed_purpose signed then loop rest
              else
                let* requires_review =
                  Trust.requires_late_review authority signed
                  |> Result.map_error (fun error -> Trust_error error)
                in
                if not requires_review then loop rest
                else
                  let accepted_adoptions =
                    Store.adoptions existing @ Package.adoptions inspected
                    |> List.filter (fun adoption ->
                        Trust.adoption_matches_signed_revision adoption signed
                        && Trust.authority_epoch_is_head authority
                             (Trust.adoption_epoch adoption))
                  in
                  if List.length accepted_adoptions = 1 then loop rest
                  else Ok true
        in
        loop (Package.revisions inspected)
      in
      let rec separate normal deferred = function
        | [] -> Ok (List.rev normal, List.rev deferred)
        | (arrival, inspected) :: rest ->
            let* defer = needs_late_review inspected in
            if defer then
              let* _ =
                Package.validate_with_authority ~package:arrival.package
                  ~authority:initial_authority
                |> Result.map_error (fun error -> Package_error error)
              in
              separate normal (arrival :: deferred) rest
            else separate (arrival :: normal) deferred rest
      in
      let* arrivals, deferred_arrivals = separate [] [] inspected_arrivals in
      let before_decisions =
        List.length (Model.projection loaded.Store.project).Model.decisions
      in
      let rec prepare authority project known_adoptions reversed = function
        | [] -> Ok (List.rev reversed, project)
        | arrival :: rest ->
            let* prepared =
              Package.prepare_with_authority ~package:arrival.package ~authority
                ~known_adoptions ~project
              |> Result.map_error (fun error -> Package_error error)
            in
            let verified = Package.prepared_verified prepared in
            let* authority =
              match Package.authority verified with
              | Some authority -> Ok authority
              | None ->
                  Error
                    (Package_error
                       (Package.Invalid_package
                          "authority transport preparation returned no \
                           authority"))
            in
            prepare authority
              (Package.prepared_project prepared)
              (known_adoptions @ Package.adoptions verified)
              (prepared :: reversed) rest
      in
      let* prepared, project =
        prepare initial_authority loaded.Store.project
          (Store.adoptions existing) [] arrivals
      in
      let rec import = function
        | [] -> Ok ()
        | prepared :: rest ->
            let* _ =
              Package.import_prepared
                ~destination:(Store.underlying_store repository)
                prepared
              |> Result.map_error (fun error -> Package_error error)
            in
            import rest
      in
      let* () = import prepared in
      let verified = List.map Package.prepared_verified prepared in
      let* revisions =
        merge_signed_revisions
          (Store.signed_revisions existing)
          (List.concat_map Package.revisions verified)
      in
      let* authorizations =
        merge_public_records ~encode:Trust.encode_authorization
          (Store.authorizations existing)
          (List.concat_map Package.authorizations verified)
      in
      let* adoptions =
        merge_public_records ~encode:Trust.encode_adoption
          (Store.adoptions existing)
          (List.concat_map Package.adoptions verified)
      in
      let incoming_references =
        List.map
          (fun (arrival, _) ->
            Transport.publication_reference arrival.publication)
          inspected_arrivals
      in
      let known =
        List.sort_uniq
          (fun left right ->
            String.compare
              (Transport.reference_id left)
              (Transport.reference_id right))
          (known @ incoming_references)
      in
      let announced_manifests, announced_revisions, previous_review_inbox =
        match prior_remote with
        | None -> ([], [], [])
        | Some state ->
            ( Transport.remote_announced_manifests state,
              Transport.remote_announced_revisions state,
              Transport.remote_review_inbox state )
      in
      let completed =
        List.map
          (fun arrival -> Transport.publication_id arrival.publication)
          arrivals
      in
      let deferred =
        List.map
          (fun arrival -> Transport.publication_id arrival.publication)
          deferred_arrivals
      in
      let review_inbox =
        previous_review_inbox @ deferred
        |> List.filter (fun id -> not (List.mem id completed))
        |> List.sort_uniq String.compare
      in
      let* remote_state =
        Transport.remote_state ~name:remote ~cursor ~known ~announced_manifests
          ~announced_revisions ~review_inbox
        |> Result.map_error (fun error -> Transport_error error)
      in
      let* transport =
        Transport.with_remote transport remote_state
        |> Result.map_error (fun error -> Transport_error error)
      in
      let* collaboration =
        Store.collaboration_with_authority_transport ~transport
          ~authority:inspected_authority ~revisions
          ~local_certificate:(Store.local_certificate existing)
          ~authorizations ~adoptions
        |> Result.map_error (fun error -> Store_error error)
      in
      let* _ = persist_collaborative repository loaded project collaboration in
      let after_decisions =
        List.length (Model.projection project).Model.decisions
      in
      Ok
        {
          discovered_publications = List.length inspected_arrivals;
          received_revisions =
            List.fold_left
              (fun count verified ->
                count + List.length (Package.revisions verified))
              0 verified;
          deferred_publications = List.length deferred_arrivals;
          created_decisions = max 0 (after_decisions - before_decisions);
          transport_status = status_of_project project;
        })
