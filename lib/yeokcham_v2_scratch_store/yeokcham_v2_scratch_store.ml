module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module V2_model = Yeokcham_v2_model

type repository = {
  bootstrap : Bootstrap_store.repository;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  scratch_ref : Ledger.Ref_name.t;
}

type checkpoint = {
  event_id : Ledger.Event_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
  snapshot : Model.Snapshot.t;
}

type inspection =
  | No_checkpoint
  | Checkpoint of checkpoint
  | Divergent_checkpoints of Ledger.Event_id.t list

type publication = Published of checkpoint | Unchanged of checkpoint

type plan =
  | Unchanged_plan of checkpoint
  | Publish_plan of {
      checkpoint : checkpoint;
      snapshot_envelope : Envelope.t;
      ledger_envelope : Envelope.t;
    }

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Bootstrap.error
  | Object_store_error of Object_store.error
  | Ledger_store_error of Ledger_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Scratch_event_missing_target of Ledger.Event_id.t
  | Unknown_scratch_event of Ledger.Event_id.t
  | Event_outside_scratch_scope of Ledger.Event_id.t
  | Scratch_target_not_snapshot of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_checkpoint of Ledger.Event_id.t
  | Divergent_scratch_heads of Ledger.Event_id.t list
  | Nonce_reuse

type validated_event = { verified : Ledger.verified; checkpoint : checkpoint }

let ( let* ) = Result.bind

let error_to_string = function
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Ledger_error error -> Ledger.error_to_string error
  | Scratch_event_missing_target event_id ->
      "scratch event has no snapshot target: " ^ Ledger.Event_id.to_hex event_id
  | Unknown_scratch_event event_id ->
      "unknown signed scratch event: " ^ Ledger.Event_id.to_hex event_id
  | Event_outside_scratch_scope event_id ->
      "selected event is outside this device scratch scope: "
      ^ Ledger.Event_id.to_hex event_id
  | Scratch_target_not_snapshot { event_id; object_ref } ->
      Printf.sprintf "scratch event %s targets non-snapshot object %s"
        (Ledger.Event_id.to_hex event_id)
        (V2_model.Opaque_object_ref.to_hex object_ref)
  | Missing_evaluated_checkpoint event_id ->
      "causal evaluator returned unknown scratch event: "
      ^ Ledger.Event_id.to_hex event_id
  | Divergent_scratch_heads event_ids ->
      "scratch causal heads require explicit resolution: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex event_ids)
  | Nonce_reuse -> "snapshot and ledger envelopes require distinct nonces"

let scratch_ref_of_device device_id =
  Ledger.Ref_name.of_string ("scratch-" ^ V2_model.Device_id.to_hex device_id)
  |> Result.map_error (fun error ->
      Ledger_error (Ledger.Invalid_ref_name error))

let open_repository ~root ~bootstrap_repository =
  let capability = Bootstrap_store.capability bootstrap_repository in
  let* bootstrap =
    Bootstrap_store.open_repository ~root ~capability
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  let record = Bootstrap_store.bootstrap bootstrap in
  let* public_keys =
    Bootstrap.public_key_registry capability
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* objects =
    Object_store.open_repository ~root
      ~repository_id:(Bootstrap.repository_id record)
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* ledger =
    Ledger_store.open_repository ~root
      ~repository_id:(Bootstrap.repository_id record)
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
      ~public_keys
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let* scratch_ref = scratch_ref_of_device (Bootstrap.device_id record) in
  Ok { bootstrap; objects; ledger; scratch_ref }

let scratch_ref_name repository = repository.scratch_ref

let checkpoint_of_verified repository verified =
  let event = Ledger.verified_event verified in
  let event_id = Ledger.event_id event in
  let* object_ref =
    match Ledger.event_unsigned event |> Ledger.unsigned_target with
    | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
    | None -> Error (Scratch_event_missing_target event_id)
  in
  let* object_ =
    Object_store.load repository.objects ~object_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.snapshot object_ with
  | Some snapshot -> Ok { event_id; snapshot_ref = object_ref; snapshot }
  | None -> Error (Scratch_target_not_snapshot { event_id; object_ref })

let inspect repository =
  let* object_refs =
    Ledger_store.list_object_refs repository.ledger
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let rec collect result = function
    | [] -> Ok (List.rev result)
    | object_ref :: rest -> (
        let* object_ =
          Ledger_store.load_object repository.ledger ~object_ref
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        match Object.ledger object_ with
        | None -> collect result rest
        | Some event ->
            let event_ref =
              Ledger.event_unsigned event |> Ledger.unsigned_ref_name
            in
            if not (Ledger.Ref_name.equal event_ref repository.scratch_ref) then
              collect result rest
            else
              let* verified =
                Ledger_store.load repository.ledger ~object_ref
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              let* checkpoint = checkpoint_of_verified repository verified in
              collect ({ verified; checkpoint } :: result) rest)
  in
  let* events = collect [] object_refs in
  match events with
  | [] -> Ok No_checkpoint
  | _ -> (
      let* heads =
        Ledger.evaluate
          ~repository_id:(Ledger_store.repository_id repository.ledger)
          ~ref_name:repository.scratch_ref
          (List.map (fun event -> event.verified) events)
        |> Result.map_error (fun error -> Ledger_error error)
      in
      let head_events = Ledger.heads heads in
      let find_checkpoint verified =
        let event_id = Ledger.verified_event verified |> Ledger.event_id in
        List.find_opt
          (fun event ->
            Ledger.Event_id.equal event.checkpoint.event_id event_id)
          events
      in
      match head_events with
      | [] -> Ok No_checkpoint
      | [ verified ] -> (
          match find_checkpoint verified with
          | Some event -> Ok (Checkpoint event.checkpoint)
          | None ->
              Error
                (Missing_evaluated_checkpoint
                   (Ledger.verified_event verified |> Ledger.event_id)))
      | heads ->
          let event_ids =
            List.map
              (fun verified ->
                Ledger.verified_event verified |> Ledger.event_id)
              heads
            |> List.sort Ledger.Event_id.compare
          in
          Ok (Divergent_checkpoints event_ids))

