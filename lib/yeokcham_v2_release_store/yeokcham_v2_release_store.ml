module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Record = Yeokcham_v2_release_record
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record
module Workspace_store = Yeokcham_v2_workspace_store

type repository = {
  bootstrap : Bootstrap_store.repository;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  workspaces : Workspace_store.repository;
}

type evidence_publication =
  | Evidence_published of {
      evidence : Record.validation_evidence;
      evidence_ref : V2_model.Opaque_object_ref.t;
    }
  | Evidence_already_published of {
      evidence : Record.validation_evidence;
      evidence_ref : V2_model.Opaque_object_ref.t;
    }

type nonces = { release_nonce : Envelope.nonce; binding_nonce : Envelope.nonce }

module Fault = struct
  type boundary = After_release_object | Before_binding
  type t = boundary

  let at boundary = boundary
end

type resolved = {
  release : Record.release;
  release_ref : V2_model.Opaque_object_ref.t;
  release_binding_event_id : Ledger.Event_id.t;
}

type publication = Published of resolved | Already_published of resolved

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Ledger_store.error
  | Object_store_error of Object_store.error
  | Record_error of Record.error
  | Workspace_store_error of Workspace_store.error
  | Invalid_release_ref_name of string
  | Nonce_reuse
  | Divergent_release_binding of Ledger.Event_id.t list
  | Release_missing of V2_model.Release_id.t
  | Release_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_release of V2_model.Opaque_object_ref.t
  | Release_link_mismatch of string
  | Release_id_already_bound of V2_model.Release_id.t
  | Evidence_link_mismatch of string
  | Evidence_not_passed of V2_model.Validation_id.t
  | Workspace_attempt_missing of V2_model.Workspace_attempt_id.t
  | Workspace_attempt_link_mismatch of string
  | Workspace_revision_link_mismatch of string
  | Unresolved_conflicts of V2_model.Workspace_attempt_id.t
  | Release_reproduction_mismatch of string
  | Parent_cycle of V2_model.Release_id.t list
  | Fault_injected of Fault.boundary

let ( let* ) = Result.bind

let error_to_string = function
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Ledger_error error -> Ledger.error_to_string error
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Record_error error -> Record.error_to_string error
  | Workspace_store_error error -> Workspace_store.error_to_string error
  | Invalid_release_ref_name name -> "invalid release ref name: " ^ name
  | Nonce_reuse -> "release publication requires distinct nonces"
  | Divergent_release_binding events ->
      "release binding has divergent causal heads: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex events)
  | Release_missing id ->
      "release has no visible binding: " ^ V2_model.Release_id.to_hex id
  | Release_binding_missing_target event ->
      "release binding has no target: " ^ Ledger.Event_id.to_hex event
  | Binding_target_not_release reference ->
      "release binding targets a non-release object: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Release_link_mismatch detail -> "release link mismatch: " ^ detail
  | Release_id_already_bound id ->
      "release ID already binds different immutable bytes: "
      ^ V2_model.Release_id.to_hex id
  | Evidence_link_mismatch detail ->
      "validation evidence link mismatch: " ^ detail
  | Evidence_not_passed id ->
      "release evidence is not passed: " ^ V2_model.Validation_id.to_hex id
  | Workspace_attempt_missing id ->
      "release names no visible workspace attempt: "
      ^ V2_model.Workspace_attempt_id.to_hex id
  | Workspace_attempt_link_mismatch detail ->
      "release workspace attempt link mismatch: " ^ detail
  | Workspace_revision_link_mismatch detail ->
      "release workspace revision link mismatch: " ^ detail
  | Unresolved_conflicts id ->
      "release refuses unresolved workspace conflicts in attempt: "
      ^ V2_model.Workspace_attempt_id.to_hex id
  | Release_reproduction_mismatch detail ->
      "release composition does not reproduce: " ^ detail
  | Parent_cycle ids ->
      "release parent graph has a cycle: "
      ^ String.concat "," (List.map V2_model.Release_id.to_hex ids)
  | Fault_injected Fault.After_release_object ->
      "injected release publication interruption after release object"
  | Fault_injected Fault.Before_binding ->
      "injected release publication interruption before release binding"

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
  let* workspaces =
    Workspace_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Workspace_store_error error)
  in
  Ok { bootstrap = bootstrap_repository; objects; ledger; workspaces }

