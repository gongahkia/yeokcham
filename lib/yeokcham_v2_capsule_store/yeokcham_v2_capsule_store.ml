module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Retention = Yeokcham_v2_retention
module Scratch_store = Yeokcham_v2_scratch_store
module V2_model = Yeokcham_v2_model

type repository = {
  bootstrap : Bootstrap_store.repository;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  scratch : Scratch_store.repository;
}

type nonces = {
  capsule_nonce : Envelope.nonce;
  selected_result_nonce : Envelope.nonce;
  revision_nonce : Envelope.nonce;
  source_protection_nonce : Envelope.nonce;
  source_protection_ledger_nonce : Envelope.nonce;
  target_protection_nonce : Envelope.nonce;
  target_protection_ledger_nonce : Envelope.nonce;
  binding_ledger_nonce : Envelope.nonce;
}

type revision_nonces = {
  fold_selected_result_nonce : Envelope.nonce;
  fold_revision_nonce : Envelope.nonce;
  fold_source_protection_nonce : Envelope.nonce;
  fold_source_protection_ledger_nonce : Envelope.nonce;
  fold_target_protection_nonce : Envelope.nonce;
  fold_target_protection_ledger_nonce : Envelope.nonce;
  fold_binding_ledger_nonce : Envelope.nonce;
}

module Fault = struct
  type boundary =
    | After_capsule_object
    | After_selected_result_object
    | After_revision_object
    | After_source_protection
    | After_target_protection
    | Before_binding

  type t = boundary

  let at boundary = boundary
end

type resolved = {
  capsule : Capsule.capsule;
  capsule_ref : V2_model.Opaque_object_ref.t;
  revision : Capsule.revision;
  revision_ref : V2_model.Opaque_object_ref.t;
  binding_event_id : Ledger.Event_id.t;
  declared_base : Model.Snapshot.t;
  expected_result : Model.Snapshot.t;
}

type publication = Published of resolved | Already_published of resolved
type split_plan = { split_source : resolved; split : Capsule.split_plan }

type combine_plan = {
  combine_sources : resolved list;
  combine : Capsule.combine_plan;
}

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Capsule_error of Capsule.error
  | Capsule_proposal_error of Capsule.proposal_error
  | Capsule_selection_error of Capsule.selection_error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Ledger_store.error
  | Object_store_error of Object_store.error
  | Scratch_store_error of Scratch_store.error
  | Invalid_capsule_ref_name of string
  | Nonce_reuse
  | Capsule_id_already_bound of V2_model.Capsule_id.t
  | Capsule_missing of V2_model.Capsule_id.t
  | Capsule_split_error of Capsule.split_error
  | Capsule_combine_error of Capsule.combine_error
  | Divergent_capsule_binding of Ledger.Event_id.t list
  | Capsule_binding_missing_target of Ledger.Event_id.t
  | Capsule_binding_target_mismatch of {
      capsule : V2_model.Capsule_id.t;
      expected : V2_model.Opaque_object_ref.t;
      actual : V2_model.Opaque_object_ref.t;
    }
  | Binding_target_not_revision of V2_model.Opaque_object_ref.t
  | Revision_capsule_mismatch of {
      expected : V2_model.Capsule_id.t;
      actual : V2_model.Capsule_id.t;
    }
  | Revision_capsule_ref_mismatch of {
      expected : V2_model.Opaque_object_ref.t;
      actual : V2_model.Opaque_object_ref.t;
    }
  | Capsule_ref_not_capsule of V2_model.Opaque_object_ref.t
  | Capsule_metadata_mismatch
  | Snapshot_ref_not_snapshot of V2_model.Opaque_object_ref.t
  | Snapshot_identity_mismatch of V2_model.Opaque_object_ref.t
  | Revision_replay_rejected of Model.replay_error
  | Revision_result_mismatch
  | Concurrent_current_update of {
      expected_revision : V2_model.Capsule_revision_id.t;
      expected_binding : Ledger.Event_id.t;
      actual_revision : V2_model.Capsule_revision_id.t option;
      actual_binding : Ledger.Event_id.t option;
    }
  | Parent_link_mismatch of string
  | Revision_history_cycle of V2_model.Opaque_object_ref.t
  | Fault_injected of Fault.boundary

