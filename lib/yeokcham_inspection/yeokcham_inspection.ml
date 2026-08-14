module Capsule = Yeokcham_capsule
module Capsule_store = Yeokcham_capsule_store
module Envelope = Yeokcham_envelope
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace_store = Yeokcham_workspace_store

type storage_bucket =
  | Scratch
  | Capsule
  | Release
  | Chunk
  | Snapshot
  | Workspace
  | Other

type storage_stat = {
  bucket : storage_bucket;
  object_count : int;
  stored_bytes : int64;
}

type storage_report = {
  total_objects : int;
  total_stored_bytes : int64;
  buckets : storage_stat list;
  retained_checkpoints : int;
  retained_checkpoint_object_bytes : int64;
}

type status = {
  scratch_head : Scratch.Checkpoint_id.t option;
  active_generation : Scratch.Generation_id.t option;
  capsule_count : int;
  workspace_count : int;
  release_count : int;
  repository_object_count : int;
}

type timeline_entry = {
  checkpoint : Scratch.Checkpoint_id.t;
  created_at : int64;
  changed_paths : string list;
  snapshot_bytes : int64;
  tags : string list;
  validation_state : string;
  retention : string list;
}

type verification_report = {
  verified_objects : int;
  verified_snapshots : int;
  verified_capsules : int;
  verified_capsule_revisions : int;
  verified_workspaces : int;
  verified_releases : int;
}

type error =
  | Store_error of Store.error
  | Scratch_error of Scratch.error
  | Snapshot_error of Snapshot.error
  | Capsule_error of Capsule_store.error
  | Workspace_error of Workspace_store.error
  | Release_error of Release.error
  | Materialize_error of Snapshot.Materialize.error
  | Invalid_dependency of string
  | Missing_inventory_entry of Store.Stored_object_id.t

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Scratch_error error -> Scratch.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Capsule_error error -> Capsule_store.error_to_string error
  | Workspace_error error -> Workspace_store.error_to_string error
  | Release_error error -> Release.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Invalid_dependency detail -> "invalid capsule dependency: " ^ detail
  | Missing_inventory_entry id ->
      "verified object inventory is missing checkpoint object "
      ^ Store.Stored_object_id.to_hex id

let ( let* ) = Result.bind

let storage_bucket_to_string = function
  | Scratch -> "scratch"
  | Capsule -> "capsule"
  | Release -> "release"
  | Chunk -> "chunk"
  | Snapshot -> "snapshot"
  | Workspace -> "workspace"
  | Other -> "other"

let buckets = [ Scratch; Capsule; Release; Chunk; Snapshot; Workspace; Other ]

let bucket_of_type = function
  | Envelope.Scratch_event | Envelope.Checkpoint | Envelope.Retention_change
  | Envelope.Scratch_generation_segment | Envelope.Scratch_generation
  | Envelope.Scratch_cleanup_manifest ->
      Scratch
  | Envelope.Capsule | Envelope.Capsule_revision -> Capsule
  | Envelope.Release | Envelope.Release_attestation | Envelope.Validation ->
      Release
  | Envelope.Chunk | Envelope.File_manifest -> Chunk
  | Envelope.Content | Envelope.Tree | Envelope.Snapshot -> Snapshot
  | Envelope.Workspace | Envelope.Workspace_revision
  | Envelope.Workspace_attempt | Envelope.Conflict | Envelope.Resolution ->
      Workspace
  | Envelope.Repository_config | Envelope.Git_mapping
  | Envelope.Imported_transition | Envelope.Imported_tag | Envelope.Ref_event
  | Envelope.Device_identity | Envelope.Divergent_ref_set | Envelope.Git_archive
    ->
      Other

let stats entries =
  List.map
    (fun bucket ->
      List.fold_left
        (fun (stat : storage_stat) (entry : Store.object_info) ->
          if bucket_of_type entry.Store.object_type = bucket then
            ({
               bucket;
               object_count = stat.object_count + 1;
               stored_bytes =
                 Int64.add stat.stored_bytes
                   (Int64.of_int entry.Store.stored_bytes);
             }
              : storage_stat)
          else stat)
        { bucket; object_count = 0; stored_bytes = 0L }
        entries)
    buckets

let scratch_repository store = Scratch.open_repository store

