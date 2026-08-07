module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Compaction = Yeokcham_compaction
module Capsule = Yeokcham_capsule
module Capsule_store = Yeokcham_capsule_store
module Workspace = Yeokcham_workspace
module Workspace_store = Yeokcham_workspace_store
module Validation = Yeokcham_validation
module Validation_retention = Yeokcham_validation_retention
module Release = Yeokcham_release
module Git = Yeokcham_git
module Inspection = Yeokcham_inspection

let now () = Int64.of_float (Unix.gettimeofday ())

let fail render error =
  prerr_endline (render error);
  exit 2

let checkpoint_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Scratch.Checkpoint_id.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let capsule_id value =
  match Yeokcham_id.Capsule_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let revision_id value =
  match Yeokcham_id.Capsule_revision_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let revision_link value =
  match String.split_on_char ':' value with
  | [ capsule; revision; object_id ] -> (
      match Store.Stored_object_id.of_hex object_id with
      | Ok object_id ->
          Capsule_store.make_revision_link ~capsule:(capsule_id capsule)
            ~revision:(revision_id revision) ~object_id
      | Error error -> fail Store.Stored_object_id.parse_error_to_string error)
  | _ ->
      fail Fun.id
        "revision link must be capsule-id:revision-id:stored-object-id"

let workspace_id value =
  match Yeokcham_id.Workspace_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let snapshot_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Snapshot.Snapshot.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let conflict_id value =
  match Yeokcham_id.Conflict_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let release_id value =
  match Yeokcham_id.Release_id.of_hex value with
  | Ok identity
    when String.length (Yeokcham_id.Release_id.to_bytes identity) = 32 ->
      identity
  | Ok _ -> fail Fun.id "release ID must be 32 bytes"
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let validation root arguments =
  match arguments with
  | "run" :: options -> (
      let parse_environment value =
        match String.index_opt value '=' with
        | None -> None
        | Some index ->
            Some
              ( String.sub value 0 index,
                String.sub value (index + 1) (String.length value - index - 1)
              )
      in
      let parse_working_directory value =
        if String.is_empty value then Some []
        else
          let values = String.split_on_char '/' value in
          if List.exists String.is_empty values then None else Some values
      in
      let rec parse snapshot executable arguments working_directory timeout_ms
          max_stdout_bytes max_stderr_bytes environment environment_policy
          retain_output retain_passing_checkpoints = function
        | [] -> (
            match (snapshot, executable) with
            | Some snapshot, Some executable ->
                ( snapshot,
                  executable,
                  List.rev arguments,
                  working_directory,
                  timeout_ms,
                  max_stdout_bytes,
                  max_stderr_bytes,
                  List.sort
                    (fun (left, _) (right, _) -> String.compare left right)
                    environment,
                  environment_policy,
                  retain_output,
                  retain_passing_checkpoints )
            | _ -> exit 2)
        | "--snapshot" :: value :: rest ->
            parse
              (Some (snapshot_id value))
              executable arguments working_directory timeout_ms max_stdout_bytes
              max_stderr_bytes environment environment_policy retain_output
              retain_passing_checkpoints rest
        | "--exec" :: value :: rest ->
            parse snapshot (Some value) arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment environment_policy
              retain_output retain_passing_checkpoints rest
        | "--arg" :: value :: rest ->
            parse snapshot executable (value :: arguments) working_directory
              timeout_ms max_stdout_bytes max_stderr_bytes environment
              environment_policy retain_output retain_passing_checkpoints rest
        | "--cwd" :: value :: rest -> (
            match parse_working_directory value with
            | None -> exit 2
            | Some working_directory ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes max_stderr_bytes environment
                  environment_policy retain_output retain_passing_checkpoints
                  rest)
        | "--timeout-ms" :: value :: rest -> (
            match try Some (Int64.of_string value) with Failure _ -> None with
            | Some value ->
                parse snapshot executable arguments working_directory value
                  max_stdout_bytes max_stderr_bytes environment
                  environment_policy retain_output retain_passing_checkpoints
                  rest
            | None -> exit 2)
        | "--max-stdout-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | Some value ->
                parse snapshot executable arguments working_directory timeout_ms
                  value max_stderr_bytes environment environment_policy
                  retain_output retain_passing_checkpoints rest
            | None -> exit 2)
        | "--max-stderr-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | Some value ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes value environment environment_policy
                  retain_output retain_passing_checkpoints rest
            | None -> exit 2)
        | "--env" :: value :: rest -> (
            match parse_environment value with
            | None -> exit 2
            | Some entry ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes max_stderr_bytes (entry :: environment)
                  environment_policy retain_output retain_passing_checkpoints
                  rest)
        | "--inherit-env" :: rest ->
            parse snapshot executable arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment Validation.Inherit
              retain_output retain_passing_checkpoints rest
        | "--retain-output" :: rest ->
            parse snapshot executable arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment environment_policy
              true retain_passing_checkpoints rest
        | "--retain-passing-checkpoints" :: rest ->
            parse snapshot executable arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment environment_policy
              retain_output true rest
        | _ -> exit 2
      in
      let ( snapshot,
            executable,
            arguments,
            working_directory,
            timeout_ms,
            max_stdout_bytes,
            max_stderr_bytes,
            environment,
            environment_policy,
            retain_output,
            retain_passing_checkpoints ) =
        parse None None [] [] 60000L 65536 65536 [] Validation.Empty false false
          options
      in
      let command =
        {
          Validation.executable;
          arguments;
          working_directory;
          timeout_ms;
          max_stdout_bytes;
          max_stderr_bytes;
          environment_policy;
          environment;
          retain_output;
          format_version = 1L;
          mandatory_features = 0L;
        }
      in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let observed_at = now () in
          Validation.run ~store ~snapshot ~command ~command_index:0 ~observed_at
            ()
          |> Result.map_error Validation.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (evidence, object_id) -> (
              let status =
                match Validation.evidence_status evidence with
                | Validation.Passed -> "passed"
                | Validation.Failed -> "failed"
                | Validation.Timed_out -> "timed-out"
                | Validation.Execution_error -> "execution-error"
              in
              let retention =
                if not retain_passing_checkpoints then Ok None
                else
                  let scratch = Scratch.open_repository store in
                  Validation_retention.apply
                    Validation_retention.Pin_all_exact_snapshot_checkpoints
                    ~store ~scratch ~evidence_object:object_id
                    ~changed_at:observed_at
                  |> Result.map_error Validation_retention.error_to_string
                  |> Result.map Option.some
              in
              match retention with
              | Error error -> fail Fun.id error
              | Ok retention ->
                  let retained, already_retained =
                    match retention with
                    | None -> (0, 0)
                    | Some outcome ->
                        ( outcome.Validation_retention.newly_retained,
                          outcome.Validation_retention.already_retained )
                  in
                  Printf.printf
                    "evidence=%s object=%s status=%s retained-checkpoints=%d \
                     already-retained=%d\n"
                    (Yeokcham_id.Validation_id.to_hex
                       (Validation.evidence_id evidence))
                    (Store.Stored_object_id.to_hex object_id)
                    status retained already_retained)))
  | _ -> exit 2

type validation_draft = {
  executable : string;
  arguments : string list;
  working_directory : string list;
  timeout_ms : int64;
  max_stdout_bytes : int;
  max_stderr_bytes : int;
  environment : (string * string) list;
  environment_policy : Validation.environment_policy;
  retain_output : bool;
}

let default_validation_draft executable =
  {
    executable;
    arguments = [];
    working_directory = [];
    timeout_ms = 60000L;
    max_stdout_bytes = 65536;
    max_stderr_bytes = 65536;
    environment = [];
    environment_policy = Validation.Empty;
    retain_output = false;
  }

