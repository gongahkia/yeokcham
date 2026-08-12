module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Publication_guard = Yeokcham_v2_publication_guard
module Reclamation = Yeokcham_v2_reclamation
module Restore_journal = Yeokcham_v2_restore_journal
module Restore_journal_store = Yeokcham_v2_restore_journal_store
module Retention = Yeokcham_v2_retention
module Scratch_store = Yeokcham_v2_scratch_store
module Transaction_store = Yeokcham_v2_transaction_store
module Workspace_record = Yeokcham_v2_workspace_record
module Release_record = Yeokcham_v2_release_record

type repository = {
  root : string;
  objects : Object_store.repository;
  ledger : Ledger_store.repository;
  restores : Restore_journal_store.repository;
  transactions : Transaction_store.repository;
  scratch : Scratch_store.repository;
  repository_id : Model.Repository_id.t;
  device_id : Model.Device_id.t;
}

type publication = Manifest_published | Manifest_already_published

module Fault = struct
  type boundary = Before_candidate of int | After_candidate of int
  type t = boundary

  let before_candidate index = Before_candidate index
  let after_candidate index = After_candidate index
end

type cleanup_report = {
  plan_id : string;
  quarantined_objects : int;
  quarantined_bytes : int64;
  already_quarantined_objects : int;
  pruned_objects : int;
  pruned_bytes : int64;
  already_pruned_objects : int;
}

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Bootstrap.error
  | Object_store_error of Object_store.error
  | Ledger_store_error of Ledger_store.error
  | Restore_journal_store_error of Restore_journal_store.error
  | Transaction_store_error of Transaction_store.error
  | Scratch_store_error of Scratch_store.error
  | Publication_guard_error of Publication_guard.error
  | Reclamation_error of Reclamation.error
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_manifest_path of string
  | Manifest_collision of string
  | Manifest_changed of string
  | Missing_manifest of string
  | Stale_manifest of {
      expected_root_digest : string;
      actual_root_digest : string;
    }
  | Stale_plan of { expected_plan_id : string; actual_plan_id : string }
  | Unknown_ledger_scope of string
  | Divergent_ledger_scope of string
  | Ledger_event_id_collision of Ledger.Event_id.t
  | Missing_ledger_event of Ledger.Event_id.t
  | Active_generation_target_not_manifest of Model.Opaque_object_ref.t
  | Active_generation_ref_invalid of string
  | Ledger_root_missing_target of { scope : string; event : Ledger.Event_id.t }
  | Candidate_became_reachable of Model.Opaque_object_ref.t
  | Candidate_changed of Model.Opaque_object_ref.t
  | Direct_link_kind_mismatch of {
      source : Model.Opaque_object_ref.t;
      target : Model.Opaque_object_ref.t;
      expected : Object.kind;
      actual : Object.kind;
    }
  | Fault_injected of Fault.boundary

type raw_object = {
  object_ref : Model.Opaque_object_ref.t;
  object_kind : Object.kind;
  stored_bytes : int64;
  object_ : Object.t;
}

type ledger_object = {
  raw : raw_object;
  verified : Ledger.verified;
  event : Ledger.t;
  ref_name : Ledger.Ref_name.t;
}

let max_manifest_bytes = 1024 * 1024
let max_temporary_attempts = 32
let ( let* ) = Result.bind

