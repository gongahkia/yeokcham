module Envelope = Paengi_envelope
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

module Object_set = Set.Make (struct
  type t = Store.Stored_object_id.t

  let compare = Store.Stored_object_id.compare
end)

module Int64_map = Map.Make (Int64)

module Policy = struct
  type t = {
    recent_window_seconds : int64;
    periodic_interval_seconds : int64;
    storage_budget_bytes : int64 option;
  }

  type error =
    | Negative_recent_window of int64
    | Negative_periodic_interval of int64
    | Negative_storage_budget of int64

  type decision =
    | Protected_by of Scratch.retention_reason
    | Recent_window
    | Periodic_bucket of int64
    | Expired

  type checkpoint = {
    id : Scratch.Checkpoint_id.t;
    created_at : int64;
    effective_retention : Scratch.retention_reason list;
  }

  type selection = { checkpoint : checkpoint; decision : decision }

  let error_to_string = function
    | Negative_recent_window value ->
        Printf.sprintf "recent window must be non-negative, got %Ld" value
    | Negative_periodic_interval value ->
        Printf.sprintf "periodic interval must be non-negative, got %Ld" value
    | Negative_storage_budget value ->
        Printf.sprintf "storage budget must be non-negative, got %Ld" value

  let create ~recent_window_seconds ~periodic_interval_seconds
      ~storage_budget_bytes =
    if Int64.compare recent_window_seconds 0L < 0 then
      Error (Negative_recent_window recent_window_seconds)
    else if Int64.compare periodic_interval_seconds 0L < 0 then
      Error (Negative_periodic_interval periodic_interval_seconds)
    else
      match storage_budget_bytes with
      | Some value when Int64.compare value 0L < 0 ->
          Error (Negative_storage_budget value)
      | None | Some _ ->
          Ok
            {
              recent_window_seconds;
              periodic_interval_seconds;
              storage_budget_bytes;
            }

  let default =
    match
      create
        ~recent_window_seconds:(Int64.of_int (3 * 24 * 60 * 60))
        ~periodic_interval_seconds:(Int64.of_int (7 * 24 * 60 * 60))
        ~storage_budget_bytes:None
    with
    | Ok policy -> policy
    | Error _ -> assert false

  let recent_window_seconds policy = policy.recent_window_seconds
  let periodic_interval_seconds policy = policy.periodic_interval_seconds
  let storage_budget_bytes policy = policy.storage_budget_bytes

  let protected_reason reasons =
    List.find_opt
      (function
        | Scratch.Recent_window -> false
        | Scratch.User_pinned | Scratch.Capsule_boundary _
        | Scratch.Release_boundary _ | Scratch.Validation_passed _
        | Scratch.Periodic_retention | Scratch.Conflict_reference _ ->
            true)
      reasons

  let recent policy ~now checkpoint =
    let earliest = Int64.add Int64.min_int policy.recent_window_seconds in
    let cutoff =
      if Int64.compare now earliest <= 0 then Int64.min_int
      else Int64.sub now policy.recent_window_seconds
    in
    Int64.compare checkpoint.created_at cutoff >= 0

  let id_compare left right =
    Store.Stored_object_id.compare
      (Scratch.Checkpoint_id.stored_object_id left)
      (Scratch.Checkpoint_id.stored_object_id right)

  let newer left right =
    let timestamp = Int64.compare left.created_at right.created_at in
    timestamp > 0 || (timestamp = 0 && id_compare left.id right.id > 0)

  let select policy ~now checkpoints =
    let preliminary checkpoint =
      match protected_reason checkpoint.effective_retention with
      | Some reason -> Protected_by reason
      | None when recent policy ~now checkpoint -> Recent_window
      | None -> Expired
    in
    let buckets =
      if Int64.equal policy.periodic_interval_seconds 0L then Int64_map.empty
      else
        List.fold_left
          (fun buckets checkpoint ->
            match preliminary checkpoint with
            | Protected_by _ | Recent_window -> buckets
            | Expired | Periodic_bucket _ -> (
                let bucket =
                  Int64.div checkpoint.created_at
                    policy.periodic_interval_seconds
                in
                match Int64_map.find_opt bucket buckets with
                | None -> Int64_map.add bucket checkpoint buckets
                | Some selected when newer checkpoint selected ->
                    Int64_map.add bucket checkpoint buckets
                | Some _ -> buckets))
          Int64_map.empty checkpoints
    in
    List.map
      (fun checkpoint ->
        let decision =
          match preliminary checkpoint with
          | (Protected_by _ | Recent_window) as decision -> decision
          | Expired | Periodic_bucket _ -> (
              if Int64.equal policy.periodic_interval_seconds 0L then Expired
              else
                let bucket =
                  Int64.div checkpoint.created_at
                    policy.periodic_interval_seconds
                in
                match Int64_map.find_opt bucket buckets with
                | Some selected
                  when Scratch.Checkpoint_id.equal selected.id checkpoint.id ->
                    Periodic_bucket bucket
                | None | Some _ -> Expired)
        in
        { checkpoint; decision })
      checkpoints

  let checkpoint selection = selection.checkpoint
  let decision selection = selection.decision

  let retained selection =
    match selection.decision with
    | Expired -> false
    | Protected_by _ | Recent_window | Periodic_bucket _ -> true
end

module Fault = struct
  type boundary = Before_candidate of int | After_candidate of int
  type t = boundary

  let before_candidate index = Before_candidate index
  let after_candidate index = After_candidate index

  let boundary_to_string = function
    | Before_candidate index -> Printf.sprintf "before-candidate-%d" index
    | After_candidate index -> Printf.sprintf "after-candidate-%d" index

  let equal left right =
    match (left, right) with
    | Before_candidate left, Before_candidate right
    | After_candidate left, After_candidate right ->
        left = right
    | Before_candidate _, After_candidate _
    | After_candidate _, Before_candidate _ ->
        false
end

type error =
  | Scratch_error of Scratch.error
  | Snapshot_error of Snapshot.error
  | Store_error of Store.error
  | Scratch_head_missing
  | Reachable_object_type_unsupported of Envelope.object_type
  | Estimated_size_overflow
  | Source_head_not_retained of Scratch.Checkpoint_id.t
  | Source_refs_changed
  | Active_generation_missing
  | Cleanup_manifest_error of string
  | Cleanup_error of string
  | Cleanup_fault_injected of Fault.boundary
  | Cleanup_generation_changed of {
      expected : Scratch.Generation_id.t;
      actual : Scratch.Generation_id.t;
    }