let retained_checkpoints scratch entries =
  let* timeline =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let retained =
    List.filter (fun entry -> entry.Scratch.effective_retention <> []) timeline
  in
  let rec count seen bytes = function
    | [] -> Ok (List.length retained, bytes)
    | entry :: rest -> (
        let* resolved =
          Scratch.resolve_checkpoint scratch entry.Scratch.logical_id
          |> Result.map_error (fun error -> Scratch_error error)
        in
        let physical =
          Scratch.resolved_physical_id resolved
          |> Scratch.Checkpoint_id.stored_object_id
        in
        if List.exists (Store.Stored_object_id.equal physical) seen then
          count seen bytes rest
        else
          match
            List.find_opt
              (fun (item : Store.object_info) ->
                Store.Stored_object_id.equal item.Store.id physical)
              entries
          with
          | None -> Error (Missing_inventory_entry physical)
          | Some item ->
              count (physical :: seen)
                (Int64.add bytes (Int64.of_int item.Store.stored_bytes))
                rest)
  in
  count [] 0L retained

let storage store =
  let* entries =
    Store.list_objects store
    |> Result.map_error (fun error -> Store_error error)
  in
  let scratch = scratch_repository store in
  let* retained_checkpoints, retained_checkpoint_object_bytes =
    retained_checkpoints scratch entries
  in
  Ok
    {
      total_objects = List.length entries;
      total_stored_bytes =
        List.fold_left
          (fun total (entry : Store.object_info) ->
            Int64.add total (Int64.of_int entry.Store.stored_bytes))
          0L entries;
      buckets = stats entries;
      retained_checkpoints;
      retained_checkpoint_object_bytes;
    }

let status store =
  let scratch = scratch_repository store in
  let* scratch_head =
    Scratch.head_id scratch
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let* active_generation =
    Scratch.active_generation scratch
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let* capsules =
    Capsule_store.Durable.list store
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let* workspaces =
    Workspace_store.Durable.list store
    |> Result.map_error (fun error -> Workspace_error error)
  in
  let* releases =
    Release.Durable.list store
    |> Result.map_error (fun error -> Release_error error)
  in
  let* objects =
    Store.list_objects store
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok
    {
      scratch_head;
      active_generation = Option.map Scratch.Generation.id active_generation;
      capsule_count = List.length capsules;
      workspace_count = List.length workspaces;
      release_count = List.length releases;
      repository_object_count = List.length objects;
    }

let path_to_string path = String.concat "/" path

let operation_paths operation =
  match operation with
  | Scratch.Create { path; _ }
  | Scratch.Delete { path; _ }
  | Scratch.Modify_content { path; _ }
  | Scratch.Change_mode { path; _ } ->
      [ path ]
  | Scratch.Move { source; destination; _ } -> [ source; destination ]

let snapshot_bytes store snapshot =
  let* snapshot =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* actions =
    Snapshot.Materialize.plan store snapshot
    |> Result.map_error (fun error -> Materialize_error error)
  in
  List.fold_left
    (fun result action ->
      let* total = result in
      match action with
      | Snapshot.Materialize.Create_directory _ -> Ok total
      | Snapshot.Materialize.Write_file { content; _ }
      | Snapshot.Materialize.Create_symlink { target = content; _ } ->
          Snapshot.Content.load store content
          |> Result.map_error (fun error -> Snapshot_error error)
          |> Result.map (fun bytes ->
              Int64.add total (Int64.of_int (String.length bytes))))
    (Ok 0L) actions

let validation_state reasons =
  if
    List.exists
      (fun reason ->
        String.starts_with ~prefix:"validation passed:"
          (Scratch.retention_reason_to_string reason))
      reasons
  then "passed"
  else "not-recorded"

let timeline store ~limit =
  let scratch = scratch_repository store in
  let* entries =
    Scratch.timeline scratch ~limit ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let rec render reversed = function
    | [] -> Ok (List.rev reversed)
    | entry :: rest ->
        let checkpoint = entry.Scratch.checkpoint in
        let* changed_paths =
          match Scratch.Checkpoint.event checkpoint with
          | None -> Ok []
          | Some event ->
              Scratch.Event.load store event
              |> Result.map_error (fun error -> Scratch_error error)
              |> Result.map (fun event ->
                  Scratch.Event.operations event
                  |> List.concat_map operation_paths
                  |> List.map path_to_string
                  |> List.sort_uniq String.compare)
        in
        let* snapshot_bytes =
          snapshot_bytes store (Scratch.Checkpoint.snapshot checkpoint)
        in
        let retention =
          List.map Scratch.retention_reason_to_string
            entry.Scratch.effective_retention
        in
        render
          ({
             checkpoint = entry.Scratch.logical_id;
             created_at = Scratch.Checkpoint.created_at checkpoint;
             changed_paths;
             snapshot_bytes;
             tags = retention;
             validation_state =
               validation_state entry.Scratch.effective_retention;
             retention;
           }
          :: reversed)
          rest
  in
  render [] entries