let rec error_to_string = function
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Ledger_store_error error -> Ledger_store.error_to_string error
  | Restore_journal_store_error error ->
      Restore_journal_store.error_to_string error
  | Transaction_store_error error -> Transaction_store.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error
  | Publication_guard_error error -> Publication_guard.error_to_string error
  | Reclamation_error error -> Reclamation.error_to_string error
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Invalid_manifest_path path ->
      "invalid V2 reclamation manifest path: " ^ path
  | Manifest_collision path ->
      "V2 reclamation manifest path contains different bytes: " ^ path
  | Manifest_changed path ->
      "V2 reclamation manifest changed while being read: " ^ path
  | Missing_manifest plan_id -> "V2 reclamation manifest is missing: " ^ plan_id
  | Stale_manifest { expected_root_digest; actual_root_digest } ->
      Printf.sprintf "V2 reclamation root digest changed: %s != %s"
        (hex expected_root_digest) (hex actual_root_digest)
  | Stale_plan { expected_plan_id; actual_plan_id } ->
      Printf.sprintf "V2 reclamation plan changed: %s != %s"
        (hex expected_plan_id) (hex actual_plan_id)
  | Unknown_ledger_scope name ->
      "unknown V2 ledger scope blocks reclamation: " ^ name
  | Divergent_ledger_scope name ->
      "divergent V2 ledger scope blocks reclamation: " ^ name
  | Ledger_event_id_collision event_id ->
      "V2 ledger event ID has multiple physical objects: "
      ^ Ledger.Event_id.to_hex event_id
  | Missing_ledger_event event_id ->
      "V2 reclamation cannot resolve ledger event: "
      ^ Ledger.Event_id.to_hex event_id
  | Active_generation_target_not_manifest object_ref ->
      "active V2 scratch generation targets a non-generation object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Active_generation_ref_invalid name ->
      "active V2 scratch generation names invalid compact scope: " ^ name
  | Ledger_root_missing_target { scope; event } ->
      "V2 reclamation root event "
      ^ Ledger.Event_id.to_hex event
      ^ " has no target in scope " ^ scope
  | Candidate_became_reachable object_ref ->
      "V2 reclamation candidate became reachable: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Candidate_changed object_ref ->
      "V2 reclamation candidate changed or has wrong type: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Direct_link_kind_mismatch { source; target; expected; actual } ->
      Printf.sprintf "V2 reclamation object %s links %s as kind %Ld, found %Ld"
        (Model.Opaque_object_ref.to_hex source)
        (Model.Opaque_object_ref.to_hex target)
        (kind_code expected) (kind_code actual)
  | Fault_injected (Fault.Before_candidate index) ->
      Printf.sprintf "V2 reclamation fault before candidate %d" index
  | Fault_injected (Fault.After_candidate index) ->
      Printf.sprintf "V2 reclamation fault after candidate %d" index

and hex bytes =
  let digits = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index byte ->
      let value = Char.code byte in
      Bytes.set output (index * 2) digits.[value lsr 4];
      Bytes.set output ((index * 2) + 1) digits.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string output

and kind_code = function
  | Object.Ledger_event -> 0L
  | Object.Scratch_snapshot -> 1L
  | Object.Scratch_protection -> 2L
  | Object.Scratch_generation -> 3L
  | Object.Capsule -> 4L
  | Object.Capsule_revision -> 5L
  | Object.Workspace -> 6L
  | Object.Workspace_revision -> 7L
  | Object.Workspace_attempt -> 8L
  | Object.Conflict -> 9L
  | Object.Resolution -> 10L
  | Object.Validation_evidence -> 11L
  | Object.Release -> 12L

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

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
  let repository_id = Bootstrap.repository_id record in
  let* objects =
    Object_store.open_repository ~root ~repository_id
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* ledger =
    Ledger_store.open_repository ~root ~repository_id
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
      ~public_keys
    |> Result.map_error (fun error -> Ledger_store_error error)
  in
  let* restores =
    Restore_journal_store.open_repository ~root ~repository_id
    |> Result.map_error (fun error -> Restore_journal_store_error error)
  in
  let* transactions =
    Transaction_store.open_repository ~root ~repository_id
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
      ~public_keys
    |> Result.map_error (fun error -> Transaction_store_error error)
  in
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  Ok
    {
      root;
      objects;
      ledger;
      restores;
      transactions;
      scratch;
      repository_id;
      device_id = Bootstrap.device_id record;
    }

let ref_compare = Model.Opaque_object_ref.compare

let rec find_raw raw_objects object_ref =
  match raw_objects with
  | [] -> Error (Reclamation_error (Reclamation.Missing_object object_ref))
  | raw :: rest ->
      if ref_compare raw.object_ref object_ref = 0 then Ok raw
      else find_raw rest object_ref

let find_raw_opt raw_objects object_ref =
  List.find_opt
    (fun raw -> ref_compare raw.object_ref object_ref = 0)
    raw_objects

let load_raw_objects repository =
  let* object_refs =
    Object_store.list_object_refs repository.objects
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let rec load result = function
    | [] -> Ok (List.rev result)
    | object_ref :: rest ->
        let* object_ =
          Object_store.load repository.objects ~object_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        let* stored_bytes =
          Object_store.stored_bytes repository.objects ~object_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        load
          ({
             object_ref;
             object_kind = Object.kind object_;
             stored_bytes;
             object_;
           }
          :: result)
          rest
  in
  load [] object_refs