let error_to_string = function
  | Scratch_error error -> Scratch.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Scratch_head_missing -> "scratch history is not initialized"
  | Reachable_object_type_unsupported object_type ->
      Printf.sprintf "cannot traverse reachable object type %d"
        (Envelope.object_type_code object_type)
  | Estimated_size_overflow -> "reachable-object byte estimate exceeds int64"
  | Source_head_not_retained identity ->
      Printf.sprintf "compaction policy does not retain scratch head %s"
        (Store.Stored_object_id.to_hex
           (Scratch.Checkpoint_id.stored_object_id identity))
  | Source_refs_changed -> "compaction source refs changed during construction"
  | Active_generation_missing -> "no active scratch generation"
  | Cleanup_manifest_error detail -> "cleanup manifest error: " ^ detail
  | Cleanup_error detail -> "cleanup error: " ^ detail
  | Cleanup_fault_injected boundary ->
      "cleanup fault injected at " ^ Fault.boundary_to_string boundary
  | Cleanup_generation_changed { expected; actual } ->
      Printf.sprintf "cleanup generation changed: expected %s, active %s"
        (Store.Stored_object_id.to_hex
           (Scratch.Generation_id.stored_object_id expected))
        (Store.Stored_object_id.to_hex
           (Scratch.Generation_id.stored_object_id actual))

let ( let* ) = Result.bind

let object_id_of_checkpoint checkpoint =
  Scratch.Checkpoint_id.stored_object_id checkpoint

let object_id_of_event event = Scratch.Event_id.stored_object_id event

let object_id_of_retention_change change =
  Scratch.Retention_change_id.stored_object_id change

let object_id_of_snapshot snapshot = Snapshot.Snapshot.stored_object_id snapshot
let object_id_of_tree tree = Snapshot.Tree.stored_object_id tree
let object_id_of_content content = Snapshot.Content.stored_object_id content
let object_id_of_chunk chunk = Snapshot.Chunk.stored_object_id chunk

let children_of_entry = function
  | Scratch.Directory -> []
  | Scratch.File { content; _ } -> [ object_id_of_content content ]

let children_of_operation = function
  | Scratch.Create { entry; _ }
  | Scratch.Delete { prior = entry; _ }
  | Scratch.Move { prior = entry; _ } ->
      children_of_entry entry
  | Scratch.Modify_content { expected; replacement; _ } ->
      [ object_id_of_content expected; object_id_of_content replacement ]
  | Scratch.Change_mode _ -> []

let resolved_checkpoint_object scratch logical =
  Scratch.resolve_checkpoint scratch logical
  |> Result.map (fun resolved ->
      object_id_of_checkpoint (Scratch.resolved_physical_id resolved))
  |> Result.map_error (fun error -> Scratch_error error)

let object_children scratch store identity envelope =
  match Envelope.object_type envelope with
  | Envelope.Content | Envelope.Chunk -> Ok []
  | Envelope.Tree ->
      let* tree =
        Snapshot.Tree.load store (Snapshot.Tree.of_stored_object_id identity)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok
        (List.concat_map
           (fun (_, entry) ->
             match entry with
             | Snapshot.Tree.File { content; _ } ->
                 [ object_id_of_content content ]
             | Snapshot.Tree.Directory child -> [ object_id_of_tree child ])
           (Snapshot.Tree.entries tree))
  | Envelope.Snapshot ->
      let* snapshot =
        Snapshot.Snapshot.load store
          (Snapshot.Snapshot.of_stored_object_id identity)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok [ object_id_of_tree (Snapshot.Snapshot.root snapshot) ]
  | Envelope.File_manifest ->
      let* manifest =
        Snapshot.Manifest.load store
          (Snapshot.Manifest.of_stored_object_id identity)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok
        (List.map
           (fun (chunk, _) -> object_id_of_chunk chunk)
           (Snapshot.Manifest.chunks manifest))
  | Envelope.Scratch_event ->
      let* event =
        Scratch.Event.load store (Scratch.Event_id.of_stored_object_id identity)
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let* parent =
        resolved_checkpoint_object scratch (Scratch.Event.parent event)
      in
      Ok
        (parent
        :: object_id_of_snapshot (Scratch.Event.base event)
        :: object_id_of_snapshot (Scratch.Event.resulting event)
        :: List.concat_map children_of_operation
             (Scratch.Event.operations event))
  | Envelope.Checkpoint ->
      let* checkpoint =
        Scratch.Checkpoint.load store
          (Scratch.Checkpoint_id.of_stored_object_id identity)
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let* parent =
        match Scratch.Checkpoint.parent checkpoint with
        | None -> Ok None
        | Some parent ->
            resolved_checkpoint_object scratch parent |> Result.map Option.some
      in
      Ok
        (object_id_of_snapshot (Scratch.Checkpoint.snapshot checkpoint)
        :: List.filter_map
             (fun value -> value)
             [
               parent;
               Option.map object_id_of_event
                 (Scratch.Checkpoint.event checkpoint);
             ])
  | Envelope.Retention_change ->
      let* change =
        Scratch.Retention_change.load store
          (Scratch.Retention_change_id.of_stored_object_id identity)
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let* checkpoint =
        resolved_checkpoint_object scratch
          (Scratch.Retention_change.checkpoint change)
      in
      Ok
        (checkpoint
        :: List.filter_map
             (fun value -> value)
             [
               Option.map object_id_of_retention_change
                 (Scratch.Retention_change.previous change);
             ])
  | Envelope.Capsule | Envelope.Capsule_revision | Envelope.Release
  | Envelope.Conflict | Envelope.Validation | Envelope.Resolution
  | Envelope.Repository_config | Envelope.Scratch_generation_segment
  | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest ->
      Error (Reachable_object_type_unsupported (Envelope.object_type envelope))

let add_size total size =
  if Int64.compare total (Int64.sub Int64.max_int size) > 0 then
    Error Estimated_size_overflow
  else Ok (Int64.add total size)

let stored_file_length store identity =
  let path = Store.object_path store identity in
  try
    let stat = Unix.stat path in
    if stat.Unix.st_kind <> Unix.S_REG then
      Error (Cleanup_manifest_error ("object is not a regular file: " ^ path))
    else Ok (Int64.of_int stat.Unix.st_size)
  with Unix.Unix_error (error, _, _) ->
    Error
      (Cleanup_manifest_error
         ("cannot stat object "
         ^ Store.Stored_object_id.to_hex identity
         ^ ": " ^ Unix.error_message error))

let reachable scratch store roots =
  let rec visit visited total = function
    | [] -> Ok (visited, total)
    | identity :: remaining when Object_set.mem identity visited ->
        visit visited total remaining
    | identity :: remaining ->
        let* envelope =
          Store.get store identity
          |> Result.map_error (fun error -> Store_error error)
        in
        let* size = stored_file_length store identity in
        let* total = add_size total size in
        let* children = object_children scratch store identity envelope in
        visit
          (Object_set.add identity visited)
          total
          (List.rev_append children remaining)
  in
  visit Object_set.empty 0L roots

