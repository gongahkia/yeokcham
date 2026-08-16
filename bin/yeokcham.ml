module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Cutover = Yeokcham_cutover
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
module Local_service = Yeokcham_local_service
module Local_command = Yeokcham_local_command
module Peer = Yeokcham_peer
module Peer_sync = Yeokcham_peer_sync
module Progress = Yeokcham_cli_progress

let ( let* ) = Result.bind
let now () = Int64.of_float (Unix.gettimeofday ())
let progress_enabled = ref false

let with_determinate_progress message callback =
  Progress.with_determinate_progress ~enabled:!progress_enabled ~message
    callback

let fail render error =
  Progress.stop_active ();
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

let parse_cli_options arguments =
  let rec loop root no_progress reversed = function
    | "--root" :: path :: rest -> loop path no_progress reversed rest
    | "--no-progress" :: rest -> loop root true reversed rest
    | value :: rest -> loop root no_progress (value :: reversed) rest
    | [] -> (root, no_progress, List.rev reversed)
  in
  loop (Sys.getcwd ()) false [] arguments

let has_option option = List.exists (String.equal option)

let compaction_is_dry_run arguments =
  List.fold_left
    (fun mode -> function
      | "--dry-run" -> `Dry_run
      | "--resume" | "--prune" -> `Mutating
      | _ -> mode)
    `Mutating arguments
  = `Dry_run

let mutation_progress_message command arguments =
  match (command, arguments) with
  | "init", [] -> Some "Initializing repository"
  | "archive", _ -> Some "Archiving legacy repository"
  | "reset", _ -> Some "Resetting repository"
  | "checkpoint", [] -> Some "Scanning working tree and recording checkpoint"
  | "restore", [ _ ] -> Some "Restoring checkpoint"
  | "pin", [ _ ] -> Some "Pinning checkpoint"
  | "unpin", [ _ ] -> Some "Unpinning checkpoint"
  | "compact", _ when not (compaction_is_dry_run arguments) ->
      Some "Compacting scratch history"
  | "capsule", "create" :: _ -> Some "Creating capsule revision"
  | "capsule", "edit" :: _ -> Some "Preparing capsule editing"
  | "capsule", "fold" :: _ -> Some "Folding capsule revision"
  | "capsule", "retarget" :: _ -> Some "Retargeting capsule revision"
  | "capsule", "split" :: _ when has_option "--confirm" arguments ->
      Some "Publishing capsule split"
  | "capsule", "combine" :: _ when has_option "--confirm" arguments ->
      Some "Publishing combined capsule"
  | "work", "create" :: _ -> Some "Creating workspace"
  | "work", "enable" :: _ -> Some "Enabling capsule revision"
  | "work", "disable" :: _ -> Some "Disabling capsule"
  | "work", "reorder" :: _ -> Some "Reordering workspace"
  | "work", "materialise" :: _ when not (has_option "--dry-run" arguments) ->
      Some "Materialising workspace"
  | "conflict", "resolve" :: _ -> Some "Recording conflict resolution"
  | "validation", "run" :: _ -> Some "Running validation"
  | "release", "create" :: _ -> Some "Creating release"
  | "git", "archive" :: "create" :: _ -> Some "Archiving Git repository"
  | "git", [ "archive"; "materialize-lineage"; _ ] ->
      Some "Materialising Git lineage"
  | "git", [ "archive"; "exit"; _; "--destination"; _ ] ->
      Some "Exporting Git archive"
  | "git", "archive" :: "adopt" :: _ -> Some "Adopting Git archive"
  | "git", "import" :: _ -> Some "Importing Git history"
  | "git", "export" :: _ -> Some "Exporting Git history"
  | "peer", "publish" :: _ -> Some "Publishing peer projection"
  | "peer", "fetch" :: _ -> Some "Fetching peer publication"
  | "peer", "integrate" :: _ -> Some "Integrating peer capsule"
  | "peer", [ "identity"; "init"; "--key"; _ ] ->
      Some "Creating pinned peer identity"
  | "peer", "contact" :: "add" :: _ -> Some "Adding pinned peer contact"
  | "peer", [ "sync"; "snapshot" ] ->
      Some "Scanning peer synchronization snapshot"
  | "peer", "sync" :: "node" :: "create" :: _ ->
      Some "Creating signed peer synchronization node"
  | "peer", "sync" :: "local" :: _ -> Some "Synchronizing peer tracking"
  | "peer", "reconcile" :: _ -> Some "Reconciling peer snapshots"
  | _ -> None

let open_scratch root =
  let store =
    Store.open_repository ~root |> Result.map_error Store.error_to_string
  in
  store |> Result.map (fun store -> (store, Scratch.open_repository store))

let legacy_demo_mode () =
  (* only the checked-in V1 demonstration fixtures enable this; it never changes
     ordinary CLI behavior or permits old commands on a V2 repository. *)
  match Sys.getenv_opt "YEOKCHAM_LEGACY_DEMO_V1" with
  | Some "1" -> true
  | None | Some _ -> false

let legacy_demo_fixture root =
  legacy_demo_mode ()
  && Sys.file_exists (Filename.concat root ".yeokcham-demo-owned-v1")

let require_v2_root root =
  if legacy_demo_fixture root then
    match Cutover.detect ~root with
    | Error error -> fail Cutover.error_to_string error
    | Ok Cutover.Legacy | Ok (Cutover.Mixed_or_unknown _) -> ()
    | Ok Cutover.Empty | Ok Cutover.V2 | Ok (Cutover.Incomplete _) ->
        fail Fun.id
          "legacy demo mode only permits the checked-in V1 fixture repository"
  else if legacy_demo_mode () then
    fail Fun.id
      "legacy demo mode requires the checked-in V1 fixture ownership marker"
  else
    match Local_service.require_v2 ~root with
    | Ok () -> ()
    | Error error -> fail Local_service.error_to_string error

let run_v2_local_command root name arguments =
  match Local_command.parse ~name ~arguments with
  | Error _ -> exit 2
  | Ok command -> (
      match Local_command.execute ~root command with
      | Error error -> fail Local_service.error_to_string error
      | Ok response -> Local_command.render response |> List.iter print_endline)