let release_ref_name id =
  let name = "release-" ^ V2_model.Release_id.to_hex id in
  Ledger.Ref_name.of_string name
  |> Result.map_error (fun _ -> Invalid_release_ref_name name)

let distinct_nonces nonces =
  let bytes = List.map Envelope.nonce_to_bytes nonces in
  List.length bytes = List.length (List.sort_uniq String.compare bytes)

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

let binding_head repository ref_name =
  let* events = scoped_events repository ref_name in
  match events with
  | [] -> Ok None
  | _ -> (
      let* state =
        Ledger.evaluate
          ~repository_id:(Ledger_store.repository_id repository.ledger)
          ~ref_name events
        |> Result.map_error (fun error -> Ledger_error error)
      in
      match Ledger.heads state with
      | [] -> Ok None
      | [ head ] -> Ok (Some head)
      | heads ->
          Error
            (Divergent_release_binding
               (List.map event_id_of_verified heads
               |> List.sort Ledger.Event_id.compare)))

let target_of_binding verified =
  let event = Ledger.verified_event verified in
  match Ledger.event_unsigned event |> Ledger.unsigned_target with
  | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
  | None -> Error (Release_binding_missing_target (Ledger.event_id event))

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
  if V2_model.Opaque_object_ref.equal expected actual then Ok actual
  else assert false

let binding_envelope repository ~ref_name ~target ~nonce =
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  let capability = Bootstrap_store.capability repository.bootstrap in
  let* unsigned =
    Ledger.make_unsigned
      ~repository_id:(Bootstrap.repository_id record)
      ~ref_name
      ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
      ~predecessor:None
      ~target:(Some (Ledger.Ref_target.of_opaque_object_ref target))
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

let inject fault boundary =
  match fault with
  | Some actual when actual = boundary -> Error (Fault_injected boundary)
  | None | Some _ -> Ok ()

let same_snapshot_link left right =
  Yeokcham_id.Snapshot_id.equal left.Capsule.snapshot_id
    right.Capsule.snapshot_id
  && V2_model.Opaque_object_ref.equal left.Capsule.snapshot_ref
       right.Capsule.snapshot_ref

let same_workspace_revision_link left right =
  V2_model.Workspace_id.equal
    (Workspace_record.workspace_revision_link_workspace_id left)
    (Workspace_record.workspace_revision_link_workspace_id right)
  && V2_model.Workspace_revision_id.equal
       (Workspace_record.workspace_revision_link_revision_id left)
       (Workspace_record.workspace_revision_link_revision_id right)
  && V2_model.Opaque_object_ref.equal
       (Workspace_record.workspace_revision_link_ref left)
       (Workspace_record.workspace_revision_link_ref right)

let same_workspace_attempt_link left right =
  V2_model.Workspace_attempt_id.equal
    (Record.workspace_attempt_link_id left)
    (Record.workspace_attempt_link_id right)
  && V2_model.Opaque_object_ref.equal
       (Record.workspace_attempt_link_ref left)
       (Record.workspace_attempt_link_ref right)

let same_capsule_revision_link left right =
  V2_model.Capsule_id.equal
    (Capsule.revision_link_capsule_id left)
    (Capsule.revision_link_capsule_id right)
  && V2_model.Capsule_revision_id.equal
       (Capsule.revision_link_revision_id left)
       (Capsule.revision_link_revision_id right)
  && V2_model.Opaque_object_ref.equal
       (Capsule.revision_link_ref left)
       (Capsule.revision_link_ref right)