let validation_command_of_draft draft =
  {
    Validation.executable = draft.executable;
    arguments = List.rev draft.arguments;
    working_directory = draft.working_directory;
    timeout_ms = draft.timeout_ms;
    max_stdout_bytes = draft.max_stdout_bytes;
    max_stderr_bytes = draft.max_stderr_bytes;
    environment =
      List.sort
        (fun (left, _) (right, _) -> String.compare left right)
        draft.environment;
    environment_policy = draft.environment_policy;
    retain_output = draft.retain_output;
    format_version = 1L;
    mandatory_features = 0L;
  }

let release root arguments =
  let parse_environment value =
    match String.index_opt value '=' with
    | None -> None
    | Some index ->
        Some
          ( String.sub value 0 index,
            String.sub value (index + 1) (String.length value - index - 1) )
  in
  let parse_working_directory value =
    if String.is_empty value then Some []
    else
      let values = String.split_on_char '/' value in
      if List.exists String.is_empty values then None else Some values
  in
  let current_draft = function Some draft -> draft | None -> exit 2 in
  match arguments with
  | [ "show"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Release.Durable.read store (release_id identity)
          |> Result.map_error Release.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok release ->
              Printf.printf
                "release=%s workspace=%s revision=%s final=%s evidence=%d\n"
                (Yeokcham_id.Release_id.to_hex (Release.release_id release))
                (Yeokcham_id.Workspace_id.to_hex
                   (Release.release_workspace release))
                (Yeokcham_id.Workspace_revision_id.to_hex
                   (Release.release_workspace_revision release))
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id
                      (Release.release_final_snapshot release)))
                (List.length (Release.release_evidence release))))
  | [ "verify"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Release.Durable.verify store (release_id identity)
          |> Result.map_error Release.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok release ->
              Printf.printf "verified release=%s final=%s\n"
                (Yeokcham_id.Release_id.to_hex (Release.release_id release))
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id
                      (Release.release_final_snapshot release)))))
  | [ "list" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Release.Durable.list store |> Result.map_error Release.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok releases ->
              List.iter
                (fun release ->
                  Printf.printf "%s %s\n"
                    (Yeokcham_id.Release_id.to_hex (Release.release_id release))
                    (Store.Stored_object_id.to_hex
                       (Snapshot.Snapshot.stored_object_id
                          (Release.release_final_snapshot release))))
                releases))
  | "create" :: options -> (
      let rec parse workspace parents message drafts current = function
        | [] -> (
            match workspace with
            | None -> exit 2
            | Some workspace ->
                let drafts =
                  match current with
                  | None -> drafts
                  | Some draft -> draft :: drafts
                in
                (workspace, List.rev parents, message, List.rev drafts))
        | "--workspace" :: value :: rest ->
            parse
              (Some (workspace_id value))
              parents message drafts current rest
        | "--parent" :: value :: rest ->
            parse workspace
              (release_id value :: parents)
              message drafts current rest
        | "--message" :: value :: rest ->
            parse workspace parents (Some value) drafts current rest
        | "--validation-exec" :: value :: rest ->
            let drafts =
              match current with
              | None -> drafts
              | Some draft -> draft :: drafts
            in
            parse workspace parents message drafts
              (Some (default_validation_draft value))
              rest
        | "--validation-arg" :: value :: rest ->
            let draft = current_draft current in
            parse workspace parents message drafts
              (Some { draft with arguments = value :: draft.arguments })
              rest
        | "--validation-cwd" :: value :: rest -> (
            match parse_working_directory value with
            | None -> exit 2
            | Some working_directory ->
                let draft = current_draft current in
                parse workspace parents message drafts
                  (Some { draft with working_directory })
                  rest)
        | "--validation-timeout-ms" :: value :: rest -> (
            match try Some (Int64.of_string value) with Failure _ -> None with
            | None -> exit 2
            | Some timeout_ms ->
                let draft = current_draft current in
                parse workspace parents message drafts
                  (Some { draft with timeout_ms })
                  rest)
        | "--validation-max-stdout-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | None -> exit 2
            | Some max_stdout_bytes ->
                let draft = current_draft current in
                parse workspace parents message drafts
                  (Some { draft with max_stdout_bytes })
                  rest)
        | "--validation-max-stderr-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | None -> exit 2
            | Some max_stderr_bytes ->
                let draft = current_draft current in
                parse workspace parents message drafts
                  (Some { draft with max_stderr_bytes })
                  rest)
        | "--validation-env" :: value :: rest -> (
            match parse_environment value with
            | None -> exit 2
            | Some entry ->
                let draft = current_draft current in
                parse workspace parents message drafts
                  (Some { draft with environment = entry :: draft.environment })
                  rest)
        | "--validation-inherit-env" :: rest ->
            let draft = current_draft current in
            parse workspace parents message drafts
              (Some { draft with environment_policy = Validation.Inherit })
              rest
        | "--validation-retain-output" :: rest ->
            let draft = current_draft current in
            parse workspace parents message drafts
              (Some { draft with retain_output = true })
              rest
        | _ -> exit 2
      in
      let workspace, parents, message, drafts =
        parse None [] None [] None options
      in
      let commands = List.map validation_command_of_draft drafts in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Release.Durable.create ~store ~workspace ~parents ~commands ~message
            ~observed_at:(now ()) ~created_at:(now ()) ()
          |> Result.map_error Release.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok release ->
              Printf.printf "release=%s final=%s evidence=%d\n"
                (Yeokcham_id.Release_id.to_hex (Release.release_id release))
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id
                      (Release.release_final_snapshot release)))
                (List.length (Release.release_evidence release))))
  | _ -> exit 2

let print_checkpoint checkpoint =
  print_endline
    (Store.Stored_object_id.to_hex
       (Scratch.Checkpoint_id.stored_object_id
          (Scratch.Checkpoint.id checkpoint)))

let render_path path = String.concat "/" path

let render_operation = function
  | Scratch.Create { path; _ } -> "create " ^ render_path path
  | Scratch.Delete { path; _ } -> "delete " ^ render_path path
  | Scratch.Modify_content { path; _ } -> "modify " ^ render_path path
  | Scratch.Change_mode { path; _ } -> "mode " ^ render_path path
  | Scratch.Move { source; destination; _ } ->
      "move " ^ render_path source ^ " -> " ^ render_path destination

let render_capsule_operation = function
  | Capsule.Exact_file_transition transition ->
      "exact " ^ render_path transition.Capsule.transition_path
  | Capsule.Text_edit edit -> "text " ^ render_path edit.Capsule.edit_path
  | Capsule.Move { source; destination; _ } ->
      "move " ^ render_path source ^ " -> " ^ render_path destination
  | Capsule.Mode_change { path; _ } -> "mode " ^ render_path path

let parse_root arguments =
  let rec loop root reversed = function
    | "--root" :: path :: rest -> loop path reversed rest
    | value :: rest -> loop root (value :: reversed) rest
    | [] -> (root, List.rev reversed)
  in
  loop (Sys.getcwd ()) [] arguments

let open_scratch root =
  let store =
    Store.open_repository ~root |> Result.map_error Store.error_to_string
  in
  store |> Result.map (fun store -> (store, Scratch.open_repository store))

let initialise root =
  let store = Store.init ~root |> Result.map_error Store.error_to_string in
  match store with
  | Error error -> fail Fun.id error
  | Ok store -> (
      let snapshot =
        Snapshot.scan ~root ~store |> Result.map_error Snapshot.error_to_string
      in
      match snapshot with
      | Error error -> fail Fun.id error
      | Ok (snapshot, _) -> (
          let scratch = Scratch.open_repository store in
          match
            Scratch.create_initial scratch ~snapshot ~created_at:(now ())
          with
          | Ok checkpoint -> print_checkpoint checkpoint
          | Error error -> fail Scratch.error_to_string error))