let ( let* ) = Result.bind

let error_to_string = function
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Capsule_error error -> Capsule.error_to_string error
  | Capsule_proposal_error error -> Capsule.proposal_error_to_string error
  | Capsule_selection_error error -> Capsule.selection_error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Ledger_error error -> Ledger.error_to_string error
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error
  | Invalid_capsule_ref_name name -> "invalid capsule ref name: " ^ name
  | Nonce_reuse -> "capsule creation requires pairwise distinct envelope nonces"
  | Capsule_id_already_bound id ->
      "capsule already has a current binding: " ^ V2_model.Capsule_id.to_hex id
  | Capsule_missing id ->
      "capsule has no current binding: " ^ V2_model.Capsule_id.to_hex id
  | Capsule_split_error error -> Capsule.split_error_to_string error
  | Capsule_combine_error error -> Capsule.combine_error_to_string error
  | Divergent_capsule_binding events ->
      "capsule binding has divergent causal heads: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex events)
  | Capsule_binding_missing_target event ->
      "capsule binding has no revision target: " ^ Ledger.Event_id.to_hex event
  | Capsule_binding_target_mismatch { capsule; expected; actual } ->
      Printf.sprintf "capsule %s is already bound to %s, not %s"
        (V2_model.Capsule_id.to_hex capsule)
        (V2_model.Opaque_object_ref.to_hex actual)
        (V2_model.Opaque_object_ref.to_hex expected)
  | Binding_target_not_revision reference ->
      "capsule binding targets a non-revision object: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Revision_capsule_mismatch { expected; actual } ->
      Printf.sprintf "capsule revision belongs to %s, expected %s"
        (V2_model.Capsule_id.to_hex actual)
        (V2_model.Capsule_id.to_hex expected)
  | Revision_capsule_ref_mismatch { expected; actual } ->
      Printf.sprintf "capsule revision names capsule object %s, expected %s"
        (V2_model.Opaque_object_ref.to_hex actual)
        (V2_model.Opaque_object_ref.to_hex expected)
  | Capsule_ref_not_capsule reference ->
      "capsule object reference is not a capsule frame: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Capsule_metadata_mismatch -> "capsule metadata does not match its revision"
  | Snapshot_ref_not_snapshot reference ->
      "capsule snapshot link is not an exact snapshot: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Snapshot_identity_mismatch reference ->
      "capsule snapshot link logical identity mismatches: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Revision_replay_rejected error ->
      "capsule revision replay rejected: " ^ Model.replay_error_to_string error
  | Revision_result_mismatch ->
      "capsule revision replay does not reach its declared exact result"
  | Concurrent_current_update
      { expected_revision; expected_binding; actual_revision; actual_binding }
    ->
      let revision = function
        | None -> "none"
        | Some id -> V2_model.Capsule_revision_id.to_hex id
      in
      let binding = function
        | None -> "none"
        | Some id -> Ledger.Event_id.to_hex id
      in
      Printf.sprintf
        "capsule current changed from revision %s at binding %s to revision %s \
         at binding %s"
        (V2_model.Capsule_revision_id.to_hex expected_revision)
        (Ledger.Event_id.to_hex expected_binding)
        (revision actual_revision) (binding actual_binding)
  | Parent_link_mismatch detail ->
      "capsule revision parent link mismatch: " ^ detail
  | Revision_history_cycle reference ->
      "capsule revision history contains object cycle: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Fault_injected boundary ->
      let name =
        match boundary with
        | Fault.After_capsule_object -> "after capsule object"
        | Fault.After_selected_result_object -> "after selected result object"
        | Fault.After_revision_object -> "after revision object"
        | Fault.After_source_protection -> "after source protection"
        | Fault.After_target_protection -> "after target protection"
        | Fault.Before_binding -> "before capsule binding"
      in
      "injected capsule creation interruption " ^ name