let run_v2_or_legacy_demo root name arguments legacy =
  if legacy_demo_fixture root then legacy ()
  else if legacy_demo_mode () then
    fail Fun.id
      "legacy demo mode requires the checked-in V1 fixture ownership marker"
  else run_v2_local_command root name arguments

let initialise_legacy_demo root =
  if not (legacy_demo_fixture root) then
    fail Fun.id
      "legacy demo mode requires the checked-in V1 fixture ownership marker"
  else
    match Cutover.detect ~root with
    | Error error -> fail Cutover.error_to_string error
    | Ok Cutover.Empty -> (
        let store =
          Store.init ~root |> Result.map_error Store.error_to_string
        in
        match store with
        | Error error -> fail Fun.id error
        | Ok store -> (
            let snapshot =
              Snapshot.scan ~root ~store
              |> Result.map_error Snapshot.error_to_string
            in
            match snapshot with
            | Error error -> fail Fun.id error
            | Ok (snapshot, _) -> (
                let scratch = Scratch.open_repository store in
                match
                  Scratch.create_initial scratch ~snapshot ~created_at:(now ())
                with
                | Ok checkpoint -> print_checkpoint checkpoint
                | Error error -> fail Scratch.error_to_string error)))
    | Ok Cutover.V2
    | Ok Cutover.Legacy
    | Ok (Cutover.Mixed_or_unknown _)
    | Ok (Cutover.Incomplete _) ->
        fail Fun.id
          "legacy demo mode only initializes an empty V1 demonstration fixture"

let initialise root =
  if legacy_demo_mode () then initialise_legacy_demo root
  else run_v2_local_command root "init" []

let archive root arguments = run_v2_local_command root "archive" arguments
let reset root arguments = run_v2_local_command root "reset" arguments

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

let legacy_timeline root arguments =
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

let legacy_status root arguments =
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

let legacy_storage root arguments =
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

let legacy_verify root arguments =
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

let timeline root arguments =
  run_v2_or_legacy_demo root "timeline" arguments (fun () ->
      legacy_timeline root arguments)

let status root arguments =
  run_v2_or_legacy_demo root "status" arguments (fun () ->
      legacy_status root arguments)

let storage root arguments =
  run_v2_or_legacy_demo root "storage" arguments (fun () ->
      legacy_storage root arguments)

let verify root arguments =
  run_v2_or_legacy_demo root "verify" arguments (fun () ->
      legacy_verify root arguments)

let history root arguments =
  let scope =
    match arguments with
    | [ "--graph" ] -> Inspection.Combined_history
    | [ "--graph"; "--scratch" ] -> Inspection.Scratch_history
    | [ "--graph"; "--capsules" ] -> Inspection.Capsule_histories
    | [ "--graph"; "--workspace"; workspace ] ->
        Inspection.Workspace_history (workspace_id workspace)
    | [ "--graph"; "--releases" ] -> Inspection.Release_history
    | _ -> exit 2
  in
  match Store.open_repository ~root with
  | Error error -> fail Store.error_to_string error
  | Ok store -> (
      match Inspection.history_graph store ~scope with
      | Error error -> fail Inspection.error_to_string error
      | Ok graph ->
          Inspection.render_history_graph graph |> List.iter print_endline)

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
        with_determinate_progress "Restoring checkpoint" (fun ~report ->
            Scratch.Restore.restore ~on_progress:report scratch ~root ~target
              ~observed_at:timestamp ~created_at:timestamp)
        |> function
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
              with_determinate_progress "Processing compaction cleanup"
                (fun ~report ->
                  Compaction.activate ~on_progress:report ~store scratch ~policy
                    ~now:timestamp)
              |> function
              | Error error -> fail Compaction.error_to_string error
              | Ok execution ->
                  if explain then
                    Compaction.render_explain
                      (Compaction.execution_plan execution)
                    |> List.iter print_endline;
                  print_cleanup (Compaction.execution_cleanup execution))
          | `Resume -> (
              with_determinate_progress "Processing compaction cleanup"
                (fun ~report ->
                  Compaction.resume_cleanup ~on_progress:report ~store scratch)
              |> function
              | Error error -> fail Compaction.error_to_string error
              | Ok report -> print_cleanup report)
          | `Prune -> (
              with_determinate_progress "Processing compaction cleanup"
                (fun ~report ->
                  Compaction.prune ~on_progress:report ~store scratch)
              |> function
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
          (if dry_run then
             Workspace_store.Durable.materialise ~store ~scratch ~root
               ~workspace:(workspace_id workspace) ~observed_at:(now ())
               ~created_at:(now ()) ~dry_run ()
           else
             with_determinate_progress "Materialising workspace" (fun ~report ->
                 Workspace_store.Durable.materialise ~on_progress:report ~store
                   ~scratch ~root ~workspace:(workspace_id workspace)
                   ~observed_at:(now ()) ~created_at:(now ()) ~dry_run ()))
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

let git_archive_id value =
  match Yeokcham_id.Git_archive_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let publication_id value =
  match Yeokcham_id.Publication_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let peer_integration_id value =
  match Yeokcham_id.Peer_integration_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let peer_id value =
  match Yeokcham_id.Peer_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let peer_contact_id value =
  match Yeokcham_id.Peer_contact_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let peer_sync_node_id value =
  match Yeokcham_id.Peer_sync_node_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let hex_of_bytes bytes =
  let hex = "0123456789abcdef" in
  let output = Bytes.create (2 * String.length bytes) in
  String.iteri
    (fun index byte ->
      Bytes.set output (2 * index) hex.[Char.code byte lsr 4];
      Bytes.set output ((2 * index) + 1) hex.[Char.code byte land 15])
    bytes;
  Bytes.unsafe_to_string output

let bytes_of_hex value =
  let hex_value = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (10 + Char.code character - Char.code 'a')
    | 'A' .. 'F' as character -> Some (10 + Char.code character - Char.code 'A')
    | _ -> None
  in
  if String.length value mod 2 <> 0 then None
  else
    let output = Bytes.create (String.length value / 2) in
    let rec decode index =
      if index = String.length value then Some (Bytes.unsafe_to_string output)
      else
        match (hex_value value.[index], hex_value value.[index + 1]) with
        | Some high, Some low ->
            Bytes.set output (index / 2) (Char.chr ((high lsl 4) lor low));
            decode (index + 2)
        | None, _ | _, None -> None
    in
    decode 0

let peer_public_key value =
  match bytes_of_hex value with
  | Some public_key -> public_key
  | None -> fail Fun.id "peer public key must be even-length hexadecimal"

let peer_private_key path =
  let invalid detail = Error ("invalid peer private key file: " ^ detail) in
  if Filename.is_relative path then invalid "path must be absolute"
  else
    try
      let before = Unix.lstat path in
      if before.Unix.st_kind <> Unix.S_REG then invalid "not a regular file"
      else if before.Unix.st_uid <> Unix.getuid () then
        invalid "not owned by the current user"
      else if before.Unix.st_perm land 0o077 <> 0 then
        invalid "accessible by group or other users"
      else if before.Unix.st_size <> 32 then
        invalid "must contain exactly 32 bytes"
      else
        let descriptor =
          Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
        in
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            let after = Unix.fstat descriptor in
            if
              after.Unix.st_kind <> Unix.S_REG
              || before.Unix.st_dev <> after.Unix.st_dev
              || before.Unix.st_ino <> after.Unix.st_ino
            then invalid "changed while opening"
            else
              let bytes = Bytes.create 32 in
              let rec read offset =
                if offset = Bytes.length bytes then Ok ()
                else
                  match
                    Unix.read descriptor bytes offset
                      (Bytes.length bytes - offset)
                  with
                  | 0 -> invalid "ended before 32 bytes"
                  | read_bytes -> read (offset + read_bytes)
              in
              let* () = read 0 in
              Mirage_crypto_ec.Ed25519.priv_of_octets
                (Bytes.unsafe_to_string bytes)
              |> Result.map_error (fun _ -> "invalid peer private key bytes"))
    with Unix.Unix_error (error, operation, path) ->
      invalid
        (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error))