let verify_snapshot store object_id =
  let snapshot = Snapshot.Snapshot.of_stored_object_id object_id in
  let* snapshot =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  Snapshot.Materialize.plan store snapshot
  |> Result.map_error (fun error -> Materialize_error error)
  |> Result.map (fun _ -> ())

let verify_dependency store = function
  | Capsule.Requires_capsule { capsule; revision = None }
  | Capsule.Conflicts_with_capsule capsule
  | Capsule.Ordered_after capsule ->
      Capsule_store.Durable.read_current store capsule
      |> Result.map_error (fun error -> Capsule_error error)
      |> Result.map (fun _ -> ())
  | Capsule.Requires_capsule { capsule; revision = Some revision } ->
      let* revisions =
        Capsule_store.Durable.history store capsule
        |> Result.map_error (fun error -> Capsule_error error)
      in
      if
        List.exists
          (fun value ->
            Yeokcham_id.Capsule_revision_id.equal revision
              (Capsule_store.revision_id value))
          revisions
      then Ok ()
      else
        Error
          (Invalid_dependency
             "required capsule revision is absent from its current history")
  | Capsule.Requires_release release ->
      Release.Durable.verify store release
      |> Result.map_error (fun error -> Release_error error)
      |> Result.map (fun _ -> ())

let verify_capsule_revision store object_id =
  let* revision =
    Capsule_store.load_revision store object_id
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let link =
    Capsule_store.make_revision_link
      ~capsule:(Capsule_store.revision_capsule revision)
      ~revision:(Capsule_store.revision_id revision)
      ~object_id
  in
  let* revision =
    Capsule_store.Durable.verify_link store link
    |> Result.map_error (fun error -> Capsule_error error)
  in
  List.fold_left
    (fun result dependency ->
      let* () = result in
      verify_dependency store dependency)
    (Ok ())
    (Capsule_store.revision_dependencies revision)

let verify store =
  let* entries =
    Store.list_objects store
    |> Result.map_error (fun error -> Store_error error)
  in
  let* () =
    entries
    |> List.filter (fun (entry : Store.object_info) ->
        entry.Store.object_type = Envelope.Snapshot)
    |> List.fold_left
         (fun result entry ->
           let* () = result in
           verify_snapshot store entry.Store.id)
         (Ok ())
  in
  let* () =
    entries
    |> List.filter (fun (entry : Store.object_info) ->
        entry.Store.object_type = Envelope.Capsule_revision)
    |> List.fold_left
         (fun result entry ->
           let* () = result in
           verify_capsule_revision store entry.Store.id)
         (Ok ())
  in
  let* capsules =
    Capsule_store.Durable.list store
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let* workspaces =
    Workspace_store.Durable.list store
    |> Result.map_error (fun error -> Workspace_error error)
  in
  let* releases =
    Release.Durable.list store
    |> Result.map_error (fun error -> Release_error error)
  in
  let* () =
    List.fold_left
      (fun result release ->
        let* () = result in
        Release.Durable.verify store (Release.release_id release)
        |> Result.map_error (fun error -> Release_error error)
        |> Result.map (fun _ -> ()))
      (Ok ()) releases
  in
  let scratch = scratch_repository store in
  let* _ =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  Ok
    {
      verified_objects = List.length entries;
      verified_snapshots =
        List.length
          (List.filter
             (fun (entry : Store.object_info) ->
               entry.Store.object_type = Envelope.Snapshot)
             entries);
      verified_capsules = List.length capsules;
      verified_capsule_revisions =
        List.length
          (List.filter
             (fun (entry : Store.object_info) ->
               entry.Store.object_type = Envelope.Capsule_revision)
             entries);
      verified_workspaces = List.length workspaces;
      verified_releases = List.length releases;
    }
