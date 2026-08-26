module Capsule = Yeokcham_capsule
module Capsule_store = Yeokcham_capsule_store
module Envelope = Yeokcham_envelope
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace_store = Yeokcham_workspace_store
module Id = Yeokcham_id

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

type history_scope =
  | Combined_history
  | Scratch_history
  | Capsule_histories
  | Workspace_history of Id.Workspace_id.t
  | Release_history

type history_section = { heading : string; lines : string list }
type history_graph = { sections : history_section list }

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
  | Invalid_history_link of string
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
  | Invalid_history_link detail -> "invalid history link: " ^ detail
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
  | Envelope.Git_adoption | Envelope.Peer_publication
  | Envelope.Peer_integration | Envelope.Git_lineage_node | Envelope.Git_lineage
  | Envelope.Peer_identity | Envelope.Peer_contact | Envelope.Peer_advertisement
  | Envelope.Peer_sync_node | Envelope.Peer_sync_conflict
  | Envelope.V4_project_state ->
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

let short_id value =
  let length = String.length value in
  if length <= 12 then value else String.sub value 0 12

let checkpoint_text identity =
  Scratch.Checkpoint_id.stored_object_id identity
  |> Store.Stored_object_id.to_hex |> short_id

let capsule_text identity = Id.Capsule_id.to_hex identity |> short_id

let capsule_revision_text identity =
  Id.Capsule_revision_id.to_hex identity |> short_id

let workspace_text identity = Id.Workspace_id.to_hex identity |> short_id

let workspace_revision_text identity =
  Id.Workspace_revision_id.to_hex identity |> short_id

let conflict_text identity = Id.Conflict_id.to_hex identity |> short_id
let resolution_text identity = Id.Resolution_id.to_hex identity |> short_id
let release_text identity = Id.Release_id.to_hex identity |> short_id
let quoted value = Printf.sprintf "%S" value

let capsule_link_text link =
  Printf.sprintf "capsule=%s revision=%s"
    (capsule_text (Capsule_store.revision_link_capsule link))
    (capsule_revision_text (Capsule_store.revision_link_revision link))

let capsule_provenance_text = function
  | Capsule_store.Created -> "created"
  | Capsule_store.Folded -> "folded"
  | Capsule_store.Retargeted_from link ->
      "retargeted-from " ^ capsule_link_text link
  | Capsule_store.Split_from link -> "split-from " ^ capsule_link_text link
  | Capsule_store.Combined_from links ->
      "combined-from " ^ String.concat "," (List.map capsule_link_text links)

let scratch_history_section store =
  let scratch = scratch_repository store in
  let* entries =
    Scratch.timeline scratch ~limit:max_int ()
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let lines =
    match entries with
    | [] -> [ "  (no retained checkpoints)" ]
    | entries ->
        entries
        |> List.mapi (fun index entry ->
            let checkpoint = entry.Scratch.checkpoint in
            let node =
              Printf.sprintf "  * checkpoint %s created-at=%Ld"
                (checkpoint_text entry.Scratch.logical_id)
                (Scratch.Checkpoint.created_at checkpoint)
            in
            if index = List.length entries - 1 then [ node ]
            else [ node; "  | parent" ])
        |> List.concat
  in
  Ok { heading = "scratch (retained checkpoints, newest first)"; lines }

let capsule_history_lines store resolved =
  let capsule = Capsule_store.Durable.resolved_capsule resolved in
  let current = Capsule_store.Durable.resolved_revision resolved in
  let* revisions =
    Capsule_store.Durable.history store (Capsule_store.capsule_id capsule)
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let revision_lines =
    revisions
    |> List.concat_map (fun revision ->
        let marker =
          if
            Id.Capsule_revision_id.equal
              (Capsule_store.revision_id revision)
              (Capsule_store.revision_id current)
          then " current"
          else ""
        in
        let node =
          Printf.sprintf "  |-- revision %s%s created-at=%Ld provenance=%s"
            (capsule_revision_text (Capsule_store.revision_id revision))
            marker
            (Capsule_store.revision_created_at revision)
            (capsule_provenance_text
               (Capsule_store.revision_provenance revision))
        in
        match Capsule_store.revision_parent revision with
        | None -> [ node ]
        | Some parent ->
            [
              node;
              Printf.sprintf "  |   +-- parent -> revision %s"
                (capsule_revision_text parent.Capsule_store.revision);
            ])
  in
  Ok
    (Printf.sprintf "  * capsule %s title=%s"
       (capsule_text (Capsule_store.capsule_id capsule))
       (quoted (Capsule_store.capsule_title capsule))
    :: revision_lines)