let open_repository ~root ~bootstrap_repository =
  let record = Bootstrap_store.bootstrap bootstrap_repository in
  let capability = Bootstrap_store.capability bootstrap_repository in
  let* objects =
    Object_store.open_repository ~root
      ~repository_id:(Bootstrap.repository_id record)
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* public_keys =
    Bootstrap.public_key_registry capability
    |> Result.map_error (fun error ->
        Bootstrap_store_error (Bootstrap_store.Bootstrap_error error))
  in
  let* ledger =
    Ledger_store.open_repository ~root
      ~repository_id:(Bootstrap.repository_id record)
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
      ~public_keys
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  Ok { bootstrap = bootstrap_repository; objects; ledger; scratch }

let capsule_ref_name id =
  let name = "capsule-" ^ V2_model.Capsule_id.to_hex id in
  Ledger.Ref_name.of_string name
  |> Result.map_error (fun _ -> Invalid_capsule_ref_name name)

let distinct_nonces nonces =
  let values =
    [
      nonces.capsule_nonce;
      nonces.selected_result_nonce;
      nonces.revision_nonce;
      nonces.source_protection_nonce;
      nonces.source_protection_ledger_nonce;
      nonces.target_protection_nonce;
      nonces.target_protection_ledger_nonce;
      nonces.binding_ledger_nonce;
    ]
    |> List.map Envelope.nonce_to_bytes
  in
  List.length values = List.length (List.sort_uniq String.compare values)

let distinct_revision_nonces (nonces : revision_nonces) =
  let values =
    [
      nonces.fold_selected_result_nonce;
      nonces.fold_revision_nonce;
      nonces.fold_source_protection_nonce;
      nonces.fold_source_protection_ledger_nonce;
      nonces.fold_target_protection_nonce;
      nonces.fold_target_protection_ledger_nonce;
      nonces.fold_binding_ledger_nonce;
    ]
    |> List.map Envelope.nonce_to_bytes
  in
  List.length values = List.length (List.sort_uniq String.compare values)

let event_id_of_verified verified =
  Ledger.verified_event verified |> Ledger.event_id

let scoped_events repository ref_name =
  let* references =
    Ledger_store.list_object_refs repository.ledger
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | reference :: rest -> (
        let* object_ =
          Ledger_store.load_object repository.ledger ~object_ref:reference
          |> Result.map_error (fun error -> Ledger_store_error error)
        in
        match Object.ledger object_ with
        | None -> collect reversed rest
        | Some event ->
            let event_ref =
              Ledger.event_unsigned event |> Ledger.unsigned_ref_name
            in
            if Ledger.Ref_name.equal event_ref ref_name then
              let* verified =
                Ledger_store.load repository.ledger ~object_ref:reference
                |> Result.map_error (fun error -> Ledger_store_error error)
              in
              collect (verified :: reversed) rest
            else collect reversed rest)
  in
  collect [] references

let binding_head repository id =
  let* ref_name = capsule_ref_name id in
  let* events = scoped_events repository ref_name in
  match events with
  | [] -> Ok None
  | _ -> (
      let* heads =
        Ledger.evaluate
          ~repository_id:(Ledger_store.repository_id repository.ledger)
          ~ref_name events
        |> Result.map_error (fun error -> Ledger_error error)
      in
      match Ledger.heads heads with
      | [] -> Ok None
      | [ head ] -> Ok (Some head)
      | heads ->
          Error
            (Divergent_capsule_binding
               (List.map event_id_of_verified heads
               |> List.sort Ledger.Event_id.compare)))

let target_of_binding verified =
  let event = Ledger.verified_event verified in
  match Ledger.event_unsigned event |> Ledger.unsigned_target with
  | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
  | None -> Error (Capsule_binding_missing_target (Ledger.event_id event))

let snapshot_for_link repository (link : Capsule.snapshot_link) =
  let* object_ =
    Object_store.load repository.objects ~object_ref:link.Capsule.snapshot_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.snapshot object_ with
  | None -> Error (Snapshot_ref_not_snapshot link.Capsule.snapshot_ref)
  | Some snapshot ->
      if
        Yeokcham_id.Snapshot_id.equal link.Capsule.snapshot_id
          (Model.Snapshot.id snapshot)
      then Ok snapshot
      else Error (Snapshot_identity_mismatch link.Capsule.snapshot_ref)

