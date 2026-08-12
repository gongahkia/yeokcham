module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Capsule_store = Yeokcham_v2_capsule_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Publication_guard = Yeokcham_v2_publication_guard
module Record = Yeokcham_v2_workspace_record
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace

type repository = {
  root : string;
  bootstrap : Bootstrap_store.repository;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  capsules : Capsule_store.repository;
}

type create_nonces = {
  create_workspace_nonce : Envelope.nonce;
  create_revision_nonce : Envelope.nonce;
  create_binding_nonce : Envelope.nonce;
}

type attempt_nonces = {
  attempt_result_nonce : Envelope.nonce;
  conflict_nonces : Envelope.nonce list;
  attempt_nonce : Envelope.nonce;
  attempt_binding_nonce : Envelope.nonce;
}

type resolution_nonces = {
  resolve_resolution_nonce : Envelope.nonce;
  resolve_revision_nonce : Envelope.nonce;
  resolve_binding_nonce : Envelope.nonce;
}

module Fault = struct
  type boundary =
    | After_workspace_object
    | After_workspace_revision
    | After_attempt_result
    | After_conflict_objects
    | After_attempt_object
    | After_resolution_object
    | After_resolution_revision
    | Before_binding

  type t = boundary

  let at boundary = boundary
end

type resolved = {
  workspace : Record.workspace;
  workspace_ref : V2_model.Opaque_object_ref.t;
  revision : Record.workspace_revision;
  revision_ref : V2_model.Opaque_object_ref.t;
  workspace_binding_event_id : Ledger.Event_id.t;
  base_snapshot : Model.Snapshot.t;
  order : Workspace.order;
  application : Workspace.application;
}

type resolved_attempt = {
  attempt : Record.workspace_attempt;
  attempt_ref : V2_model.Opaque_object_ref.t;
  attempt_binding_event_id : Ledger.Event_id.t;
}

type publication = Published of resolved | Already_published of resolved

type attempt_publication =
  | Attempt_published of resolved_attempt
  | Attempt_already_published of resolved_attempt

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Capsule_store_error of Capsule_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Ledger_store.error
  | Object_store_error of Object_store.error
  | Record_error of Record.error
  | Workspace_error of Workspace.error
  | Publication_guard_error of Publication_guard.error
  | Invalid_workspace_ref_name of string
  | Invalid_attempt_ref_name of string
  | Nonce_reuse
  | Conflict_nonce_count_mismatch of { expected : int; actual : int }
  | Workspace_id_already_bound of V2_model.Workspace_id.t
  | Workspace_missing of V2_model.Workspace_id.t
  | Divergent_workspace_binding of Ledger.Event_id.t list
  | Workspace_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_workspace_revision of V2_model.Opaque_object_ref.t
  | Workspace_revision_link_mismatch of string
  | Workspace_metadata_mismatch
  | Snapshot_ref_not_snapshot of V2_model.Opaque_object_ref.t
  | Snapshot_identity_mismatch of V2_model.Opaque_object_ref.t
  | Revision_order_mismatch
  | Resolution_link_mismatch of string
  | Conflict_link_mismatch of string
  | Conflict_not_in_workspace of V2_model.Conflict_id.t
  | Attempt_id_already_bound of V2_model.Workspace_attempt_id.t
  | Attempt_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_workspace_attempt of V2_model.Opaque_object_ref.t
  | Attempt_link_mismatch of string
  | Concurrent_current_update of {
      expected_revision : V2_model.Workspace_revision_id.t;
      expected_binding : Ledger.Event_id.t;
      actual_revision : V2_model.Workspace_revision_id.t option;
      actual_binding : Ledger.Event_id.t option;
    }
  | Fault_injected of Fault.boundary

let ( let* ) = Result.bind