let write_peer_private_key path private_key =
  if Filename.is_relative path then
    Error "peer private key path must be absolute"
  else
    let bytes = Mirage_crypto_ec.Ed25519.priv_to_octets private_key in
    let created = ref false in
    let cleanup () =
      if !created then try Unix.unlink path with Unix.Unix_error _ -> ()
    in
    try
      let descriptor =
        Unix.openfile path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
          0o600
      in
      created := true;
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          Unix.fchmod descriptor 0o600;
          let rec write offset =
            if offset = String.length bytes then Ok ()
            else
              let written =
                Unix.write_substring descriptor bytes offset
                  (String.length bytes - offset)
              in
              if written = 0 then Error "could not write peer private key"
              else write (offset + written)
          in
          write 0)
      |> Result.map_error (fun error ->
          cleanup ();
          error)
    with Unix.Unix_error (error, operation, failed_path) ->
      cleanup ();
      Error
        (Printf.sprintf "could not create peer private key (%s %s: %s)"
           operation failed_path (Unix.error_message error))

let peer_sync_nonce () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Ok (Mirage_crypto_rng.generate Peer_sync.nonce_bytes)
  with _ -> Error "could not obtain peer-sync nonce from the OS CSPRNG"

let print_peer_identity identity =
  Printf.printf "peer=%s\npublic-key=%s\n"
    (Yeokcham_id.Peer_id.to_hex (Peer_sync.peer_id identity))
    (hex_of_bytes (Peer_sync.public_key identity))

let print_peer_endpoint = function
  | Peer_sync.Local_path path -> Printf.printf "endpoint=local:%s\n" path
  | Peer_sync.Ssh { target; root } ->
      Printf.printf "endpoint=ssh:%s:%s\n" target root
  | Peer_sync.Relay path -> Printf.printf "endpoint=relay:%s\n" path

let print_peer_contact contact =
  Printf.printf "contact=%s\nname=%s\npeer=%s\n"
    (Yeokcham_id.Peer_contact_id.to_hex (Peer_sync.contact_id contact))
    (Peer_sync.contact_name contact)
    (Yeokcham_id.Peer_id.to_hex
       (Peer_sync.peer_id (Peer_sync.contact_identity contact)));
  List.iter print_peer_endpoint (Peer_sync.contact_endpoints contact)

let git_adoption_id value =
  match Yeokcham_id.Git_adoption_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let git_lineage_id value =
  match Yeokcham_id.Git_lineage_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Yeokcham_id.parse_error_to_string error

let print_git_archive archive =
  let source_bare =
    match Git.archive_capability archive with
    | None -> "unknown"
    | Some capability -> string_of_bool capability.Git.archive_source_bare
  in
  Printf.printf "archive=%s format=%s refs=%d bundle=%s source-bare=%s\n"
    (Yeokcham_id.Git_archive_id.to_hex (Git.archive_id archive))
    (Git.object_format_to_string (Git.archive_object_format archive))
    (List.length (Git.archive_refs archive))
    (Git.archive_bundle archive |> Snapshot.Content.stored_object_id
   |> Store.Stored_object_id.to_hex)
    source_bare

let show_git_archive archive =
  print_git_archive archive;
  Git.archive_refs archive
  |> List.iter (fun reference ->
      Printf.printf "ref=%s object=%s\n" reference.Git.archive_ref_name
        (Git.object_id_to_hex reference.Git.archive_ref_object))

let empty_adoption_snapshot store =
  let* tree =
    Snapshot.Tree.create [] |> Result.map_error Snapshot.error_to_string
  in
  let* tree =
    Snapshot.Tree.store store tree |> Result.map_error Snapshot.error_to_string
  in
  Snapshot.Snapshot.create ~root:tree
  |> Snapshot.Snapshot.store store
  |> Result.map_error Snapshot.error_to_string