type blocked_removal = { checkpoint : Scratch.Checkpoint_id.t; reason : string }

type cleanup_candidate = {
  candidate_object_id : Store.Stored_object_id.t;
  candidate_expected_type : Envelope.object_type;
}

type cleanup_metric = {
  metric_object_id : Store.Stored_object_id.t;
  metric_expected_type : Envelope.object_type;
  stored_bytes : int64;
}

type plan = {
  policy : Policy.t;
  selections : Policy.selection list;
  reachable_object_count : int;
  estimated_before_bytes : int64;
  estimated_after_bytes : int64;
  removable_checkpoints : Scratch.Checkpoint_id.t list;
  removable_events : Scratch.Event_id.t list;
  removable_objects : Store.Stored_object_id.t list;
  planned_cleanup : cleanup_metric list;
  blocked_removals : blocked_removal list;
  budget_exceeded_by : int64 option;
}

let policy plan = plan.policy
let selections plan = plan.selections
let reachable_object_count plan = plan.reachable_object_count
let estimated_before_bytes plan = plan.estimated_before_bytes
let estimated_after_bytes plan = plan.estimated_after_bytes
let removable_checkpoints plan = plan.removable_checkpoints
let removable_events plan = plan.removable_events
let removable_objects plan = plan.removable_objects
let planned_cleanup plan = plan.planned_cleanup
let planned_cleanup_count plan = List.length plan.planned_cleanup

let planned_cleanup_bytes plan =
  List.fold_left
    (fun total metric -> Int64.add total metric.stored_bytes)
    0L plan.planned_cleanup

let blocked_removals plan = plan.blocked_removals
let budget_exceeded_by plan = plan.budget_exceeded_by

let retention_head_root store =
  let* reference =
    Store.read_ref store ~name:"retention-head"
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok (Option.bind reference Store.Mutable_ref.target)

let analyze_reachable ~store scratch ~policy ~now =
  let* timeline =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let* head =
    Scratch.head scratch |> Result.map_error (fun error -> Scratch_error error)
  in
  let* head =
    match head with
    | Some checkpoint -> Ok checkpoint
    | None -> Error Scratch_head_missing
  in
  let selections =
    Policy.select policy ~now
      (List.map
         (fun entry ->
           {
             Policy.id = entry.Scratch.logical_id;
             created_at = Scratch.Checkpoint.created_at entry.Scratch.checkpoint;
             effective_retention = entry.Scratch.effective_retention;
           })
         timeline)
  in
  let* retention_head = retention_head_root store in
  let roots =
    object_id_of_checkpoint (Scratch.Checkpoint.id head)
    :: Option.to_list retention_head
  in
  let* current_objects, estimated_before_bytes =
    reachable scratch store roots
  in
  let estimated_after_bytes = estimated_before_bytes in
  let blocked_removals =
    List.filter_map
      (fun selection ->
        if Policy.retained selection then None
        else
          Some
            {
              checkpoint = (Policy.checkpoint selection).Policy.id;
              reason =
                "referenced by scratch-head ancestry; immutable checkpoint \
                 parent links require a new generation representation before \
                 removal";
            })
      selections
  in
  let budget_exceeded_by =
    match Policy.storage_budget_bytes policy with
    | None -> None
    | Some budget when Int64.compare estimated_after_bytes budget <= 0 -> None
    | Some budget -> Some (Int64.sub estimated_after_bytes budget)
  in
  Ok
    {
      policy;
      selections;
      reachable_object_count = Object_set.cardinal current_objects;
      estimated_before_bytes;
      estimated_after_bytes;
      removable_checkpoints = [];
      removable_events = [];
      removable_objects = [];
      planned_cleanup = [];
      blocked_removals;
      budget_exceeded_by;
    }

let checkpoint_hex checkpoint =
  checkpoint |> Scratch.Checkpoint_id.stored_object_id
  |> Store.Stored_object_id.to_hex

let decision_to_string = function
  | Policy.Protected_by reason ->
      "protected=" ^ Scratch.retention_reason_to_string reason
  | Policy.Recent_window -> "recent-window"
  | Policy.Periodic_bucket bucket -> Printf.sprintf "periodic-bucket=%Ld" bucket
  | Policy.Expired -> "expired"

let render_explain plan =
  let policy = policy plan in
  let budget =
    match Policy.storage_budget_bytes policy with
    | None -> "unbounded"
    | Some bytes -> Int64.to_string bytes
  in
  let lines =
    [
      Printf.sprintf
        "policy recent-window-seconds=%Ld periodic-interval-seconds=%Ld \
         storage-budget-bytes=%s"
        (Policy.recent_window_seconds policy)
        (Policy.periodic_interval_seconds policy)
        budget;
      Printf.sprintf "reachable-objects=%d" (reachable_object_count plan);
      Printf.sprintf "estimated-before-bytes=%Ld" (estimated_before_bytes plan);
      Printf.sprintf "estimated-after-bytes=%Ld" (estimated_after_bytes plan);
      Printf.sprintf "removable-checkpoints=%d"
        (List.length (removable_checkpoints plan));
      Printf.sprintf "removable-events=%d" (List.length (removable_events plan));
      Printf.sprintf "removable-objects=%d"
        (List.length (removable_objects plan));
      Printf.sprintf "planned-cleanup-objects=%d" (planned_cleanup_count plan);
      Printf.sprintf "planned-cleanup-bytes=%Ld" (planned_cleanup_bytes plan);
    ]
  in
  let selections =
    List.map
      (fun selection ->
        Printf.sprintf "checkpoint %s %s"
          (checkpoint_hex (Policy.checkpoint selection).Policy.id)
          (decision_to_string (Policy.decision selection)))
      (selections plan)
  in
  let blocked =
    List.map
      (fun { checkpoint; reason } ->
        Printf.sprintf "blocked-removal %s %s"
          (checkpoint_hex checkpoint)
          reason)
      (blocked_removals plan)
  in
  let budget =
    match budget_exceeded_by plan with
    | None -> []
    | Some bytes -> [ Printf.sprintf "budget-exceeded-bytes=%Ld" bytes ]
  in
  let cleanup_types =
    planned_cleanup plan
    |> List.map (fun metric -> metric.metric_expected_type)
    |> List.sort_uniq compare
    |> List.concat_map (fun expected_type ->
        let metrics =
          List.filter
            (fun metric -> metric.metric_expected_type = expected_type)
            (planned_cleanup plan)
        in
        let bytes =
          List.fold_left
            (fun total metric -> Int64.add total metric.stored_bytes)
            0L metrics
        in
        let code = Envelope.object_type_code expected_type in
        [
          Printf.sprintf "planned-cleanup-type-%d-objects=%d" code
            (List.length metrics);
          Printf.sprintf "planned-cleanup-type-%d-bytes=%Ld" code bytes;
        ])
  in
  let cleanup_objects =
    List.map
      (fun metric ->
        Printf.sprintf "planned-cleanup-object %s type=%d stored-bytes=%Ld"
          (Store.Stored_object_id.to_hex metric.metric_object_id)
          (Envelope.object_type_code metric.metric_expected_type)
          metric.stored_bytes)
      (planned_cleanup plan)
  in
  lines @ cleanup_types @ cleanup_objects @ selections @ blocked @ budget