let error_to_string = function
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Capsule_store_error error -> Capsule_store.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Ledger_error error -> Ledger.error_to_string error
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Record_error error -> Record.error_to_string error
  | Workspace_error error -> Workspace.error_to_string error
  | Publication_guard_error error -> Publication_guard.error_to_string error
  | Invalid_workspace_ref_name name -> "invalid workspace ref name: " ^ name
  | Invalid_attempt_ref_name name ->
      "invalid workspace attempt ref name: " ^ name
  | Nonce_reuse -> "workspace publication requires pairwise distinct nonces"
  | Conflict_nonce_count_mismatch { expected; actual } ->
      Printf.sprintf
        "workspace attempt has %d conflicts but received %d conflict nonces"
        expected actual
  | Workspace_id_already_bound id ->
      "workspace already has a current binding: "
      ^ V2_model.Workspace_id.to_hex id
  | Workspace_missing id ->
      "workspace has no current binding: " ^ V2_model.Workspace_id.to_hex id
  | Divergent_workspace_binding events ->
      "workspace binding has divergent causal heads: "
      ^ String.concat "," (List.map Ledger.Event_id.to_hex events)
  | Workspace_binding_missing_target event ->
      "workspace binding has no target: " ^ Ledger.Event_id.to_hex event
  | Binding_target_not_workspace_revision reference ->
      "workspace binding targets a non-workspace-revision object: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Workspace_revision_link_mismatch detail ->
      "workspace revision link mismatch: " ^ detail
  | Workspace_metadata_mismatch ->
      "workspace revision names a different workspace metadata object"
  | Snapshot_ref_not_snapshot reference ->
      "workspace snapshot link is not an exact snapshot: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Snapshot_identity_mismatch reference ->
      "workspace snapshot link logical identity mismatches: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Revision_order_mismatch ->
      "workspace revision stored order differs from deterministic order"
  | Resolution_link_mismatch detail ->
      "workspace resolution link mismatch: " ^ detail
  | Conflict_link_mismatch detail ->
      "workspace conflict link mismatch: " ^ detail
  | Conflict_not_in_workspace id ->
      "workspace conflict is not currently resolvable: "
      ^ V2_model.Conflict_id.to_hex id
  | Attempt_id_already_bound id ->
      "workspace attempt already has a binding: "
      ^ V2_model.Workspace_attempt_id.to_hex id
  | Attempt_binding_missing_target event ->
      "workspace attempt binding has no target: " ^ Ledger.Event_id.to_hex event
  | Binding_target_not_workspace_attempt reference ->
      "workspace attempt binding targets a non-attempt object: "
      ^ V2_model.Opaque_object_ref.to_hex reference
  | Attempt_link_mismatch detail -> "workspace attempt link mismatch: " ^ detail
  | Concurrent_current_update
      { expected_revision; expected_binding; actual_revision; actual_binding }
    ->
      let revision = function
        | None -> "none"
        | Some id -> V2_model.Workspace_revision_id.to_hex id
      in
      let binding = function
        | None -> "none"
        | Some id -> Ledger.Event_id.to_hex id
      in
      Printf.sprintf
        "workspace current changed from revision %s at binding %s to revision \
         %s at binding %s"
        (V2_model.Workspace_revision_id.to_hex expected_revision)
        (Ledger.Event_id.to_hex expected_binding)
        (revision actual_revision) (binding actual_binding)
  | Fault_injected boundary ->
      let name =
        match boundary with
        | Fault.After_workspace_object -> "after workspace object"
        | Fault.After_workspace_revision -> "after workspace revision"
        | Fault.After_attempt_result -> "after attempt result"
        | Fault.After_conflict_objects -> "after conflict objects"
        | Fault.After_attempt_object -> "after attempt object"
        | Fault.After_resolution_object -> "after resolution object"
        | Fault.After_resolution_revision -> "after resolution revision"
        | Fault.Before_binding -> "before workspace binding"
      in
      "injected workspace publication interruption " ^ name

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
  let* capsules =
    Capsule_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Capsule_store_error error)
  in
  Ok { root; bootstrap = bootstrap_repository; objects; ledger; capsules }

let with_shared_guard repository action =
  match
    Publication_guard.with_guard ~root:repository.root
      ~mode:Publication_guard.Shared action
  with
  | Ok result -> result
  | Error error -> Error (Publication_guard_error error)

let workspace_ref_name id =
  let name = "workspace-" ^ V2_model.Workspace_id.to_hex id in
  Ledger.Ref_name.of_string name
  |> Result.map_error (fun _ -> Invalid_workspace_ref_name name)

let attempt_ref_name ~workspace ~attempt =
  let name =
    "workspace-attempt-"
    ^ V2_model.Workspace_id.to_hex workspace
    ^ "-"
    ^ V2_model.Workspace_attempt_id.to_hex attempt
  in
  Ledger.Ref_name.of_string name
  |> Result.map_error (fun _ -> Invalid_attempt_ref_name name)

let nonce_bytes nonces = List.map Envelope.nonce_to_bytes nonces

let distinct_nonces nonces =
  let values = nonce_bytes nonces in
  List.length values = List.length (List.sort_uniq String.compare values)

let distinct_create_nonces nonces =
  distinct_nonces
    [
      nonces.create_workspace_nonce;
      nonces.create_revision_nonce;
      nonces.create_binding_nonce;
    ]

let distinct_attempt_nonces nonces =
  distinct_nonces
    (nonces.attempt_result_nonce :: nonces.attempt_nonce
   :: nonces.attempt_binding_nonce :: nonces.conflict_nonces)

let distinct_resolution_nonces nonces =
  distinct_nonces
    [
      nonces.resolve_resolution_nonce;
      nonces.resolve_revision_nonce;
      nonces.resolve_binding_nonce;
    ]

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
            (Divergent_workspace_binding
               (List.map event_id_of_verified heads
               |> List.sort Ledger.Event_id.compare)))

let target_of_binding ~missing verified =
  let event = Ledger.verified_event verified in
  match Ledger.event_unsigned event |> Ledger.unsigned_target with
  | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
  | None -> Error (missing (Ledger.event_id event))

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

let binding_envelope repository ~ref_name ~predecessor ~target ~nonce =
  let record = Bootstrap_store.bootstrap repository.bootstrap in
  let capability = Bootstrap_store.capability repository.bootstrap in
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

let same_workspace_revision_link left right =
  V2_model.Workspace_id.equal
    (Record.workspace_revision_link_workspace_id left)
    (Record.workspace_revision_link_workspace_id right)
  && V2_model.Workspace_revision_id.equal
       (Record.workspace_revision_link_revision_id left)
       (Record.workspace_revision_link_revision_id right)
  && V2_model.Opaque_object_ref.equal
       (Record.workspace_revision_link_ref left)
       (Record.workspace_revision_link_ref right)