let capsule_history_section store =
  let* capsules =
    Capsule_store.Durable.list store
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed |> List.concat)
    | resolved :: rest ->
        let* lines = capsule_history_lines store resolved in
        collect (lines :: reversed) rest
  in
  let* lines = collect [] capsules in
  let lines = if lines = [] then [ "  (no capsules)" ] else lines in
  Ok { heading = "capsules (immutable revisions)"; lines }

let workspace_conflict_kind_text = function
  | Workspace_store.Missing_or_ambiguous_precondition ->
      "missing-or-ambiguous-precondition"
  | Workspace_store.Competing_edits -> "competing-edits"
  | Workspace_store.Delete_modify -> "delete-modify"
  | Workspace_store.Move_modify -> "move-modify"
  | Workspace_store.Binary_conflict -> "binary-conflict"
  | Workspace_store.Dependency_failure -> "dependency-failure"
  | Workspace_store.Unsupported_or_uncertain_operation ->
      "unsupported-or-uncertain-operation"

let workspace_revision_history store ~workspace ~revision ~object_id =
  let rec collect seen reversed revision object_id =
    let identity = Workspace_store.revision_id revision in
    if
      List.exists
        (fun seen -> Id.Workspace_revision_id.equal seen identity)
        seen
    then
      Error
        (Invalid_history_link
           ("workspace revision cycle at " ^ workspace_revision_text identity))
    else if
      not
        (Id.Workspace_id.equal
           (Workspace_store.revision_workspace revision)
           workspace)
    then
      Error
        (Invalid_history_link
           ("workspace revision belongs to another workspace: "
           ^ workspace_revision_text identity))
    else
      match Workspace_store.revision_parent revision with
      | None -> Ok (List.rev ((revision, object_id) :: reversed))
      | Some parent ->
          let* parent_revision =
            Workspace_store.load_revision store
              parent.Workspace_store.parent_object_id
            |> Result.map_error (fun error -> Workspace_error error)
          in
          if
            not
              (Id.Workspace_revision_id.equal
                 (Workspace_store.revision_id parent_revision)
                 parent.Workspace_store.parent_revision)
          then
            Error
              (Invalid_history_link
                 ("workspace parent object does not match revision "
                 ^ workspace_revision_text
                     parent.Workspace_store.parent_revision))
          else
            collect (identity :: seen)
              ((revision, object_id) :: reversed)
              parent_revision parent.Workspace_store.parent_object_id
  in
  collect [] [] revision object_id

let workspace_revision_lines revision =
  let node =
    Printf.sprintf "  |-- revision %s created-at=%Ld"
      (workspace_revision_text (Workspace_store.revision_id revision))
      (Workspace_store.revision_created_at revision)
  in
  let parent_lines =
    match Workspace_store.revision_parent revision with
    | None -> []
    | Some parent ->
        [
          Printf.sprintf "  |   +-- parent -> revision %s"
            (workspace_revision_text parent.Workspace_store.parent_revision);
        ]
  in
  let selection_lines =
    Workspace_store.revision_selected revision
    |> List.map (fun link -> "  |   +-- selects -> " ^ capsule_link_text link)
  in
  let order_lines =
    Workspace_store.revision_precedence revision
    |> List.map (fun edge ->
        Printf.sprintf "  |   +-- order %s -> %s"
          (capsule_revision_text edge.Workspace_store.before)
          (capsule_revision_text edge.Workspace_store.after))
  in
  let resolution_lines =
    Workspace_store.revision_resolutions revision
    |> List.map (fun binding ->
        Printf.sprintf "  |   +-- resolution %s -> conflict %s"
          (resolution_text binding.Workspace_store.binding_resolution)
          (conflict_text binding.Workspace_store.binding_conflict))
  in
  (node :: parent_lines) @ selection_lines @ order_lines @ resolution_lines