type source_refs = {
  scratch_ref : Store.Mutable_ref.t;
  scratch_head : Scratch.Checkpoint_id.t;
  retention_ref : Store.Mutable_ref.t option;
  retention_head : Scratch.Retention_change_id.t option;
  generation_ref : Store.Mutable_ref.t option;
  previous_generation : Scratch.Generation_id.t option;
}

type execution = {
  execution_generation_id : Scratch.Generation_id.t;
  plan : plan;
  cleanup : cleanup_report;
}

and cleanup_report = {
  generation : Scratch.Generation_id.t;
  quarantined_objects : int;
  quarantined_bytes : int64;
  pruned_objects : int;
  pruned_bytes : int64;
  already_quarantined_objects : int;
  already_pruned_objects : int;
  quarantined_candidates : cleanup_metric list;
  pruned_candidates : cleanup_metric list;
  already_quarantined_candidates : cleanup_candidate list;
  already_pruned_candidates : cleanup_candidate list;
}

let execution_generation (execution : execution) =
  execution.execution_generation_id

let execution_plan execution = execution.plan
let execution_cleanup execution = execution.cleanup
let scratch_generation_name = "scratch-generation"
let compaction_lock_name = "scratch-compaction"

let read_source_refs store =
  let* scratch_ref =
    Store.read_ref store ~name:"scratch-head"
    |> Result.map_error (fun error -> Store_error error)
  in
  let* scratch_ref =
    match scratch_ref with
    | Some reference -> Ok reference
    | None -> Error Scratch_head_missing
  in
  let* scratch_head =
    match Store.Mutable_ref.target scratch_ref with
    | Some identity -> Ok (Scratch.Checkpoint_id.of_stored_object_id identity)
    | None -> Error (Cleanup_manifest_error "scratch-head ref is null")
  in
  let* retention_ref =
    Store.read_ref store ~name:"retention-head"
    |> Result.map_error (fun error -> Store_error error)
  in
  let retention_head =
    Option.bind retention_ref Store.Mutable_ref.target
    |> Option.map Scratch.Retention_change_id.of_stored_object_id
  in
  let* generation_ref =
    Store.read_ref store ~name:scratch_generation_name
    |> Result.map_error (fun error -> Store_error error)
  in
  let* previous_generation =
    match generation_ref with
    | None -> Ok None
    | Some reference -> (
        match Store.Mutable_ref.target reference with
        | None ->
            Error (Cleanup_manifest_error "scratch-generation ref is null")
        | Some identity ->
            let generation =
              Scratch.Generation_id.of_stored_object_id identity
            in
            Scratch.Generation.load store generation
            |> Result.map (fun _ -> Some generation)
            |> Result.map_error (fun error -> Scratch_error error))
  in
  Ok
    {
      scratch_ref;
      scratch_head;
      retention_ref;
      retention_head;
      generation_ref;
      previous_generation;
    }

let ref_generation = Option.map Store.Mutable_ref.generation

let retained_timeline plan timeline =
  let selected identity =
    List.find_opt
      (fun selection ->
        Scratch.Checkpoint_id.equal identity
          (Policy.checkpoint selection).Policy.id)
      plan.selections
  in
  timeline
  |> List.filter_map (fun entry ->
      match selected entry.Scratch.logical_id with
      | Some selection when Policy.retained selection -> Some (entry, selection)
      | None | Some _ -> None)
  |> List.rev

let checkpoint_state store checkpoint =
  let* snapshot =
    Snapshot.Snapshot.load store (Scratch.Checkpoint.snapshot checkpoint)
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  Scratch.State.of_snapshot store snapshot
  |> Result.map_error (fun error -> Scratch_error error)

let source_event_metadata store checkpoint =
  match Scratch.Checkpoint.event checkpoint with
  | None ->
      Error
        (Cleanup_manifest_error "retained non-initial checkpoint has no event")
  | Some event ->
      Scratch.Event.load store event
      |> Result.map_error (fun error -> Scratch_error error)

type generated_checkpoint = {
  entry : Scratch.Generation.entry;
  checkpoint : Scratch.Checkpoint.t;
  event : Scratch.Event.t option;
}

let build_physical_chain store retained =
  let rec build reversed previous = function
    | [] -> Ok (List.rev reversed)
    | (entry, _) :: rest ->
        let source = entry.Scratch.checkpoint in
        let logical = entry.Scratch.logical_id in
        let snapshot = Scratch.Checkpoint.snapshot source in
        let created_at = Scratch.Checkpoint.created_at source in
        let intrinsic_retention =
          Scratch.Checkpoint.intrinsic_retention source
        in
        let* checkpoint, event, previous_logical =
          match previous with
          | None ->
              let checkpoint =
                Scratch.Checkpoint.create_initial_with_retention ~snapshot
                  ~created_at ~intrinsic_retention
              in
              Ok (checkpoint, None, None)
          | Some (prior_logical, prior_checkpoint) ->
              let* base_state = checkpoint_state store prior_checkpoint in
              let* target_state = checkpoint_state store source in
              let operations =
                Scratch.State.diff ~from:base_state ~to_:target_state
              in
              let* replayed =
                Scratch.State.apply base_state operations
                |> Result.map_error (fun error -> Scratch_error error)
              in
              if not (Scratch.State.equal replayed target_state) then
                Error
                  (Cleanup_manifest_error
                     "generated compacted replay mismatches")
              else
                let* metadata = source_event_metadata store source in
                let event =
                  Scratch.Event.create ~parent:prior_logical
                    ~base:(Scratch.Checkpoint.snapshot prior_checkpoint)
                    ~resulting:snapshot ~operations
                    ~source:(Scratch.Event.source metadata)
                    ~observed_at:(Scratch.Event.observed_at metadata)
                in
                let checkpoint =
                  Scratch.Checkpoint.create_with_retention ~parent:prior_logical
                    ~event:(Scratch.Event.id event) ~snapshot ~created_at
                    ~intrinsic_retention
                in
                Ok (checkpoint, Some event, Some prior_logical)
        in
        let generated_entry =
          Scratch.Generation.entry ~logical
            ~physical:(Scratch.Checkpoint.id checkpoint)
            ~snapshot ~previous_logical
            ~effective_retention:entry.Scratch.effective_retention
        in
        build
          ({ entry = generated_entry; checkpoint; event } :: reversed)
          (Some (logical, checkpoint))
          rest
  in
  build [] None retained