let rec verify_parent_chain repository ~visited revision =
  match Capsule.revision_parent revision with
  | None -> Ok ()
  | Some parent ->
      let parent_ref = Capsule.revision_link_ref parent in
      if List.exists (V2_model.Opaque_object_ref.equal parent_ref) visited then
        Error (Revision_history_cycle parent_ref)
      else if
        not
          (V2_model.Capsule_id.equal
             (Capsule.revision_capsule_id revision)
             (Capsule.revision_link_capsule_id parent))
      then Error (Parent_link_mismatch "parent names another capsule")
      else
        let* object_ =
          Object_store.load repository.objects ~object_ref:parent_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        let* parent_revision =
          match Object.capsule_revision_record object_ with
          | Some revision -> Ok revision
          | None ->
              Error (Parent_link_mismatch "parent object is not a revision")
        in
        if
          not
            (V2_model.Capsule_revision_id.equal
               (Capsule.revision_link_revision_id parent)
               (Capsule.revision_id parent_revision))
        then Error (Parent_link_mismatch "parent logical identity differs")
        else if
          not
            (V2_model.Capsule_id.equal
               (Capsule.revision_link_capsule_id parent)
               (Capsule.revision_capsule_id parent_revision))
        then Error (Parent_link_mismatch "parent capsule identity differs")
        else
          verify_parent_chain repository ~visited:(parent_ref :: visited)
            parent_revision

let resolve repository ~id =
  let* head = binding_head repository id in
  match head with
  | None -> Ok None
  | Some verified ->
      let binding_event_id = event_id_of_verified verified in
      let* revision_ref = target_of_binding verified in
      let* revision_object =
        Object_store.load repository.objects ~object_ref:revision_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      let* revision =
        match Object.capsule_revision_record revision_object with
        | Some revision -> Ok revision
        | None -> Error (Binding_target_not_revision revision_ref)
      in
      let actual_id = Capsule.revision_capsule_id revision in
      if not (V2_model.Capsule_id.equal id actual_id) then
        Error (Revision_capsule_mismatch { expected = id; actual = actual_id })
      else
        let capsule_ref = Capsule.revision_capsule_ref revision in
        let* capsule_object =
          Object_store.load repository.objects ~object_ref:capsule_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        let* capsule =
          match Object.capsule_record capsule_object with
          | Some capsule -> Ok capsule
          | None -> Error (Capsule_ref_not_capsule capsule_ref)
        in
        if not (V2_model.Capsule_id.equal id (Capsule.capsule_id capsule)) then
          Error Capsule_metadata_mismatch
        else
          let* declared_base =
            snapshot_for_link repository
              (Capsule.revision_declared_base revision)
          in
          let* expected_result =
            snapshot_for_link repository
              (Capsule.revision_expected_result revision)
          in
          let boundary = Capsule.revision_source_boundary revision in
          let* boundary_source =
            snapshot_for_link repository boundary.Capsule.source_snapshot
          in
          let* _boundary_target =
            snapshot_for_link repository boundary.Capsule.target_snapshot
          in
          if not (Model.Snapshot.equal declared_base boundary_source) then
            Error Revision_result_mismatch
          else
            let* actual =
              Capsule.apply_revision ~base:declared_base revision
              |> Result.map_error (fun error -> Revision_replay_rejected error)
            in
            if not (Model.Snapshot.equal actual expected_result) then
              Error Revision_result_mismatch
            else
              let* () =
                verify_parent_chain repository ~visited:[ revision_ref ]
                  revision
              in
              Ok
                (Some
                   {
                     capsule;
                     capsule_ref;
                     revision;
                     revision_ref;
                     binding_event_id;
                     declared_base;
                     expected_result;
                   })