let checkpoint root =
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (store, scratch) -> (
      let snapshot =
        Snapshot.scan ~root ~store |> Result.map_error Snapshot.error_to_string
      in
      match snapshot with
      | Error error -> fail Fun.id error
      | Ok (snapshot, _) -> (
          let timestamp = now () in
          match
            Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
              ~observed_at:timestamp ~created_at:timestamp
          with
          | Ok (Scratch.Created checkpoint) -> print_checkpoint checkpoint
          | Ok (Scratch.Unchanged checkpoint) ->
              print_endline
                ("unchanged "
                ^ Store.Stored_object_id.to_hex
                    (Scratch.Checkpoint_id.stored_object_id
                       (Scratch.Checkpoint.id checkpoint)))
          | Error error -> fail Scratch.error_to_string error))

let timeline root arguments =
  let limit =
    match arguments with
    | [] -> 32
    | [ "--limit"; value ] -> (
        match int_of_string_opt value with
        | Some value -> value
        | None -> exit 2)
    | _ -> exit 2
  in
  match Store.open_repository ~root with
  | Error error -> fail Store.error_to_string error
  | Ok store -> (
      match Inspection.timeline store ~limit with
      | Error error -> fail Inspection.error_to_string error
      | Ok entries ->
          List.iter
            (fun entry ->
              Printf.printf
                "checkpoint=%s created-at=%Ld changed-paths=%s \
                 snapshot-bytes=%Ld tags=%s validation=%s retention=%s\n"
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id
                      entry.Inspection.checkpoint))
                entry.Inspection.created_at
                (String.concat "," entry.Inspection.changed_paths)
                entry.Inspection.snapshot_bytes
                (String.concat "," entry.Inspection.tags)
                entry.Inspection.validation_state
                (String.concat "," entry.Inspection.retention))
            entries)

let status root arguments =
  match arguments with
  | [] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Inspection.status store with
          | Error error -> fail Inspection.error_to_string error
          | Ok status ->
              let checkpoint = function
                | None -> "none"
                | Some identity ->
                    Store.Stored_object_id.to_hex
                      (Scratch.Checkpoint_id.stored_object_id identity)
              in
              let generation = function
                | None -> "none"
                | Some identity ->
                    Store.Stored_object_id.to_hex
                      (Scratch.Generation_id.stored_object_id identity)
              in
              Printf.printf
                "scratch-head=%s active-generation=%s capsules=%d \
                 workspaces=%d releases=%d objects=%d\n"
                (checkpoint status.Inspection.scratch_head)
                (generation status.Inspection.active_generation)
                status.Inspection.capsule_count
                status.Inspection.workspace_count
                status.Inspection.release_count
                status.Inspection.repository_object_count))
  | _ -> exit 2

let storage root arguments =
  match arguments with
  | [ "stats" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Inspection.storage store with
          | Error error -> fail Inspection.error_to_string error
          | Ok report ->
              List.iter
                (fun (stat : Inspection.storage_stat) ->
                  Printf.printf "bucket=%s objects=%d stored-bytes=%Ld\n"
                    (Inspection.storage_bucket_to_string stat.Inspection.bucket)
                    stat.Inspection.object_count stat.Inspection.stored_bytes)
                report.Inspection.buckets;
              Printf.printf
                "total-objects=%d total-stored-bytes=%Ld \
                 retained-checkpoints=%d retained-checkpoint-object-bytes=%Ld\n"
                report.Inspection.total_objects
                report.Inspection.total_stored_bytes
                report.Inspection.retained_checkpoints
                report.Inspection.retained_checkpoint_object_bytes))
  | _ -> exit 2

let verify root arguments =
  match arguments with
  | [] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Inspection.verify store with
          | Error error -> fail Inspection.error_to_string error
          | Ok report ->
              Printf.printf
                "verified objects=%d snapshots=%d capsules=%d \
                 capsule-revisions=%d workspaces=%d releases=%d\n"
                report.Inspection.verified_objects
                report.Inspection.verified_snapshots
                report.Inspection.verified_capsules
                report.Inspection.verified_capsule_revisions
                report.Inspection.verified_workspaces
                report.Inspection.verified_releases))
  | _ -> exit 2

let restore root arguments =
  let dry_run, target =
    match arguments with
    | [ "--dry-run"; target ] -> (true, target)
    | [ target ] -> (false, target)
    | _ -> exit 2
  in
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (_, scratch) -> (
      let target = checkpoint_id target in
      if dry_run then
        match Scratch.Restore.dry_run scratch ~root ~target with
        | Ok plan ->
            Scratch.Restore.actions plan
            |> List.iter (fun action -> print_endline (render_operation action));
            Printf.printf "%d actions\n"
              (List.length (Scratch.Restore.actions plan))
        | Error error -> fail Scratch.error_to_string error
      else
        let timestamp = now () in
        match
          Scratch.Restore.restore scratch ~root ~target ~observed_at:timestamp
            ~created_at:timestamp
        with
        | Ok None -> print_endline "restored"
        | Ok (Some safety) ->
            Printf.printf "restored safety=%s\n"
              (Store.Stored_object_id.to_hex
                 (Scratch.Checkpoint_id.stored_object_id safety))
        | Error error -> fail Scratch.error_to_string error)

let change_pin root arguments pin =
  match arguments with
  | [ checkpoint ] -> (
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (_, scratch) -> (
          let checkpoint = checkpoint_id checkpoint in
          let result =
            if pin then Scratch.pin scratch checkpoint ~changed_at:(now ())
            else Scratch.unpin scratch checkpoint ~changed_at:(now ())
          in
          match result with
          | Ok () -> print_endline "ok"
          | Error error -> fail Scratch.error_to_string error))
  | _ -> exit 2

let parse_int64 value =
  try Some (Int64.of_string value) with Failure _ -> None

let compact root arguments =
  let default = Compaction.Policy.default in
  let rec parse mode explain recent periodic budget timestamp = function
    | [] ->
        let policy =
          Compaction.Policy.create ~recent_window_seconds:recent
            ~periodic_interval_seconds:periodic ~storage_budget_bytes:budget
          |> Result.map_error Compaction.Policy.error_to_string
        in
        (mode, explain, policy, Option.value timestamp ~default:(now ()))
    | "--dry-run" :: rest ->
        parse `Dry_run explain recent periodic budget timestamp rest
    | "--resume" :: rest ->
        parse `Resume explain recent periodic budget timestamp rest
    | "--prune" :: rest ->
        parse `Prune explain recent periodic budget timestamp rest
    | "--explain" :: rest ->
        parse mode true recent periodic budget timestamp rest
    | "--recent-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value -> parse mode explain value periodic budget timestamp rest
        | None -> exit 2)
    | "--periodic-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value -> parse mode explain recent value budget timestamp rest
        | None -> exit 2)
    | "--storage-budget-bytes" :: value :: rest -> (
        match parse_int64 value with
        | Some value ->
            parse mode explain recent periodic (Some value) timestamp rest
        | None -> exit 2)
    | "--now-unix-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value ->
            parse mode explain recent periodic budget (Some value) rest
        | None -> exit 2)
    | _ -> exit 2
  in
  let mode, explain, policy, timestamp =
    parse `Activate false
      (Compaction.Policy.recent_window_seconds default)
      (Compaction.Policy.periodic_interval_seconds default)
      (Compaction.Policy.storage_budget_bytes default)
      None arguments
  in
  match policy with
  | Error error -> fail Fun.id error
  | Ok policy -> (
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let print_cleanup report =
            Printf.printf
              "generation=%s quarantined-objects=%d quarantined-bytes=%Ld \
               pruned-objects=%d pruned-bytes=%Ld already-quarantined=%d \
               already-pruned=%d\n"
              (Store.Stored_object_id.to_hex
                 (Scratch.Generation_id.stored_object_id
                    report.Compaction.generation))
              report.Compaction.quarantined_objects
              report.Compaction.quarantined_bytes
              report.Compaction.pruned_objects report.Compaction.pruned_bytes
              report.Compaction.already_quarantined_objects
              report.Compaction.already_pruned_objects
          in
          match mode with
          | `Dry_run -> (
              match
                Compaction.analyze ~store scratch ~policy ~now:timestamp
              with
              | Error error -> fail Compaction.error_to_string error
              | Ok plan ->
                  Compaction.render_explain plan |> List.iter print_endline)
          | `Activate -> (
              match
                Compaction.activate ~store scratch ~policy ~now:timestamp
              with
              | Error error -> fail Compaction.error_to_string error
              | Ok execution ->
                  if explain then
                    Compaction.render_explain
                      (Compaction.execution_plan execution)
                    |> List.iter print_endline;
                  print_cleanup (Compaction.execution_cleanup execution))
          | `Resume -> (
              match Compaction.resume_cleanup ~store scratch with
              | Error error -> fail Compaction.error_to_string error
              | Ok report -> print_cleanup report)
          | `Prune -> (
              match Compaction.prune ~store scratch with
              | Error error -> fail Compaction.error_to_string error
              | Ok report -> print_cleanup report)))