let detached_adoption_checkpoints store ~source ~target =
  let source_checkpoint =
    Scratch.Checkpoint.create_initial ~snapshot:source ~created_at:(now ())
  in
  let* source =
    Scratch.Checkpoint.store store source_checkpoint
    |> Result.map_error Scratch.error_to_string
  in
  let* source_snapshot =
    Snapshot.Snapshot.load store (Scratch.Checkpoint.snapshot source_checkpoint)
    |> Result.map_error Snapshot.error_to_string
  in
  let* target_snapshot =
    Snapshot.Snapshot.load store target
    |> Result.map_error Snapshot.error_to_string
  in
  let* source_state =
    Scratch.State.of_snapshot store source_snapshot
    |> Result.map_error Scratch.error_to_string
  in
  let* target_state =
    Scratch.State.of_snapshot store target_snapshot
    |> Result.map_error Scratch.error_to_string
  in
  let operations = Scratch.State.diff ~from:source_state ~to_:target_state in
  let* replayed =
    Scratch.State.apply source_state operations
    |> Result.map_error Scratch.error_to_string
  in
  if not (Scratch.State.equal replayed target_state) then
    Error "Git adoption checkpoint replay did not reach the selected commit"
  else
    let event =
      Scratch.Event.create ~parent:source
        ~base:(Scratch.Checkpoint.snapshot source_checkpoint)
        ~resulting:target ~operations ~source:Scratch.Explicit
        ~observed_at:(now ())
    in
    let* event =
      Scratch.Event.store store event
      |> Result.map_error Scratch.error_to_string
    in
    let target_checkpoint =
      Scratch.Checkpoint.create ~parent:source ~event ~snapshot:target
        ~created_at:(now ())
    in
    let* target =
      Scratch.Checkpoint.store store target_checkpoint
      |> Result.map_error Scratch.error_to_string
    in
    Ok (source, target)

let print_git_adoption adoption =
  let parent =
    match Git.adoption_parent adoption with
    | None -> "none"
    | Some parent -> Git.object_id_to_hex parent
  in
  Printf.printf
    "adoption=%s archive=%s git-commit=%s parent=%s mapping=%s capsule=%s \
     revision=%s from=%s to=%s\n"
    (Yeokcham_id.Git_adoption_id.to_hex (Git.adoption_id adoption))
    (Yeokcham_id.Git_archive_id.to_hex (Git.adoption_archive adoption))
    (Git.object_id_to_hex (Git.adoption_commit adoption))
    parent
    (Yeokcham_id.Git_mapping_id.to_hex (Git.adoption_mapping adoption))
    (Yeokcham_id.Capsule_id.to_hex (Git.adoption_capsule adoption))
    (Yeokcham_id.Capsule_revision_id.to_hex (Git.adoption_revision adoption))
    (Git.adoption_source adoption
    |> Scratch.Checkpoint_id.stored_object_id |> Store.Stored_object_id.to_hex)
    (Git.adoption_target adoption
    |> Scratch.Checkpoint_id.stored_object_id |> Store.Stored_object_id.to_hex)

let print_git_lineage_node node =
  Printf.printf
    "node=%s commit=%s snapshot=%s transition=%s mapping=%s parents=%s\n"
    (Yeokcham_id.Git_lineage_node_id.to_hex (Git.lineage_node_id node))
    (Git.object_id_to_hex (Git.lineage_node_commit node))
    (Git.lineage_node_snapshot node
    |> Snapshot.Snapshot.stored_object_id |> Store.Stored_object_id.to_hex)
    (Yeokcham_id.Imported_transition_id.to_hex
       (Git.lineage_node_transition node))
    (Yeokcham_id.Git_mapping_id.to_hex (Git.lineage_node_mapping node))
    (Git.lineage_node_parents node
    |> List.map Yeokcham_id.Git_lineage_node_id.to_hex
    |> String.concat ",")

let show_git_lineage store lineage =
  Printf.printf "lineage=%s archive=%s refs=%d\n"
    (Yeokcham_id.Git_lineage_id.to_hex (Git.lineage_id lineage))
    (Yeokcham_id.Git_archive_id.to_hex (Git.lineage_archive lineage))
    (List.length (Git.lineage_refs lineage));
  let seen = Hashtbl.create 16 in
  let rec show_node identity =
    let raw = Yeokcham_id.Git_lineage_node_id.to_bytes identity in
    if Hashtbl.mem seen raw then Ok ()
    else (
      Hashtbl.add seen raw ();
      match Git.load_lineage_node store identity with
      | Error error -> Error (Git.error_to_string error)
      | Ok node ->
          print_git_lineage_node node;
          List.fold_left
            (fun result parent ->
              let* () = result in
              show_node parent)
            (Ok ())
            (Git.lineage_node_parents node))
  in
  let result =
    List.fold_left
      (fun result reference ->
        let* () = result in
        let head =
          match Git.lineage_ref_head reference with
          | None -> "none"
          | Some identity -> Yeokcham_id.Git_lineage_node_id.to_hex identity
        in
        Printf.printf "ref=%s object=%s head=%s\n"
          (Git.lineage_ref_name reference)
          (Git.object_id_to_hex (Git.lineage_ref_object reference))
          head;
        match Git.lineage_ref_head reference with
        | None -> Ok ()
        | Some identity -> show_node identity)
      (Ok ()) (Git.lineage_refs lineage)
  in
  match result with Error error -> fail Fun.id error | Ok () -> ()