let persist_physical_chain store generated =
  let rec persist reversed = function
    | [] -> Ok (List.rev reversed)
    | generated :: rest ->
        let* () =
          match generated.event with
          | None -> Ok ()
          | Some event ->
              let* identity =
                Scratch.Event.store store event
                |> Result.map_error (fun error -> Scratch_error error)
              in
              if Scratch.Event_id.equal identity (Scratch.Event.id event) then
                Ok ()
              else
                Error
                  (Cleanup_manifest_error
                     "generated compacted event identity changed during storage")
        in
        let* identity =
          Scratch.Checkpoint.store store generated.checkpoint
          |> Result.map_error (fun error -> Scratch_error error)
        in
        if
          Scratch.Checkpoint_id.equal identity
            (Scratch.Checkpoint.id generated.checkpoint)
        then persist (generated.entry :: reversed) rest
        else
          Error
            (Cleanup_manifest_error
               "generated compacted checkpoint identity changed during storage")
  in
  persist [] generated

let construct_physical_chain store retained =
  let* generated = build_physical_chain store retained in
  let* _ = persist_physical_chain store generated in
  Ok generated

let generated_entries generated =
  List.map (fun generated -> generated.entry) generated

let object_id_of_checkpoint checkpoint =
  Scratch.Checkpoint_id.stored_object_id checkpoint

let object_id_of_event event = Scratch.Event_id.stored_object_id event

let object_id_of_retention change =
  Scratch.Retention_change_id.stored_object_id change

let candidate object_id expected_type : cleanup_candidate =
  { candidate_object_id = object_id; candidate_expected_type = expected_type }

let manifest_candidate candidate : Scratch.Cleanup_manifest.candidate =
  {
    Scratch.Cleanup_manifest.object_id = candidate.candidate_object_id;
    expected_type = candidate.candidate_expected_type;
  }

let cleanup_candidate_of_manifest
    (candidate : Scratch.Cleanup_manifest.candidate) =
  {
    candidate_object_id = candidate.Scratch.Cleanup_manifest.object_id;
    candidate_expected_type = candidate.Scratch.Cleanup_manifest.expected_type;
  }

let active_physical_ids store previous_generation =
  match previous_generation with
  | None -> Ok Object_set.empty
  | Some identity ->
      let* generation =
        Scratch.Generation.load store identity
        |> Result.map_error (fun error -> Scratch_error error)
      in
      List.fold_left
        (fun result entry ->
          let* kept = result in
          let physical = Scratch.Generation.physical entry in
          let kept = Object_set.add (object_id_of_checkpoint physical) kept in
          let* checkpoint =
            Scratch.Checkpoint.load store physical
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let kept =
            match Scratch.Checkpoint.event checkpoint with
            | None -> kept
            | Some event -> Object_set.add (object_id_of_event event) kept
          in
          Ok kept)
        (Ok Object_set.empty)
        (Scratch.Generation.entries generation)

let older_retention_candidates store cutoff =
  let rec walk seen reversed = function
    | None -> Ok (List.rev reversed)
    | Some identity ->
        if List.exists (Scratch.Retention_change_id.equal identity) seen then
          Error (Cleanup_manifest_error "retention cutoff chain has a cycle")
        else
          let* change =
            Scratch.Retention_change.load store identity
            |> Result.map_error (fun error -> Scratch_error error)
          in
          walk (identity :: seen) (identity :: reversed)
            (Scratch.Retention_change.previous change)
  in
  match cutoff with
  | None -> Ok []
  | Some cutoff ->
      let* change =
        Scratch.Retention_change.load store cutoff
        |> Result.map_error (fun error -> Scratch_error error)
      in
      walk [ cutoff ] [] (Scratch.Retention_change.previous change)

let cleanup_candidates store ~previous_generation ~timeline ~generated ~cutoff =
  let* protected = active_physical_ids store previous_generation in
  let protected =
    List.fold_left
      (fun kept entry ->
        Object_set.add
          (object_id_of_checkpoint (Scratch.Generation.physical entry.entry))
          kept)
      protected generated
  in
  let protected =
    List.fold_left
      (fun kept entry ->
        match entry.event with
        | None -> kept
        | Some event ->
            Object_set.add (object_id_of_event (Scratch.Event.id event)) kept)
      protected generated
  in
  let source_candidates =
    List.concat_map
      (fun entry ->
        let checkpoint = entry.Scratch.checkpoint in
        candidate
          (object_id_of_checkpoint (Scratch.Checkpoint.id checkpoint))
          Envelope.Checkpoint
        ::
        (match Scratch.Checkpoint.event checkpoint with
        | None -> []
        | Some event ->
            [ candidate (object_id_of_event event) Envelope.Scratch_event ]))
      timeline
    |> List.filter (fun candidate ->
        not (Object_set.mem candidate.candidate_object_id protected))
  in
  let* retention = older_retention_candidates store cutoff in
  let candidates =
    source_candidates
    @ List.map
        (fun identity ->
          candidate (object_id_of_retention identity) Envelope.Retention_change)
        retention
  in
  let* manifest =
    Scratch.Cleanup_manifest.create (List.map manifest_candidate candidates)
    |> Result.map_error (fun error -> Scratch_error error)
  in
  Ok
    (List.map cleanup_candidate_of_manifest
       (Scratch.Cleanup_manifest.candidates manifest))

let metric_of_candidate store candidate =
  let* envelope =
    Store.get store candidate.candidate_object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> candidate.candidate_expected_type then
    Error (Cleanup_manifest_error "planned cleanup candidate type mismatches")
  else
    let* stored_bytes =
      stored_file_length store candidate.candidate_object_id
    in
    Ok
      {
        metric_object_id = candidate.candidate_object_id;
        metric_expected_type = candidate.candidate_expected_type;
        stored_bytes;
      }

let cleanup_metrics store candidates =
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | candidate :: rest ->
        let* metric = metric_of_candidate store candidate in
        collect (metric :: reversed) rest
  in
  collect [] candidates

let cleanup_metrics_equal left right =
  List.length left = List.length right
  && List.for_all2
       (fun left right ->
         Store.Stored_object_id.equal left.metric_object_id
           right.metric_object_id
         && left.metric_expected_type = right.metric_expected_type
         && Int64.equal left.stored_bytes right.stored_bytes)
       left right