let watch root arguments =
  let interval_ms, debounce_ms, iterations =
    let rec parse interval debounce iterations = function
      | [] -> (interval, debounce, iterations)
      | "--interval-ms" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 -> parse value debounce iterations rest
          | Some _ | None -> exit 2)
      | "--debounce-ms" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 -> parse interval value iterations rest
          | Some _ | None -> exit 2)
      | "--iterations" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 ->
              parse interval debounce (Some value) rest
          | Some _ | None -> exit 2)
      | _ -> exit 2
    in
    parse 500 500 None arguments
  in
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (store, scratch) ->
      let polling = ref (Scratch.Polling.create ~debounce_ms) in
      let rec loop count =
        match iterations with
        | Some limit when count >= limit -> ()
        | None | Some _ -> (
            let scanned = Snapshot.scan ~root ~store in
            match scanned with
            | Error error -> fail Snapshot.error_to_string error
            | Ok (snapshot, _) -> (
                let head =
                  Scratch.head scratch
                  |> Result.map_error Scratch.error_to_string
                in
                match head with
                | Error error -> fail Fun.id error
                | Ok None ->
                    prerr_endline "scratch history is not initialized";
                    exit 2
                | Ok (Some checkpoint) ->
                    let updated, checkpoint_now =
                      Scratch.Polling.observe !polling
                        ~head:(Scratch.Checkpoint.snapshot checkpoint)
                        ~observed:snapshot
                        ~now_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.))
                    in
                    polling := updated;
                    if checkpoint_now then (
                      let timestamp = now () in
                      (match
                         Scratch.checkpoint scratch ~snapshot
                           ~source:Scratch.Scan ~observed_at:timestamp
                           ~created_at:timestamp
                       with
                      | Ok (Scratch.Created checkpoint) ->
                          print_checkpoint checkpoint
                      | Ok (Scratch.Unchanged _) -> ()
                      | Error error -> fail Scratch.error_to_string error);
                      if interval_ms > 0 then
                        ignore
                          (Unix.select [] [] []
                             (float_of_int interval_ms /. 1000.));
                      loop (count + 1))))
      in
      loop 0

let revision_link_capsule = Capsule_store.revision_link_capsule
let revision_link_revision = Capsule_store.revision_link_revision
let revision_link_object = Capsule_store.revision_link_object

let render_revision_provenance = function
  | Capsule_store.Created -> "created"
  | Capsule_store.Folded -> "folded"
  | Capsule_store.Split_from (link : Capsule_store.revision_link) ->
      "split-from="
      ^ Yeokcham_id.Capsule_revision_id.to_hex (revision_link_revision link)
  | Capsule_store.Retargeted_from (link : Capsule_store.revision_link) ->
      "retargeted-from="
      ^ Yeokcham_id.Capsule_revision_id.to_hex (revision_link_revision link)
  | Capsule_store.Combined_from links ->
      "combined-from="
      ^ String.concat ","
          (List.map
             (fun (link : Capsule_store.revision_link) ->
               Yeokcham_id.Capsule_revision_id.to_hex
                 (revision_link_revision link))
             links)

let print_plan_output (capsule, revision) =
  Printf.printf
    "output capsule=%s revision=%s base=%s expected=%s operations=%d \
     dependencies=%d provenance=%s\n"
    (Yeokcham_id.Capsule_id.to_hex (Capsule_store.capsule_id capsule))
    (Yeokcham_id.Capsule_revision_id.to_hex
       (Capsule_store.revision_id revision))
    (Store.Stored_object_id.to_hex
       (Snapshot.Snapshot.stored_object_id
          (Capsule_store.revision_declared_base revision)))
    (Store.Stored_object_id.to_hex
       (Snapshot.Snapshot.stored_object_id
          (Capsule_store.revision_expected_result revision)))
    (List.length (Capsule_store.revision_operations revision))
    (List.length (Capsule_store.revision_dependencies revision))
    (render_revision_provenance (Capsule_store.revision_provenance revision))

let print_boundary_pins boundaries =
  List.iter
    (fun boundary ->
      Printf.printf "pin from=%s to=%s\n"
        (Store.Stored_object_id.to_hex
           (Scratch.Checkpoint_id.stored_object_id boundary.Capsule_store.source))
        (Store.Stored_object_id.to_hex
           (Scratch.Checkpoint_id.stored_object_id boundary.Capsule_store.target)))
    boundaries

let print_split_plan plan =
  let source = Capsule_store.Durable.split_plan_source plan in
  Printf.printf
    "plan split source-capsule=%s source-revision=%s source-object=%s\n"
    (Yeokcham_id.Capsule_id.to_hex (revision_link_capsule source))
    (Yeokcham_id.Capsule_revision_id.to_hex (revision_link_revision source))
    (Store.Stored_object_id.to_hex (revision_link_object source));
  Printf.printf "selected-indices=%s outputs=%d\n"
    (String.concat ","
       (List.map string_of_int
          (Capsule_store.Durable.split_plan_selected_operation_indices plan)))
    (List.length (Capsule_store.Durable.split_plan_outputs plan));
  List.iter print_plan_output (Capsule_store.Durable.split_plan_outputs plan);
  List.iter
    (fun (capsule, revision) ->
      Printf.printf "composition capsule=%s revision=%s\n"
        (Yeokcham_id.Capsule_id.to_hex capsule)
        (Yeokcham_id.Capsule_revision_id.to_hex revision))
    (Capsule_store.Durable.split_plan_composition_order plan);
  print_boundary_pins (Capsule_store.Durable.split_plan_boundary_pins plan)

let print_combine_plan plan =
  let sources = Capsule_store.Durable.combine_plan_sources plan in
  Printf.printf "plan combine sources=%d outputs=1\n" (List.length sources);
  List.iteri
    (fun index source ->
      Printf.printf "source[%d] capsule=%s revision=%s object=%s\n" index
        (Yeokcham_id.Capsule_id.to_hex (revision_link_capsule source))
        (Yeokcham_id.Capsule_revision_id.to_hex (revision_link_revision source))
        (Store.Stored_object_id.to_hex (revision_link_object source)))
    (Capsule_store.Durable.combine_plan_composition_order plan);
  print_plan_output (Capsule_store.Durable.combine_plan_output plan);
  print_boundary_pins (Capsule_store.Durable.combine_plan_boundary_pins plan)

let operation_indices value =
  let values = String.split_on_char ',' value in
  if values = [] || List.exists String.is_empty values then exit 2
  else
    match List.map int_of_string_opt values with
    | values when List.for_all Option.is_some values ->
        List.map Option.get values
    | _ -> exit 2