let git root arguments =
  match arguments with
  | "archive" :: "create" :: options -> (
      let rec parse repository_option refs = function
        | [] -> (
            match repository_option with
            | Some repository -> (repository, List.rev refs)
            | None -> exit 2)
        | "--repository" :: repository :: rest -> (
            match repository_option with
            | None when not (String.is_empty repository) ->
                parse (Some repository) refs rest
            | None | Some _ -> exit 2)
        | "--ref" :: reference :: rest ->
            parse repository_option (reference :: refs) rest
        | _ -> exit 2
      in
      let repository, refs = parse None [] options in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.archive_repository ~refs Git.default_configuration ~store
              ~repository
          with
          | Error error -> fail Git.error_to_string error
          | Ok archive -> print_git_archive archive))
  | [ "archive"; "list" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Git.list_archives store with
          | Error error -> fail Git.error_to_string error
          | Ok archives -> List.iter print_git_archive archives))
  | [ "archive"; "show"; archive ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Git.load_archive store (git_archive_id archive) with
          | Error error -> fail Git.error_to_string error
          | Ok archive -> show_git_archive archive))
  | [ "archive"; "materialize-lineage"; archive ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.materialize_archive_lineage Git.default_configuration ~store
              ~archive:(git_archive_id archive)
          with
          | Error error -> fail Git.error_to_string error
          | Ok result ->
              Printf.printf "lineage=%s archive=%s nodes=%d\n"
                (Yeokcham_id.Git_lineage_id.to_hex
                   (Git.lineage_id result.Git.lineage))
                (Yeokcham_id.Git_archive_id.to_hex
                   (Git.lineage_archive result.Git.lineage))
                (List.length result.Git.lineage_nodes)))
  | [ "lineage"; "show"; lineage ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Git.load_lineage store (git_lineage_id lineage) with
          | Error error -> fail Git.error_to_string error
          | Ok lineage -> show_git_lineage store lineage))
  | [ "lineage"; "verify"; lineage ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.verify_lineage Git.default_configuration ~store
              (git_lineage_id lineage)
          with
          | Error error -> fail Git.error_to_string error
          | Ok lineage ->
              Printf.printf
                "lineage=%s archive=%s verification=archive-ref-peel\n"
                (Yeokcham_id.Git_lineage_id.to_hex (Git.lineage_id lineage))
                (Yeokcham_id.Git_archive_id.to_hex
                   (Git.lineage_archive lineage))))
  | [ "archive"; "adoption"; "show"; adoption ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match Git.load_adoption store (git_adoption_id adoption) with
          | Error error -> fail Git.error_to_string error
          | Ok adoption -> print_git_adoption adoption))
  | [ "archive"; "exit"; archive; "--destination"; destination ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          match
            Git.exit_archive Git.default_configuration ~store
              ~archive:(git_archive_id archive) ~destination
          with
          | Error error -> fail Git.error_to_string error
          | Ok archive -> print_git_archive archive))
  | "archive" :: "adopt" :: archive :: options -> (
      let rec parse commit parent root_adoption capsule title description =
        function
        | [] -> (
            match
              (commit, parent, root_adoption, capsule, title, description)
            with
            | ( Some commit,
                Some parent,
                false,
                Some capsule,
                Some title,
                Some description ) ->
                (commit, Some parent, capsule, title, description)
            | ( Some commit,
                None,
                true,
                Some capsule,
                Some title,
                Some description ) ->
                (commit, None, capsule, title, description)
            | _ -> exit 2)
        | "--commit" :: value :: rest -> (
            match commit with
            | None ->
                parse
                  (Some (git_object_id value))
                  parent root_adoption capsule title description rest
            | Some _ -> exit 2)
        | "--parent" :: value :: rest -> (
            match parent with
            | None when not root_adoption ->
                parse commit
                  (Some (git_object_id value))
                  root_adoption capsule title description rest
            | None | Some _ -> exit 2)
        | "--root" :: rest when (not root_adoption) && Option.is_none parent ->
            parse commit parent true capsule title description rest
        | "--as-capsule" :: value :: rest -> (
            match capsule with
            | None ->
                parse commit parent root_adoption
                  (Some (capsule_id value))
                  title description rest
            | Some _ -> exit 2)
        | "--title" :: value :: rest -> (
            match title with
            | None ->
                parse commit parent root_adoption capsule (Some value)
                  description rest
            | Some _ -> exit 2)
        | "--description" :: value :: rest -> (
            match description with
            | None ->
                parse commit parent root_adoption capsule title (Some value)
                  rest
            | Some _ -> exit 2)
        | _ -> exit 2
      in
      let commit, parent, capsule, title, description =
        parse None None false None None None options
      in
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let archive = git_archive_id archive in
          match
            Git.import_archive_commit Git.default_configuration ~store ~archive
              ~commit
          with
          | Error error -> fail Git.error_to_string error
          | Ok imported -> (
              let transition = imported.Git.imported_transition in
              let parents = Git.imported_transition_parents transition in
              let parent_import =
                match parent with
                | None ->
                    if parents = [] then Ok None
                    else
                      Error
                        "selected non-root Git commit requires one --parent \
                         direct parent"
                | Some parent ->
                    if
                      List.exists
                        (fun candidate ->
                          String.equal
                            (Git.object_id_raw candidate)
                            (Git.object_id_raw parent)
                          && Git.object_id_format candidate
                             = Git.object_id_format parent)
                        parents
                    then
                      Git.import_archive_commit Git.default_configuration ~store
                        ~archive ~commit:parent
                      |> Result.map Option.some
                      |> Result.map_error Git.error_to_string
                    else
                      Error
                        "selected --parent is not a direct parent of the Git \
                         commit"
              in
              match parent_import with
              | Error error -> fail Fun.id error
              | Ok parent_import -> (
                  let source =
                    match parent_import with
                    | Some imported ->
                        Ok
                          (Git.imported_transition_snapshot
                             imported.Git.imported_transition)
                    | None -> empty_adoption_snapshot store
                  in
                  match source with
                  | Error error -> fail Fun.id error
                  | Ok source -> (
                      let target =
                        Git.imported_transition_snapshot transition
                      in
                      if Snapshot.Snapshot.equal_id source target then
                        fail Fun.id
                          "selected Git change has no byte-exact snapshot \
                           delta; it remains preserved as foreign evidence"
                      else
                        match
                          detached_adoption_checkpoints store ~source ~target
                        with
                        | Error error -> fail Fun.id error
                        | Ok (source, target) -> (
                            let scratch = Scratch.open_repository store in
                            let timestamp = now () in
                            match
                              Capsule_store.Durable.create_from_checkpoints
                                ~store ~scratch ~id:capsule ~title ~description
                                ~dependencies:[] ~evidence:[] ~from:source
                                ~target ~created_at:timestamp
                                ~changed_at:timestamp ()
                            with
                            | Error error ->
                                fail Capsule_store.error_to_string error
                            | Ok resolved -> (
                                let revision =
                                  Capsule_store.Durable.resolved_revision
                                    resolved
                                in
                                let parent_transition, parent_mapping =
                                  match parent_import with
                                  | None -> (None, None)
                                  | Some imported ->
                                      ( Some imported.Git.imported_transition,
                                        Some imported.Git.commit_mapping )
                                in
                                match
                                  Git.record_archive_adoption store ~archive
                                    ~commit ~parent
                                    ~transition:imported.Git.imported_transition
                                    ~mapping:imported.Git.commit_mapping
                                    ~parent_transition ~parent_mapping ~capsule
                                    ~revision:
                                      (Capsule_store.revision_id revision)
                                    ~source ~target
                                with
                                | Error error -> fail Git.error_to_string error
                                | Ok adoption -> print_git_adoption adoption))))
              )))
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