let is_hex value =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let suffix_is_hex ~prefix ~length value =
  String.length value = String.length prefix + length
  && String.starts_with ~prefix value
  && is_hex (String.sub value (String.length prefix) length)

let compact_scope ~device value =
  let prefix = "scratch-compact-" ^ Model.Device_id.to_hex device ^ "-" in
  suffix_is_hex ~prefix ~length:64 value

let known_scope ~device value =
  let device_hex = Model.Device_id.to_hex device in
  String.equal value ("scratch-" ^ device_hex)
  || String.equal value ("scratch-protection-" ^ device_hex)
  || String.equal value ("scratch-generation-" ^ device_hex)
  || compact_scope ~device value
  || suffix_is_hex ~prefix:"capsule-" ~length:64 value
  || suffix_is_hex ~prefix:"workspace-" ~length:64 value
  || suffix_is_hex ~prefix:"release-" ~length:64 value
  ||
  let prefix = "workspace-attempt-" in
  String.length value = String.length prefix + 129
  && String.starts_with ~prefix value
  && is_hex (String.sub value (String.length prefix) 64)
  && Char.equal value.[String.length prefix + 64] '-'
  && is_hex (String.sub value (String.length prefix + 65) 64)

let load_ledger_objects repository raw_objects =
  let rec load result = function
    | [] -> Ok (List.rev result)
    | raw :: rest -> (
        match Object.ledger raw.object_ with
        | None -> load result rest
        | Some _ ->
            let* verified =
              Ledger_store.load repository.ledger ~object_ref:raw.object_ref
              |> Result.map_error (fun error -> Ledger_store_error error)
            in
            let event = Ledger.verified_event verified in
            let ref_name =
              Ledger.unsigned_ref_name (Ledger.event_unsigned event)
            in
            let scope = Ledger.Ref_name.to_string ref_name in
            if not (known_scope ~device:repository.device_id scope) then
              Error (Unknown_ledger_scope scope)
            else load ({ raw; verified; event; ref_name } :: result) rest)
  in
  load [] raw_objects

let event_ref ledger_objects event_id =
  let matches =
    List.filter
      (fun entry ->
        Ledger.Event_id.equal (Ledger.event_id entry.event) event_id)
      ledger_objects
  in
  match matches with
  | [] -> Error (Missing_ledger_event event_id)
  | [ entry ] -> Ok entry.raw.object_ref
  | _ -> Error (Ledger_event_id_collision event_id)

let required_link raw_objects ~source ~expected target =
  let* target_raw = find_raw raw_objects target in
  if target_raw.object_kind = expected then Ok target
  else
    Error
      (Direct_link_kind_mismatch
         { source; target; expected; actual = target_raw.object_kind })

let existing_link raw_objects target =
  let* _ = find_raw raw_objects target in
  Ok target

let snapshot_link raw_objects ~source (link : Capsule.snapshot_link) =
  required_link raw_objects ~source ~expected:Object.Scratch_snapshot
    link.Capsule.snapshot_ref

let revision_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Capsule_revision
    (Capsule.revision_link_ref link)

let workspace_revision_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Workspace_revision
    (Workspace_record.workspace_revision_link_ref link)

let conflict_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Conflict
    (Workspace_record.conflict_link_ref link)

let resolution_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Resolution
    (Workspace_record.resolution_link_ref link)

let evidence_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Validation_evidence
    (Release_record.validation_evidence_link_ref link)

let release_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Release
    (Release_record.release_link_ref link)

let attempt_link raw_objects ~source link =
  required_link raw_objects ~source ~expected:Object.Workspace_attempt
    (Release_record.workspace_attempt_link_ref link)

let rec all result = function
  | [] -> Ok (List.rev result)
  | value :: rest ->
      let* value = value in
      all (value :: result) rest

let provenance_links raw_objects ~source = function
  | Capsule.Created -> Ok []
  | Capsule.Folded link ->
      revision_link raw_objects ~source link |> Result.map List.singleton
  | Capsule.Split_from links | Capsule.Combined_from links ->
      List.map (revision_link raw_objects ~source) links |> all []

