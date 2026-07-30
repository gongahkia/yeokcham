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

type error =
  | Scratch_error of Scratch.error
  | Snapshot_error of Snapshot.error
  | Store_error of Store.error
  | Scratch_head_missing
  | Reachable_object_type_unsupported of Envelope.object_type
  | Estimated_size_overflow

let error_to_string = function
  | Scratch_error error -> Scratch.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Scratch_head_missing -> "scratch history is not initialized"
  | Reachable_object_type_unsupported object_type ->
      Printf.sprintf "cannot traverse reachable object type %d"
        (Envelope.object_type_code object_type)
  | Estimated_size_overflow -> "reachable-object byte estimate exceeds int64"

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

let object_children store identity envelope =
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
      Ok
        (object_id_of_checkpoint (Scratch.Event.parent event)
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
      Ok
        (object_id_of_snapshot (Scratch.Checkpoint.snapshot checkpoint)
        :: List.filter_map
             (fun value -> value)
             [
               Option.map object_id_of_checkpoint
                 (Scratch.Checkpoint.parent checkpoint);
               Option.map object_id_of_event
                 (Scratch.Checkpoint.event checkpoint);
             ])
  | Envelope.Retention_change ->
      let* change =
        Scratch.Retention_change.load store
          (Scratch.Retention_change_id.of_stored_object_id identity)
        |> Result.map_error (fun error -> Scratch_error error)
      in
      Ok
        (object_id_of_checkpoint (Scratch.Retention_change.checkpoint change)
        :: List.filter_map
             (fun value -> value)
             [
               Option.map object_id_of_retention_change
                 (Scratch.Retention_change.previous change);
             ])
  | Envelope.Capsule | Envelope.Capsule_revision | Envelope.Release
  | Envelope.Conflict | Envelope.Validation | Envelope.Resolution
  | Envelope.Repository_config ->
      Error (Reachable_object_type_unsupported (Envelope.object_type envelope))

let add_size total size =
  if Int64.compare total (Int64.sub Int64.max_int size) > 0 then
    Error Estimated_size_overflow
  else Ok (Int64.add total size)

let reachable store roots =
  let rec visit visited total = function
    | [] -> Ok (visited, total)
    | identity :: remaining when Object_set.mem identity visited ->
        visit visited total remaining
    | identity :: remaining ->
        let* envelope =
          Store.get store identity
          |> Result.map_error (fun error -> Store_error error)
        in
        let size = Int64.of_int (String.length (Envelope.encode envelope)) in
        let* total = add_size total size in
        let* children = object_children store identity envelope in
        visit
          (Object_set.add identity visited)
          total
          (List.rev_append children remaining)
  in
  visit Object_set.empty 0L roots

type blocked_removal = { checkpoint : Scratch.Checkpoint_id.t; reason : string }

type plan = {
  policy : Policy.t;
  selections : Policy.selection list;
  reachable_object_count : int;
  estimated_before_bytes : int64;
  estimated_after_bytes : int64;
  removable_checkpoints : Scratch.Checkpoint_id.t list;
  removable_events : Scratch.Event_id.t list;
  removable_objects : Store.Stored_object_id.t list;
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
let blocked_removals plan = plan.blocked_removals
let budget_exceeded_by plan = plan.budget_exceeded_by

let retention_head_root store =
  let* reference =
    Store.read_ref store ~name:"retention-head"
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok (Option.bind reference Store.Mutable_ref.target)

let analyze ~store scratch ~policy ~now =
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
             Policy.id = Scratch.Checkpoint.id entry.Scratch.checkpoint;
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
  let* current_objects, estimated_before_bytes = reachable store roots in
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
  lines @ selections @ blocked @ budget
