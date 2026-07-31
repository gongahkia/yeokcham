module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Compaction = Paengi_compaction
module Capsule = Paengi_capsule
module Capsule_store = Paengi_capsule_store
module Workspace = Paengi_workspace
module Workspace_store = Paengi_workspace_store
module Validation = Paengi_validation

let now () = Int64.of_float (Unix.gettimeofday ())

let fail render error =
  prerr_endline (render error);
  exit 2

let checkpoint_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Scratch.Checkpoint_id.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let capsule_id value =
  match Paengi_id.Capsule_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Paengi_id.parse_error_to_string error

let revision_id value =
  match Paengi_id.Capsule_revision_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Paengi_id.parse_error_to_string error

let workspace_id value =
  match Paengi_id.Workspace_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Paengi_id.parse_error_to_string error

let snapshot_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Snapshot.Snapshot.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let conflict_id value =
  match Paengi_id.Conflict_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Paengi_id.parse_error_to_string error

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
          retain_output = function
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
                  retain_output )
            | _ -> exit 2)
        | "--snapshot" :: value :: rest ->
            parse
              (Some (snapshot_id value))
              executable arguments working_directory timeout_ms max_stdout_bytes
              max_stderr_bytes environment environment_policy retain_output rest
        | "--exec" :: value :: rest ->
            parse snapshot (Some value) arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment environment_policy
              retain_output rest
        | "--arg" :: value :: rest ->
            parse snapshot executable (value :: arguments) working_directory
              timeout_ms max_stdout_bytes max_stderr_bytes environment
              environment_policy retain_output rest
        | "--cwd" :: value :: rest -> (
            match parse_working_directory value with
            | None -> exit 2
            | Some working_directory ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes max_stderr_bytes environment
                  environment_policy retain_output rest)
        | "--timeout-ms" :: value :: rest -> (
            match try Some (Int64.of_string value) with Failure _ -> None with
            | Some value ->
                parse snapshot executable arguments working_directory value
                  max_stdout_bytes max_stderr_bytes environment
                  environment_policy retain_output rest
            | None -> exit 2)
        | "--max-stdout-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | Some value ->
                parse snapshot executable arguments working_directory timeout_ms
                  value max_stderr_bytes environment environment_policy
                  retain_output rest
            | None -> exit 2)
        | "--max-stderr-bytes" :: value :: rest -> (
            match int_of_string_opt value with
            | Some value ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes value environment environment_policy
                  retain_output rest
            | None -> exit 2)
        | "--env" :: value :: rest -> (
            match parse_environment value with
            | None -> exit 2
            | Some entry ->
                parse snapshot executable arguments working_directory timeout_ms
                  max_stdout_bytes max_stderr_bytes (entry :: environment)
                  environment_policy retain_output rest)
        | "--inherit-env" :: rest ->
            parse snapshot executable arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment Validation.Inherit
              retain_output rest
        | "--retain-output" :: rest ->
            parse snapshot executable arguments working_directory timeout_ms
              max_stdout_bytes max_stderr_bytes environment environment_policy
              true rest
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
            retain_output ) =
        parse None None [] [] 60000L 65536 65536 [] Validation.Empty false
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
          Validation.run ~store ~snapshot ~command ~command_index:0
            ~observed_at:(now ()) ()
          |> Result.map_error Validation.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok (evidence, object_id) ->
              let status =
                match Validation.evidence_status evidence with
                | Validation.Passed -> "passed"
                | Validation.Failed -> "failed"
                | Validation.Timed_out -> "timed-out"
                | Validation.Execution_error -> "execution-error"
              in
              Printf.printf "evidence=%s object=%s status=%s\n"
                (Paengi_id.Validation_id.to_hex
                   (Validation.evidence_id evidence))
                (Store.Stored_object_id.to_hex object_id)
                status))
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
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (_, scratch) -> (
      match Scratch.timeline scratch ~limit () with
      | Error error -> fail Scratch.error_to_string error
      | Ok entries ->
          List.iter
            (fun entry ->
              let checkpoint = entry.Scratch.checkpoint in
              let retention =
                entry.Scratch.effective_retention
                |> List.map Scratch.retention_reason_to_string
                |> String.concat ","
              in
              Printf.printf "%d %s %Ld %s\n" entry.Scratch.depth
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id
                      entry.Scratch.logical_id))
                (Scratch.Checkpoint.created_at checkpoint)
                retention)
            entries)

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
      ^ Paengi_id.Capsule_revision_id.to_hex (revision_link_revision link)
  | Capsule_store.Combined_from links ->
      "combined-from="
      ^ String.concat ","
          (List.map
             (fun (link : Capsule_store.revision_link) ->
               Paengi_id.Capsule_revision_id.to_hex
                 (revision_link_revision link))
             links)

let print_plan_output (capsule, revision) =
  Printf.printf
    "output capsule=%s revision=%s base=%s expected=%s operations=%d \
     dependencies=%d provenance=%s\n"
    (Paengi_id.Capsule_id.to_hex (Capsule_store.capsule_id capsule))
    (Paengi_id.Capsule_revision_id.to_hex (Capsule_store.revision_id revision))
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
    (Paengi_id.Capsule_id.to_hex (revision_link_capsule source))
    (Paengi_id.Capsule_revision_id.to_hex (revision_link_revision source))
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
        (Paengi_id.Capsule_id.to_hex capsule)
        (Paengi_id.Capsule_revision_id.to_hex revision))
    (Capsule_store.Durable.split_plan_composition_order plan);
  print_boundary_pins (Capsule_store.Durable.split_plan_boundary_pins plan)