let analyze ~store scratch ~policy ~now =
  let* baseline = analyze_reachable ~store scratch ~policy ~now in
  let* source = read_source_refs store in
  let* timeline =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let retained = retained_timeline baseline timeline in
  let head_retained =
    List.exists
      (fun (entry, _) ->
        Scratch.Checkpoint_id.equal entry.Scratch.logical_id source.scratch_head)
      retained
  in
  if not head_retained then Error (Source_head_not_retained source.scratch_head)
  else
    let* generated = build_physical_chain store retained in
    let* candidates =
      cleanup_candidates store ~previous_generation:source.previous_generation
        ~timeline ~generated ~cutoff:source.retention_head
    in
    let* planned_cleanup = cleanup_metrics store candidates in
    let removable_checkpoints =
      List.filter_map
        (fun metric ->
          if metric.metric_expected_type = Envelope.Checkpoint then
            Some
              (Scratch.Checkpoint_id.of_stored_object_id metric.metric_object_id)
          else None)
        planned_cleanup
    in
    let removable_events =
      List.filter_map
        (fun metric ->
          if metric.metric_expected_type = Envelope.Scratch_event then
            Some (Scratch.Event_id.of_stored_object_id metric.metric_object_id)
          else None)
        planned_cleanup
    in
    Ok
      {
        baseline with
        removable_checkpoints;
        removable_events;
        removable_objects =
          List.map (fun metric -> metric.metric_object_id) planned_cleanup;
        planned_cleanup;
        blocked_removals = [];
      }

let verify_generation store ~plan ~retained generation_id =
  let _ = plan.policy in
  let* generation =
    Scratch.Generation.load store generation_id
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let entries = Scratch.Generation.entries generation in
  if List.length entries <> List.length retained then
    Error
      (Cleanup_manifest_error
         "generation retained entry count disagrees with plan")
  else
    let rec verify previous expected actual =
      match (expected, actual) with
      | [], [] -> Ok ()
      | (timeline_entry, selection) :: expected, entry :: actual ->
          if
            (not
               (Scratch.Checkpoint_id.equal timeline_entry.Scratch.logical_id
                  (Scratch.Generation.logical entry)))
            || (not
                  (Snapshot.Snapshot.equal_id
                     (Scratch.Checkpoint.snapshot
                        timeline_entry.Scratch.checkpoint)
                     (Scratch.Generation.snapshot entry)))
            || timeline_entry.Scratch.effective_retention
               <> Scratch.Generation.effective_retention entry
            || not (Policy.retained selection)
          then
            Error
              (Cleanup_manifest_error "generation timeline disagrees with plan")
          else
            let physical = Scratch.Generation.physical entry in
            let* checkpoint =
              Scratch.Checkpoint.load store physical
              |> Result.map_error (fun error -> Scratch_error error)
            in
            let* () =
              match previous with
              | None ->
                  if
                    Option.is_none (Scratch.Checkpoint.parent checkpoint)
                    && Option.is_none (Scratch.Checkpoint.event checkpoint)
                  then Ok ()
                  else
                    Error
                      (Cleanup_manifest_error
                         "initial compacted checkpoint is linked")
              | Some (previous_logical, previous_checkpoint) ->
                  if
                    not
                      (Option.equal Scratch.Checkpoint_id.equal
                         (Scratch.Checkpoint.parent checkpoint)
                         (Some previous_logical))
                  then
                    Error
                      (Cleanup_manifest_error
                         "compacted parent logical ID mismatches")
                  else
                    let* event =
                      match Scratch.Checkpoint.event checkpoint with
                      | None ->
                          Error
                            (Cleanup_manifest_error "compacted event is missing")
                      | Some event ->
                          Scratch.Event.load store event
                          |> Result.map_error (fun error -> Scratch_error error)
                    in
                    if
                      (not
                         (Scratch.Checkpoint_id.equal
                            (Scratch.Event.parent event)
                            previous_logical))
                      || (not
                            (Snapshot.Snapshot.equal_id
                               (Scratch.Event.base event)
                               (Scratch.Checkpoint.snapshot previous_checkpoint)))
                      || not
                           (Snapshot.Snapshot.equal_id
                              (Scratch.Event.resulting event)
                              (Scratch.Checkpoint.snapshot checkpoint))
                    then
                      Error
                        (Cleanup_manifest_error
                           "compacted event linkage mismatches")
                    else
                      let* base = checkpoint_state store previous_checkpoint in
                      let* expected = checkpoint_state store checkpoint in
                      let* replayed =
                        Scratch.State.apply base
                          (Scratch.Event.operations event)
                        |> Result.map_error (fun error -> Scratch_error error)
                      in
                      if Scratch.State.equal replayed expected then Ok ()
                      else
                        Error
                          (Cleanup_manifest_error "compacted replay mismatches")
            in
            verify
              (Some (Scratch.Generation.logical entry, checkpoint))
              expected actual
      | [], _ :: _ | _ :: _, [] ->
          Error
            (Cleanup_manifest_error
               "generation retained entry count disagrees with plan")
    in
    let* () = verify None retained entries in
    let* _ =
      Scratch.Cleanup_manifest.load store
        (Scratch.Generation.cleanup_manifest generation)
      |> Result.map_error (fun error -> Scratch_error error)
    in
    let final = List.hd (List.rev entries) in
    if
      Scratch.Checkpoint_id.equal
        (Scratch.Generation.physical_head generation)
        (Scratch.Generation.physical final)
    then Ok generation
    else Error (Cleanup_manifest_error "generation physical head mismatches")

let source_refs_unchanged store source =
  let* current = read_source_refs store in
  if
    Store.Mutable_ref.equal current.scratch_ref source.scratch_ref
    && Option.equal Store.Mutable_ref.equal current.retention_ref
         source.retention_ref
    && Option.equal Store.Mutable_ref.equal current.generation_ref
         source.generation_ref
  then Ok ()
  else Error Source_refs_changed

let generation_hex generation =
  Store.Stored_object_id.to_hex
    (Scratch.Generation_id.stored_object_id generation)

let candidate_hex candidate =
  Store.Stored_object_id.to_hex candidate.Scratch.Cleanup_manifest.object_id

let ensure_directory path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_DIR then Ok ()
    else Error (Cleanup_error ("not a directory: " ^ path))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> (
      try
        Unix.mkdir path 0o700;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (Cleanup_error (Unix.error_message error ^ ": " ^ path)))
  | Unix.Unix_error (error, _, _) ->
      Error (Cleanup_error (Unix.error_message error ^ ": " ^ path))

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Unix.fsync descriptor;
    Unix.close descriptor;
    Ok ()
  with Unix.Unix_error (error, _, _) ->
    Error
      (Cleanup_error
         ("fsync directory " ^ path ^ ": " ^ Unix.error_message error))