let print_peer_publication publication =
  let identity =
    Yeokcham_id.Publication_id.to_hex (Peer.publication_id publication)
  in
  let objects = List.length (Peer.publication_objects publication) in
  match Peer.publication_target publication with
  | Peer.Capsule_revision target ->
      Printf.printf
        "publication=%s kind=capsule source-capsule=%s source-revision=%s \
         source-snapshot=%s target-snapshot=%s objects=%d\n"
        identity
        (Yeokcham_id.Capsule_id.to_hex
           (Peer.capsule_target_source_capsule target))
        (Yeokcham_id.Capsule_revision_id.to_hex
           (Peer.capsule_target_source_revision target))
        (Peer.capsule_target_source_snapshot target
        |> Snapshot.Snapshot.stored_object_id |> Store.Stored_object_id.to_hex)
        (Peer.capsule_target_result_snapshot target
        |> Snapshot.Snapshot.stored_object_id |> Store.Stored_object_id.to_hex)
        objects
  | Peer.Release target ->
      Printf.printf
        "publication=%s kind=release source-release=%s base-snapshot=%s \
         final-snapshot=%s objects=%d\n"
        identity
        (Yeokcham_id.Release_id.to_hex
           (Peer.release_target_source_release target))
        (Peer.release_target_base target
        |> Snapshot.Snapshot.stored_object_id |> Store.Stored_object_id.to_hex)
        (Peer.release_target_final_snapshot target
        |> Snapshot.Snapshot.stored_object_id |> Store.Stored_object_id.to_hex)
        objects

let print_peer_integration integration =
  Printf.printf
    "integration=%s publication=%s capsule=%s revision=%s from=%s to=%s\n"
    (Yeokcham_id.Peer_integration_id.to_hex (Peer.integration_id integration))
    (Yeokcham_id.Publication_id.to_hex
       (Peer.integration_publication integration))
    (Yeokcham_id.Capsule_id.to_hex (Peer.integration_capsule integration))
    (Yeokcham_id.Capsule_revision_id.to_hex
       (Peer.integration_revision integration))
    (Peer.integration_source integration
    |> Scratch.Checkpoint_id.stored_object_id |> Store.Stored_object_id.to_hex)
    (Peer.integration_target integration
    |> Scratch.Checkpoint_id.stored_object_id |> Store.Stored_object_id.to_hex)

let parse_peer_sync_local_options arguments =
  let rec loop destination contact destination_identity source_key head tracking
      = function
    | [] -> (
        match
          ( destination,
            contact,
            destination_identity,
            source_key,
            head,
            tracking )
        with
        | ( Some destination,
            Some contact,
            Some destination_identity,
            Some source_key,
            Some head,
            Some tracking ) ->
            Ok
              ( destination,
                peer_contact_id contact,
                peer_id destination_identity,
                source_key,
                peer_sync_node_id head,
                tracking )
        | _ ->
            Error
              "peer sync local requires --to, --contact, \
               --destination-identity, --source-key, --head, and --tracking")
    | "--to" :: value :: rest when Option.is_none destination ->
        loop (Some value) contact destination_identity source_key head tracking
          rest
    | "--contact" :: value :: rest when Option.is_none contact ->
        loop destination (Some value) destination_identity source_key head
          tracking rest
    | "--destination-identity" :: value :: rest
      when Option.is_none destination_identity ->
        loop destination contact (Some value) source_key head tracking rest
    | "--source-key" :: value :: rest when Option.is_none source_key ->
        loop destination contact destination_identity (Some value) head tracking
          rest
    | "--head" :: value :: rest when Option.is_none head ->
        loop destination contact destination_identity source_key (Some value)
          tracking rest
    | "--tracking" :: value :: rest when Option.is_none tracking ->
        loop destination contact destination_identity source_key head
          (Some value) rest
    | _ -> Error "invalid or duplicated peer sync local option"
  in
  loop None None None None None None arguments

let parse_peer_sync_node_options arguments =
  let rec loop identity key snapshot parents = function
    | [] -> (
        match (identity, key, snapshot) with
        | Some identity, Some key, Some snapshot ->
            Ok
              ( peer_id identity,
                key,
                snapshot_id snapshot,
                List.rev_map peer_sync_node_id parents )
        | _ ->
            Error
              "peer sync node create requires --identity, --key, and --snapshot"
        )
    | "--identity" :: value :: rest when Option.is_none identity ->
        loop (Some value) key snapshot parents rest
    | "--key" :: value :: rest when Option.is_none key ->
        loop identity (Some value) snapshot parents rest
    | "--snapshot" :: value :: rest when Option.is_none snapshot ->
        loop identity key (Some value) parents rest
    | "--parent" :: value :: rest ->
        loop identity key snapshot (value :: parents) rest
    | _ -> Error "invalid or duplicated peer sync node option"
  in
  loop None None None [] arguments

let print_peer_sync_outcome outcome decision =
  Printf.printf "offered=%d\nrequested=%d\ntransferred=%d\n"
    outcome.Yeokcham_exchange_store.offered
    outcome.Yeokcham_exchange_store.requested
    (List.length outcome.Yeokcham_exchange_store.transferred);
  match decision with
  | Peer_sync.Tracking_advanced node ->
      Printf.printf "tracking=advanced\nhead=%s\n"
        (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id node))
  | Peer_sync.Tracking_already_current node ->
      Printf.printf "tracking=already-current\nhead=%s\n"
        (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id node))
  | Peer_sync.Tracking_diverged { current; received } ->
      Printf.printf "tracking=diverged\ncurrent=%s\nreceived=%s\n"
        (Yeokcham_id.Peer_sync_node_id.to_hex current)
        (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id received))