let capsule_revision_dependency value =
  match String.split_on_char ':' value with
  | [ capsule; revision ] ->
      Capsule.Requires_capsule
        { capsule = capsule_id capsule; revision = Some (revision_id revision) }
  | _ -> fail Fun.id "required capsule revision must be capsule-id:revision-id"

let capsule root arguments =
  match arguments with
  | "create" :: "--current" :: options -> (
      let rec parse id title description dependencies = function
        | [] -> (
            match (id, title, description) with
            | Some id, Some title, Some description ->
                (id, title, description, List.rev dependencies)
            | _ -> exit 2)
        | "--id" :: value :: rest ->
            parse (Some (capsule_id value)) title description dependencies rest
        | "--title" :: value :: rest ->
            parse id (Some value) description dependencies rest
        | "--description" :: value :: rest ->
            parse id title (Some value) dependencies rest
        | "--requires-capsule" :: value :: rest ->
            parse id title description
              (Capsule.Requires_capsule
                 { capsule = capsule_id value; revision = None }
              :: dependencies)
              rest
        | "--requires-revision" :: value :: rest ->
            parse id title description
              (capsule_revision_dependency value :: dependencies)
              rest
        | "--requires-release" :: value :: rest ->
            parse id title description
              (Capsule.Requires_release (release_id value) :: dependencies)
              rest
        | "--conflicts-with" :: value :: rest ->
            parse id title description
              (Capsule.Conflicts_with_capsule (capsule_id value) :: dependencies)
              rest
        | "--ordered-after" :: value :: rest ->
            parse id title description
              (Capsule.Ordered_after (capsule_id value) :: dependencies)
              rest
        | _ -> exit 2
      in
      let id, title, description, dependencies =
        parse None None None [] options
      in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let timestamp = now () in
          Capsule_store.Durable.create_from_current ~store ~scratch ~root ~id
            ~title ~description ~dependencies ~evidence:[] ~created_at:timestamp
            ~changed_at:timestamp ()
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (Capsule_store.Durable.No_current_changes { checkpoint; _ }) ->
              Printf.printf "no-changes checkpoint=%s\n"
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id checkpoint))
          | Ok
              (Capsule_store.Durable.Created_from_current
                 { resolved; source; target }) ->
              let revision = Capsule_store.Durable.resolved_revision resolved in
              Printf.printf "capsule=%s revision=%s from=%s to=%s\n"
                (Yeokcham_id.Capsule_id.to_hex id)
                (Yeokcham_id.Capsule_revision_id.to_hex
                   (Capsule_store.revision_id revision))
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id source))
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id target))))
  | [ "list" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Capsule_store.Durable.list store with
          | Error error -> fail Capsule_store.error_to_string error
          | Ok resolved ->
              List.iter
                (fun value ->
                  let capsule = Capsule_store.Durable.resolved_capsule value in
                  let revision =
                    Capsule_store.Durable.resolved_revision value
                  in
                  Printf.printf
                    "capsule=%s revision=%s dependencies=%d title=%S\n"
                    (Yeokcham_id.Capsule_id.to_hex
                       (Capsule_store.capsule_id capsule))
                    (Yeokcham_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_id revision))
                    (List.length (Capsule_store.revision_dependencies revision))
                    (Capsule_store.capsule_title capsule))
                resolved))
  | [ "retarget"; identity; "--onto"; base ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let capsule = capsule_id identity in
          Capsule_store.Durable.retarget ~store ~capsule
            ~base:(snapshot_id base) ~created_at:(now ())
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (Capsule_store.Durable.Retargeted resolved) ->
              let revision = Capsule_store.Durable.resolved_revision resolved in
              Printf.printf "capsule=%s revision=%s retargeted=true\n"
                (Yeokcham_id.Capsule_id.to_hex capsule)
                (Yeokcham_id.Capsule_revision_id.to_hex
                   (Capsule_store.revision_id revision))
          | Ok (Capsule_store.Durable.Retarget_conflicts conflicts) ->
              Printf.printf "capsule=%s retargeted=false conflicts=%d\n"
                (Yeokcham_id.Capsule_id.to_hex capsule)
                (List.length conflicts);
              List.iter
                (fun conflict ->
                  Printf.printf "conflict=%s\n"
                    (Capsule.application_conflict_to_string conflict))
                conflicts))
  | "split" :: source :: options -> (
      let rec parse left_id left_title left_description right_id right_title
          right_description indices confirmed = function
        | [] -> (
            match
              ( left_id,
                left_title,
                left_description,
                right_id,
                right_title,
                right_description,
                indices )
            with
            | ( Some left_id,
                Some left_title,
                Some left_description,
                Some right_id,
                Some right_title,
                Some right_description,
                Some indices ) ->
                ( left_id,
                  left_title,
                  left_description,
                  right_id,
                  right_title,
                  right_description,
                  indices,
                  confirmed )
            | _ -> exit 2)
        | "--left-id" :: value :: rest ->
            parse
              (Some (capsule_id value))
              left_title left_description right_id right_title right_description
              indices confirmed rest
        | "--left-title" :: value :: rest ->
            parse left_id (Some value) left_description right_id right_title
              right_description indices confirmed rest
        | "--left-description" :: value :: rest ->
            parse left_id left_title (Some value) right_id right_title
              right_description indices confirmed rest
        | "--right-id" :: value :: rest ->
            parse left_id left_title left_description
              (Some (capsule_id value))
              right_title right_description indices confirmed rest
        | "--right-title" :: value :: rest ->
            parse left_id left_title left_description right_id (Some value)
              right_description indices confirmed rest
        | "--right-description" :: value :: rest ->
            parse left_id left_title left_description right_id right_title
              (Some value) indices confirmed rest
        | "--left-indices" :: value :: rest ->
            parse left_id left_title left_description right_id right_title
              right_description
              (Some (operation_indices value))
              confirmed rest
        | "--confirm" :: rest ->
            parse left_id left_title left_description right_id right_title
              right_description indices true rest
        | _ -> exit 2
      in
      let ( left_id,
            left_title,
            left_description,
            right_id,
            right_title,
            right_description,
            indices,
            confirmed ) =
        parse None None None None None None None false options
      in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let timestamp = now () in
          let source = capsule_id source in
          let plan =
            Capsule_store.Durable.plan_split ~store ~source ~left_id ~left_title
              ~left_description ~right_id ~right_title ~right_description
              ~left_operation_indices:indices ~created_at:timestamp
          in
          match plan with
          | Error error -> fail Capsule_store.error_to_string error
          | Ok plan -> (
              print_split_plan plan;
              if not confirmed then
                fail Fun.id
                  "explicit confirmation is required before capsule split"
              else
                Capsule_store.Durable.split ~store ~scratch ~source ~left_id
                  ~left_title ~left_description ~right_id ~right_title
                  ~right_description ~left_operation_indices:indices
                  ~created_at:timestamp ~changed_at:timestamp ~confirmed:true ()
                |> Result.map_error Capsule_store.error_to_string
                |> function
                | Error error -> fail Fun.id error
                | Ok (left, right) ->
                    Printf.printf "published left=%s right=%s\n"
                      (Yeokcham_id.Capsule_id.to_hex
                         (Capsule_store.capsule_id
                            (Capsule_store.Durable.resolved_capsule left)))
                      (Yeokcham_id.Capsule_id.to_hex
                         (Capsule_store.capsule_id
                            (Capsule_store.Durable.resolved_capsule right))))))
  | "combine" :: options -> (
      let rec parse id title description sources confirmed = function
        | [] -> (
            match (id, title, description, List.rev sources) with
            | Some id, Some title, Some description, (_ :: _ as sources) ->
                (id, title, description, sources, confirmed)
            | _ -> exit 2)
        | "--id" :: value :: rest ->
            parse
              (Some (capsule_id value))
              title description sources confirmed rest
        | "--title" :: value :: rest ->
            parse id (Some value) description sources confirmed rest
        | "--description" :: value :: rest ->
            parse id title (Some value) sources confirmed rest
        | "--source" :: value :: rest ->
            parse id title description
              (capsule_id value :: sources)
              confirmed rest
        | "--confirm" :: rest -> parse id title description sources true rest
        | _ -> exit 2
      in
      let id, title, description, source_ids, confirmed =
        parse None None None [] false options
      in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let rec resolve_links reversed = function
            | [] -> Ok (List.rev reversed)
            | capsule :: rest -> (
                match Capsule_store.Durable.read_current store capsule with
                | Error _ as error -> error
                | Ok resolved ->
                    let link : Capsule_store.revision_link =
                      Capsule_store.make_revision_link ~capsule
                        ~revision:
                          (Capsule_store.revision_id
                             (Capsule_store.Durable.resolved_revision resolved))
                        ~object_id:
                          (Capsule_store.Durable.resolved_revision_object
                             resolved)
                    in
                    resolve_links (link :: reversed) rest)
          in
          let sources =
            resolve_links [] source_ids
            |> Result.map_error Capsule_store.error_to_string
          in
          match sources with
          | Error error -> fail Fun.id error
          | Ok sources -> (
              let timestamp = now () in
              let plan =
                Capsule_store.Durable.plan_combine ~store ~id ~title
                  ~description ~sources ~created_at:timestamp
              in
              match plan with
              | Error error -> fail Capsule_store.error_to_string error
              | Ok plan -> (
                  print_combine_plan plan;
                  if not confirmed then
                    fail Fun.id
                      "explicit confirmation is required before capsule combine"
                  else
                    Capsule_store.Durable.combine ~store ~scratch ~id ~title
                      ~description ~sources ~created_at:timestamp
                      ~changed_at:timestamp ~confirmed:true ()
                    |> Result.map_error Capsule_store.error_to_string
                    |> function
                    | Error error -> fail Fun.id error
                    | Ok resolved ->
                        Printf.printf "published capsule=%s revision=%s\n"
                          (Yeokcham_id.Capsule_id.to_hex id)
                          (Yeokcham_id.Capsule_revision_id.to_hex
                             (Capsule_store.revision_id
                                (Capsule_store.Durable.resolved_revision
                                   resolved)))))))
  | [ "edit"; identity ] -> (
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let timestamp = now () in
          Capsule_store.Durable.enable_for_editing ~store ~scratch ~root
            ~capsule:(capsule_id identity) ~observed_at:timestamp
            ~created_at:timestamp ()
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok anchor ->
              Printf.printf "editing-anchor=%s\n"
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id anchor))))
  | "fold" :: identity :: options -> (
      let rec parse from target = function
        | [] -> (
            match (from, target) with
            | Some from, Some target -> (from, target)
            | _ -> exit 2)
        | "--from" :: value :: rest ->
            parse (Some (checkpoint_id value)) target rest
        | "--to" :: value :: rest ->
            parse from (Some (checkpoint_id value)) rest
        | _ -> exit 2
      in
      let from, target = parse None None options in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let capsule = capsule_id identity in
          let current =
            Capsule_store.Durable.read_current store capsule
            |> Result.map_error Capsule_store.error_to_string
          in
          match current with
          | Error error -> fail Fun.id error
          | Ok current -> (
              let reference =
                Capsule_store.Durable.resolved_current_ref current
              in
              let timestamp = now () in
              Capsule_store.Durable.fold_from_checkpoints ~store ~scratch
                ~capsule
                ~expected_revision:(Capsule_store.current_revision reference)
                ~expected_generation:
                  (Capsule_store.current_generation reference)
                ~evidence:[] ~from ~target ~created_at:timestamp
                ~changed_at:timestamp ()
              |> Result.map_error Capsule_store.error_to_string
              |> function
              | Error error -> fail Fun.id error
              | Ok resolved ->
                  Printf.printf "capsule=%s revision=%s\n"
                    (Yeokcham_id.Capsule_id.to_hex capsule)
                    (Yeokcham_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_id
                          (Capsule_store.Durable.resolved_revision resolved)))))
      )
  | [ "show"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let resolved =
            Capsule_store.Durable.show store (capsule_id identity)
            |> Result.map_error Capsule_store.error_to_string
          in
          match resolved with
          | Error error -> fail Fun.id error
          | Ok resolved ->
              let capsule = Capsule_store.Durable.resolved_capsule resolved in
              let revision = Capsule_store.Durable.resolved_revision resolved in
              Printf.printf
                "capsule %s\nrevision %s\ntitle %s\ndescription %s\n"
                (Yeokcham_id.Capsule_id.to_hex
                   (Capsule_store.capsule_id capsule))
                (Yeokcham_id.Capsule_revision_id.to_hex
                   (Capsule_store.revision_id revision))
                (Capsule_store.capsule_title capsule)
                (Capsule_store.capsule_description capsule)))
  | [ "current-diff"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Capsule_store.Durable.current_diff store (capsule_id identity)
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok operations ->
              List.iter
                (fun operation ->
                  print_endline (render_capsule_operation operation))
                operations))
  | [ "history"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Capsule_store.Durable.history store (capsule_id identity)
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok revisions ->
              List.iter
                (fun revision ->
                  print_endline
                    (Yeokcham_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_id revision)))
                revisions))
  | _ -> exit 2

