module Service = Yeokcham_local_service
module Inspection = Yeokcham_inspection
module Scratch = Yeokcham_scratch
module Store = Yeokcham_store

type command =
  | Init
  | Archive of { archive_name : string }
  | Reset of { archive_name : string }
  | Status
  | Timeline of { limit : int }
  | Storage_stats
  | Verify

type parse_error = Invalid_arguments

type response =
  | Initialized
  | Already_initialized
  | Init_refused of Service.root_availability
  | Archived of Service.archive_outcome
  | Reset_completed
  | Already_reset
  | Inspected_status of Inspection.status
  | Inspected_timeline of Inspection.timeline_entry list
  | Inspected_storage of Inspection.storage_report
  | Inspected_verification of Inspection.verification_report

let parse_reset arguments =
  let rec loop archive_name confirmed = function
    | [] -> (
        match (archive_name, confirmed) with
        | Some archive_name, true -> Ok (Reset { archive_name })
        | None, _ | Some _, false -> Error Invalid_arguments)
    | "--archive" :: name :: rest when Option.is_none archive_name ->
        loop (Some name) confirmed rest
    | "--confirm-v2-reset" :: rest when not confirmed ->
        loop archive_name true rest
    | _ -> Error Invalid_arguments
  in
  loop None false arguments

let parse ~name ~arguments =
  match (name, arguments) with
  | "init", [] -> Ok Init
  | "archive", [ "--name"; archive_name ] -> Ok (Archive { archive_name })
  | "reset", arguments -> parse_reset arguments
  | "status", [] -> Ok Status
  | "timeline", [] -> Ok (Timeline { limit = 32 })
  | "timeline", [ "--limit"; value ] -> (
      match int_of_string_opt value with
      | Some limit -> Ok (Timeline { limit })
      | None -> Error Invalid_arguments)
  | "storage", [ "stats" ] -> Ok Storage_stats
  | "verify", [] -> Ok Verify
  | _ -> Error Invalid_arguments

let execute ~root = function
  | Init ->
      Service.initialize ~root
      |> Result.map (function
        | Service.Initialized -> Initialized
        | Service.Already_initialized -> Already_initialized
        | Service.Init_refused availability -> Init_refused availability)
  | Archive { archive_name } ->
      Service.archive ~root ~archive_name
      |> Result.map (fun result -> Archived result)
  | Reset { archive_name } ->
      Service.reset ~root ~archive_name ~confirm:true
      |> Result.map (function
        | Service.Reset -> Reset_completed
        | Service.Already_reset -> Already_reset)
  | Status ->
      Service.status ~root |> Result.map (fun status -> Inspected_status status)
  | Timeline { limit } ->
      Service.timeline ~root ~limit
      |> Result.map (fun timeline -> Inspected_timeline timeline)
  | Storage_stats ->
      Service.storage ~root
      |> Result.map (fun storage -> Inspected_storage storage)
  | Verify ->
      Service.verify ~root
      |> Result.map (fun report -> Inspected_verification report)

let checkpoint = function
  | None -> "none"
  | Some identity ->
      Store.Stored_object_id.to_hex
        (Scratch.Checkpoint_id.stored_object_id identity)

let generation = function
  | None -> "none"
  | Some identity ->
      Store.Stored_object_id.to_hex
        (Scratch.Generation_id.stored_object_id identity)

let render = function
  | Initialized -> [ "initialized empty V2 repository" ]
  | Already_initialized -> [ "V2 repository is already initialized" ]
  | Init_refused Service.Legacy ->
      [
        "legacy repository detected; init will not overwrite it. Run `yeokcham \
         archive --name <archive-name>` first.";
      ]
  | Init_refused (Service.Mixed_or_unknown detail) ->
      [ "init refused mixed or unknown repository state: " ^ detail ]
  | Init_refused (Service.Incomplete detail) ->
      [ "init refused incomplete repository state: " ^ detail ]
  | Init_refused (Service.V2_ready | Service.Uninitialized) ->
      [ "init reached an invalid root state" ]
  | Archived outcome ->
      let prefix =
        if outcome.Service.already_archived then "already-archived"
        else "archived"
      in
      [
        Printf.sprintf "%s=%s manifest=%s" prefix outcome.Service.archive_path
          outcome.Service.manifest_path;
      ]
  | Reset_completed ->
      [ "initialized empty V2 repository after verified archive" ]
  | Already_reset ->
      [ "V2 repository is already initialized; archive remains verified" ]
  | Inspected_status status ->
      [
        Printf.sprintf
          "scratch-head=%s active-generation=%s capsules=%d workspaces=%d \
           releases=%d objects=%d"
          (checkpoint status.Inspection.scratch_head)
          (generation status.Inspection.active_generation)
          status.Inspection.capsule_count status.Inspection.workspace_count
          status.Inspection.release_count
          status.Inspection.repository_object_count;
      ]
  | Inspected_timeline entries ->
      List.map
        (fun entry ->
          Printf.sprintf
            "checkpoint=%s created-at=%Ld changed-paths=%s snapshot-bytes=%Ld \
             tags=%s validation=%s retention=%s"
            (Store.Stored_object_id.to_hex
               (Scratch.Checkpoint_id.stored_object_id
                  entry.Inspection.checkpoint))
            entry.Inspection.created_at
            (String.concat "," entry.Inspection.changed_paths)
            entry.Inspection.snapshot_bytes
            (String.concat "," entry.Inspection.tags)
            entry.Inspection.validation_state
            (String.concat "," entry.Inspection.retention))
        entries
  | Inspected_storage report ->
      let buckets =
        List.map
          (fun (stat : Inspection.storage_stat) ->
            Printf.sprintf "bucket=%s objects=%d stored-bytes=%Ld"
              (Inspection.storage_bucket_to_string stat.Inspection.bucket)
              stat.Inspection.object_count stat.Inspection.stored_bytes)
          report.Inspection.buckets
      in
      buckets
      @ [
          Printf.sprintf
            "total-objects=%d total-stored-bytes=%Ld retained-checkpoints=%d \
             retained-checkpoint-object-bytes=%Ld"
            report.Inspection.total_objects report.Inspection.total_stored_bytes
            report.Inspection.retained_checkpoints
            report.Inspection.retained_checkpoint_object_bytes;
        ]
  | Inspected_verification report ->
      [
        Printf.sprintf
          "verified objects=%d snapshots=%d capsules=%d capsule-revisions=%d \
           workspaces=%d releases=%d"
          report.Inspection.verified_objects
          report.Inspection.verified_snapshots
          report.Inspection.verified_capsules
          report.Inspection.verified_capsule_revisions
          report.Inspection.verified_workspaces
          report.Inspection.verified_releases;
      ]

let parse_error_to_string = function
  | Invalid_arguments -> "invalid command arguments"