let peer root arguments =
  match arguments with
  | [ "identity"; "init"; "--key"; key ] -> (
      let identity, private_key =
        Peer_sync.generate () |> function
        | Ok value -> value
        | Error error -> fail Peer_sync.error_to_string error
      in
      match write_peer_private_key key private_key with
      | Error error -> fail Fun.id error
      | Ok () -> (
          match Store.open_repository ~root with
          | Error error ->
              (try Unix.unlink key with Unix.Unix_error _ -> ());
              fail Store.error_to_string error
          | Ok store -> (
              match Peer_sync.store_identity store identity with
              | Error error ->
                  (try Unix.unlink key with Unix.Unix_error _ -> ());
                  fail Peer_sync.error_to_string error
              | Ok _ ->
                  print_peer_identity identity;
                  Printf.printf "key=%s\n" key)))
  | [ "identity"; "show"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer_sync.load_identity store (peer_id identity)
          |> Result.map_error Peer_sync.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok identity -> print_peer_identity identity))
  | [
   "contact"; "add"; name; "--peer-public-key"; public_key; "--direct"; endpoint;
  ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let identity =
            Peer_sync.make_identity ~public_key:(peer_public_key public_key)
            |> Result.map_error Peer_sync.error_to_string
          in
          match identity with
          | Error error -> fail Fun.id error
          | Ok identity -> (
              Peer_sync.make_contact ~name ~identity
                ~endpoints:[ Peer_sync.Local_path endpoint ]
              |> Result.map_error Peer_sync.error_to_string
              |> function
              | Error error -> fail Fun.id error
              | Ok contact -> (
                  match Peer_sync.store_contact store contact with
                  | Error error -> fail Peer_sync.error_to_string error
                  | Ok _ -> print_peer_contact contact))))
  | [
   "contact";
   "add";
   name;
   "--peer-public-key";
   public_key;
   "--ssh";
   target;
   "--remote-root";
   remote_root;
  ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          let identity =
            Peer_sync.make_identity ~public_key:(peer_public_key public_key)
            |> Result.map_error Peer_sync.error_to_string
          in
          match identity with
          | Error error -> fail Fun.id error
          | Ok identity -> (
              Peer_sync.make_contact ~name ~identity
                ~endpoints:[ Peer_sync.Ssh { target; root = remote_root } ]
              |> Result.map_error Peer_sync.error_to_string
              |> function
              | Error error -> fail Fun.id error
              | Ok contact -> (
                  match Peer_sync.store_contact store contact with
                  | Error error -> fail Peer_sync.error_to_string error
                  | Ok _ -> print_peer_contact contact))))
  | [ "contact"; "show"; contact ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer_sync.load_contact store (peer_contact_id contact)
          |> Result.map_error Peer_sync.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok contact -> print_peer_contact contact))
  | [ "sync"; "snapshot" ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Snapshot.scan ~root ~store
          |> Result.map_error Snapshot.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (snapshot, _) ->
              Printf.printf "snapshot=%s\n"
                (snapshot |> Snapshot.Snapshot.stored_object_id
               |> Store.Stored_object_id.to_hex)))
  | "sync" :: "node" :: "create" :: options -> (
      match parse_peer_sync_node_options options with
      | Error error -> fail Fun.id error
      | Ok (identity_id, key, snapshot, parents) -> (
          match (Store.open_repository ~root, peer_private_key key) with
          | Error error, _ -> fail Store.error_to_string error
          | _, Error error -> fail Fun.id error
          | Ok store, Ok private_key -> (
              match Peer_sync.load_identity store identity_id with
              | Error error -> fail Peer_sync.error_to_string error
              | Ok identity -> (
                  Peer_sync.make_sync_node ~author:identity ~private_key
                    ~snapshot ~parents
                  |> Result.map_error Peer_sync.error_to_string
                  |> function
                  | Error error -> fail Fun.id error
                  | Ok node -> (
                      match Peer_sync.store_sync_node store node with
                      | Error error -> fail Peer_sync.error_to_string error
                      | Ok _ ->
                          Printf.printf "sync-node=%s\n"
                            (Yeokcham_id.Peer_sync_node_id.to_hex
                               (Peer_sync.sync_node_id node)))))))
  | "sync" :: "local" :: options -> (
      match parse_peer_sync_local_options options with
      | Error error -> fail Fun.id error
      | Ok
          ( destination_root,
            contact_id,
            destination_identity_id,
            source_key,
            head,
            tracking_name ) -> (
          match
            ( Store.open_repository ~root,
              Store.open_repository ~root:destination_root,
              peer_private_key source_key )
          with
          | Error error, _, _ | _, Error error, _ ->
              fail Store.error_to_string error
          | _, _, Error error -> fail Fun.id error
          | Ok source, Ok destination, Ok source_private_key -> (
              match
                ( Peer_sync.load_contact destination contact_id,
                  Peer_sync.load_identity destination destination_identity_id,
                  peer_sync_nonce () )
              with
              | Error error, _, _ | _, Error error, _ ->
                  fail Peer_sync.error_to_string error
              | _, _, Error error -> fail Fun.id error
              | Ok contact, Ok destination_identity, Ok nonce -> (
                  Peer_sync.sync_local ~source ~destination ~contact
                    ~destination_identity ~source_private_key ~nonce
                    ~transcript:("peer-sync:" ^ tracking_name)
                    ~tracking_name ~head ()
                  |> Result.map_error Peer_sync.error_to_string
                  |> function
                  | Error error -> fail Fun.id error
                  | Ok (outcome, decision) ->
                      print_peer_sync_outcome outcome decision))))
  | [
   "reconcile";
   "--identity";
   identity;
   "--key";
   key;
   "--local";
   local;
   "--remote";
   remote;
  ] -> (
      match (Store.open_repository ~root, peer_private_key key) with
      | Error error, _ -> fail Store.error_to_string error
      | _, Error error -> fail Fun.id error
      | Ok store, Ok private_key -> (
          Peer_sync.load_identity store (peer_id identity)
          |> Result.map_error Peer_sync.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok identity -> (
              Peer_sync.reconcile store ~author:identity ~private_key
                ~local:(peer_sync_node_id local)
                ~remote:(peer_sync_node_id remote)
              |> Result.map_error Peer_sync.error_to_string
              |> function
              | Error error -> fail Fun.id error
              | Ok (Peer_sync.Fast_forward node) ->
                  Printf.printf "reconciliation=fast-forward\nhead=%s\n"
                    (Yeokcham_id.Peer_sync_node_id.to_hex
                       (Peer_sync.sync_node_id node))
              | Ok (Peer_sync.Already_current node) ->
                  Printf.printf "reconciliation=already-current\nhead=%s\n"
                    (Yeokcham_id.Peer_sync_node_id.to_hex
                       (Peer_sync.sync_node_id node))
              | Ok (Peer_sync.Merged node) ->
                  Printf.printf "reconciliation=merged\nhead=%s\n"
                    (Yeokcham_id.Peer_sync_node_id.to_hex
                       (Peer_sync.sync_node_id node))
              | Ok (Peer_sync.Conflict conflict) ->
                  Printf.printf "reconciliation=conflict\nconflict=%s\n"
                    (Yeokcham_id.Peer_sync_conflict_id.to_hex
                       (Peer_sync.conflict_id conflict)))))
  | [ "publish"; "capsule"; "--capsule"; capsule; "--revision"; revision ]
  | [ "publish"; "capsule"; "--revision"; revision; "--capsule"; capsule ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.publish_capsule_revision store ~capsule:(capsule_id capsule)
            ~revision:(revision_id revision)
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok publication -> print_peer_publication publication))
  | [ "publish"; "release"; "--release"; release ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.publish_release store (release_id release)
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok publication -> print_peer_publication publication))
  | [ "show"; publication ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.load_publication store (publication_id publication)
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok publication -> print_peer_publication publication))
  | [ "fetch"; "--from"; source; "--publication"; publication ]
  | [ "fetch"; "--publication"; publication; "--from"; source ] -> (
      match
        (Store.open_repository ~root, Store.open_repository ~root:source)
      with
      | Error error, _ | _, Error error -> fail Store.error_to_string error
      | Ok destination, Ok source -> (
          with_determinate_progress "Reconciling peer objects" (fun ~report ->
              Peer.fetch_local ~on_progress:report ~source ~destination
                (publication_id publication))
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (outcome, publication) ->
              print_peer_publication publication;
              Printf.printf "offered=%d requested=%d transferred=%d\n"
                outcome.Yeokcham_exchange_store.offered
                outcome.Yeokcham_exchange_store.requested
                (List.length outcome.Yeokcham_exchange_store.transferred)))
  | [
      "fetch";
      "--ssh";
      target;
      "--remote-root";
      remote_root;
      "--publication";
      publication;
    ]
  | [
      "fetch";
      "--publication";
      publication;
      "--ssh";
      target;
      "--remote-root";
      remote_root;
    ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok destination -> (
          Peer.fetch_ssh ~destination ~target ~remote_root
            ~publication:(publication_id publication)
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (outcome, publication) ->
              print_peer_publication publication;
              Printf.printf "offered=%d requested=%d transferred=%d\n"
                outcome.Yeokcham_exchange_store.offered
                outcome.Yeokcham_exchange_store.requested
                (List.length outcome.Yeokcham_exchange_store.transferred)))
  | [ "serve"; "--publication"; publication ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.serve store
            ~publication:(publication_id publication)
            ~input:stdin ~output:stdout
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok () -> ()))
  | [
      "integrate";
      publication;
      "--as-capsule";
      capsule;
      "--title";
      title;
      "--description";
      description;
    ]
  | [
      "integrate";
      publication;
      "--as-capsule";
      capsule;
      "--description";
      description;
      "--title";
      title;
    ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.integrate_capsule store
            ~publication:(publication_id publication)
            ~capsule:(capsule_id capsule) ~title ~description
            ~created_at:(now ())
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok integration -> print_peer_integration integration))
  | [ "integration"; "show"; integration ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store -> (
          Peer.load_integration store (peer_integration_id integration)
          |> Result.map_error Peer.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok integration -> print_peer_integration integration))
  | _ -> exit 2