let links_for_nonledger raw_objects ledger_objects raw =
  let source = raw.object_ref in
  match raw.object_kind with
  | Object.Ledger_event ->
      let entry =
        List.find
          (fun entry -> ref_compare entry.raw.object_ref source = 0)
          ledger_objects
      in
      let unsigned = Ledger.event_unsigned entry.event in
      let predecessor = Ledger.unsigned_predecessor unsigned in
      let* predecessor =
        match predecessor with
        | None -> Ok []
        | Some event_id ->
            event_ref ledger_objects event_id |> Result.map List.singleton
      in
      let target = Ledger.unsigned_target unsigned in
      let* target =
        match target with
        | None -> Ok []
        | Some target ->
            existing_link raw_objects
              (Ledger.Ref_target.to_opaque_object_ref target)
            |> Result.map List.singleton
      in
      Ok (predecessor @ target)
  | Object.Scratch_snapshot | Object.Capsule | Object.Workspace -> Ok []
  | Object.Scratch_protection ->
      let protection =
        match Object.protection raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let* snapshot =
        required_link raw_objects ~source ~expected:Object.Scratch_snapshot
          protection.Retention.protected_snapshot_ref
      in
      let* binding =
        match protection.Retention.protection_reason with
        | Retention.User_pin -> Ok []
        | Retention.Capsule_boundary object_ref
        | Retention.Release_boundary object_ref ->
            existing_link raw_objects object_ref |> Result.map List.singleton
      in
      Ok (snapshot :: binding)
  | Object.Scratch_generation ->
      let generation =
        match Object.generation raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      event_ref ledger_objects generation.Retention.active_anchor
      |> Result.map List.singleton
  | Object.Capsule_revision ->
      let revision =
        match Object.capsule_revision_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let links =
        [
          required_link raw_objects ~source ~expected:Object.Capsule
            (Capsule.revision_capsule_ref revision);
          snapshot_link raw_objects ~source
            (Capsule.revision_declared_base revision);
          snapshot_link raw_objects ~source
            (Capsule.revision_expected_result revision);
        ]
        @ List.map
            (fun boundary ->
              snapshot_link raw_objects ~source boundary.Capsule.source_snapshot)
            (Capsule.revision_source_boundaries revision)
        @ List.map
            (fun boundary ->
              snapshot_link raw_objects ~source boundary.Capsule.target_snapshot)
            (Capsule.revision_source_boundaries revision)
      in
      let* links = all [] links in
      let* parent =
        match Capsule.revision_parent revision with
        | None -> Ok []
        | Some link ->
            revision_link raw_objects ~source link |> Result.map List.singleton
      in
      let* provenance =
        provenance_links raw_objects ~source
          (Capsule.revision_provenance revision)
      in
      Ok (links @ parent @ provenance)
  | Object.Workspace_revision ->
      let revision =
        match Object.workspace_revision_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let links =
        [
          required_link raw_objects ~source ~expected:Object.Workspace
            (Workspace_record.workspace_revision_workspace_ref revision);
          snapshot_link raw_objects ~source
            (Workspace_record.workspace_revision_base revision);
        ]
        @ List.map
            (revision_link raw_objects ~source)
            (Workspace_record.workspace_revision_selected revision)
        @ List.map
            (revision_link raw_objects ~source)
            (Workspace_record.workspace_revision_resolved_order revision)
        @ List.concat_map
            (fun binding ->
              [
                conflict_link raw_objects ~source
                  (Workspace_record.resolution_binding_conflict binding);
                resolution_link raw_objects ~source
                  (Workspace_record.resolution_binding_resolution binding);
              ])
            (Workspace_record.workspace_revision_resolutions revision)
      in
      let* links = all [] links in
      let* parent =
        match Workspace_record.workspace_revision_parent revision with
        | None -> Ok []
        | Some link ->
            workspace_revision_link raw_objects ~source link
            |> Result.map List.singleton
      in
      Ok (links @ parent)
  | Object.Workspace_attempt ->
      let attempt =
        match Object.workspace_attempt_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let links =
        [
          workspace_revision_link raw_objects ~source
            (Workspace_record.workspace_attempt_workspace attempt);
          snapshot_link raw_objects ~source
            (Workspace_record.workspace_attempt_base attempt);
          snapshot_link raw_objects ~source
            (Workspace_record.workspace_attempt_resulting_snapshot attempt);
        ]
        @ List.map
            (revision_link raw_objects ~source)
            (Workspace_record.workspace_attempt_ordered attempt)
        @ List.map
            (conflict_link raw_objects ~source)
            (Workspace_record.workspace_attempt_conflicts attempt)
      in
      all [] links
  | Object.Conflict ->
      let conflict =
        match Object.conflict_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      all []
        [
          workspace_revision_link raw_objects ~source
            (Workspace_record.conflict_workspace conflict);
          revision_link raw_objects ~source
            (Workspace_record.conflict_revision conflict);
        ]
  | Object.Resolution ->
      let resolution =
        match Object.resolution_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let action = Workspace_record.resolution_action resolution in
      let* revision =
        match action with
        | Workspace_record.Skip_operation { revision; _ } ->
            revision_link raw_objects ~source revision
      in
      all []
        [
          conflict_link raw_objects ~source
            (Workspace_record.resolution_conflict resolution);
          workspace_revision_link raw_objects ~source
            (Workspace_record.resolution_workspace resolution);
          Ok revision;
        ]
  | Object.Validation_evidence ->
      let evidence =
        match Object.validation_evidence_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      snapshot_link raw_objects ~source
        (Release_record.validation_evidence_snapshot evidence)
      |> Result.map List.singleton
  | Object.Release ->
      let release =
        match Object.release_record raw.object_ with
        | Some value -> value
        | None -> assert false
      in
      let links =
        List.map
          (release_link raw_objects ~source)
          (Release_record.release_parents release)
        @ [
            workspace_revision_link raw_objects ~source
              (Release_record.release_workspace release);
            attempt_link raw_objects ~source
              (Release_record.release_attempt release);
            snapshot_link raw_objects ~source
              (Release_record.release_base release);
            snapshot_link raw_objects ~source
              (Release_record.release_final_snapshot release);
          ]
        @ List.map
            (revision_link raw_objects ~source)
            (Release_record.release_capsules release)
        @ List.concat_map
            (fun binding ->
              [
                conflict_link raw_objects ~source
                  (Workspace_record.resolution_binding_conflict binding);
                resolution_link raw_objects ~source
                  (Workspace_record.resolution_binding_resolution binding);
              ])
            (Release_record.release_resolutions release)
        @ List.map
            (evidence_link raw_objects ~source)
            (Release_record.release_evidence release)
      in
      all [] links