let same_conflict_link left right =
  V2_model.Conflict_id.equal
    (Workspace_record.conflict_link_id left)
    (Workspace_record.conflict_link_id right)
  && V2_model.Opaque_object_ref.equal
       (Workspace_record.conflict_link_ref left)
       (Workspace_record.conflict_link_ref right)

let same_resolution_link left right =
  V2_model.Resolution_id.equal
    (Workspace_record.resolution_link_id left)
    (Workspace_record.resolution_link_id right)
  && V2_model.Opaque_object_ref.equal
       (Workspace_record.resolution_link_ref left)
       (Workspace_record.resolution_link_ref right)

let same_resolution_binding left right =
  same_conflict_link
    (Workspace_record.resolution_binding_conflict left)
    (Workspace_record.resolution_binding_conflict right)
  && same_resolution_link
       (Workspace_record.resolution_binding_resolution left)
       (Workspace_record.resolution_binding_resolution right)

let snapshot_for_link repository (link : Capsule.snapshot_link) =
  let* object_ =
    Object_store.load repository.objects ~object_ref:link.Capsule.snapshot_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.snapshot object_ with
  | None ->
      Error
        (Release_reproduction_mismatch
           "snapshot link targets a non-snapshot object")
  | Some snapshot ->
      if
        Yeokcham_id.Snapshot_id.equal link.Capsule.snapshot_id
          (Yeokcham_model.Snapshot.id snapshot)
      then Ok snapshot
      else
        Error
          (Release_reproduction_mismatch
             "snapshot link logical identity differs from its object")

let load_evidence repository link =
  let* object_ =
    Object_store.load repository.objects
      ~object_ref:(Record.validation_evidence_link_ref link)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.validation_evidence_record object_ with
  | None -> Error (Evidence_link_mismatch "object is not validation evidence")
  | Some evidence ->
      if
        V2_model.Validation_id.equal
          (Record.validation_evidence_link_id link)
          (Record.validation_evidence_id evidence)
      then Ok evidence
      else Error (Evidence_link_mismatch "logical identity differs")

let resolve_bound repository id =
  let* ref_name = release_ref_name id in
  let* head = binding_head repository ref_name in
  match head with
  | None -> Ok None
  | Some verified -> (
      let* release_ref = target_of_binding verified in
      let* object_ =
        Object_store.load repository.objects ~object_ref:release_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      match Object.release_record object_ with
      | None -> Error (Binding_target_not_release release_ref)
      | Some release ->
          if V2_model.Release_id.equal id (Record.release_id release) then
            Ok
              (Some
                 {
                   release;
                   release_ref;
                   release_binding_event_id = event_id_of_verified verified;
                 })
          else Error (Release_link_mismatch "binding ID differs from target"))

type composition = {
  base : Capsule.snapshot_link;
  capsules : Capsule.revision_link list;
  resolutions : Workspace_record.resolution_binding list;
  final_snapshot : Capsule.snapshot_link;
}