let print_combine_plan plan =
  let sources = Capsule_store.Durable.combine_plan_sources plan in
  Printf.printf "plan combine sources=%d outputs=1\n" (List.length sources);
  List.iteri
    (fun index source ->
      Printf.printf "source[%d] capsule=%s revision=%s object=%s\n" index
        (Paengi_id.Capsule_id.to_hex (revision_link_capsule source))
        (Paengi_id.Capsule_revision_id.to_hex (revision_link_revision source))
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

let capsule root arguments =
  match arguments with
  | "create" :: "--current" :: options -> (
      let rec parse id title description = function
        | [] -> (
            match (id, title, description) with
            | Some id, Some title, Some description -> (id, title, description)
            | _ -> exit 2)
        | "--id" :: value :: rest ->
            parse (Some (capsule_id value)) title description rest
        | "--title" :: value :: rest -> parse id (Some value) description rest
        | "--description" :: value :: rest -> parse id title (Some value) rest
        | _ -> exit 2
      in
      let id, title, description = parse None None None options in
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let timestamp = now () in
          Capsule_store.Durable.create_from_current ~store ~scratch ~root ~id
            ~title ~description ~dependencies:[] ~evidence:[]
            ~created_at:timestamp ~changed_at:timestamp ()
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
                (Paengi_id.Capsule_id.to_hex id)
                (Paengi_id.Capsule_revision_id.to_hex
                   (Capsule_store.revision_id revision))
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id source))
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id target))))
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
                      (Paengi_id.Capsule_id.to_hex
                         (Capsule_store.capsule_id
                            (Capsule_store.Durable.resolved_capsule left)))
                      (Paengi_id.Capsule_id.to_hex
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
                          (Paengi_id.Capsule_id.to_hex id)
                          (Paengi_id.Capsule_revision_id.to_hex
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
                    (Paengi_id.Capsule_id.to_hex capsule)
                    (Paengi_id.Capsule_revision_id.to_hex
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
                (Paengi_id.Capsule_id.to_hex (Capsule_store.capsule_id capsule))
                (Paengi_id.Capsule_revision_id.to_hex
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
                    (Paengi_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_id revision)))
                revisions))
  | _ -> exit 2

let print_workspace resolved =
  let workspace = Workspace_store.resolved_workspace resolved in
  let revision = Workspace_store.resolved_revision resolved in
  let current = Workspace_store.resolved_current_ref resolved in
  Printf.printf "workspace=%s revision=%s generation=%Ld base=%s\n"
    (Paengi_id.Workspace_id.to_hex (Workspace_store.workspace_id workspace))
    (Paengi_id.Workspace_revision_id.to_hex
       (Workspace_store.revision_id revision))
    (Workspace_store.current_generation current)
    (Store.Stored_object_id.to_hex
       (Snapshot.Snapshot.stored_object_id
          (Workspace_store.revision_base revision)));
  Workspace_store.revision_selected revision
  |> List.iteri (fun index link ->
      Printf.printf "selected[%d] capsule=%s revision=%s object=%s\n" index
        (Paengi_id.Capsule_id.to_hex (Capsule_store.revision_link_capsule link))
        (Paengi_id.Capsule_revision_id.to_hex
           (Capsule_store.revision_link_revision link))
        (Store.Stored_object_id.to_hex
           (Capsule_store.revision_link_object link)));
  match Workspace_store.current_latest_attempt current with
  | None -> ()
  | Some (attempt, object_id) ->
      Printf.printf "latest-attempt=%s object=%s\n"
        (Paengi_id.Workspace_attempt_id.to_hex attempt)
        (Store.Stored_object_id.to_hex object_id)

let print_workspace_order order =
  Workspace.revisions order
  |> List.iteri (fun index selected ->
      Printf.printf "order[%d] capsule=%s revision=%s\n" index
        (Paengi_id.Capsule_id.to_hex selected.Workspace.capsule)
        (Paengi_id.Capsule_revision_id.to_hex selected.Workspace.revision));
  Workspace.edges order
  |> List.iter (fun edge ->
      Printf.printf "edge before=%s after=%s reasons=%s\n"
        (Paengi_id.Capsule_revision_id.to_hex edge.Workspace.before)
        (Paengi_id.Capsule_revision_id.to_hex edge.Workspace.after)
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
                (Paengi_id.Workspace_attempt_id.to_hex
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
                    (Paengi_id.Conflict_id.to_hex
                       (Workspace_store.conflict_id conflict))
                    (Paengi_id.Capsule_id.to_hex
                       (Workspace_store.conflict_capsule conflict))
                    (Paengi_id.Capsule_revision_id.to_hex
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
                (Paengi_id.Conflict_id.to_hex
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

let usage () =
  prerr_endline
    "usage: paengi \
     <init|checkpoint|timeline|restore|pin|unpin|compact|watch|capsule|work|conflict|validation> \
     [--root PATH] ...";
  exit 2

let () =
  Sys.catch_break true;
  try
    match Array.to_list Sys.argv with
    | _ :: command :: arguments -> (
        let root, arguments = parse_root arguments in
        match command with
        | "init" when arguments = [] -> initialise root
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
        | _ -> usage ())
    | _ -> usage ()
  with Sys.Break -> print_endline "watch stopped"