let inventory_entries raw_objects ledger_objects =
  let rec build result = function
    | [] -> Ok (List.rev result)
    | raw :: rest ->
        let* links = links_for_nonledger raw_objects ledger_objects raw in
        let* entry =
          Reclamation.object_entry ~object_ref:raw.object_ref
            ~object_kind:raw.object_kind ~stored_bytes:raw.stored_bytes
            ~direct_links:links
          |> Result.map_error (fun error -> Reclamation_error error)
        in
        build (entry :: result) rest
  in
  build [] raw_objects

let ref_name value =
  Ledger.Ref_name.of_string value
  |> Result.map_error (fun _ -> Active_generation_ref_invalid value)

let sole_head repository ledger_objects ref_name =
  let events =
    List.filter
      (fun entry -> Ledger.Ref_name.equal entry.ref_name ref_name)
      ledger_objects
  in
  match events with
  | [] -> Ok None
  | _ -> (
      let* evaluated =
        Ledger.evaluate ~repository_id:repository.repository_id ~ref_name
          (List.map (fun entry -> entry.verified) events)
        |> Result.map_error (fun _ ->
            Divergent_ledger_scope (Ledger.Ref_name.to_string ref_name))
      in
      match Ledger.heads evaluated with
      | [] -> Ok None
      | [ verified ] ->
          let event = Ledger.verified_event verified in
          event_ref ledger_objects (Ledger.event_id event)
          |> Result.map Option.some
      | _ -> Error (Divergent_ledger_scope (Ledger.Ref_name.to_string ref_name))
      )

let scope_prefix prefix value = String.starts_with ~prefix value

let binding_expected_kind value =
  if scope_prefix "capsule-" value then Some Object.Capsule_revision
  else if scope_prefix "workspace-attempt-" value then
    Some Object.Workspace_attempt
  else if scope_prefix "workspace-" value then Some Object.Workspace_revision
  else if scope_prefix "release-" value then Some Object.Release
  else None