let same_conflict_link left right =
  V2_model.Conflict_id.equal
    (Record.conflict_link_id left)
    (Record.conflict_link_id right)
  && V2_model.Opaque_object_ref.equal
       (Record.conflict_link_ref left)
       (Record.conflict_link_ref right)

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

let workspace_revision_link ~workspace ~revision ~revision_ref =
  Record.make_workspace_revision_link
    ~workspace_id:(Record.workspace_id workspace)
    ~revision_id:(Record.workspace_revision_id revision)
    ~revision_ref

let verify_workspace_revision_link repository link =
  let revision_ref = Record.workspace_revision_link_ref link in
  let* object_ =
    Object_store.load repository.objects ~object_ref:revision_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.workspace_revision_record object_ with
  | None -> Error (Binding_target_not_workspace_revision revision_ref)
  | Some revision ->
      if
        not
          (V2_model.Workspace_id.equal
             (Record.workspace_revision_link_workspace_id link)
             (Record.workspace_revision_workspace_id revision))
      then Error (Workspace_revision_link_mismatch "workspace identity differs")
      else if
        not
          (V2_model.Workspace_revision_id.equal
             (Record.workspace_revision_link_revision_id link)
             (Record.workspace_revision_id revision))
      then Error (Workspace_revision_link_mismatch "revision identity differs")
      else Ok revision

let load_revision_link = verify_workspace_revision_link

let load_conflict_link repository link =
  let* object_ =
    Object_store.load repository.objects
      ~object_ref:(Record.conflict_link_ref link)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.conflict_record object_ with
  | None -> Error (Conflict_link_mismatch "object is not a conflict")
  | Some conflict ->
      if
        V2_model.Conflict_id.equal
          (Record.conflict_link_id link)
          (Record.conflict_id conflict)
      then Ok conflict
      else Error (Conflict_link_mismatch "logical identity differs")

let load_resolution_link repository link =
  let* object_ =
    Object_store.load repository.objects
      ~object_ref:(Record.resolution_link_ref link)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match Object.resolution_record object_ with
  | None -> Error (Resolution_link_mismatch "object is not a resolution")
  | Some resolution ->
      if
        V2_model.Resolution_id.equal
          (Record.resolution_link_id link)
          (Record.resolution_id resolution)
      then Ok resolution
      else Error (Resolution_link_mismatch "logical identity differs")

let conflict_has_published_attempt repository ~conflict_link conflict =
  let workspace =
    Record.workspace_revision_link_workspace_id
      (Record.conflict_workspace conflict)
  in
  let attempt = Record.conflict_attempt conflict in
  let* ref_name = attempt_ref_name ~workspace ~attempt in
  let* head = binding_head repository ref_name in
  match head with
  | None -> Error (Conflict_not_in_workspace (Record.conflict_id conflict))
  | Some verified -> (
      let* attempt_ref =
        target_of_binding
          ~missing:(fun event -> Attempt_binding_missing_target event)
          verified
      in
      let* object_ =
        Object_store.load repository.objects ~object_ref:attempt_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      match Object.workspace_attempt_record object_ with
      | None -> Error (Binding_target_not_workspace_attempt attempt_ref)
      | Some record ->
          if
            not
              (V2_model.Workspace_attempt_id.equal attempt
                 (Record.workspace_attempt_id record))
          then Error (Attempt_link_mismatch "attempt logical identity differs")
          else if
            not
              (same_workspace_revision_link
                 (Record.conflict_workspace conflict)
                 (Record.workspace_attempt_workspace record))
          then
            Error
              (Attempt_link_mismatch "attempt names another workspace revision")
          else if
            List.exists
              (same_conflict_link conflict_link)
              (Record.workspace_attempt_conflicts record)
          then Ok ()
          else Error (Conflict_not_in_workspace (Record.conflict_id conflict)))

let rec link_in_history repository ~candidate ~current ~visited =
  if same_workspace_revision_link candidate current then Ok true
  else
    let current_ref = Record.workspace_revision_link_ref current in
    if List.exists (V2_model.Opaque_object_ref.equal current_ref) visited then
      Error (Workspace_revision_link_mismatch "parent history contains a cycle")
    else
      let* revision = verify_workspace_revision_link repository current in
      match Record.workspace_revision_parent revision with
      | None -> Ok false
      | Some parent ->
          link_in_history repository ~candidate ~current:parent
            ~visited:(current_ref :: visited)

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

let same_conflict_source conflict (source : Workspace.conflict) =
  same_capsule_revision_link
    (Record.conflict_revision conflict)
    source.Workspace.revision
  && Int.equal
       (Record.conflict_operation_index conflict)
       source.Workspace.operation_index
  && List.equal Model.Path.equal
       (Record.conflict_paths conflict)
       source.Workspace.paths
  && Record.conflict_cause conflict = source.Workspace.cause