let usage ?(status = 2) () =
  Progress.stop_active ();
  let message =
    "usage: yeokcham \
     <init|archive|reset|status|checkpoint|timeline|history|restore|pin|unpin|compact|watch|capsule|work|conflict|validation|release|storage|verify|git|peer> \
     [--root PATH] [--no-progress] ..."
  in
  if status = 0 then print_endline message else prerr_endline message;
  exit status

let () =
  Sys.catch_break true;
  try
    match Array.to_list Sys.argv with
    | [ _; ("--help" | "-h" | "help") ] -> usage ~status:0 ()
    | _ :: command :: raw_arguments -> (
        let root, no_progress, arguments = parse_cli_options raw_arguments in
        progress_enabled := Progress.enabled ~no_progress;
        let execute () =
          match command with
          | "init" when arguments = [] -> initialise root
          | "archive" -> archive root arguments
          | "reset" -> reset root arguments
          | "status" -> status root arguments
          | "checkpoint" when arguments = [] ->
              require_v2_root root;
              checkpoint root
          | "timeline" -> timeline root arguments
          | "restore" ->
              require_v2_root root;
              restore root arguments
          | "pin" ->
              require_v2_root root;
              change_pin root arguments true
          | "unpin" ->
              require_v2_root root;
              change_pin root arguments false
          | "compact" ->
              require_v2_root root;
              compact root arguments
          | "watch" ->
              require_v2_root root;
              watch root arguments
          | "capsule" ->
              require_v2_root root;
              capsule root arguments
          | "work" ->
              require_v2_root root;
              workspace root arguments
          | "conflict" ->
              require_v2_root root;
              conflict root arguments
          | "validation" ->
              require_v2_root root;
              validation root arguments
          | "release" ->
              require_v2_root root;
              release root arguments
          | "storage" -> storage root arguments
          | "verify" -> verify root arguments
          | "history" ->
              require_v2_root root;
              history root arguments
          | "git" ->
              require_v2_root root;
              git root arguments
          | "peer" ->
              require_v2_root root;
              peer root arguments
          | _ -> usage ()
        in
        match mutation_progress_message command arguments with
        | None -> execute ()
        | Some message ->
            Progress.with_progress ~enabled:!progress_enabled message execute)
    | _ -> usage ()
  with Sys.Break -> print_endline "watch stopped"