let root_target raw_objects ledger_objects ~scope ~expected root_event_ref =
  let* raw = find_raw raw_objects root_event_ref in
  let ledger =
    match Object.ledger raw.object_ with
    | Some value -> value
    | None -> assert false
  in
  let event = Ledger.event_id ledger in
  let* target =
    match Ledger.unsigned_target (Ledger.event_unsigned ledger) with
    | Some target -> Ok (Ledger.Ref_target.to_opaque_object_ref target)
    | None -> Error (Ledger_root_missing_target { scope; event })
  in
  let* _ = required_link raw_objects ~source:root_event_ref ~expected target in
  let* _ = event_ref ledger_objects event in
  Ok ()

let roots_for_ledger repository raw_objects ledger_objects =
  let device = Model.Device_id.to_hex repository.device_id in
  let* protection = ref_name ("scratch-protection-" ^ device) in
  let* generation = ref_name ("scratch-generation-" ^ device) in
  let* protection_head = sole_head repository ledger_objects protection in
  let* generation_head = sole_head repository ledger_objects generation in
  let* active_ref =
    Scratch_store.active_scratch_ref_name repository.scratch
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* scratch_head = sole_head repository ledger_objects active_ref in
  let binding_scopes =
    ledger_objects
    |> List.map (fun entry -> entry.ref_name)
    |> List.sort_uniq Ledger.Ref_name.compare
    |> List.filter (fun name ->
        let value = Ledger.Ref_name.to_string name in
        Option.is_some (binding_expected_kind value))
  in
  let* bindings =
    List.map (sole_head repository ledger_objects) binding_scopes |> all []
  in
  let* _ =
    List.map
      (fun (scope, expected, root) ->
        match root with
        | None -> Ok ()
        | Some event_ref ->
            root_target raw_objects ledger_objects
              ~scope:(Ledger.Ref_name.to_string scope)
              ~expected event_ref)
      [
        (protection, Object.Scratch_protection, protection_head);
        (generation, Object.Scratch_generation, generation_head);
        (active_ref, Object.Scratch_snapshot, scratch_head);
      ]
    |> all []
  in
  let* _ =
    List.map2
      (fun scope root ->
        match
          (binding_expected_kind (Ledger.Ref_name.to_string scope), root)
        with
        | Some expected, Some event_ref ->
            root_target raw_objects ledger_objects
              ~scope:(Ledger.Ref_name.to_string scope)
              ~expected event_ref
        | Some _, None -> Ok ()
        | None, _ -> assert false)
      binding_scopes bindings
    |> all []
  in
  Ok
    (List.filter_map
       (fun root -> root)
       (protection_head :: generation_head :: scratch_head :: bindings))

let recovery_roots repository =
  let* restores =
    Restore_journal_store.scan repository.restores
    |> Result.map_error (fun error -> Restore_journal_store_error error)
  in
  let restore_roots =
    restores
    |> List.filter_map (fun record ->
        match Restore_journal.phase record with
        | Restore_journal.Published -> None
        | Restore_journal.Prepared | Restore_journal.Applying _
        | Restore_journal.Materialized ->
            Some
              [
                Restore_journal.safety_snapshot record;
                Restore_journal.target_snapshot record;
              ])
    |> List.concat
  in
  let* transactions =
    Transaction_store.recovery_object_refs repository.transactions
    |> Result.map_error (fun error -> Transaction_store_error error)
  in
  Ok (restore_roots @ transactions)

let gather repository =
  let* raw_objects = load_raw_objects repository in
  let* ledger_objects = load_ledger_objects repository raw_objects in
  let* entries = inventory_entries raw_objects ledger_objects in
  let* ledger_roots = roots_for_ledger repository raw_objects ledger_objects in
  let* recovery_roots = recovery_roots repository in
  Ok (raw_objects, entries, ledger_roots @ recovery_roots)

let with_exclusive repository action =
  Publication_guard.with_guard ~root:repository.root
    ~mode:Publication_guard.Exclusive action
  |> Result.map_error (fun error -> Publication_guard_error error)
  |> Result.join

let plan_unlocked repository ~cache_budget_bytes =
  let* _, entries, roots = gather repository in
  Reclamation.make_plan ~objects:entries ~roots ~cache_budget_bytes
  |> Result.map_error (fun error -> Reclamation_error error)

let plan repository ~cache_budget_bytes =
  with_exclusive repository (fun () ->
      plan_unlocked repository ~cache_budget_bytes)