let resolution_actions repository ~revision_link revision =
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | binding :: rest -> (
        let conflict_link = Record.resolution_binding_conflict binding in
        let resolution_link = Record.resolution_binding_resolution binding in
        let* conflict = load_conflict_link repository conflict_link in
        let* resolution = load_resolution_link repository resolution_link in
        if
          not
            (same_conflict_link conflict_link
               (Record.resolution_conflict resolution))
        then
          Error (Resolution_link_mismatch "resolution names another conflict")
        else if
          not
            (same_workspace_revision_link
               (Record.conflict_workspace conflict)
               (Record.resolution_workspace resolution))
        then
          Error
            (Resolution_link_mismatch "conflict and resolution workspace differ")
        else
          let* in_history =
            link_in_history repository
              ~candidate:(Record.conflict_workspace conflict)
              ~current:revision_link ~visited:[]
          in
          if not in_history then
            Error
              (Resolution_link_mismatch "conflict is outside workspace history")
          else
            let* () =
              conflict_has_published_attempt repository ~conflict_link conflict
            in
            match Record.resolution_action resolution with
            | Record.Skip_operation { revision; operation_index } ->
                if
                  same_capsule_revision_link revision
                    (Record.conflict_revision conflict)
                  && Int.equal operation_index
                       (Record.conflict_operation_index conflict)
                then
                  collect
                    (Workspace.Skip_operation { revision; operation_index }
                    :: reversed)
                    rest
                else
                  Error
                    (Resolution_link_mismatch
                       "skip action does not name conflict operation"))
  in
  collect [] (Record.workspace_revision_resolutions revision)

let order_matches_revision order revision =
  let actual =
    List.map
      (fun selected -> selected.Workspace.link)
      (Workspace.ordered_revisions order)
  in
  let expected = Record.workspace_revision_resolved_order revision in
  List.length actual = List.length expected
  && List.for_all2 same_capsule_revision_link actual expected

let verify_resolved_revision repository ~workspace ~workspace_ref ~revision_ref
    ~binding_event_id =
  let* revision_object =
    Object_store.load repository.objects ~object_ref:revision_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* revision =
    match Object.workspace_revision_record revision_object with
    | Some revision -> Ok revision
    | None -> Error (Binding_target_not_workspace_revision revision_ref)
  in
  if
    not
      (V2_model.Workspace_id.equal
         (Record.workspace_id workspace)
         (Record.workspace_revision_workspace_id revision))
  then Error Workspace_metadata_mismatch
  else if
    not
      (V2_model.Opaque_object_ref.equal workspace_ref
         (Record.workspace_revision_workspace_ref revision))
  then Error Workspace_metadata_mismatch
  else
    let revision_link =
      workspace_revision_link ~workspace ~revision ~revision_ref
    in
    let* base_snapshot =
      snapshot_for_link repository (Record.workspace_revision_base revision)
    in
    let rec selected reversed = function
      | [] -> Ok (List.rev reversed)
      | link :: rest ->
          let* verified =
            Capsule_store.verify_revision_link repository.capsules link
            |> Result.map_error (fun error -> Capsule_store_error error)
          in
          selected
            ({
               Workspace.link;
               capsule_revision = verified.Capsule_store.verified_revision;
             }
            :: reversed)
            rest
    in
    let* selected = selected [] (Record.workspace_revision_selected revision) in
    let* order =
      Workspace.derive_order ~selected
        ~precedence:(Record.workspace_revision_precedence revision)
      |> Result.map_error (fun error -> Workspace_error error)
    in
    if not (order_matches_revision order revision) then
      Error Revision_order_mismatch
    else
      let* resolutions =
        resolution_actions repository ~revision_link revision
      in
      let application =
        Workspace.apply ~base:base_snapshot ~order ~resolutions
      in
      Ok
        {
          workspace;
          workspace_ref;
          revision;
          revision_ref;
          workspace_binding_event_id = binding_event_id;
          base_snapshot;
          order;
          application;
        }

let resolve repository ~id =
  let* ref_name = workspace_ref_name id in
  let* head = binding_head repository ref_name in
  match head with
  | None -> Ok None
  | Some verified ->
      let binding_event_id = event_id_of_verified verified in
      let* revision_ref =
        target_of_binding
          ~missing:(fun event -> Workspace_binding_missing_target event)
          verified
      in
      let* revision_object =
        Object_store.load repository.objects ~object_ref:revision_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      let* revision =
        match Object.workspace_revision_record revision_object with
        | Some revision -> Ok revision
        | None -> Error (Binding_target_not_workspace_revision revision_ref)
      in
      if
        not
          (V2_model.Workspace_id.equal id
             (Record.workspace_revision_workspace_id revision))
      then Error Workspace_metadata_mismatch
      else
        let workspace_ref = Record.workspace_revision_workspace_ref revision in
        let* workspace_object =
          Object_store.load repository.objects ~object_ref:workspace_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        let* workspace =
          match Object.workspace_record workspace_object with
          | Some workspace -> Ok workspace
          | None -> Error Workspace_metadata_mismatch
        in
        if not (V2_model.Workspace_id.equal id (Record.workspace_id workspace))
        then Error Workspace_metadata_mismatch
        else
          verify_resolved_revision repository ~workspace ~workspace_ref
            ~revision_ref ~binding_event_id
          |> Result.map Option.some

let current_matches resolved ~expected_revision ~expected_binding =
  V2_model.Workspace_revision_id.equal
    (Record.workspace_revision_id resolved.revision)
    expected_revision
  && Ledger.Event_id.equal resolved.workspace_binding_event_id expected_binding

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
          actual_revision =
            Some (Record.workspace_revision_id resolved.revision);
          actual_binding = Some resolved.workspace_binding_event_id;
        }