let plan_split repository ~source ~left_indices =
  let* resolved = resolve repository ~id:source in
  let* source =
    match resolved with
    | Some resolved -> Ok resolved
    | None -> Error (Capsule_missing source)
  in
  let* split =
    Capsule.plan_split ~base:source.declared_base source.revision ~left_indices
    |> Result.map_error (fun error -> Capsule_split_error error)
  in
  Ok { split_source = source; split }

let split_plan_source plan = plan.split_source
let split_plan_left_indices plan = Capsule.split_plan_left_indices plan.split
let split_plan_left_result plan = Capsule.split_plan_left_result plan.split

let split_plan_right_operations plan =
  Capsule.split_plan_right_operations plan.split

let plan_combine repository ~sources =
  let rec resolve_sources reversed = function
    | [] -> Ok (List.rev reversed)
    | id :: rest ->
        let* resolved = resolve repository ~id in
        let* resolved =
          match resolved with
          | Some resolved -> Ok resolved
          | None -> Error (Capsule_missing id)
        in
        resolve_sources (resolved :: reversed) rest
  in
  let* sources = resolve_sources [] sources in
  match sources with
  | [] -> Error (Capsule_combine_error Capsule.Empty_combine)
  | first :: _ ->
      let* combine =
        Capsule.plan_combine ~base:first.declared_base
          (List.map (fun source -> source.revision) sources)
        |> Result.map_error (fun error -> Capsule_combine_error error)
      in
      Ok { combine_sources = sources; combine }

let combine_plan_sources plan = plan.combine_sources
let combine_plan_result plan = Capsule.combine_plan_result plan.combine
let combine_plan_operations plan = Capsule.combine_plan_operations plan.combine

let envelope_for repository ~nonce object_ =
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  let capability = Bootstrap_store.capability repository.bootstrap in
  let* envelope =
    Envelope.seal
      ~key:(Bootstrap.envelope_key capability)
      ~nonce ~mandatory_features:0L (Object.encode object_)
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let reference =
    Address.derive
      ~repository_id:(Bootstrap.repository_id record)
      ~key:(Bootstrap.address_key capability)
      ~envelope
  in
  Ok (reference, envelope)

let publish_object repository ~expected envelope =
  let* actual =
    Object_store.publish repository.objects ~envelope
    |> Result.map_error (fun error -> Object_store_error error)
    |> Result.map (function
        | Object_store.Published reference
        | Object_store.Already_published reference
        -> reference)
  in
  if V2_model.Opaque_object_ref.equal expected actual then Ok ()
  else assert false

let inject fault boundary =
  match fault with
  | Some actual when actual = boundary -> Error (Fault_injected boundary)
  | None | Some _ -> Ok ()

let binding_envelope repository ~id ~predecessor ~revision_ref ~nonce =
  let* ref_name = capsule_ref_name id in
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  let capability = Bootstrap_store.capability repository.bootstrap in
  let* unsigned =
    Ledger.make_unsigned
      ~repository_id:(Bootstrap.repository_id record)
      ~ref_name
      ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
      ~predecessor
      ~target:(Some (Ledger.Ref_target.of_opaque_object_ref revision_ref))
      ~mandatory_features:0L
    |> Result.map_error (fun error -> Ledger_error error)
  in
  let* event =
    Ledger.make ~unsigned ~algorithm:Ledger.algorithm
      ~signature:(Bootstrap.sign_ledger capability unsigned)
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