let composition_for_attempt repository ~workspace ~attempt =
  let workspace_id =
    Workspace_record.workspace_revision_link_workspace_id workspace
  in
  let* resolved_attempt =
    Workspace_store.resolve_attempt repository.workspaces
      ~workspace:workspace_id
      ~attempt:(Record.workspace_attempt_link_id attempt)
    |> Result.map_error (fun error -> Workspace_store_error error)
  in
  let* resolved_attempt =
    match resolved_attempt with
    | None ->
        Error
          (Workspace_attempt_missing (Record.workspace_attempt_link_id attempt))
    | Some resolved -> Ok resolved
  in
  let actual_attempt =
    Record.make_workspace_attempt_link
      ~id:
        (Workspace_record.workspace_attempt_id
           resolved_attempt.Workspace_store.attempt)
      ~object_ref:resolved_attempt.Workspace_store.attempt_ref
  in
  if not (same_workspace_attempt_link attempt actual_attempt) then
    Error
      (Workspace_attempt_link_mismatch "logical ID or object reference differs")
  else if
    not
      (same_workspace_revision_link workspace
         (Workspace_record.workspace_attempt_workspace
            resolved_attempt.Workspace_store.attempt))
  then Error (Workspace_attempt_link_mismatch "attempt names another revision")
  else
    let* revision =
      Workspace_store.load_revision_link repository.workspaces workspace
      |> Result.map_error (fun error -> Workspace_store_error error)
    in
    if
      not
        (same_workspace_revision_link workspace
           (Workspace_record.make_workspace_revision_link
              ~workspace_id:
                (Workspace_record.workspace_revision_workspace_id revision)
              ~revision_id:(Workspace_record.workspace_revision_id revision)
              ~revision_ref:
                (Workspace_record.workspace_revision_link_ref workspace)))
    then Error (Workspace_revision_link_mismatch "object link differs")
    else if
      Workspace_record.workspace_attempt_conflicts
        resolved_attempt.Workspace_store.attempt
      <> []
    then
      Error
        (Unresolved_conflicts
           (Workspace_record.workspace_attempt_id
              resolved_attempt.Workspace_store.attempt))
    else
      Ok
        {
          base =
            Workspace_record.workspace_attempt_base
              resolved_attempt.Workspace_store.attempt;
          capsules =
            Workspace_record.workspace_attempt_ordered
              resolved_attempt.Workspace_store.attempt;
          resolutions = Workspace_record.workspace_revision_resolutions revision;
          final_snapshot =
            Workspace_record.workspace_attempt_resulting_snapshot
              resolved_attempt.Workspace_store.attempt;
        }

let verify_evidence repository release =
  let rec loop = function
    | [] -> Ok ()
    | link :: rest -> (
        let* evidence = load_evidence repository link in
        if
          not
            (same_snapshot_link
               (Record.validation_evidence_snapshot evidence)
               (Record.release_final_snapshot release))
        then
          Error
            (Evidence_link_mismatch
               "evidence snapshot differs from release final snapshot")
        else
          match Record.validation_evidence_status evidence with
          | Record.Passed -> loop rest
          | Record.Failed ->
              Error
                (Evidence_not_passed (Record.validation_evidence_id evidence)))
  in
  loop (Record.release_evidence release)

let same_list same left right =
  List.length left = List.length right && List.for_all2 same left right

let verify_release_inputs repository release =
  let* composition =
    composition_for_attempt repository
      ~workspace:(Record.release_workspace release)
      ~attempt:(Record.release_attempt release)
  in
  if not (same_snapshot_link composition.base (Record.release_base release))
  then
    Error (Release_reproduction_mismatch "base snapshot differs from attempt")
  else if
    not
      (same_list same_capsule_revision_link composition.capsules
         (Record.release_capsules release))
  then
    Error
      (Release_reproduction_mismatch
         "ordered capsule revisions differ from attempt")
  else if
    not
      (same_list same_resolution_binding composition.resolutions
         (Record.release_resolutions release))
  then
    Error
      (Release_reproduction_mismatch
         "resolution bindings differ from workspace revision")
  else if
    not
      (same_snapshot_link composition.final_snapshot
         (Record.release_final_snapshot release))
  then
    Error (Release_reproduction_mismatch "final snapshot differs from attempt")
  else
    let* _ =
      snapshot_for_link repository (Record.release_final_snapshot release)
    in
    verify_evidence repository release

let rec verify_parents repository ~visited parents =
  match parents with
  | [] -> Ok ()
  | parent :: rest ->
      let id = Record.release_link_id parent in
      if List.exists (V2_model.Release_id.equal id) visited then
        Error (Parent_cycle (List.rev (id :: visited)))
      else
        let* resolved = resolve_internal repository ~visited id in
        if
          not
            (V2_model.Opaque_object_ref.equal
               (Record.release_link_ref parent)
               resolved.release_ref)
        then Error (Release_link_mismatch "parent physical reference differs")
        else verify_parents repository ~visited rest

