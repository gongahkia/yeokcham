module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Journal_store = Yeokcham_v2_restore_journal_store
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Scratch_store = Yeokcham_v2_scratch_store
module Verification = Yeokcham_v2_verification
module V2_model = Yeokcham_v2_model

type checkpoint = {
  event_id : Scratch_store.Ledger.Event_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
  snapshot_id : Yeokcham_id.Snapshot_id.t;
  entry_count : int;
}

type scratch =
  | No_checkpoint
  | Checkpoint of checkpoint
  | Divergent of string list

type status = {
  repository_id : V2_model.Repository_id.t;
  device_id : V2_model.Device_id.t;
  scratch : scratch;
  journal_record_count : int;
}

type storage = {
  encrypted_objects : int;
  encrypted_bytes : int64;
  ledger_frames : int;
  scratch_snapshot_frames : int;
  scratch_protection_frames : int;
  scratch_generation_frames : int;
  capsule_frames : int;
  capsule_revision_frames : int;
  workspace_frames : int;
  workspace_revision_frames : int;
  workspace_attempt_frames : int;
  conflict_frames : int;
  resolution_frames : int;
  restore_journal_records : int;
}

type error =
  | Bootstrap_error of Bootstrap.error
  | Scratch_store_error of Scratch_store.error
  | Object_store_error of Object_store.error
  | Journal_store_error of Journal_store.error
  | Verification_error of Verification.error
  | Io_error of { operation : string; path : string; message : string }

let ( let* ) = Result.bind

let error_to_string = function
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error
  | Object_store_error error -> Object_store.error_to_string error
  | Journal_store_error error -> Journal_store.error_to_string error
  | Verification_error error -> Verification.error_to_string error
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let object_store ~root bootstrap_repository =
  let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
  let capability = Bootstrap_store.capability bootstrap_repository in
  Object_store.open_repository ~root
    ~repository_id:(Bootstrap.repository_id bootstrap)
    ~address_key:(Bootstrap.address_key capability)
    ~encryption_key:(Bootstrap.envelope_key capability)
  |> Result.map_error (fun error -> Object_store_error error)

let journal_store ~root bootstrap_repository =
  let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
  Journal_store.open_repository ~root
    ~repository_id:(Bootstrap.repository_id bootstrap)
  |> Result.map_error (fun error -> Journal_store_error error)

let scratch_status = function
  | Scratch_store.No_checkpoint -> No_checkpoint
  | Scratch_store.Checkpoint checkpoint ->
      Checkpoint
        {
          event_id = checkpoint.Scratch_store.event_id;
          snapshot_ref = checkpoint.Scratch_store.snapshot_ref;
          snapshot_id =
            Yeokcham_model.Snapshot.id checkpoint.Scratch_store.snapshot;
          entry_count =
            List.length
              (Yeokcham_model.Snapshot.entries checkpoint.Scratch_store.snapshot);
        }
  | Scratch_store.Divergent_checkpoints events ->
      Divergent (List.map Scratch_store.Ledger.Event_id.to_hex events)

let status ~root ~bootstrap_repository =
  let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* scratch_state =
    Scratch_store.inspect scratch
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  let* journal = journal_store ~root bootstrap_repository in
  let* records =
    Journal_store.scan journal
    |> Result.map_error (fun error -> Journal_store_error error)
  in
  Ok
    {
      repository_id = Bootstrap.repository_id bootstrap;
      device_id = Bootstrap.device_id bootstrap;
      scratch = scratch_status scratch_state;
      journal_record_count = List.length records;
    }

let storage ~root ~bootstrap_repository =
  let* objects = object_store ~root bootstrap_repository in
  let* refs =
    Object_store.list_object_refs objects
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let rec count bytes ledger snapshots protections generations capsules
      revisions workspaces workspace_revisions workspace_attempts conflicts
      resolutions = function
    | [] ->
        Ok
          ( bytes,
            ledger,
            snapshots,
            protections,
            generations,
            capsules,
            revisions,
            workspaces,
            workspace_revisions,
            workspace_attempts,
            conflicts,
            resolutions )
    | object_ref :: rest ->
        let path = Object_store.object_path objects object_ref in
        let* stat =
          try Ok (Unix.lstat path)
          with Unix.Unix_error (error, _, _) ->
            Error
              (Io_error
                 {
                   operation = "lstat";
                   path;
                   message = Unix.error_message error;
                 })
        in
        let* object_ =
          Object_store.load objects ~object_ref
          |> Result.map_error (fun error -> Object_store_error error)
        in
        let ( ledger,
              snapshots,
              protections,
              generations,
              capsules,
              revisions,
              workspaces,
              workspace_revisions,
              workspace_attempts,
              conflicts,
              resolutions ) =
          match Object.kind object_ with
          | Object.Ledger_event ->
              ( ledger + 1,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Scratch_snapshot ->
              ( ledger,
                snapshots + 1,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Scratch_protection ->
              ( ledger,
                snapshots,
                protections + 1,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Scratch_generation ->
              ( ledger,
                snapshots,
                protections,
                generations + 1,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Capsule ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules + 1,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Capsule_revision ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions + 1,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Workspace ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces + 1,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Workspace_revision ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions + 1,
                workspace_attempts,
                conflicts,
                resolutions )
          | Object.Workspace_attempt ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts + 1,
                conflicts,
                resolutions )
          | Object.Conflict ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts + 1,
                resolutions )
          | Object.Resolution ->
              ( ledger,
                snapshots,
                protections,
                generations,
                capsules,
                revisions,
                workspaces,
                workspace_revisions,
                workspace_attempts,
                conflicts,
                resolutions + 1 )
        in
        count
          Int64.(add bytes (of_int stat.Unix.st_size))
          ledger snapshots protections generations capsules revisions workspaces
          workspace_revisions workspace_attempts conflicts resolutions rest
  in
  let* ( encrypted_bytes,
         ledger_frames,
         scratch_snapshot_frames,
         scratch_protection_frames,
         scratch_generation_frames,
         capsule_frames,
         capsule_revision_frames,
         workspace_frames,
         workspace_revision_frames,
         workspace_attempt_frames,
         conflict_frames,
         resolution_frames ) =
    count 0L 0 0 0 0 0 0 0 0 0 0 0 refs
  in
  let* journal = journal_store ~root bootstrap_repository in
  let* records =
    Journal_store.scan journal
    |> Result.map_error (fun error -> Journal_store_error error)
  in
  Ok
    {
      encrypted_objects = List.length refs;
      encrypted_bytes;
      ledger_frames;
      scratch_snapshot_frames;
      scratch_protection_frames;
      scratch_generation_frames;
      capsule_frames;
      capsule_revision_frames;
      workspace_frames;
      workspace_revision_frames;
      workspace_attempt_frames;
      conflict_frames;
      resolution_frames;
      restore_journal_records = List.length records;
    }

let verify ~root ~bootstrap_repository =
  let bootstrap = Bootstrap_store.bootstrap bootstrap_repository in
  let capability = Bootstrap_store.capability bootstrap_repository in
  let* public_keys =
    Bootstrap.public_key_registry capability
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* repository =
    Verification.open_repository ~root
      ~repository_id:(Bootstrap.repository_id bootstrap)
      ~address_key:(Bootstrap.address_key capability)
      ~encryption_key:(Bootstrap.envelope_key capability)
      ~public_keys
    |> Result.map_error (fun error -> Verification_error error)
  in
  Verification.verify repository
  |> Result.map_error (fun error -> Verification_error error)