let create ?fault repository ~id ~title ~description ~created_at ~source_event
    ~target_event ~selected_indices ~nonces =
  if not (distinct_nonces nonces) then Error Nonce_reuse
  else
    let* () =
      Scratch_store.require_ancestor repository.scratch ~source:source_event
        ~target:target_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    let* source =
      Scratch_store.checkpoint_for_event repository.scratch
        ~event_id:source_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    let* target =
      Scratch_store.checkpoint_for_event repository.scratch
        ~event_id:target_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    let* proposal =
      Capsule.propose ~from:source.Scratch_store.snapshot
        ~to_:target.Scratch_store.snapshot
      |> Result.map_error (fun error -> Capsule_proposal_error error)
    in
    let* selected =
      Capsule.select proposal ~indices:selected_indices
      |> Result.map_error (fun error -> Capsule_selection_error error)
    in
    let* capsule =
      Capsule.make_capsule ~id ~title ~description ~created_at
      |> Result.map_error (fun error -> Capsule_error error)
    in
    let* capsule_ref, capsule_envelope =
      envelope_for repository ~nonce:nonces.capsule_nonce
        (Object.capsule capsule)
    in
    let selected_result = Capsule.selected_result selected in
    let target_link : Capsule.snapshot_link =
      {
        Capsule.snapshot_id = Model.Snapshot.id target.Scratch_store.snapshot;
        snapshot_ref = target.Scratch_store.snapshot_ref;
      }
    in
    let* expected_result, selected_result_envelope =
      if Model.Snapshot.equal selected_result target.Scratch_store.snapshot then
        Ok (target_link, None)
      else
        let* reference, envelope =
          envelope_for repository ~nonce:nonces.selected_result_nonce
            (Object.scratch_snapshot selected_result)
        in
        Ok
          ( {
              Capsule.snapshot_id = Model.Snapshot.id selected_result;
              snapshot_ref = reference;
            },
            Some envelope )
    in
    let declared_base : Capsule.snapshot_link =
      {
        Capsule.snapshot_id = Model.Snapshot.id source.Scratch_store.snapshot;
        snapshot_ref = source.Scratch_store.snapshot_ref;
      }
    in
    let boundary : Capsule.source_boundary =
      { Capsule.source_snapshot = declared_base; target_snapshot = target_link }
    in
    let* revision =
      Capsule.make_initial_revision ~capsule ~capsule_ref ~declared_base
        ~declared_base_snapshot:source.Scratch_store.snapshot ~expected_result
        ~selected ~source_boundary:boundary
      |> Result.map_error (fun error -> Capsule_error error)
    in
    let* revision_ref, revision_envelope =
      envelope_for repository ~nonce:nonces.revision_nonce
        (Object.capsule_revision revision)
    in
    let* prior = resolve repository ~id in
    match prior with
    | Some resolved ->
        if V2_model.Opaque_object_ref.equal resolved.revision_ref revision_ref
        then Ok (Already_published resolved)
        else Error (Capsule_id_already_bound id)
    | None -> (
        let* () =
          publish_object repository ~expected:capsule_ref capsule_envelope
        in
        let* () = inject fault Fault.After_capsule_object in
        let* () =
          match selected_result_envelope with
          | None -> Ok ()
          | Some envelope ->
              publish_object repository
                ~expected:expected_result.Capsule.snapshot_ref envelope
        in
        let* () = inject fault Fault.After_selected_result_object in
        let* () =
          publish_object repository ~expected:revision_ref revision_envelope
        in
        let* () = inject fault Fault.After_revision_object in
        let reason = Retention.Capsule_boundary revision_ref in
        let* source_protection =
          Scratch_store.plan_protection repository.scratch
            ~event_id:source_event ~action:Retention.Protect ~reason
            ~protection_nonce:nonces.source_protection_nonce
            ~ledger_nonce:nonces.source_protection_ledger_nonce
          |> Result.map_error (fun error -> Scratch_store_error error)
        in
        let* _ =
          Scratch_store.publish_protection_plan repository.scratch
            source_protection
          |> Result.map_error (fun error -> Scratch_store_error error)
        in
        let* () = inject fault Fault.After_source_protection in
        let* target_protection =
          Scratch_store.plan_protection repository.scratch
            ~event_id:target_event ~action:Retention.Protect ~reason
            ~protection_nonce:nonces.target_protection_nonce
            ~ledger_nonce:nonces.target_protection_ledger_nonce
          |> Result.map_error (fun error -> Scratch_store_error error)
        in
        let* _ =
          Scratch_store.publish_protection_plan repository.scratch
            target_protection
          |> Result.map_error (fun error -> Scratch_store_error error)
        in
        let* () = inject fault Fault.After_target_protection in
        let* () = inject fault Fault.Before_binding in
        let* latest = resolve repository ~id in
        match latest with
        | Some resolved ->
            if
              V2_model.Opaque_object_ref.equal resolved.revision_ref
                revision_ref
            then Ok (Already_published resolved)
            else
              Error
                (Capsule_binding_target_mismatch
                   {
                     capsule = id;
                     expected = revision_ref;
                     actual = resolved.revision_ref;
                   })
        | None -> (
            let* expected_event_id, ledger_envelope =
              binding_envelope repository ~id ~predecessor:None ~revision_ref
                ~nonce:nonces.binding_ledger_nonce
            in
            let* publication =
              Ledger_store.publish repository.ledger ~envelope:ledger_envelope
              |> Result.map_error (fun error -> Ledger_store_error error)
            in
            let actual_event_id =
              match publication with
              | Ledger_store.Published { event_id; _ }
              | Ledger_store.Already_published { event_id; _ } ->
                  event_id
            in
            if not (Ledger.Event_id.equal expected_event_id actual_event_id)
            then assert false
            else
              let* resolved = resolve repository ~id in
              match resolved with
              | Some resolved -> Ok (Published resolved)
              | None -> assert false))