let workspace_history_lines store resolved =
  let workspace = Workspace_store.resolved_workspace resolved in
  let workspace_id = Workspace_store.workspace_id workspace in
  let* revisions =
    workspace_revision_history store ~workspace:workspace_id
      ~revision:(Workspace_store.resolved_revision resolved)
      ~object_id:(Workspace_store.resolved_revision_object resolved)
  in
  let* conflicts =
    Workspace_store.Durable.list_conflicts store workspace_id
    |> Result.map_error (fun error -> Workspace_error error)
  in
  let conflict_lines =
    conflicts
    |> List.map (fun conflict ->
        Printf.sprintf "  |-- conflict %s revision=%s capsule=%s kind=%s"
          (conflict_text (Workspace_store.conflict_id conflict))
          (workspace_revision_text
             (Workspace_store.conflict_workspace_revision conflict))
          (capsule_text (Workspace_store.conflict_capsule conflict))
          (workspace_conflict_kind_text
             (Workspace_store.conflict_kind conflict)))
  in
  let name =
    match Workspace_store.workspace_name workspace with
    | None -> "none"
    | Some value -> quoted value
  in
  Ok
    (Printf.sprintf "  * workspace %s name=%s"
       (workspace_text workspace_id)
       name
     :: List.concat_map
          (fun (revision, _) -> workspace_revision_lines revision)
          revisions
    @ conflict_lines)

let workspace_history_section store scope =
  let* workspaces =
    match scope with
    | Workspace_history workspace ->
        Workspace_store.Durable.read_current store workspace
        |> Result.map (fun resolved -> [ resolved ])
        |> Result.map_error (fun error -> Workspace_error error)
    | Combined_history ->
        Workspace_store.Durable.list store
        |> Result.map_error (fun error -> Workspace_error error)
    | Scratch_history | Capsule_histories | Release_history -> Ok []
  in
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed |> List.concat)
    | resolved :: rest ->
        let* lines = workspace_history_lines store resolved in
        collect (lines :: reversed) rest
  in
  let* lines = collect [] workspaces in
  let lines = if lines = [] then [ "  (no workspaces)" ] else lines in
  Ok { heading = "workspaces (selected capsule revisions)"; lines }

let compare_release left right =
  String.compare
    (Id.Release_id.to_hex (Release.release_id left))
    (Id.Release_id.to_hex (Release.release_id right))

let release_history_section store =
  let* releases =
    Release.Durable.list store
    |> Result.map_error (fun error -> Release_error error)
  in
  let lines =
    releases |> List.sort compare_release
    |> List.concat_map (fun release ->
        let message =
          match Release.release_message release with
          | None -> "none"
          | Some value -> quoted value
        in
        let parents =
          Release.release_parents release
          |> List.sort (fun left right ->
              String.compare
                (Id.Release_id.to_hex left)
                (Id.Release_id.to_hex right))
          |> List.map (fun parent ->
              "  |-- parent -> release " ^ release_text parent)
        in
        let workspace =
          [
            Printf.sprintf "  |-- workspace -> %s revision=%s"
              (workspace_text (Release.release_workspace release))
              (workspace_revision_text
                 (Release.release_workspace_revision release));
          ]
        in
        let capsules =
          Release.release_capsules release
          |> List.sort (fun left right ->
              String.compare (capsule_link_text left) (capsule_link_text right))
          |> List.map (fun link -> "  |-- selects -> " ^ capsule_link_text link)
        in
        Printf.sprintf "  * release %s created-at=%Ld message=%s"
          (release_text (Release.release_id release))
          (Release.release_created_at release)
          message
        :: parents
        @ workspace @ capsules)
  in
  let lines = if lines = [] then [ "  (no releases)" ] else lines in
  Ok { heading = "releases (immutable reproducible snapshots)"; lines }

let history_graph store ~scope =
  match scope with
  | Scratch_history ->
      scratch_history_section store
      |> Result.map (fun section -> { sections = [ section ] })
  | Capsule_histories ->
      capsule_history_section store
      |> Result.map (fun section -> { sections = [ section ] })
  | Workspace_history _ ->
      workspace_history_section store scope
      |> Result.map (fun section -> { sections = [ section ] })
  | Release_history ->
      release_history_section store
      |> Result.map (fun section -> { sections = [ section ] })
  | Combined_history ->
      let* scratch = scratch_history_section store in
      let* capsules = capsule_history_section store in
      let* workspaces = workspace_history_section store scope in
      let* releases = release_history_section store in
      Ok { sections = [ scratch; capsules; workspaces; releases ] }

let render_history_graph graph =
  let header =
    [
      "history graph (retained native records; not a command event log)";
      "legend: * record, | parent or contained record, +-- typed relationship";
    ]
  in
  header
  @ List.concat_map
      (fun section -> "" :: section.heading :: section.lines)
      graph.sections

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