let check_object_file path candidate =
  try
    let bytes = In_channel.with_open_bin path In_channel.input_all in
    match Envelope.decode bytes with
    | Error error ->
        Error (Cleanup_error (Envelope.decode_error_to_string error))
    | Ok envelope ->
        let identity = Store.id_of_envelope envelope in
        if
          not
            (Store.Stored_object_id.equal identity
               candidate.Scratch.Cleanup_manifest.object_id)
        then Error (Cleanup_error "quarantine object identity mismatches")
        else if
          Envelope.object_type envelope
          <> candidate.Scratch.Cleanup_manifest.expected_type
        then Error (Cleanup_error "quarantine object type mismatches")
        else
          let stat = Unix.stat path in
          if stat.Unix.st_kind <> Unix.S_REG then
            Error (Cleanup_error "cleanup candidate is not a regular file")
          else
            let stored_bytes = Int64.of_int stat.Unix.st_size in
            if Int64.equal stored_bytes (Int64.of_int (String.length bytes))
            then Ok stored_bytes
            else
              Error (Cleanup_error "cleanup candidate changed while verified")
  with
  | Sys_error message -> Error (Cleanup_error message)
  | Unix.Unix_error (error, _, _) ->
      Error (Cleanup_error (Unix.error_message error ^ ": " ^ path))

let candidate_in_other_quarantine ~trash_root ~generation candidate =
  if not (Sys.file_exists trash_root) then Ok false
  else
    try
      let active = generation_hex generation in
      let candidate = candidate_hex candidate in
      let found =
        Sys.readdir trash_root
        |> Array.exists (fun directory ->
            (not (String.equal directory active))
            && Sys.file_exists
                 (Filename.concat
                    (Filename.concat trash_root directory)
                    candidate))
      in
      Ok found
    with Sys_error message -> Error (Cleanup_error message)

let active_cleanup_generation store =
  let* reference =
    Store.read_ref store ~name:scratch_generation_name
    |> Result.map_error (fun error -> Store_error error)
  in
  match reference with
  | None -> Error Active_generation_missing
  | Some reference -> (
      match Store.Mutable_ref.target reference with
      | None -> Error (Cleanup_manifest_error "scratch-generation ref is null")
      | Some identity ->
          let generation = Scratch.Generation_id.of_stored_object_id identity in
          let* root =
            Scratch.Generation.load store generation
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let* manifest =
            Scratch.Cleanup_manifest.load store
              (Scratch.Generation.cleanup_manifest root)
            |> Result.map_error (fun error -> Scratch_error error)
          in
          Ok (reference, generation, root, manifest))

let active_keep_set store generation root =
  let initial =
    Object_set.empty
    |> Object_set.add (Scratch.Generation_id.stored_object_id generation)
    |> Object_set.add
         (Scratch.Cleanup_manifest_id.stored_object_id
            (Scratch.Generation.cleanup_manifest root))
  in
  let initial =
    List.fold_left
      (fun kept segment ->
        Object_set.add (Scratch.Generation_id.stored_object_id segment) kept)
      initial
      (Scratch.Generation.segment_ids root)
  in
  List.fold_left
    (fun result entry ->
      let* kept = result in
      let physical = Scratch.Generation.physical entry in
      let kept = Object_set.add (object_id_of_checkpoint physical) kept in
      let* checkpoint =
        Scratch.Checkpoint.load store physical
        |> Result.map_error (fun error -> Scratch_error error)
      in
      Ok
        (match Scratch.Checkpoint.event checkpoint with
        | None -> kept
        | Some event -> Object_set.add (object_id_of_event event) kept))
    (Ok initial)
    (Scratch.Generation.entries root)

let inject_fault fault boundary =
  match fault with
  | Some fault when Fault.equal fault boundary ->
      Error (Cleanup_fault_injected boundary)
  | None | Some _ -> Ok ()

let cleanup_metric_of_manifest_candidate candidate stored_bytes =
  {
    metric_object_id = candidate.Scratch.Cleanup_manifest.object_id;
    metric_expected_type = candidate.Scratch.Cleanup_manifest.expected_type;
    stored_bytes;
  }

let cleanup_candidate_of_manifest_candidate candidate =
  {
    candidate_object_id = candidate.Scratch.Cleanup_manifest.object_id;
    candidate_expected_type = candidate.Scratch.Cleanup_manifest.expected_type;
  }