let checkpoint_link (checkpoint : Scratch_store.checkpoint) =
  {
    Capsule.snapshot_id = Model.Snapshot.id checkpoint.Scratch_store.snapshot;
    snapshot_ref = checkpoint.Scratch_store.snapshot_ref;
  }

let current_matches resolved ~expected_revision ~expected_binding =
  V2_model.Capsule_revision_id.equal
    (Capsule.revision_id resolved.revision)
    expected_revision
  && Ledger.Event_id.equal resolved.binding_event_id expected_binding

let stale_current_error ~expected_revision ~expected_binding = function
  | None ->
      Concurrent_current_update
        {
          expected_revision;
          expected_binding;
          actual_revision = None;
          actual_binding = None;
        }
  | Some resolved ->
      Concurrent_current_update
        {
          expected_revision;
          expected_binding;
          actual_revision = Some (Capsule.revision_id resolved.revision);
          actual_binding = Some resolved.binding_event_id;
        }

let fold ?fault repository ~id ~expected_revision ~expected_binding
    ~source_event ~target_event ~selected_indices ~created_at ~nonces =
  if not (distinct_revision_nonces nonces) then Error Nonce_reuse
  else
    let* prior = resolve repository ~id in
    let* current =
      match prior with
      | Some resolved
        when current_matches resolved ~expected_revision ~expected_binding ->
          Ok resolved
      | other ->
          Error (stale_current_error ~expected_revision ~expected_binding other)
    in
    let* () =
      Scratch_store.require_ancestor repository.scratch ~source:source_event
        ~target:target_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    let* source =
      Scratch_store.checkpoint_for_event repository.scratch
        ~event_id:source_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    let* target =
      Scratch_store.checkpoint_for_event repository.scratch
        ~event_id:target_event
      |> Result.map_error (fun error -> Scratch_store_error error)
    in
    if
      not
        (Model.Snapshot.equal source.Scratch_store.snapshot
           current.expected_result)
    then Error Revision_result_mismatch
    else
      let* increment =
        Capsule.propose ~from:current.expected_result
          ~to_:target.Scratch_store.snapshot
        |> Result.map_error (fun error -> Capsule_proposal_error error)
      in
      let* selection =
        Capsule.select increment ~indices:selected_indices
        |> Result.map_error (fun error -> Capsule_selection_error error)
      in
      let selected_result = Capsule.selected_result selection in
      let target_link = checkpoint_link target in
      let* expected_result, selected_result_envelope =
        if Model.Snapshot.equal selected_result target.Scratch_store.snapshot
        then Ok (target_link, None)
        else
          let* reference, envelope =
            envelope_for repository ~nonce:nonces.fold_selected_result_nonce
              (Object.scratch_snapshot selected_result)
          in
          Ok
            ( {
                Capsule.snapshot_id = Model.Snapshot.id selected_result;
                snapshot_ref = reference;
              },
              Some envelope )
      in
      let* complete =
        Capsule.propose ~from:current.declared_base ~to_:selected_result
        |> Result.map_error (fun error -> Capsule_proposal_error error)
      in
      let operations = Capsule.proposal_operations complete in
      let parent =
        Capsule.make_revision_link ~capsule_id:id
          ~revision_id:(Capsule.revision_id current.revision)
          ~revision_ref:current.revision_ref
      in
      let source_link = checkpoint_link source in
      let boundaries =
        Capsule.revision_source_boundaries current.revision
        @ [
            {
              Capsule.source_snapshot = source_link;
              target_snapshot = target_link;
            };
          ]
      in
      let* revision =
        Capsule.make_revision ~capsule:current.capsule
          ~capsule_ref:current.capsule_ref ~parent:(Some parent)
          ~declared_base:(Capsule.revision_declared_base current.revision)
          ~declared_base_snapshot:current.declared_base ~expected_result
          ~operations ~source_boundaries:boundaries
          ~provenance:(Capsule.Folded parent) ~created_at
        |> Result.map_error (fun error -> Capsule_error error)
      in
      let* revision_ref, revision_envelope =
        envelope_for repository ~nonce:nonces.fold_revision_nonce
          (Object.capsule_revision revision)
      in
      let* latest = resolve repository ~id in
      match latest with
      | Some resolved
        when V2_model.Opaque_object_ref.equal resolved.revision_ref revision_ref
        ->
          Ok (Already_published resolved)
      | Some resolved
        when current_matches resolved ~expected_revision ~expected_binding -> (
          let* () =
            match selected_result_envelope with
            | None -> Ok ()
            | Some envelope ->
                publish_object repository
                  ~expected:expected_result.Capsule.snapshot_ref envelope
          in
          let* () =
            publish_object repository ~expected:revision_ref revision_envelope
          in
          let* () = inject fault Fault.After_revision_object in
          let reason = Retention.Capsule_boundary revision_ref in
          let* source_protection =
            Scratch_store.plan_protection repository.scratch
              ~event_id:source_event ~action:Retention.Protect ~reason
              ~protection_nonce:nonces.fold_source_protection_nonce
              ~ledger_nonce:nonces.fold_source_protection_ledger_nonce
            |> Result.map_error (fun error -> Scratch_store_error error)
          in
          let* _ =
            Scratch_store.publish_protection_plan repository.scratch
              source_protection
            |> Result.map_error (fun error -> Scratch_store_error error)
          in
          let* () = inject fault Fault.After_source_protection in
          let* target_protection =
            Scratch_store.plan_protection repository.scratch
              ~event_id:target_event ~action:Retention.Protect ~reason
              ~protection_nonce:nonces.fold_target_protection_nonce
              ~ledger_nonce:nonces.fold_target_protection_ledger_nonce
            |> Result.map_error (fun error -> Scratch_store_error error)
          in
          let* _ =
            Scratch_store.publish_protection_plan repository.scratch
              target_protection
            |> Result.map_error (fun error -> Scratch_store_error error)
          in
          let* () = inject fault Fault.After_target_protection in
          let* () = inject fault Fault.Before_binding in
          let* latest = resolve repository ~id in
          let* () =
            match latest with
            | Some resolved
              when current_matches resolved ~expected_revision ~expected_binding
              ->
                Ok ()
            | other ->
                Error
                  (stale_current_error ~expected_revision ~expected_binding
                     other)
          in
          let* expected_event_id, ledger_envelope =
            binding_envelope repository ~id ~predecessor:(Some expected_binding)
              ~revision_ref ~nonce:nonces.fold_binding_ledger_nonce
          in
          let* publication =
            Ledger_store.publish repository.ledger ~envelope:ledger_envelope
            |> Result.map_error (fun error -> Ledger_store_error error)
          in
          let actual_event_id =
            match publication with
            | Ledger_store.Published { event_id; _ }
            | Ledger_store.Already_published { event_id; _ } ->
                event_id
          in
          if not (Ledger.Event_id.equal expected_event_id actual_event_id) then
            assert false
          else
            let* resolved = resolve repository ~id in
            match resolved with
            | Some resolved -> Ok (Published resolved)
            | None -> assert false)
      | other ->
          Error (stale_current_error ~expected_revision ~expected_binding other)
