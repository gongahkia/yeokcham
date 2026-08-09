module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Retention = Yeokcham_v2_retention
module V2_model = Yeokcham_v2_model

type repository = {
  bootstrap : Bootstrap_store.repository;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  scratch_ref : Ledger.Ref_name.t;
  protection_ref : Ledger.Ref_name.t;
  generation_ref : Ledger.Ref_name.t;
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

type compaction_nonces = {
  compact_ledger_nonces : Envelope.nonce list;
  generation_manifest_nonce : Envelope.nonce;
  generation_ledger_nonce : Envelope.nonce;
}

type compacted_event = {
  source_checkpoint : Retention.checkpoint;
  compacted_event_id : Ledger.Event_id.t;
  ledger_envelope : Envelope.t;
}

type compaction_plan = {
  source_ref : Ledger.Ref_name.t;
  source_head : Ledger.Event_id.t;
  source_generation_head : Ledger.Event_id.t option;
  source_protection_head : Ledger.Event_id.t option;
  compaction_retention : Retention.plan;
  compacted_events : compacted_event list;
  compaction_generation_manifest : Retention.generation;
  generation_object_ref : V2_model.Opaque_object_ref.t;
  generation_envelope : Envelope.t;
  activation_event_id : Ledger.Event_id.t;
  activation_envelope : Envelope.t;
}

type compaction_publication = {
  published_generation_event_id : Ledger.Event_id.t;
  published_generation_manifest : Retention.generation;
  published_retention : Retention.plan;
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
  | Generation_event_missing_target of Ledger.Event_id.t
  | Generation_target_not_manifest of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_generation of Ledger.Event_id.t
  | Divergent_generation_heads of Ledger.Event_id.t list
  | Generation_source_ref_mismatch of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Generation_active_ref_mismatch of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Generation_active_anchor_not_reachable of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Event_id.t;
      actual : Ledger.Event_id.t list;
    }
  | Protection_event_missing_target of Ledger.Event_id.t
  | Protection_target_not_claim of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_protection of Ledger.Event_id.t
  | Divergent_protection_heads of Ledger.Event_id.t list
  | Nonce_reuse
  | Retention_error of Retention.error
  | Invalid_compaction_nonce_count of { expected : int; actual : int }
  | Compaction_nonce_reuse
  | Compaction_source_not_active of {
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Compaction_source_head_changed of {
      expected : Ledger.Event_id.t;
      actual : Ledger.Event_id.t;
    }
  | Compaction_generation_head_changed of {
      expected : Ledger.Event_id.t option;
      actual : Ledger.Event_id.t option;
    }
  | Compaction_protection_head_changed of {
      expected : Ledger.Event_id.t option;
      actual : Ledger.Event_id.t option;
    }

type validated_event = { validated_checkpoint : checkpoint }

type scoped_event = {
  object_ref : V2_model.Opaque_object_ref.t;
  verified : Ledger.verified;
}

type generation_activation = {
  generation_event_id : Ledger.Event_id.t;
  manifest : Retention.generation;
}

type scoped_inspection = {
  scope_ref : Ledger.Ref_name.t;
  scope_inspection : inspection;
}

type history_checkpoint = { retention_checkpoint : Retention.checkpoint }

type active_generation = {
  generation_head : Ledger.Event_id.t;
  activation : generation_activation;
}

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
  | Generation_event_missing_target event_id ->
      "scratch generation event has no manifest target: "
      ^ Ledger.Event_id.to_hex event_id
  | Generation_target_not_manifest { event_id; object_ref } ->
      Printf.sprintf
        "scratch generation event %s targets non-generation object %s"
        (Ledger.Event_id.to_hex event_id)
        (V2_model.Opaque_object_ref.to_hex object_ref)
  | Missing_evaluated_generation event_id ->
      "causal evaluator returned unknown scratch generation event: "
      ^ Ledger.Event_id.to_hex event_id
  | Divergent_generation_heads event_ids ->
      "scratch generation causal heads require explicit resolution: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex event_ids)
  | Generation_source_ref_mismatch { event_id; expected; actual } ->
      Printf.sprintf
        "scratch generation event %s names source ref %s, expected %s"
        (Ledger.Event_id.to_hex event_id)
        (Ledger.Ref_name.to_string actual)
        (Ledger.Ref_name.to_string expected)
  | Generation_active_ref_mismatch { event_id; expected; actual } ->
      Printf.sprintf
        "scratch generation event %s names active ref %s, expected %s"
        (Ledger.Event_id.to_hex event_id)
        (Ledger.Ref_name.to_string actual)
        (Ledger.Ref_name.to_string expected)
  | Generation_active_anchor_not_reachable { event_id; expected; actual } ->
      Printf.sprintf
        "scratch generation event %s names active anchor %s, but current heads \
         do not descend from it: %s"
        (Ledger.Event_id.to_hex event_id)
        (Ledger.Event_id.to_hex expected)
        (String.concat "," (List.map Ledger.Event_id.to_hex actual))
  | Protection_event_missing_target event_id ->
      "scratch protection event has no claim target: "
      ^ Ledger.Event_id.to_hex event_id
  | Protection_target_not_claim { event_id; object_ref } ->
      Printf.sprintf
        "scratch protection event %s targets non-protection object %s"
        (Ledger.Event_id.to_hex event_id)
        (V2_model.Opaque_object_ref.to_hex object_ref)
  | Missing_evaluated_protection event_id ->
      "causal evaluator returned unknown scratch protection event: "
      ^ Ledger.Event_id.to_hex event_id
  | Divergent_protection_heads event_ids ->
      "scratch protection causal heads require explicit resolution: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex event_ids)
  | Nonce_reuse -> "snapshot and ledger envelopes require distinct nonces"
  | Retention_error error -> Retention.error_to_string error
  | Invalid_compaction_nonce_count { expected; actual } ->
      Printf.sprintf
        "V2 scratch compaction needs %d compact ledger nonces, received %d"
        expected actual
  | Compaction_nonce_reuse ->
      "V2 scratch compaction envelopes require distinct nonces"
  | Compaction_source_not_active { expected; actual } ->
      Printf.sprintf
        "V2 scratch compaction source ref %s is no longer active (active: %s)"
        (Ledger.Ref_name.to_string expected)
        (Ledger.Ref_name.to_string actual)
  | Compaction_source_head_changed { expected; actual } ->
      Printf.sprintf "V2 scratch compaction source head changed from %s to %s"
        (Ledger.Event_id.to_hex expected)
        (Ledger.Event_id.to_hex actual)
  | Compaction_generation_head_changed { expected; actual } ->
      let render = function
        | None -> "none"
        | Some event_id -> Ledger.Event_id.to_hex event_id
      in
      Printf.sprintf
        "V2 scratch compaction generation head changed from %s to %s"
        (render expected) (render actual)
  | Compaction_protection_head_changed { expected; actual } ->
      let render = function
        | None -> "none"
        | Some event_id -> Ledger.Event_id.to_hex event_id
      in
      Printf.sprintf
        "V2 scratch compaction protection head changed from %s to %s"
        (render expected) (render actual)

let scratch_ref_of_device device_id =
  Ledger.Ref_name.of_string ("scratch-" ^ V2_model.Device_id.to_hex device_id)
  |> Result.map_error (fun error ->
      Ledger_error (Ledger.Invalid_ref_name error))

let generation_ref_of_device device_id =
  Ledger.Ref_name.of_string
    ("scratch-generation-" ^ V2_model.Device_id.to_hex device_id)
  |> Result.map_error (fun error ->
      Ledger_error (Ledger.Invalid_ref_name error))

let protection_ref_of_device device_id =
  Ledger.Ref_name.of_string
    ("scratch-protection-" ^ V2_model.Device_id.to_hex device_id)
  |> Result.map_error (fun error ->
      Ledger_error (Ledger.Invalid_ref_name error))

let compact_ref_of_source ~device_id ~source_head =
  Ledger.Ref_name.of_string
    ("scratch-compact-"
    ^ V2_model.Device_id.to_hex device_id
    ^ "-"
    ^ Ledger.Event_id.to_hex source_head)
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
  let* protection_ref = protection_ref_of_device (Bootstrap.device_id record) in
  let* generation_ref = generation_ref_of_device (Bootstrap.device_id record) in
  Ok { bootstrap; objects; ledger; scratch_ref; protection_ref; generation_ref }

let scratch_ref_name repository = repository.scratch_ref
let generation_ref_name repository = repository.generation_ref
let protection_ref_name repository = repository.protection_ref

let compact_ref_name repository ~source_head =
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  compact_ref_of_source ~device_id:(Bootstrap.device_id record) ~source_head

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

let verified_events_for_ref repository ~ref_name =
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
            if not (Ledger.Ref_name.equal event_ref ref_name) then
              collect result rest
            else
              let* verified =
                Ledger_store.load repository.ledger ~object_ref
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              collect ({ object_ref; verified } :: result) rest)
  in
  collect [] object_refs

let evaluate_scope repository ~ref_name (events : scoped_event list) =
  Ledger.evaluate
    ~repository_id:(Ledger_store.repository_id repository.ledger)
    ~ref_name
    (List.map (fun event -> event.verified) events)
  |> Result.map_error (fun error -> Ledger_error error)

let event_id_of_verified verified =
  Ledger.verified_event verified |> Ledger.event_id

let event_ids verified =
  List.map event_id_of_verified verified |> List.sort Ledger.Event_id.compare

let find_scoped_event (events : scoped_event list) event_id =
  List.find_opt
    (fun event ->
      Ledger.Event_id.equal (event_id_of_verified event.verified) event_id)
    events

let descends_from events ~anchor head =
  let rec reaches event =
    let ledger_event = Ledger.verified_event event.verified in
    if Ledger.Event_id.equal (Ledger.event_id ledger_event) anchor then true
    else
      match
        Ledger.event_unsigned ledger_event |> Ledger.unsigned_predecessor
      with
      | None -> false
      | Some predecessor -> (
          match find_scoped_event events predecessor with
          | None -> false
          | Some predecessor -> reaches predecessor)
  in
  reaches head

let generation_of_event repository (event : scoped_event) =
  let ledger_event = Ledger.verified_event event.verified in
  let generation_event_id = Ledger.event_id ledger_event in
  let* object_ref =
    match Ledger.event_unsigned ledger_event |> Ledger.unsigned_target with
    | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
    | None -> Error (Generation_event_missing_target generation_event_id)
  in
  let* object_ =
    Object_store.load repository.objects ~object_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.generation object_ with
  | Some manifest -> Ok { generation_event_id; manifest }
  | None ->
      Error
        (Generation_target_not_manifest
           { event_id = generation_event_id; object_ref })

let generation_chain repository events head =
  let rec collect reverse event =
    let ledger_event = Ledger.verified_event event.verified in
    let event_id = Ledger.event_id ledger_event in
    let* activation = generation_of_event repository event in
    match Ledger.event_unsigned ledger_event |> Ledger.unsigned_predecessor with
    | None -> Ok (activation :: reverse)
    | Some predecessor -> (
        match find_scoped_event events predecessor with
        | Some predecessor -> collect (activation :: reverse) predecessor
        | None -> Error (Missing_evaluated_generation event_id))
  in
  collect [] head

let validate_generation_chain repository
    (activations : generation_activation list) =
  let rec validate previous = function
    | [] -> assert false
    | current :: rest -> (
        let generation = current.manifest in
        let expected_source =
          match previous with
          | None -> repository.scratch_ref
          | Some (previous : generation_activation) ->
              previous.manifest.Retention.active_ref
        in
        if
          not
            (Ledger.Ref_name.equal generation.Retention.source_ref
               expected_source)
        then
          Error
            (Generation_source_ref_mismatch
               {
                 event_id = current.generation_event_id;
                 expected = expected_source;
                 actual = generation.Retention.source_ref;
               })
        else
          let* expected_active =
            compact_ref_name repository
              ~source_head:generation.Retention.source_head
          in
          if
            not
              (Ledger.Ref_name.equal generation.Retention.active_ref
                 expected_active)
          then
            Error
              (Generation_active_ref_mismatch
                 {
                   event_id = current.generation_event_id;
                   expected = expected_active;
                   actual = generation.Retention.active_ref;
                 })
          else
            match rest with
            | [] -> Ok current
            | _ -> validate (Some current) rest)
  in
  validate None activations

let resolved_active_generation repository =
  let* events =
    verified_events_for_ref repository ~ref_name:repository.generation_ref
  in
  match events with
  | [] -> Ok None
  | _ -> (
      let* evaluated =
        evaluate_scope repository ~ref_name:repository.generation_ref events
      in
      let heads = Ledger.heads evaluated in
      match heads with
      | [] -> Ok None
      | [ generation_head ] -> (
          match
            find_scoped_event events (event_id_of_verified generation_head)
          with
          | None ->
              Error
                (Missing_evaluated_generation
                   (event_id_of_verified generation_head))
          | Some generation_head -> (
              let* activations =
                generation_chain repository events generation_head
              in
              let* current = validate_generation_chain repository activations in
              let* active_events =
                verified_events_for_ref repository
                  ~ref_name:current.manifest.Retention.active_ref
              in
              let* active_heads =
                evaluate_scope repository
                  ~ref_name:current.manifest.Retention.active_ref active_events
              in
              let heads = Ledger.heads active_heads in
              let actual = event_ids heads in
              match heads with
              | [ head ] -> (
                  match
                    find_scoped_event active_events (event_id_of_verified head)
                  with
                  | Some scoped
                    when descends_from active_events
                           ~anchor:current.manifest.Retention.active_anchor
                           scoped ->
                      Ok
                        (Some
                           {
                             generation_head =
                               event_id_of_verified generation_head.verified;
                             activation = current;
                           })
                  | None | Some _ ->
                      Error
                        (Generation_active_anchor_not_reachable
                           {
                             event_id = current.generation_event_id;
                             expected = current.manifest.Retention.active_anchor;
                             actual;
                           }))
              | [] | _ ->
                  Error
                    (Generation_active_anchor_not_reachable
                       {
                         event_id = current.generation_event_id;
                         expected = current.manifest.Retention.active_anchor;
                         actual;
                       })))
      | heads -> Error (Divergent_generation_heads (event_ids heads)))

let active_scratch_ref repository =
  let* generation = resolved_active_generation repository in
  match generation with
  | None -> Ok repository.scratch_ref
  | Some generation -> Ok generation.activation.manifest.Retention.active_ref

let active_scratch_ref_name repository = active_scratch_ref repository

let history_for_scope repository ~scope_ref =
  let* scoped_events = verified_events_for_ref repository ~ref_name:scope_ref in
  let rec validate reversed = function
    | [] -> Ok (List.rev reversed)
    | scoped :: rest ->
        let* checkpoint = checkpoint_of_verified repository scoped.verified in
        let retention_checkpoint : Retention.checkpoint =
          {
            Retention.event_id = checkpoint.event_id;
            event_object_ref = scoped.object_ref;
            checkpoint_snapshot_ref = checkpoint.snapshot_ref;
          }
        in
        validate ({ retention_checkpoint } :: reversed) rest
  in
  let* validated = validate [] scoped_events in
  match validated with
  | [] -> Error (Retention_error Retention.Empty_history)
  | _ -> (
      let* evaluated =
        evaluate_scope repository ~ref_name:scope_ref scoped_events
      in
      let heads = Ledger.heads evaluated in
      let actual = event_ids heads in
      match heads with
      | [] -> Error (Retention_error Retention.Empty_history)
      | head :: [] ->
          let rec collect reversed event =
            let event_id = event_id_of_verified event.verified in
            let* checkpoint =
              match
                List.find_opt
                  (fun candidate ->
                    Ledger.Event_id.equal
                      candidate.retention_checkpoint.Retention.event_id event_id)
                  validated
              with
              | Some checkpoint -> Ok checkpoint
              | None -> Error (Missing_evaluated_checkpoint event_id)
            in
            let ledger_event = Ledger.verified_event event.verified in
            match
              Ledger.event_unsigned ledger_event |> Ledger.unsigned_predecessor
            with
            | None -> Ok (checkpoint :: reversed, event_id_of_verified head)
            | Some predecessor -> (
                match find_scoped_event scoped_events predecessor with
                | Some predecessor ->
                    collect (checkpoint :: reversed) predecessor
                | None -> Error (Missing_evaluated_checkpoint event_id))
          in
          let* scoped_head =
            match
              find_scoped_event scoped_events (event_id_of_verified head)
            with
            | Some scoped -> Ok scoped
            | None ->
                Error (Missing_evaluated_checkpoint (event_id_of_verified head))
          in
          collect [] scoped_head
      | _ -> Error (Divergent_scratch_heads actual))

let protection_of_event repository (event : scoped_event) =
  let ledger_event = Ledger.verified_event event.verified in
  let event_id = Ledger.event_id ledger_event in
  let* object_ref =
    match Ledger.event_unsigned ledger_event |> Ledger.unsigned_target with
    | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
    | None -> Error (Protection_event_missing_target event_id)
  in
  let* object_ =
    Object_store.load repository.objects ~object_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.protection object_ with
  | Some protection -> Ok protection
  | None -> Error (Protection_target_not_claim { event_id; object_ref })

let protection_state repository =
  let* events =
    verified_events_for_ref repository ~ref_name:repository.protection_ref
  in
  match events with
  | [] -> Ok (None, [])
  | _ -> (
      let rec validate reversed = function
        | [] -> Ok (List.rev reversed)
        | event :: rest ->
            let* protection = protection_of_event repository event in
            validate ((event, protection) :: reversed) rest
      in
      let* validated = validate [] events in
      let* evaluated =
        evaluate_scope repository ~ref_name:repository.protection_ref events
      in
      match Ledger.heads evaluated with
      | [] -> Ok (None, [])
      | [ head ] ->
          let rec collect reversed event =
            let event_id = event_id_of_verified event.verified in
            let* protection =
              match
                List.find_opt
                  (fun (candidate, _) ->
                    Ledger.Event_id.equal
                      (event_id_of_verified candidate.verified)
                      event_id)
                  validated
              with
              | Some (_, protection) -> Ok protection
              | None -> Error (Missing_evaluated_protection event_id)
            in
            let ledger_event = Ledger.verified_event event.verified in
            match
              Ledger.event_unsigned ledger_event |> Ledger.unsigned_predecessor
            with
            | None ->
                Ok (Some (event_id_of_verified head), protection :: reversed)
            | Some predecessor -> (
                match find_scoped_event events predecessor with
                | Some predecessor ->
                    collect (protection :: reversed) predecessor
                | None -> Error (Missing_evaluated_protection event_id))
          in
          let* scoped_head =
            match find_scoped_event events (event_id_of_verified head) with
            | Some scoped -> Ok scoped
            | None ->
                Error (Missing_evaluated_protection (event_id_of_verified head))
          in
          collect [] scoped_head
      | heads -> Error (Divergent_protection_heads (event_ids heads)))

let inspect_scope repository ~scope_ref =
  let* scoped_events = verified_events_for_ref repository ~ref_name:scope_ref in
  let rec checkpoints result = function
    | [] -> Ok (List.rev result)
    | event :: rest ->
        let* checkpoint = checkpoint_of_verified repository event.verified in
        checkpoints ({ validated_checkpoint = checkpoint } :: result) rest
  in
  let* events = checkpoints [] scoped_events in
  match events with
  | [] -> Ok No_checkpoint
  | _ -> (
      let* heads =
        evaluate_scope repository ~ref_name:scope_ref scoped_events
      in
      let head_events = Ledger.heads heads in
      let find_checkpoint verified =
        let event_id = Ledger.verified_event verified |> Ledger.event_id in
        List.find_opt
          (fun event ->
            Ledger.Event_id.equal event.validated_checkpoint.event_id event_id)
          events
      in
      match head_events with
      | [] -> Ok No_checkpoint
      | [ verified ] -> (
          match find_checkpoint verified with
          | Some event -> Ok (Checkpoint event.validated_checkpoint)
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

let inspect_active repository =
  let* scope_ref = active_scratch_ref repository in
  let* scope_inspection = inspect_scope repository ~scope_ref in
  Ok { scope_ref; scope_inspection }

let inspect repository =
  let* inspection = inspect_active repository in
  Ok inspection.scope_inspection

let checkpoint_for_event repository ~event_id =
  let* active_ref = active_scratch_ref repository in
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
            if not (Ledger.Ref_name.equal ref_name active_ref) then
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
    let* active = inspect_active repository in
    match active.scope_inspection with
    | Divergent_checkpoints event_ids ->
        Error (Divergent_scratch_heads event_ids)
    | No_checkpoint | Checkpoint _ -> (
        let prior_checkpoint =
          match active.scope_inspection with
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
                ~ref_name:active.scope_ref
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

let ledger_candidate repository ~ref_name ~predecessor ~target ~nonce =
  let capability = Bootstrap_store.capability repository.bootstrap in
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  let* unsigned =
    Ledger.make_unsigned
      ~repository_id:(Bootstrap.repository_id record)
      ~ref_name
      ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
      ~predecessor
      ~target:(Some (Ledger.Ref_target.of_opaque_object_ref target))
      ~mandatory_features:0L
    |> Result.map_error (fun error -> Ledger_error error)
  in
  let signature = Bootstrap.sign_ledger capability unsigned in
  let* event =
    Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature
    |> Result.map_error (fun error -> Ledger_error error)
  in
  let* envelope =
    Envelope.seal
      ~key:(Bootstrap.envelope_key capability)
      ~nonce ~mandatory_features:0L
      (Object.ledger_event event |> Object.encode)
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Ok (Ledger.event_id event, envelope)

let object_sizes_for_history repository history =
  let refs =
    history
    |> List.map (fun entry ->
        [
          entry.retention_checkpoint.Retention.event_object_ref;
          entry.retention_checkpoint.Retention.checkpoint_snapshot_ref;
        ])
    |> List.flatten
    |> List.sort_uniq V2_model.Opaque_object_ref.compare
  in
  let rec measure reversed = function
    | [] -> Ok (List.rev reversed)
    | sized_object_ref :: rest ->
        let* stored_bytes =
          Object_store.stored_bytes repository.objects
            ~object_ref:sized_object_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        measure ({ Retention.sized_object_ref; stored_bytes } :: reversed) rest
  in
  measure [] refs

let externally_referenced_targets repository ~retired_refs =
  let* object_refs =
    Ledger_store.list_object_refs repository.ledger
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let retired ref_name =
    List.exists
      (fun candidate -> Ledger.Ref_name.equal candidate ref_name)
      retired_refs
  in
  let rec collect reversed = function
    | [] -> Ok (List.sort_uniq V2_model.Opaque_object_ref.compare reversed)
    | object_ref :: rest -> (
        let* object_ =
          Ledger_store.load_object repository.ledger ~object_ref
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        match Object.ledger object_ with
        | None -> collect reversed rest
        | Some event ->
            let ref_name =
              Ledger.event_unsigned event |> Ledger.unsigned_ref_name
            in
            if retired ref_name then collect reversed rest
            else
              let* verified =
                Ledger_store.load repository.ledger ~object_ref
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              let target =
                Ledger.verified_event verified
                |> Ledger.event_unsigned |> Ledger.unsigned_target
                |> Option.map Ledger.Ref_target.to_opaque_object_ref
              in
              let reversed =
                match target with
                | None -> reversed
                | Some target -> target :: reversed
              in
              collect reversed rest)
  in
  collect [] object_refs

let nonce_bytes nonces = List.map Envelope.nonce_to_bytes nonces

let compaction_nonces_are_distinct nonces =
  let all =
    nonces.compact_ledger_nonces
    @ [ nonces.generation_manifest_nonce; nonces.generation_ledger_nonce ]
    |> nonce_bytes
  in
  List.length all = List.length (List.sort_uniq String.compare all)

let plan_compaction repository ~policy ~nonces =
  let* active_generation = resolved_active_generation repository in
  let source_ref, source_generation_head, older_retired_refs =
    match active_generation with
    | None -> (repository.scratch_ref, None, [])
    | Some active ->
        ( active.activation.manifest.Retention.active_ref,
          Some active.generation_head,
          active.activation.manifest.Retention.retired_refs )
  in
  let* history, source_head =
    history_for_scope repository ~scope_ref:source_ref
  in
  if not (compaction_nonces_are_distinct nonces) then
    Error Compaction_nonce_reuse
  else
    let* source_protection_head, claims = protection_state repository in
    let* object_sizes = object_sizes_for_history repository history in
    let retention_history =
      List.map (fun entry -> entry.retention_checkpoint) history
    in
    let* retention =
      Retention.select ~policy ~claims ~history:retention_history ~object_sizes
      |> Result.map_error (fun error -> Retention_error error)
    in
    let retained =
      List.map
        (fun planned -> planned.Retention.checkpoint)
        retention.Retention.retained
    in
    let expected_nonces = List.length retained in
    let actual_nonces = List.length nonces.compact_ledger_nonces in
    if expected_nonces <> actual_nonces then
      Error
        (Invalid_compaction_nonce_count
           { expected = expected_nonces; actual = actual_nonces })
    else
      let* active_ref = compact_ref_name repository ~source_head in
      let rec compact reversed predecessor checkpoints event_nonces =
        match (checkpoints, event_nonces) with
        | [], [] -> Ok (List.rev reversed)
        | checkpoint :: checkpoints, nonce :: event_nonces ->
            let* event_id, ledger_envelope =
              ledger_candidate repository ~ref_name:active_ref ~predecessor
                ~target:checkpoint.Retention.checkpoint_snapshot_ref ~nonce
            in
            let compacted =
              {
                source_checkpoint = checkpoint;
                compacted_event_id = event_id;
                ledger_envelope;
              }
            in
            compact (compacted :: reversed) (Some event_id) checkpoints
              event_nonces
        | [], _ :: _ | _ :: _, [] -> assert false
      in
      let* compacted_events =
        compact [] None retained nonces.compact_ledger_nonces
      in
      let active_anchor =
        match List.rev compacted_events with
        | event :: _ -> event.compacted_event_id
        | [] -> assert false
      in
      let retired_refs = source_ref :: older_retired_refs in
      let* externally_referenced =
        externally_referenced_targets repository ~retired_refs
      in
      let externally_referenced =
        Retention.effective_protected_snapshots claims @ externally_referenced
        |> List.sort_uniq V2_model.Opaque_object_ref.compare
      in
      let* cleanup_candidates =
        Retention.cleanup_candidates ~history:retention_history ~retained
          ~externally_referenced
        |> Result.map_error (fun error -> Retention_error error)
      in
      let* generation =
        Retention.make_generation ~source_ref ~source_head ~active_ref
          ~active_anchor ~retired_refs ~cleanup_candidates
        |> Result.map_error (fun error -> Retention_error error)
      in
      let capability = Bootstrap_store.capability repository.bootstrap in
      let record = Bootstrap_store.bootstrap repository.bootstrap in
      let* generation_envelope =
        Envelope.seal
          ~key:(Bootstrap.envelope_key capability)
          ~nonce:nonces.generation_manifest_nonce ~mandatory_features:0L
          (Object.scratch_generation generation |> Object.encode)
        |> Result.map_error (fun error -> Envelope_error error)
      in
      let generation_object_ref =
        Address.derive
          ~repository_id:(Bootstrap.repository_id record)
          ~key:(Bootstrap.address_key capability)
          ~envelope:generation_envelope
      in
      let* activation_event_id, activation_envelope =
        ledger_candidate repository ~ref_name:repository.generation_ref
          ~predecessor:source_generation_head ~target:generation_object_ref
          ~nonce:nonces.generation_ledger_nonce
      in
      let plan : compaction_plan =
        {
          source_ref;
          source_head;
          source_generation_head;
          source_protection_head;
          compaction_retention = retention;
          compacted_events;
          compaction_generation_manifest = generation;
          generation_object_ref;
          generation_envelope;
          activation_event_id;
          activation_envelope;
        }
      in
      Ok plan

let option_event_id_equal left right =
  match (left, right) with
  | None, None -> true
  | Some left, Some right -> Ledger.Event_id.equal left right
  | None, Some _ | Some _, None -> false

let revalidate_compaction_source repository (plan : compaction_plan) =
  let* active_generation = resolved_active_generation repository in
  let actual_ref, actual_generation_head =
    match active_generation with
    | None -> (repository.scratch_ref, None)
    | Some active ->
        ( active.activation.manifest.Retention.active_ref,
          Some active.generation_head )
  in
  if not (Ledger.Ref_name.equal plan.source_ref actual_ref) then
    Error
      (Compaction_source_not_active
         { expected = plan.source_ref; actual = actual_ref })
  else if
    not
      (option_event_id_equal plan.source_generation_head actual_generation_head)
  then
    Error
      (Compaction_generation_head_changed
         {
           expected = plan.source_generation_head;
           actual = actual_generation_head;
         })
  else
    let* _, actual_head =
      history_for_scope repository ~scope_ref:plan.source_ref
    in
    if not (Ledger.Event_id.equal plan.source_head actual_head) then
      Error
        (Compaction_source_head_changed
           { expected = plan.source_head; actual = actual_head })
    else
      let* actual_protection_head, _ = protection_state repository in
      if
        not
          (option_event_id_equal plan.source_protection_head
             actual_protection_head)
      then
        Error
          (Compaction_protection_head_changed
             {
               expected = plan.source_protection_head;
               actual = actual_protection_head;
             })
      else Ok ()

let publish_compaction_plan repository (plan : compaction_plan) =
  let rec publish_compacted = function
    | [] -> Ok ()
    | compacted :: rest ->
        let* publication =
          Ledger_store.publish repository.ledger
            ~envelope:compacted.ledger_envelope
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        let event_id =
          match publication with
          | Ledger_store.Published { event_id; _ }
          | Ledger_store.Already_published { event_id; _ } ->
              event_id
        in
        if not (Ledger.Event_id.equal compacted.compacted_event_id event_id)
        then assert false
        else publish_compacted rest
  in
  let* () = publish_compacted plan.compacted_events in
  let* generation_object_ref =
    Object_store.publish repository.objects ~envelope:plan.generation_envelope
    |> Result.map publication_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  if
    not
      (V2_model.Opaque_object_ref.equal generation_object_ref
         plan.generation_object_ref)
  then assert false
  else
    let* () = revalidate_compaction_source repository plan in
    let* publication =
      Ledger_store.publish repository.ledger ~envelope:plan.activation_envelope
      |> Result.map_error (fun error -> Ledger_store_error error)
    in
    let generation_event_id =
      match publication with
      | Ledger_store.Published { event_id; _ }
      | Ledger_store.Already_published { event_id; _ } ->
          event_id
    in
    if not (Ledger.Event_id.equal generation_event_id plan.activation_event_id)
    then assert false
    else
      let publication : compaction_publication =
        {
          published_generation_event_id = generation_event_id;
          published_generation_manifest = plan.compaction_generation_manifest;
          published_retention = plan.compaction_retention;
        }
      in
      Ok publication