let plan_hex plan = Reclamation.plan_id plan |> hex
let valid_plan_hex value = String.length value = 64 && is_hex value

let reclamation_directory repository =
  Filename.concat repository.root ".yeokcham/reclamation"

let manifest_path repository ~plan_id =
  let plan_id = hex plan_id in
  if not (valid_plan_hex plan_id) then Error (Invalid_manifest_path plan_id)
  else
    Ok
      (Filename.concat
         (Filename.concat (reclamation_directory repository) plan_id)
         "manifest.cbor")

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        try
          Unix.fsync descriptor;
          Ok ()
        with
        | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _)
          ->
            Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"fsync" ~path error))
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"open" ~path error)

let rec ensure_directory path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_DIR then Ok ()
    else Error (Invalid_manifest_path path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> (
      try
        Unix.mkdir path 0o700;
        fsync_directory (Filename.dirname path)
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory path
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"mkdir" ~path error))
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let write_all descriptor bytes =
  let rec loop offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let written =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if written = 0 then
          Error
            (Io_error
               {
                 operation = "write";
                 path = "";
                 message = "write returned zero";
               })
        else loop (offset + written)
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"write" ~path:"" error)
  in
  loop 0

let read_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_manifest_path path)
    else if stat.Unix.st_size > max_manifest_bytes then
      Error (Invalid_manifest_path path)
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let bytes = Bytes.create stat.Unix.st_size in
          let rec loop offset =
            if offset = Bytes.length bytes then
              Ok (Bytes.unsafe_to_string bytes)
            else
              try
                let count =
                  Unix.read descriptor bytes offset (Bytes.length bytes - offset)
                in
                if count = 0 then Error (Manifest_changed path)
                else loop (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"read" ~path error)
          in
          loop 0)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Missing_manifest path)
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let temporary_manifest_path directory plan_hex attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.manifest-%d-%d" plan_hex (Unix.getpid ()) attempt)

let create_manifest path plan_hex bytes =
  let directory = Filename.dirname path in
  let rec write attempt =
    if attempt = max_temporary_attempts then Error (Manifest_collision path)
    else
      let temporary = temporary_manifest_path directory plan_hex attempt in
      try
        let descriptor =
          Unix.openfile temporary
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
            0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () = write_all descriptor (Bytes.unsafe_of_string bytes) in
              try
                Unix.fsync descriptor;
                Ok ()
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path:temporary error))
        in
        match result with
        | Error error ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            Error error
        | Ok () -> (
            try
              Unix.link temporary path;
              let* () = fsync_directory directory in
              Unix.unlink temporary;
              let* () = fsync_directory directory in
              Ok Manifest_published
            with
            | Unix.Unix_error (Unix.EEXIST, _, _) ->
                Unix.unlink temporary;
                let* existing = read_regular_file path in
                if String.equal existing bytes then
                  Ok Manifest_already_published
                else Error (Manifest_collision path)
            | Unix.Unix_error (error, _, _) ->
                (try Unix.unlink temporary with Unix.Unix_error _ -> ());
                Error (io_error ~operation:"link" ~path error))
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> write (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path:temporary error)
  in
  write 0

let publish_manifest repository plan =
  with_exclusive repository (fun () ->
      let* current =
        plan_unlocked repository
          ~cache_budget_bytes:(Reclamation.cache_budget_bytes plan)
      in
      if
        not
          (String.equal
             (Reclamation.plan_id current)
             (Reclamation.plan_id plan))
      then
        Error
          (Stale_plan
             {
               expected_plan_id = Reclamation.plan_id plan;
               actual_plan_id = Reclamation.plan_id current;
             })
      else
        let* path =
          manifest_path repository ~plan_id:(Reclamation.plan_id plan)
        in
        let* () = ensure_directory (reclamation_directory repository) in
        let* () = ensure_directory (Filename.dirname path) in
        create_manifest path (plan_hex plan) (Reclamation.encode_manifest plan))

let load_manifest repository ~plan_id =
  let* path = manifest_path repository ~plan_id in
  let* bytes = read_regular_file path in
  let* plan =
    Reclamation.decode_manifest bytes
    |> Result.map_error (fun error -> Reclamation_error error)
  in
  if String.equal plan_id (Reclamation.plan_id plan) then Ok plan
  else Error (Invalid_manifest_path path)