let print_workspace resolved =
  let workspace = Workspace_store.resolved_workspace resolved in
  let revision = Workspace_store.resolved_revision resolved in
  let current = Workspace_store.resolved_current_ref resolved in
  Printf.printf "workspace=%s revision=%s generation=%Ld base=%s\n"
    (Yeokcham_id.Workspace_id.to_hex (Workspace_store.workspace_id workspace))
    (Yeokcham_id.Workspace_revision_id.to_hex
       (Workspace_store.revision_id revision))
    (Workspace_store.current_generation current)
    (Store.Stored_object_id.to_hex
       (Snapshot.Snapshot.stored_object_id
          (Workspace_store.revision_base revision)));
  Workspace_store.revision_selected revision
  |> List.iteri (fun index link ->
      Printf.printf "selected[%d] capsule=%s revision=%s object=%s\n" index
        (Yeokcham_id.Capsule_id.to_hex
           (Capsule_store.revision_link_capsule link))
        (Yeokcham_id.Capsule_revision_id.to_hex
           (Capsule_store.revision_link_revision link))
        (Store.Stored_object_id.to_hex
           (Capsule_store.revision_link_object link)));
  match Workspace_store.current_latest_attempt current with
  | None -> ()
  | Some (attempt, object_id) ->
      Printf.printf "latest-attempt=%s object=%s\n"
        (Yeokcham_id.Workspace_attempt_id.to_hex attempt)
        (Store.Stored_object_id.to_hex object_id)

let print_workspace_order order =
  Workspace.revisions order
  |> List.iteri (fun index selected ->
      Printf.printf "order[%d] capsule=%s revision=%s\n" index
        (Yeokcham_id.Capsule_id.to_hex selected.Workspace.capsule)
        (Yeokcham_id.Capsule_revision_id.to_hex selected.Workspace.revision));
  Workspace.edges order
  |> List.iter (fun edge ->
      Printf.printf "edge before=%s after=%s reasons=%s\n"
        (Yeokcham_id.Capsule_revision_id.to_hex edge.Workspace.before)
        (Yeokcham_id.Capsule_revision_id.to_hex edge.Workspace.after)
        (String.concat ","
           (List.map Workspace.edge_kind_to_string edge.Workspace.reasons)))