let checkpoint_for_event repository ~event_id =
  let* object_refs =
    Ledger_store.list_object_refs repository.ledger
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let rec find = function
    | [] -> Error (Unknown_scratch_event event_id)
    | object_ref :: rest -> (
        let* object_ =
          Ledger_store.load_object repository.ledger ~object_ref
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        match Object.ledger object_ with
        | None -> find rest
        | Some event
          when not (Ledger.Event_id.equal event_id (Ledger.event_id event)) ->
            find rest
        | Some event ->
            let ref_name =
              Ledger.event_unsigned event |> Ledger.unsigned_ref_name
            in
            if not (Ledger.Ref_name.equal ref_name repository.scratch_ref) then
              Error (Event_outside_scratch_scope event_id)
            else
              let* verified =
                Ledger_store.load repository.ledger ~object_ref
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              let actual = Ledger.verified_event verified |> Ledger.event_id in
              if not (Ledger.Event_id.equal event_id actual) then
                Error (Unknown_scratch_event event_id)
              else checkpoint_of_verified repository verified)
  in
  find object_refs

let publication_ref = function
  | Object_store.Published object_ref
  | Object_store.Already_published object_ref ->
      object_ref

let plan repository ~snapshot ~snapshot_nonce ~ledger_nonce =
  if
    String.equal
      (Envelope.nonce_to_bytes snapshot_nonce)
      (Envelope.nonce_to_bytes ledger_nonce)
  then Error Nonce_reuse
  else
    let* prior = inspect repository in
    match prior with
    | Divergent_checkpoints event_ids ->
        Error (Divergent_scratch_heads event_ids)
    | No_checkpoint | Checkpoint _ -> (
        let prior_checkpoint =
          match prior with
          | No_checkpoint -> None
          | Checkpoint checkpoint -> Some checkpoint
          | Divergent_checkpoints _ -> assert false
        in
        match prior_checkpoint with
        | Some checkpoint when Model.Snapshot.equal snapshot checkpoint.snapshot
          ->
            Ok (Unchanged_plan checkpoint)
        | None | Some _ ->
            let capability = Bootstrap_store.capability repository.bootstrap in
            let record = Bootstrap_store.bootstrap repository.bootstrap in
            let* snapshot_envelope =
              Envelope.seal
                ~key:(Bootstrap.envelope_key capability)
                ~nonce:snapshot_nonce ~mandatory_features:0L
                (Object.scratch_snapshot snapshot |> Object.encode)
              |> Result.map_error (fun error -> Envelope_error error)
            in
            let snapshot_ref =
              Address.derive
                ~repository_id:(Bootstrap.repository_id record)
                ~key:(Bootstrap.address_key capability)
                ~envelope:snapshot_envelope
            in
            let predecessor =
              Option.map
                (fun checkpoint -> checkpoint.event_id)
                prior_checkpoint
            in
            let* unsigned =
              Ledger.make_unsigned
                ~repository_id:(Bootstrap.repository_id record)
                ~ref_name:repository.scratch_ref
                ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
                ~predecessor
                ~target:
                  (Some (Ledger.Ref_target.of_opaque_object_ref snapshot_ref))
                ~mandatory_features:0L
              |> Result.map_error (fun error -> Ledger_error error)
            in
            let signature = Bootstrap.sign_ledger capability unsigned in
            let* event =
              Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature
              |> Result.map_error (fun error -> Ledger_error error)
            in
            let* ledger_envelope =
              Envelope.seal
                ~key:(Bootstrap.envelope_key capability)
                ~nonce:ledger_nonce ~mandatory_features:0L
                (Object.ledger_event event |> Object.encode)
              |> Result.map_error (fun error -> Envelope_error error)
            in
            Ok
              (Publish_plan
                 {
                   checkpoint =
                     {
                       event_id = Ledger.event_id event;
                       snapshot_ref;
                       snapshot;
                     };
                   snapshot_envelope;
                   ledger_envelope;
                 }))

let publish_plan repository = function
  | Unchanged_plan checkpoint -> Ok (Unchanged checkpoint)
  | Publish_plan { checkpoint; snapshot_envelope; ledger_envelope } ->
      let* snapshot_ref =
        Object_store.publish repository.objects ~envelope:snapshot_envelope
        |> Result.map publication_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      if
        not
          (V2_model.Opaque_object_ref.equal snapshot_ref checkpoint.snapshot_ref)
      then assert false
      else
        let* publication =
          Ledger_store.publish repository.ledger ~envelope:ledger_envelope
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        let event_id =
          match publication with
          | Ledger_store.Published { event_id; _ }
          | Ledger_store.Already_published { event_id; _ } ->
              event_id
        in
        if not (Ledger.Event_id.equal event_id checkpoint.event_id) then
          assert false
        else Ok (Published checkpoint)

let publish repository ~snapshot ~snapshot_nonce ~ledger_nonce =
  let* plan = plan repository ~snapshot ~snapshot_nonce ~ledger_nonce in
  publish_plan repository plan