let validate_manifest_unlocked repository plan =
  let* raw_objects, entries, roots = gather repository in
  let* marked, actual_root_digest =
    Reclamation.mark ~objects:entries ~roots
    |> Result.map_error (fun error -> Reclamation_error error)
  in
  if not (String.equal (Reclamation.root_digest plan) actual_root_digest) then
    Error
      (Stale_manifest
         {
           expected_root_digest = Reclamation.root_digest plan;
           actual_root_digest;
         })
  else Ok (raw_objects, entries, marked)

let candidate_is_marked marked candidate =
  List.exists
    (fun object_ref ->
      Model.Opaque_object_ref.equal object_ref
        (Reclamation.candidate_object_ref candidate))
    marked

let validate_live_candidate raw_objects marked candidate =
  if candidate_is_marked marked candidate then
    Error
      (Candidate_became_reachable (Reclamation.candidate_object_ref candidate))
  else
    match
      find_raw_opt raw_objects (Reclamation.candidate_object_ref candidate)
    with
    | None -> Ok ()
    | Some raw ->
        if
          raw.object_kind = Reclamation.candidate_kind candidate
          && Int64.equal raw.stored_bytes
               (Reclamation.candidate_stored_bytes candidate)
        then Ok ()
        else Error (Candidate_changed raw.object_ref)

let empty_report plan =
  {
    plan_id = Reclamation.plan_id plan;
    quarantined_objects = 0;
    quarantined_bytes = 0L;
    already_quarantined_objects = 0;
    pruned_objects = 0;
    pruned_bytes = 0L;
    already_pruned_objects = 0;
  }

let fault_at fault boundary =
  match fault with
  | Some value when value = boundary -> Error (Fault_injected boundary)
  | _ -> Ok ()

let resume_quarantine ?fault repository ~plan_id =
  with_exclusive repository (fun () ->
      let* plan = load_manifest repository ~plan_id in
      let* raw_objects, _entries, marked =
        validate_manifest_unlocked repository plan
      in
      let generation = plan_hex plan in
      let rec move report index = function
        | [] -> Ok report
        | candidate :: rest ->
            let* () = fault_at fault (Fault.Before_candidate index) in
            let* () = validate_live_candidate raw_objects marked candidate in
            let* outcome =
              Object_store.quarantine repository.objects ~generation
                ~object_ref:(Reclamation.candidate_object_ref candidate)
                ~expected_kind:(Reclamation.candidate_kind candidate)
              |> Result.map_error (fun error -> Object_store_error error)
            in
            let report =
              match outcome with
              | Object_store.Quarantined bytes ->
                  {
                    report with
                    quarantined_objects = report.quarantined_objects + 1;
                    quarantined_bytes = Int64.add report.quarantined_bytes bytes;
                  }
              | Object_store.Already_quarantined _ ->
                  {
                    report with
                    already_quarantined_objects =
                      report.already_quarantined_objects + 1;
                  }
            in
            let* () = fault_at fault (Fault.After_candidate index) in
            move report (index + 1) rest
      in
      move (empty_report plan) 0 (Reclamation.candidates plan))

let prune_quarantine ?fault repository ~plan_id =
  with_exclusive repository (fun () ->
      let* plan = load_manifest repository ~plan_id in
      let* raw_objects, _entries, marked =
        validate_manifest_unlocked repository plan
      in
      let generation = plan_hex plan in
      let rec prune report index = function
        | [] -> Ok report
        | candidate :: rest ->
            let* () = fault_at fault (Fault.Before_candidate index) in
            let* () = validate_live_candidate raw_objects marked candidate in
            let* outcome =
              Object_store.prune_quarantine repository.objects ~generation
                ~object_ref:(Reclamation.candidate_object_ref candidate)
                ~expected_kind:(Reclamation.candidate_kind candidate)
              |> Result.map_error (fun error -> Object_store_error error)
            in
            let report =
              match outcome with
              | Object_store.Pruned bytes ->
                  {
                    report with
                    pruned_objects = report.pruned_objects + 1;
                    pruned_bytes = Int64.add report.pruned_bytes bytes;
                  }
              | Object_store.Already_pruned ->
                  {
                    report with
                    already_pruned_objects = report.already_pruned_objects + 1;
                  }
            in
            let* () = fault_at fault (Fault.After_candidate index) in
            prune report (index + 1) rest
      in
      prune (empty_report plan) 0 (Reclamation.candidates plan))