let cleanup_internal ?fault ?expected_generation store ~prune =
  let* reference, generation, root, manifest =
    active_cleanup_generation store
  in
  let* () =
    match expected_generation with
    | None -> Ok ()
    | Some expected when Scratch.Generation_id.equal expected generation ->
        Ok ()
    | Some expected ->
        Error (Cleanup_generation_changed { expected; actual = generation })
  in
  let* keep = active_keep_set store generation root in
  let trash_root = Filename.concat (Store.root store) ".paengi/trash" in
  let generation_trash =
    Filename.concat trash_root (generation_hex generation)
  in
  let* () = ensure_directory trash_root in
  let* () = ensure_directory generation_trash in
  let rec move index report = function
    | [] ->
        Ok
          {
            report with
            quarantined_candidates = List.rev report.quarantined_candidates;
            pruned_candidates = List.rev report.pruned_candidates;
            already_quarantined_candidates =
              List.rev report.already_quarantined_candidates;
            already_pruned_candidates =
              List.rev report.already_pruned_candidates;
          }
    | candidate :: rest ->
        let* () = inject_fault fault (Fault.Before_candidate index) in
        let* current =
          Store.read_ref store ~name:scratch_generation_name
          |> Result.map_error (fun error -> Store_error error)
        in
        if not (Option.equal Store.Mutable_ref.equal current (Some reference))
        then Error Source_refs_changed
        else if Object_set.mem candidate.Scratch.Cleanup_manifest.object_id keep
        then
          Error
            (Cleanup_manifest_error "cleanup manifest overlaps active keep set")
        else
          let source =
            Store.object_path store candidate.Scratch.Cleanup_manifest.object_id
          in
          let destination =
            Filename.concat generation_trash (candidate_hex candidate)
          in
          let source_exists = Sys.file_exists source in
          let destination_exists = Sys.file_exists destination in
          let* report =
            if prune then
              if source_exists then
                let* _ = check_object_file source candidate in
                Error
                  (Cleanup_error "refusing to prune object not in quarantine")
              else if destination_exists then
                let* bytes = check_object_file destination candidate in
                let metric =
                  cleanup_metric_of_manifest_candidate candidate bytes
                in
                try
                  Unix.unlink destination;
                  let* () = fsync_directory generation_trash in
                  Ok
                    {
                      report with
                      pruned_objects = report.pruned_objects + 1;
                      pruned_bytes = Int64.add report.pruned_bytes bytes;
                      pruned_candidates = metric :: report.pruned_candidates;
                    }
                with Unix.Unix_error (error, _, _) ->
                  Error
                    (Cleanup_error ("prune unlink: " ^ Unix.error_message error))
              else
                let* foreign =
                  candidate_in_other_quarantine ~trash_root ~generation
                    candidate
                in
                if foreign then
                  Error
                    (Cleanup_error
                       "cleanup candidate belongs to a different generation \
                        quarantine")
                else
                  Ok
                    {
                      report with
                      already_pruned_objects = report.already_pruned_objects + 1;
                      already_pruned_candidates =
                        cleanup_candidate_of_manifest_candidate candidate
                        :: report.already_pruned_candidates;
                    }
            else if source_exists then
              let* bytes = check_object_file source candidate in
              let metric =
                cleanup_metric_of_manifest_candidate candidate bytes
              in
              if destination_exists then
                let* _ = check_object_file destination candidate in
                Error
                  (Cleanup_error
                     "candidate exists in both object store and quarantine")
              else
                try
                  Unix.rename source destination;
                  let* () = fsync_directory (Filename.dirname source) in
                  let* () = fsync_directory generation_trash in
                  Ok
                    {
                      report with
                      quarantined_objects = report.quarantined_objects + 1;
                      quarantined_bytes =
                        Int64.add report.quarantined_bytes bytes;
                      quarantined_candidates =
                        metric :: report.quarantined_candidates;
                    }
                with Unix.Unix_error (error, _, _) ->
                  Error
                    (Cleanup_error
                       ("quarantine rename: " ^ Unix.error_message error))
            else if destination_exists then
              let* _ = check_object_file destination candidate in
              Ok
                {
                  report with
                  already_quarantined_objects =
                    report.already_quarantined_objects + 1;
                  already_quarantined_candidates =
                    cleanup_candidate_of_manifest_candidate candidate
                    :: report.already_quarantined_candidates;
                }
            else
              let* foreign =
                candidate_in_other_quarantine ~trash_root ~generation candidate
              in
              if foreign then
                Error
                  (Cleanup_error
                     "cleanup candidate belongs to a different generation \
                      quarantine")
              else
                Error
                  (Cleanup_error
                     "cleanup candidate unexpectedly absent from object store \
                      and quarantine")
          in
          let* () = inject_fault fault (Fault.After_candidate index) in
          move (index + 1) report rest
  in
  move 0
    {
      generation;
      quarantined_objects = 0;
      quarantined_bytes = 0L;
      pruned_objects = 0;
      pruned_bytes = 0L;
      already_quarantined_objects = 0;
      already_pruned_objects = 0;
      quarantined_candidates = [];
      pruned_candidates = [];
      already_quarantined_candidates = [];
      already_pruned_candidates = [];
    }
    (Scratch.Cleanup_manifest.candidates manifest)

let activate ?(cleanup = true) ?cleanup_fault ?before_publish ~store scratch
    ~policy ~now =
  Store.with_lock store ~name:compaction_lock_name
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* source = read_source_refs store in
      let* plan = analyze ~store scratch ~policy ~now in
      let* timeline =
        Scratch.timeline scratch ~limit:max_int ()
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let retained = retained_timeline plan timeline in
      let head_retained =
        List.exists
          (fun (entry, _) ->
            Scratch.Checkpoint_id.equal entry.Scratch.logical_id
              source.scratch_head)
          retained
      in
      if not head_retained then
        Error (Source_head_not_retained source.scratch_head)
      else
        let* generated = construct_physical_chain store retained in
        let* candidates =
          cleanup_candidates store
            ~previous_generation:source.previous_generation ~timeline ~generated
            ~cutoff:source.retention_head
        in
        let* actual_cleanup = cleanup_metrics store candidates in
        let* () =
          if cleanup_metrics_equal (planned_cleanup plan) actual_cleanup then
            Ok ()
          else
            Error
              (Cleanup_manifest_error
                 "dry-run cleanup candidates disagree with activation")
        in
        let* manifest =
          Scratch.Cleanup_manifest.create
            (List.map manifest_candidate candidates)
          |> Result.map_error (fun error -> Scratch_error error)
        in
        let* manifest =
          Scratch.Cleanup_manifest.store store manifest
          |> Result.map_error (fun error -> Scratch_error error)
        in
        let physical_head =
          Scratch.Generation.physical
            (List.hd (List.rev (generated_entries generated)))
        in
        let* generation =
          Scratch.Generation.store store ~previous:source.previous_generation
            ~source_scratch_head:source.scratch_head
            ~source_scratch_ref_generation:
              (Store.Mutable_ref.generation source.scratch_ref)
            ~source_retention_head:source.retention_head
            ~source_retention_ref_generation:
              (ref_generation source.retention_ref)
            ~recent_window_seconds:(Policy.recent_window_seconds policy)
            ~periodic_interval_seconds:(Policy.periodic_interval_seconds policy)
            ~storage_budget_bytes:(Policy.storage_budget_bytes policy)
            ~entries:(generated_entries generated)
            ~physical_head ~retention_cutoff:source.retention_head
            ~cleanup_manifest:manifest
          |> Result.map_error (fun error -> Scratch_error error)
        in
        let* _ = verify_generation store ~plan ~retained generation in
        Option.iter (fun run -> run ()) before_publish;
        let* () = source_refs_unchanged store source in
        let* _ =
          Store.compare_and_swap_ref store ~name:scratch_generation_name
            ~expected:source.generation_ref
            ~target:(Some (Scratch.Generation_id.stored_object_id generation))
          |> Result.map_error (fun error -> Store_error error)
        in
        let* cleanup_report =
          if cleanup then
            cleanup_internal ?fault:cleanup_fault store ~prune:false
          else
            Ok
              {
                generation;
                quarantined_objects = 0;
                quarantined_bytes = 0L;
                pruned_objects = 0;
                pruned_bytes = 0L;
                already_quarantined_objects = 0;
                already_pruned_objects = 0;
                quarantined_candidates = [];
                pruned_candidates = [];
                already_quarantined_candidates = [];
                already_pruned_candidates = [];
              }
        in
        Ok
          {
            execution_generation_id = generation;
            plan;
            cleanup = cleanup_report;
          })

let resume_cleanup ?fault ?expected_generation ~store _scratch =
  Store.with_lock store ~name:compaction_lock_name
    ~on_error:(fun error -> Store_error error)
    (fun () -> cleanup_internal ?fault ?expected_generation store ~prune:false)

let prune ?fault ?expected_generation ~store _scratch =
  Store.with_lock store ~name:compaction_lock_name
    ~on_error:(fun error -> Store_error error)
    (fun () -> cleanup_internal ?fault ?expected_generation store ~prune:true)