let legacy_workspace_order root options =
  let parse_order value =
    let values = String.split_on_char ',' value in
    if values = [] || List.exists String.is_empty values then exit 2
    else List.map revision_id values
  in
  let rec parse enabled explicit_order = function
    | [] -> (List.rev enabled, explicit_order)
    | "--enable" :: value :: rest ->
        parse (capsule_id value :: enabled) explicit_order rest
    | "--order" :: value :: rest ->
        if Option.is_some explicit_order then exit 2
        else parse enabled (Some (parse_order value)) rest
    | _ -> exit 2
  in
  let enabled, explicit_order = parse [] None options in
  if enabled = [] then exit 2;
  match Store.open_repository ~root with
  | Error error -> fail Store.error_to_string error
  | Ok store -> (
      let rec resolve reversed = function
        | [] -> Ok (List.rev reversed)
        | capsule :: rest -> (
            match Capsule_store.Durable.read_current store capsule with
            | Error error -> Error (Capsule_store.error_to_string error)
            | Ok resolved ->
                let revision =
                  Capsule_store.Durable.resolved_revision resolved
                in
                let selected : Workspace.selected_revision =
                  {
                    Workspace.capsule =
                      Capsule_store.capsule_id
                        (Capsule_store.Durable.resolved_capsule resolved);
                    revision = Capsule_store.revision_id revision;
                    dependencies = Capsule_store.revision_dependencies revision;
                  }
                in
                resolve (selected :: reversed) rest)
      in
      match resolve [] enabled with
      | Error error -> fail Fun.id error
      | Ok selected -> (
          match Workspace.derive_order ~selected ~explicit_order with
          | Error error -> fail Workspace.error_to_string error
          | Ok order -> print_workspace_order order))

let workspace root arguments =
  match arguments with
  | "create" :: options -> (
      let rec parse id base name description = function
        | [] -> (
            match (id, base) with
            | Some id, Some base -> (id, base, name, description)
            | _ -> exit 2)
        | "--id" :: value :: rest ->
            parse (Some (workspace_id value)) base name description rest
        | "--base" :: value :: rest ->
            parse id (Some (snapshot_id value)) name description rest
        | "--name" :: value :: rest ->
            parse id base (Some value) description rest
        | "--description" :: value :: rest ->
            parse id base name (Some value) rest
        | _ -> exit 2
      in
      let id, base, name, description = parse None None None None options in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.create ~store ~id ~base ~name ~description
            ~created_at:(now ())
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | [ "show"; workspace ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.read_current store (workspace_id workspace)
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | [ "enable"; workspace; revision ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.enable_revision ~store
            ~workspace:(workspace_id workspace) ~revision:(revision_id revision)
            ~expected_generation:None ~created_at:(now ())
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | [ "disable"; workspace; capsule ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.disable_capsule ~store
            ~workspace:(workspace_id workspace) ~capsule:(capsule_id capsule)
            ~expected_generation:None ~created_at:(now ())
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | [ "reorder"; workspace; "--order"; order ] -> (
      let values = String.split_on_char ',' order in
      if values = [] || List.exists String.is_empty values then exit 2;
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.reorder ~store
            ~workspace:(workspace_id workspace)
            ~order:(List.map revision_id values)
            ~expected_generation:None ~created_at:(now ())
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | [ "explain-order"; workspace ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.explain_order store (workspace_id workspace)
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok order -> print_workspace_order order))
  | "explain-order" :: options -> legacy_workspace_order root options
  | ([ "materialise"; workspace ] | [ "materialise"; workspace; "--dry-run" ])
    as values -> (
      let dry_run = List.exists (String.equal "--dry-run") values in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          Workspace_store.Durable.materialise ~store ~scratch ~root
            ~workspace:(workspace_id workspace) ~observed_at:(now ())
            ~created_at:(now ()) ~dry_run ()
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok materialisation ->
              Printf.printf "attempt=%s partial=%b actions=%d\n"
                (Yeokcham_id.Workspace_attempt_id.to_hex
                   (Workspace_store.attempt_id
                      materialisation.Workspace_store.Durable.attempt))
                materialisation.Workspace_store.Durable.partial
                (List.length materialisation.Workspace_store.Durable.actions);
              List.iter
                (fun action -> print_endline (render_operation action))
                materialisation.Workspace_store.Durable.actions))
  | _ -> exit 2

let conflict root arguments =
  match arguments with
  | [ "list"; workspace ] | [ "history"; workspace ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.list_conflicts store (workspace_id workspace)
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok conflicts ->
              List.iter
                (fun conflict ->
                  Printf.printf
                    "conflict=%s capsule=%s revision=%s operation=%d\n"
                    (Yeokcham_id.Conflict_id.to_hex
                       (Workspace_store.conflict_id conflict))
                    (Yeokcham_id.Capsule_id.to_hex
                       (Workspace_store.conflict_capsule conflict))
                    (Yeokcham_id.Capsule_revision_id.to_hex
                       (Workspace_store.conflict_capsule_revision conflict))
                    (Workspace_store.conflict_operation_index conflict))
                conflicts))
  | [ "show"; conflict ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.show_conflict store (conflict_id conflict)
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok conflict ->
              Printf.printf "conflict=%s kind=%s paths=%s candidates=%s\n"
                (Yeokcham_id.Conflict_id.to_hex
                   (Workspace_store.conflict_id conflict))
                (match Workspace_store.conflict_kind conflict with
                | Workspace_store.Missing_or_ambiguous_precondition ->
                    "missing-or-ambiguous-precondition"
                | Workspace_store.Competing_edits -> "competing-edits"
                | Workspace_store.Delete_modify -> "delete-modify"
                | Workspace_store.Move_modify -> "move-modify"
                | Workspace_store.Binary_conflict -> "binary-conflict"
                | Workspace_store.Dependency_failure -> "dependency-failure"
                | Workspace_store.Unsupported_or_uncertain_operation ->
                    "unsupported-or-uncertain-operation")
                (Workspace_store.conflict_paths conflict
                |> List.map render_path |> String.concat ",")
                (String.concat ","
                   (Workspace_store.conflict_candidates conflict))))
  | [ "resolve"; workspace; conflict; "--action"; "skip" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Workspace_store.Durable.resolve_skip ~store
            ~workspace:(workspace_id workspace) ~conflict:(conflict_id conflict)
            ~expected_generation:None ~created_at:(now ())
          |> Result.map_error Workspace_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok resolved -> print_workspace resolved))
  | _ -> exit 2

let git_object_id value =
  let format =
    match String.length value with
    | 40 -> Some Git.Sha1
    | 64 -> Some Git.Sha256
    | _ -> None
  in
  match format with
  | None -> fail Fun.id "Git object ID must be 40 or 64 hexadecimal characters"
  | Some format -> (
      match Git.object_id_of_hex format value with
      | Ok identity -> identity
      | Error error -> fail Git.error_to_string error)