and resolve_internal repository ~visited id =
  let* bound = resolve_bound repository id in
  let* bound =
    match bound with
    | None -> Error (Release_missing id)
    | Some bound -> Ok bound
  in
  let* () = verify_release_inputs repository bound.release in
  let* () =
    verify_parents repository ~visited:(id :: visited)
      (Record.release_parents bound.release)
  in
  Ok bound

let resolve repository ~id =
  let* bound = resolve_bound repository id in
  match bound with
  | None -> Ok None
  | Some _ ->
      resolve_internal repository ~visited:[] id |> Result.map Option.some

let publish_evidence repository ~snapshot ~check_name ~status ~observed_at
    ~nonce =
  let* _ = snapshot_for_link repository snapshot in
  let* evidence =
    Record.make_validation_evidence ~snapshot ~check_name ~status ~observed_at
    |> Result.map_error (fun error -> Record_error error)
  in
  let* evidence_ref, envelope =
    envelope_for repository ~nonce (Object.validation_evidence evidence)
  in
  let* publication =
    Object_store.publish repository.objects ~envelope
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match publication with
  | Object_store.Published actual ->
      if V2_model.Opaque_object_ref.equal evidence_ref actual then
        Ok (Evidence_published { evidence; evidence_ref })
      else assert false
  | Object_store.Already_published actual ->
      if V2_model.Opaque_object_ref.equal evidence_ref actual then
        Ok (Evidence_already_published { evidence; evidence_ref })
      else assert false

let create ?fault repository ~parents ~workspace ~attempt ~evidence ~message
    ~created_at ~nonces =
  if not (distinct_nonces [ nonces.release_nonce; nonces.binding_nonce ]) then
    Error Nonce_reuse
  else
    let* composition = composition_for_attempt repository ~workspace ~attempt in
    let* release =
      Record.make_release ~parents ~workspace ~attempt ~base:composition.base
        ~capsules:composition.capsules ~resolutions:composition.resolutions
        ~final_snapshot:composition.final_snapshot ~evidence ~message
        ~created_at
      |> Result.map_error (fun error -> Record_error error)
    in
    let* () = verify_release_inputs repository release in
    let* () =
      verify_parents repository
        ~visited:[ Record.release_id release ]
        (Record.release_parents release)
    in
    let* release_ref, release_envelope =
      envelope_for repository ~nonce:nonces.release_nonce
        (Object.release release)
    in
    let* existing = resolve repository ~id:(Record.release_id release) in
    match existing with
    | Some existing ->
        if V2_model.Opaque_object_ref.equal existing.release_ref release_ref
        then Ok (Already_published existing)
        else Error (Release_id_already_bound (Record.release_id release))
    | None -> (
        let* _ =
          publish_object repository ~expected:release_ref release_envelope
        in
        let* () = inject fault Fault.After_release_object in
        let* () = inject fault Fault.Before_binding in
        let* current = resolve repository ~id:(Record.release_id release) in
        match current with
        | Some existing ->
            if V2_model.Opaque_object_ref.equal existing.release_ref release_ref
            then Ok (Already_published existing)
            else Error (Release_id_already_bound (Record.release_id release))
        | None -> (
            let* ref_name = release_ref_name (Record.release_id release) in
            let* expected_event_id, binding_envelope =
              binding_envelope repository ~ref_name ~target:release_ref
                ~nonce:nonces.binding_nonce
            in
            let* publication =
              Ledger_store.publish repository.ledger ~envelope:binding_envelope
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
              let* resolved =
                resolve repository ~id:(Record.release_id release)
              in
              match resolved with
              | Some resolved -> Ok (Published resolved)
              | None -> assert false))