let create_unlocked ?fault repository ~id ~title ~description ~base ~selected
    ~precedence ~created_at ~nonces =
  if not (distinct_create_nonces nonces) then Error Nonce_reuse
  else
    let* _base_snapshot = snapshot_for_link repository base in
    let rec verified_selected reversed = function
      | [] -> Ok (List.rev reversed)
      | link :: rest ->
          let* verified =
            Capsule_store.verify_revision_link repository.capsules link
            |> Result.map_error (fun error -> Capsule_store_error error)
          in
          verified_selected
            ({
               Workspace.link;
               capsule_revision = verified.Capsule_store.verified_revision;
             }
            :: reversed)
            rest
    in
    let* selected_revisions = verified_selected [] selected in
    let* order =
      Workspace.derive_order ~selected:selected_revisions ~precedence
      |> Result.map_error (fun error -> Workspace_error error)
    in
    let* workspace =
      Record.make_workspace ~id ~title ~description ~created_at
      |> Result.map_error (fun error -> Record_error error)
    in
    let* workspace_ref, workspace_envelope =
      envelope_for repository ~nonce:nonces.create_workspace_nonce
        (Object.workspace workspace)
    in
    let resolved_order =
      Workspace.ordered_revisions order
      |> List.map (fun selected -> selected.Workspace.link)
    in
    let* revision =
      Record.make_workspace_revision ~workspace ~workspace_ref ~parent:None
        ~base ~selected ~precedence ~resolved_order ~resolutions:[] ~created_at
      |> Result.map_error (fun error -> Record_error error)
    in
    let* revision_ref, revision_envelope =
      envelope_for repository ~nonce:nonces.create_revision_nonce
        (Object.workspace_revision revision)
    in
    let* existing = resolve repository ~id in
    match existing with
    | Some resolved ->
        if V2_model.Opaque_object_ref.equal resolved.revision_ref revision_ref
        then Ok (Already_published resolved)
        else Error (Workspace_id_already_bound id)
    | None -> (
        let* () =
          publish_object repository ~expected:workspace_ref workspace_envelope
        in
        let* () = inject fault Fault.After_workspace_object in
        let* () =
          publish_object repository ~expected:revision_ref revision_envelope
        in
        let* () = inject fault Fault.After_workspace_revision in
        let* () = inject fault Fault.Before_binding in
        let* latest = resolve repository ~id in
        match latest with
        | Some resolved ->
            if
              V2_model.Opaque_object_ref.equal resolved.revision_ref
                revision_ref
            then Ok (Already_published resolved)
            else Error (Workspace_id_already_bound id)
        | None -> (
            let* ref_name = workspace_ref_name id in
            let* expected_event_id, ledger_envelope =
              binding_envelope repository ~ref_name ~predecessor:None
                ~target:revision_ref ~nonce:nonces.create_binding_nonce
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

let create ?fault repository ~id ~title ~description ~base ~selected ~precedence
    ~created_at ~nonces =
  with_shared_guard repository (fun () ->
      create_unlocked ?fault repository ~id ~title ~description ~base ~selected
        ~precedence ~created_at ~nonces)

let resolved_revision_for_link repository link ~binding_event_id =
  let* revision = verify_workspace_revision_link repository link in
  let workspace_ref = Record.workspace_revision_workspace_ref revision in
  let* workspace_object =
    Object_store.load repository.objects ~object_ref:workspace_ref
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* workspace =
    match Object.workspace_record workspace_object with
    | Some workspace -> Ok workspace
    | None -> Error Workspace_metadata_mismatch
  in
  if
    not
      (V2_model.Workspace_id.equal
         (Record.workspace_revision_link_workspace_id link)
         (Record.workspace_id workspace))
  then Error Workspace_metadata_mismatch
  else
    verify_resolved_revision repository ~workspace ~workspace_ref
      ~revision_ref:(Record.workspace_revision_link_ref link)
      ~binding_event_id

let conflict_link_for_source ~workspace ~attempt conflicts source =
  let* derived =
    Record.make_conflict ~workspace ~attempt ~source ~created_at:0L
    |> Result.map_error (fun error -> Record_error error)
  in
  match
    List.find_opt
      (fun link ->
        V2_model.Conflict_id.equal
          (Record.conflict_link_id link)
          (Record.conflict_id derived))
      conflicts
  with
  | Some link -> Ok link
  | None -> Error (Conflict_not_in_workspace (Record.conflict_id derived))

let attempt_outcomes_for_application ~workspace ~attempt ~conflicts application
    =
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | outcome :: rest ->
        let* outcome =
          match outcome with
          | Workspace.Applied_exactly { revision; operation_index } ->
              Ok (Record.Attempt_applied_exactly { revision; operation_index })
          | Workspace.Skipped_explicitly { revision; operation_index } ->
              Ok
                (Record.Attempt_skipped_explicitly { revision; operation_index })
          | Workspace.Conflict source ->
              let* conflict =
                conflict_link_for_source ~workspace ~attempt conflicts source
              in
              Ok (Record.Attempt_conflict conflict)
          | Workspace.Blocked_by_conflict
              { revision; operation_index; blocked_by } ->
              let* conflict =
                conflict_link_for_source ~workspace ~attempt conflicts
                  blocked_by
              in
              Ok
                (Record.Attempt_blocked_by_conflict
                   { revision; operation_index; blocked_by = conflict })
        in
        collect (outcome :: reversed) rest
  in
  collect [] application.Workspace.outcomes

let same_attempt_outcome left right =
  match (left, right) with
  | Record.Attempt_applied_exactly left, Record.Attempt_applied_exactly right ->
      same_capsule_revision_link left.revision right.revision
      && Int.equal left.operation_index right.operation_index
  | ( Record.Attempt_skipped_explicitly left,
      Record.Attempt_skipped_explicitly right ) ->
      same_capsule_revision_link left.revision right.revision
      && Int.equal left.operation_index right.operation_index
  | Record.Attempt_conflict left, Record.Attempt_conflict right ->
      same_conflict_link left right
  | ( Record.Attempt_blocked_by_conflict left,
      Record.Attempt_blocked_by_conflict right ) ->
      same_capsule_revision_link left.revision right.revision
      && Int.equal left.operation_index right.operation_index
      && same_conflict_link left.blocked_by right.blocked_by
  | ( ( Record.Attempt_applied_exactly _ | Record.Attempt_skipped_explicitly _
      | Record.Attempt_conflict _ | Record.Attempt_blocked_by_conflict _ ),
      ( Record.Attempt_applied_exactly _ | Record.Attempt_skipped_explicitly _
      | Record.Attempt_conflict _ | Record.Attempt_blocked_by_conflict _ ) ) ->
      false

let verify_attempt_conflicts repository ~workspace ~attempt conflicts =
  let rec collect = function
    | [] -> Ok ()
    | link :: rest ->
        let* conflict = load_conflict_link repository link in
        if
          not
            (same_workspace_revision_link
               (Record.conflict_workspace conflict)
               workspace)
        then
          Error
            (Attempt_link_mismatch "conflict names another workspace revision")
        else if
          not
            (V2_model.Workspace_attempt_id.equal
               (Record.conflict_attempt conflict)
               attempt)
        then Error (Attempt_link_mismatch "conflict names another attempt")
        else collect rest
  in
  collect conflicts

let resolve_attempt repository ~workspace ~attempt =
  let* ref_name = attempt_ref_name ~workspace ~attempt in
  let* head = binding_head repository ref_name in
  match head with
  | None -> Ok None
  | Some verified ->
      let binding_event_id = event_id_of_verified verified in
      let* attempt_ref =
        target_of_binding
          ~missing:(fun event -> Attempt_binding_missing_target event)
          verified
      in
      let* object_ =
        Object_store.load repository.objects ~object_ref:attempt_ref
        |> Result.map_error (fun error -> Object_store_error error)
      in
      let* attempt_record =
        match Object.workspace_attempt_record object_ with
        | Some attempt -> Ok attempt
        | None -> Error (Binding_target_not_workspace_attempt attempt_ref)
      in
      if
        not
          (V2_model.Workspace_attempt_id.equal attempt
             (Record.workspace_attempt_id attempt_record))
      then Error (Attempt_link_mismatch "attempt logical identity differs")
      else
        let workspace_link =
          Record.workspace_attempt_workspace attempt_record
        in
        if
          not
            (V2_model.Workspace_id.equal workspace
               (Record.workspace_revision_link_workspace_id workspace_link))
        then Error (Attempt_link_mismatch "attempt names another workspace")
        else
          let* replay =
            resolved_revision_for_link repository workspace_link
              ~binding_event_id
          in
          let* base_snapshot =
            snapshot_for_link repository
              (Record.workspace_attempt_base attempt_record)
          in
          if not (Model.Snapshot.equal base_snapshot replay.base_snapshot) then
            Error
              (Attempt_link_mismatch
                 "attempt base differs from workspace revision")
          else
            let ordered = Record.workspace_attempt_ordered attempt_record in
            let expected_order =
              Workspace.ordered_revisions replay.order
              |> List.map (fun selected -> selected.Workspace.link)
            in
            if
              List.length ordered <> List.length expected_order
              || not
                   (List.for_all2 same_capsule_revision_link ordered
                      expected_order)
            then
              Error
                (Attempt_link_mismatch
                   "attempt order differs from workspace revision")
            else
              let* resulting_snapshot =
                snapshot_for_link repository
                  (Record.workspace_attempt_resulting_snapshot attempt_record)
              in
              if
                not
                  (Model.Snapshot.equal resulting_snapshot
                     replay.application.Workspace.resulting_snapshot)
              then
                Error (Attempt_link_mismatch "attempt result does not replay")
              else
                let conflicts =
                  Record.workspace_attempt_conflicts attempt_record
                in
                let* () =
                  verify_attempt_conflicts repository ~workspace:workspace_link
                    ~attempt conflicts
                in
                let* expected_outcomes =
                  attempt_outcomes_for_application ~workspace:workspace_link
                    ~attempt ~conflicts replay.application
                in
                if
                  List.length expected_outcomes
                  <> List.length
                       (Record.workspace_attempt_outcomes attempt_record)
                  || not
                       (List.for_all2 same_attempt_outcome expected_outcomes
                          (Record.workspace_attempt_outcomes attempt_record))
                then
                  Error (Attempt_link_mismatch "attempt outcomes do not replay")
                else
                  Ok
                    (Some
                       {
                         attempt = attempt_record;
                         attempt_ref;
                         attempt_binding_event_id = binding_event_id;
                       })

let prepare_conflicts repository ~workspace ~attempt ~created_at ~nonces
    conflicts =
  if List.length conflicts <> List.length nonces then
    Error
      (Conflict_nonce_count_mismatch
         { expected = List.length conflicts; actual = List.length nonces })
  else
    let rec prepare reversed = function
      | [], [] -> Ok (List.rev reversed)
      | source :: sources, nonce :: nonces ->
          let* conflict =
            Record.make_conflict ~workspace ~attempt ~source ~created_at
            |> Result.map_error (fun error -> Record_error error)
          in
          let* reference, envelope =
            envelope_for repository ~nonce (Object.conflict conflict)
          in
          let link =
            Record.make_conflict_link
              ~id:(Record.conflict_id conflict)
              ~object_ref:reference
          in
          prepare ((link, envelope) :: reversed) (sources, nonces)
      | _ -> assert false
    in
    prepare [] (conflicts, nonces)

let publish_conflicts repository prepared =
  List.fold_left
    (fun result (link, envelope) ->
      let* () = result in
      publish_object repository
        ~expected:(Record.conflict_link_ref link)
        envelope)
    (Ok ()) prepared

let attempt_unlocked ?fault repository ~id ~expected_revision ~expected_binding
    ~created_at ~nonces =
  if not (distinct_attempt_nonces nonces) then Error Nonce_reuse
  else
    let* current = resolve repository ~id in
    let* current =
      match current with
      | Some current
        when current_matches current ~expected_revision ~expected_binding ->
          Ok current
      | other ->
          Error (stale_current_error ~expected_revision ~expected_binding other)
    in
    let workspace_link =
      workspace_revision_link ~workspace:current.workspace
        ~revision:current.revision ~revision_ref:current.revision_ref
    in
    let ordered =
      Workspace.ordered_revisions current.order
      |> List.map (fun selected -> selected.Workspace.link)
    in
    let attempt_id =
      Record.derive_attempt_id ~workspace:workspace_link
        ~base:(Record.workspace_revision_base current.revision)
        ~ordered
    in
    let* prepared_conflicts =
      prepare_conflicts repository ~workspace:workspace_link ~attempt:attempt_id
        ~created_at ~nonces:nonces.conflict_nonces
        current.application.Workspace.conflicts
    in
    let conflict_links = List.map fst prepared_conflicts in
    let* outcomes =
      attempt_outcomes_for_application ~workspace:workspace_link
        ~attempt:attempt_id ~conflicts:conflict_links current.application
    in
    let* resulting_snapshot, result_envelope =
      if
        Model.Snapshot.equal current.application.Workspace.resulting_snapshot
          current.base_snapshot
      then Ok (Record.workspace_revision_base current.revision, None)
      else
        let* reference, envelope =
          envelope_for repository ~nonce:nonces.attempt_result_nonce
            (Object.scratch_snapshot
               current.application.Workspace.resulting_snapshot)
        in
        Ok
          ( {
              Capsule.snapshot_id =
                Model.Snapshot.id
                  current.application.Workspace.resulting_snapshot;
              snapshot_ref = reference;
            },
            Some envelope )
    in
    let* attempt_record =
      Record.make_workspace_attempt ~id:attempt_id ~workspace:workspace_link
        ~base:(Record.workspace_revision_base current.revision)
        ~ordered ~resulting_snapshot ~outcomes ~conflicts:conflict_links
        ~created_at
      |> Result.map_error (fun error -> Record_error error)
    in
    let* attempt_ref, attempt_envelope =
      envelope_for repository ~nonce:nonces.attempt_nonce
        (Object.workspace_attempt attempt_record)
    in
    let* existing =
      resolve_attempt repository ~workspace:id ~attempt:attempt_id
    in
    match existing with
    | Some resolved ->
        if V2_model.Opaque_object_ref.equal resolved.attempt_ref attempt_ref
        then Ok (Attempt_already_published resolved)
        else Error (Attempt_id_already_bound attempt_id)
    | None -> (
        let* () =
          match result_envelope with
          | None -> Ok ()
          | Some envelope ->
              publish_object repository
                ~expected:resulting_snapshot.Capsule.snapshot_ref envelope
        in
        let* () = inject fault Fault.After_attempt_result in
        let* () = publish_conflicts repository prepared_conflicts in
        let* () = inject fault Fault.After_conflict_objects in
        let* () =
          publish_object repository ~expected:attempt_ref attempt_envelope
        in
        let* () = inject fault Fault.After_attempt_object in
        let* () = inject fault Fault.Before_binding in
        let* latest =
          resolve_attempt repository ~workspace:id ~attempt:attempt_id
        in
        match latest with
        | Some resolved ->
            if V2_model.Opaque_object_ref.equal resolved.attempt_ref attempt_ref
            then Ok (Attempt_already_published resolved)
            else Error (Attempt_id_already_bound attempt_id)
        | None -> (
            let* ref_name =
              attempt_ref_name ~workspace:id ~attempt:attempt_id
            in
            let* expected_event_id, ledger_envelope =
              binding_envelope repository ~ref_name ~predecessor:None
                ~target:attempt_ref ~nonce:nonces.attempt_binding_nonce
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
              let* resolved =
                resolve_attempt repository ~workspace:id ~attempt:attempt_id
              in
              match resolved with
              | Some resolved -> Ok (Attempt_published resolved)
              | None -> assert false))

let attempt ?fault repository ~id ~expected_revision ~expected_binding
    ~created_at ~nonces =
  with_shared_guard repository (fun () ->
      attempt_unlocked ?fault repository ~id ~expected_revision
        ~expected_binding ~created_at ~nonces)

let workspace_attempt_contains_conflict attempt link =
  List.exists (same_conflict_link link)
    (Record.workspace_attempt_conflicts attempt)

let resolve_skip_unlocked ?fault repository ~id ~expected_revision
    ~expected_binding ~(conflict : Record.conflict_link) ~created_at ~nonces =
  if not (distinct_resolution_nonces nonces) then Error Nonce_reuse
  else
    let* current = resolve repository ~id in
    let* current =
      match current with
      | Some current
        when current_matches current ~expected_revision ~expected_binding ->
          Ok current
      | other ->
          Error (stale_current_error ~expected_revision ~expected_binding other)
    in
    let current_link =
      workspace_revision_link ~workspace:current.workspace
        ~revision:current.revision ~revision_ref:current.revision_ref
    in
    let* conflict_record = load_conflict_link repository conflict in
    if
      not
        (same_workspace_revision_link
           (Record.conflict_workspace conflict_record)
           current_link)
    then Error (Conflict_not_in_workspace (Record.conflict_id conflict_record))
    else if
      not
        (List.exists
           (same_conflict_source conflict_record)
           current.application.Workspace.conflicts)
    then Error (Conflict_not_in_workspace (Record.conflict_id conflict_record))
    else
      let* persisted_attempt =
        resolve_attempt repository ~workspace:id
          ~attempt:(Record.conflict_attempt conflict_record)
      in
      let* persisted_attempt =
        match persisted_attempt with
        | Some attempt
          when workspace_attempt_contains_conflict attempt.attempt conflict ->
            Ok attempt
        | None | Some _ ->
            Error
              (Conflict_not_in_workspace (Record.conflict_id conflict_record))
      in
      ignore persisted_attempt;
      let action =
        Record.Skip_operation
          {
            revision = Record.conflict_revision conflict_record;
            operation_index = Record.conflict_operation_index conflict_record;
          }
      in
      let* resolution =
        Record.make_resolution ~conflict ~source:conflict_record
          ~workspace:current_link ~action ~created_at
        |> Result.map_error (fun error -> Record_error error)
      in
      let* resolution_ref, resolution_envelope =
        envelope_for repository ~nonce:nonces.resolve_resolution_nonce
          (Object.resolution resolution)
      in
      let resolution_link =
        Record.make_resolution_link
          ~id:(Record.resolution_id resolution)
          ~object_ref:resolution_ref
      in
      let resolutions =
        Record.make_resolution_binding ~conflict ~resolution:resolution_link
        :: Record.workspace_revision_resolutions current.revision
      in
      let* existing_actions =
        resolution_actions repository ~revision_link:current_link
          current.revision
      in
      let workspace_action =
        match action with
        | Record.Skip_operation { revision; operation_index } ->
            Workspace.Skip_operation { revision; operation_index }
      in
      ignore
        (Workspace.apply ~base:current.base_snapshot ~order:current.order
           ~resolutions:(workspace_action :: existing_actions));
      let* revision =
        Record.make_workspace_revision ~workspace:current.workspace
          ~workspace_ref:current.workspace_ref ~parent:(Some current_link)
          ~base:(Record.workspace_revision_base current.revision)
          ~selected:(Record.workspace_revision_selected current.revision)
          ~precedence:(Record.workspace_revision_precedence current.revision)
          ~resolved_order:
            (Record.workspace_revision_resolved_order current.revision)
          ~resolutions ~created_at
        |> Result.map_error (fun error -> Record_error error)
      in
      let* revision_ref, revision_envelope =
        envelope_for repository ~nonce:nonces.resolve_revision_nonce
          (Object.workspace_revision revision)
      in
      let* () =
        publish_object repository ~expected:resolution_ref resolution_envelope
      in
      let* () = inject fault Fault.After_resolution_object in
      let* () =
        publish_object repository ~expected:revision_ref revision_envelope
      in
      let* () = inject fault Fault.After_resolution_revision in
      let* () = inject fault Fault.Before_binding in
      let* latest = resolve repository ~id in
      match latest with
      | Some latest
        when current_matches latest ~expected_revision ~expected_binding -> (
          let* ref_name = workspace_ref_name id in
          let* expected_event_id, ledger_envelope =
            binding_envelope repository ~ref_name
              ~predecessor:(Some expected_binding) ~target:revision_ref
              ~nonce:nonces.resolve_binding_nonce
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

let resolve_skip ?fault repository ~id ~expected_revision ~expected_binding
    ~conflict ~created_at ~nonces =
  with_shared_guard repository (fun () ->
      resolve_skip_unlocked ?fault repository ~id ~expected_revision
        ~expected_binding ~conflict ~created_at ~nonces)