let git root arguments =
  match arguments with
  | [ "import"; "tree"; "--repository"; repository; "--tree"; tree ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.import_tree Git.default_configuration ~store ~repository
              ~tree:(git_object_id tree)
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              Printf.printf "snapshot=%s mapping=%s git-tree=%s\n"
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id result.Git.snapshot))
                (Yeokcham_id.Git_mapping_id.to_hex
                   (Git.mapping_id result.Git.mapping))
                (Git.object_id_to_hex
                   (Git.mapping_git_object result.Git.mapping))))
  | [ "import"; "commit"; "--repository"; repository; "--commit"; commit ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.import_commit Git.default_configuration ~store ~repository
              ~commit:(git_object_id commit)
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              let transition = result.Git.imported_transition in
              let author =
                match Git.imported_transition_author transition with
                | Some author -> Git.bytes_to_hex author
                | None -> "none"
              in
              let committer =
                match Git.imported_transition_committer transition with
                | Some committer -> Git.bytes_to_hex committer
                | None -> "none"
              in
              let message =
                match Git.imported_transition_message transition with
                | Some content ->
                    Snapshot.Content.stored_object_id content
                    |> Store.Stored_object_id.to_hex
                | None -> "none"
              in
              Printf.printf
                "transition=%s snapshot=%s mapping=%s git-commit=%s parents=%s \
                 author-hex=%s committer-hex=%s message=%s\n"
                (Yeokcham_id.Imported_transition_id.to_hex
                   (Git.imported_transition_id transition))
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id
                      (Git.imported_transition_snapshot transition)))
                (Yeokcham_id.Git_mapping_id.to_hex
                   (Git.mapping_id result.Git.commit_mapping))
                (Git.object_id_to_hex
                   (Git.imported_transition_commit transition))
                (Git.imported_transition_parents transition
                |> List.map Git.object_id_to_hex
                |> String.concat ",")
                author committer message))
  | [ "import"; "tag"; "--repository"; repository; "--tag"; tag ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.import_tag Git.default_configuration ~store ~repository ~tag
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              let imported = result.Git.imported_tag in
              let target_kind =
                match Git.imported_tag_target_kind imported with
                | Git.Tag_commit -> "commit"
                | Git.Tag_tree -> "tree"
                | Git.Tag_blob -> "blob"
              in
              let annotation =
                match Git.imported_tag_annotation imported with
                | None -> "none"
                | Some content ->
                    Snapshot.Content.stored_object_id content
                    |> Store.Stored_object_id.to_hex
              in
              Printf.printf
                "tag=%s mapping=%s git-object=%s target=%s target-kind=%s \
                 annotation=%s\n"
                (Yeokcham_id.Imported_tag_id.to_hex
                   (Git.imported_tag_id imported))
                (Yeokcham_id.Git_mapping_id.to_hex
                   (Git.mapping_id result.Git.tag_mapping))
                (Git.object_id_to_hex (Git.imported_tag_ref_object imported))
                (Git.object_id_to_hex (Git.imported_tag_target imported))
                target_kind annotation))
  | "export" :: "release" :: options -> (
      let set_once value next =
        match value with None -> Some next | Some _ -> exit 2
      in
      let rec parse repository release author_name author_email committer_name
          committer_email message = function
        | [] -> (
            match (repository, release) with
            | Some repository, Some release ->
                let metadata =
                  match
                    ( author_name,
                      author_email,
                      committer_name,
                      committer_email,
                      message )
                  with
                  | None, None, None, None, None -> None
                  | ( Some author_name,
                      Some author_email,
                      Some committer_name,
                      Some committer_email,
                      Some message ) ->
                      Some
                        {
                          Git.release_export_author =
                            {
                              Git.git_identity_name = author_name;
                              git_identity_email = author_email;
                            };
                          release_export_committer =
                            {
                              Git.git_identity_name = committer_name;
                              git_identity_email = committer_email;
                            };
                          release_export_message = message;
                        }
                  | _ -> exit 2
                in
                (repository, release, metadata)
            | _ -> exit 2)
        | "--repository" :: value :: rest ->
            parse
              (set_once repository value)
              release author_name author_email committer_name committer_email
              message rest
        | "--release" :: value :: rest ->
            parse repository (set_once release value) author_name author_email
              committer_name committer_email message rest
        | "--author-name" :: value :: rest ->
            parse repository release
              (set_once author_name value)
              author_email committer_name committer_email message rest
        | "--author-email" :: value :: rest ->
            parse repository release author_name
              (set_once author_email value)
              committer_name committer_email message rest
        | "--committer-name" :: value :: rest ->
            parse repository release author_name author_email
              (set_once committer_name value)
              committer_email message rest
        | "--committer-email" :: value :: rest ->
            parse repository release author_name author_email committer_name
              (set_once committer_email value)
              message rest
        | "--message" :: value :: rest ->
            parse repository release author_name author_email committer_name
              committer_email (set_once message value) rest
        | _ -> exit 2
      in
      let repository, release, metadata =
        parse None None None None None None None options
      in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.export_release ?metadata Git.default_configuration ~store
              ~repository ~release:(release_id release)
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              let policy =
                match metadata with None -> "default" | Some _ -> "configured"
              in
              Printf.printf
                "release=%s snapshot=%s git-tree=%s git-commit=%s ref=%s \
                 mapping=%s metadata=%s\n"
                (Yeokcham_id.Release_id.to_hex result.Git.export_release)
                (Store.Stored_object_id.to_hex
                   (Snapshot.Snapshot.stored_object_id
                      result.Git.export_snapshot))
                (Git.object_id_to_hex result.Git.export_tree)
                (Git.object_id_to_hex result.Git.export_commit)
                result.Git.export_target_ref
                (Yeokcham_id.Git_mapping_id.to_hex
                   (Git.mapping_id result.Git.export_mapping))
                policy))
  | "export" :: "revisions" :: options -> (
      let rec parse repository revisions = function
        | [] -> (
            match (repository, List.rev revisions) with
            | Some repository, (_ :: _ as revisions) -> (repository, revisions)
            | _ -> exit 2)
        | "--repository" :: repository :: rest ->
            parse (Some repository) revisions rest
        | "--revision" :: source :: rest ->
            parse repository (revision_link source :: revisions) rest
        | _ -> exit 2
      in
      let repository, revisions = parse None [] options in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.export_revisions Git.default_configuration ~store ~repository
              ~revisions
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              List.iter
                (fun exported ->
                  let source = exported.Git.revision_export_source in
                  Printf.printf
                    "capsule=%s revision=%s revision-object=%s snapshot=%s \
                     git-tree=%s git-commit=%s mapping=%s\n"
                    (Yeokcham_id.Capsule_id.to_hex
                       (Capsule_store.revision_link_capsule source))
                    (Yeokcham_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_link_revision source))
                    (Store.Stored_object_id.to_hex
                       (Capsule_store.revision_link_object source))
                    (Store.Stored_object_id.to_hex
                       (Snapshot.Snapshot.stored_object_id
                          exported.Git.revision_export_snapshot))
                    (Git.object_id_to_hex exported.Git.revision_export_tree)
                    (Git.object_id_to_hex exported.Git.revision_export_commit)
                    (Yeokcham_id.Git_mapping_id.to_hex
                       (Git.mapping_id exported.Git.revision_export_mapping)))
                result.Git.revision_exports;
              Printf.printf
                "ref=%s metadata=yeokcham-export-revision-created-at-utc\n"
                result.Git.revision_export_target_ref))
  | _ -> exit 2

let usage ?(status = 2) () =
  let message =
    "usage: yeokcham \
     <init|status|checkpoint|timeline|restore|pin|unpin|compact|watch|capsule|work|conflict|validation|release|storage|verify|git> \
     [--root PATH] ..."
  in
  if status = 0 then print_endline message else prerr_endline message;
  exit status

let () =
  Sys.catch_break true;
  try
    match Array.to_list Sys.argv with
    | [ _; ("--help" | "-h" | "help") ] -> usage ~status:0 ()
    | _ :: command :: arguments -> (
        let root, arguments = parse_root arguments in
        match command with
        | "init" when arguments = [] -> initialise root
        | "status" -> status root arguments
        | "checkpoint" when arguments = [] -> checkpoint root
        | "timeline" -> timeline root arguments
        | "restore" -> restore root arguments
        | "pin" -> change_pin root arguments true
        | "unpin" -> change_pin root arguments false
        | "compact" -> compact root arguments
        | "watch" -> watch root arguments
        | "capsule" -> capsule root arguments
        | "work" -> workspace root arguments
        | "conflict" -> conflict root arguments
        | "validation" -> validation root arguments
        | "release" -> release root arguments
        | "storage" -> storage root arguments
        | "verify" -> verify root arguments
        | "git" -> git root arguments
        | _ -> usage ())
    | _ -> usage ()
  with Sys.Break -> print_endline "watch stopped"
